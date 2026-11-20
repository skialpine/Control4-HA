-- One Coordinator-owned read-only dataset. Template promises carry concurrent
-- callers; only metadata/pages leave this owner, never another persistent cache.
local codec = require("ha.codec")
local deferred = require("deferred")
local contract = require("ha.contract")
local Choices = require("ha.choices")
local metrics = require("ha.performance").shared
require("lib.utils")
local Catalog = {}
Catalog.__index = Catalog
local MAX_ROWS, MAX_BYTES, MAX_PAGES, PAGE_BYTES = 5000, 1048576, 64, 16384
local function integer(value, maximum)
  return type(value) == "number" and value >= 0 and value == math.floor(value) and value <= maximum
end
local function revision(value)
  return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$") ~= nil
end

function Catalog.new(request, native, decorate, supplement)
  return setmetatable(
    { request = request, native = native, decorate = decorate, supplement = supplement, generation = 0 },
    Catalog
  )
end
function Catalog:invalidate(kind)
  metrics:finish(self.timing, "retired")
  self.generation = self.generation + 1
  self.verified = nil
  local pending = self.pending
  self.pending = nil
  if pending then
    pending:reject({ kind = kind or "disconnected", boundary = "catalog" })
  end
end
function Catalog:_metadata(family)
  local snapshot = self.snapshot
  return {
    revision = snapshot.revision,
    total = #snapshot.indices[family or "all"],
    source = snapshot.source,
    family = family,
  }
end
function Catalog:refresh(force)
  if self.pending then
    self.pending.refresh_native = self.pending.refresh_native or force == true
    return self.pending
  end
  local pending = deferred.new()
  if not force and self.snapshot and self.snapshot.source == "native" and self.verified == self.generation then
    pending:resolve(self:_metadata())
    return pending
  end
  pending.refresh_native = force == true
  self.pending = pending
  self.timing = metrics:start(self.snapshot and "catalog.refresh" or "catalog.cold")
  local generation, rows, seen, bytes = self.generation, codec.array({}), {}, 0
  local function active()
    return self.pending == pending and self.generation == generation
  end
  local function fail(kind)
    if active() then
      self.verified = nil
      self.pending = nil
      metrics:finish(self.timing, kind == "timeout" and "timeout" or "failed")
      pending:reject({ kind = kind, boundary = "catalog" })
    end
  end
  local function append(values)
    if not codec.isArray(values) then
      return false
    end
    for _, value in ipairs(values) do
      if not contract.catalogRow(value) or seen[value.entity_id] then
        return false
      end
      local size = #codec.encode(value)
      if size > PAGE_BYTES - 512 then
        return false
      end
      bytes = bytes + size
      if #rows >= MAX_ROWS or bytes > MAX_BYTES then
        return false
      end
      seen[value.entity_id] = true
      rows[#rows + 1] = value
    end
    return true
  end
  local function complete()
    self.verified, self.pending = generation, nil
    metrics:finish(self.timing, "ok")
    pending:resolve(self:_metadata())
  end
  local function readNative(callback)
    local ok, work = pcall(self.native)
    if not ok or type(work) ~= "table" or type(work.next) ~= "function" then
      fail("filtered_read_failed")
      return
    end
    work:next(function(values)
      if not active() then
        return
      end
      if not codec.isArray(values) or #values > MAX_ROWS then
        fail("invalid_filtered_catalog")
        return
      end
      local seen = {}
      for _, row in ipairs(values) do
        if not contract.catalogRow(row) or seen[row.entity_id] then
          fail("invalid_filtered_catalog")
          return
        end
        seen[row.entity_id] = true
      end
      callback(values)
    end, function(error)
      fail(error.kind or "filtered_read_failed")
    end)
  end
  local function decorate(values, callback, native)
    local ok, work = pcall(self.decorate, values, active, native)
    if not ok or type(work) ~= "table" or type(work.next) ~= "function" then
      fail("invalid_endpoint_metadata")
      return
    end
    work:next(callback, function(failure)
      fail(failure.kind or "filtered_registry_failed")
    end)
  end
  local function publish(source, upstreamRevision, pages, eligibilityVersion)
    if not active() then
      return
    end
    local function publishValues(values)
      if not active() then
        return
      end
      local indices = { all = {}, light = {}, switch = {}, quick_lighting = {}, quick_light = {}, quick_switch = {} }
      if #values > MAX_ROWS then
        fail("invalid_endpoint_metadata")
        return
      end
      table.sort(values, function(a, b)
        return a.entity_id < b.entity_id
      end)
      local bytes = 0
      for index, item in ipairs(values) do
        local size = #codec.encode(item)
        bytes = bytes + size
        if size > PAGE_BYTES - 512 or bytes > MAX_BYTES then
          fail("invalid_endpoint_metadata")
          return
        end
        for _, family in ipairs(item.families) do
          indices[family][#indices[family] + 1] = index
        end
        if #item.families > 0 then
          indices.all[#indices.all + 1] = index
          local preferred = Choices.suggestedFamily(item)
          if preferred == "light" or preferred == "switch" then
            indices.quick_lighting[#indices.quick_lighting + 1] = index
            local category = indices["quick_" .. preferred]
            category[#category + 1] = index
          end
        end
      end
      local fingerprint = C4:Hash(
        "SHA256",
        (upstreamRevision or "native") .. ":" .. tostring(eligibilityVersion or 0) .. codec.encode(values)
      )
      if not self.snapshot or self.snapshot.revision ~= fingerprint then
        self.snapshot = {
          source = source,
          revision = fingerprint,
          upstreamRevision = upstreamRevision,
          rows = values,
          upstreamRows = upstreamRevision and rows or nil,
          indices = indices,
          pages = pages,
          eligibilityVersion = eligibilityVersion,
        }
      end
      complete()
    end
    local function ready(values)
      if not active() then
        return
      end
      if source == "companion" and self.supplement then
        readNative(function(nativeRows)
          decorate(nativeRows, function(filtered)
            if active() then
              publishValues(Choices.merge(values, filtered))
            end
          end, true)
        end)
      else
        publishValues(values)
      end
    end
    if eligibilityVersion == 1 then
      local ok, values = pcall(Choices.apply, rows)
      if ok and values then
        ready(values)
      else
        fail("invalid_endpoint_metadata")
      end
      return
    end
    decorate(rows, ready, source == "native")
  end
  local function native()
    readNative(function(values)
      if not append(values) then
        fail("invalid_filtered_catalog")
        return
      end
      publish("native")
    end)
  end
  local expected, total, pages, eligibilityVersion
  local function page(index, full)
    if not active() then
      return
    end
    local known = not full
        and index == 1
        and self.snapshot
        and self.snapshot.source == "companion"
        and self.snapshot.upstreamRevision
      or expected
    local sent = pcall(self.request, {
      type = "call_service",
      domain = "ha_gesture_bridge",
      service = "get_devices",
      service_data = { page = index, revision = known or nil },
      return_response = true,
    }, function(ok, result)
      if not active() then
        return
      end
      if not ok then
        if index == 1 and result.kind == "not_found" then
          native()
        else
          fail(result.kind or "rejected")
        end
        return
      end
      local response = codec.isObject(result) and result.response
      if codec.isObject(response) and response.version ~= nil and response.version ~= 1 then
        fail("unsupported_catalog_version")
        return
      end
      if
        not codec.isObject(response)
        or response.version ~= 1
        or not revision(response.revision)
        or response.page ~= index
        or not integer(response.total, MAX_ROWS)
        or not integer(response.pages, MAX_PAGES)
        or type(response.unchanged) ~= "boolean"
        or (response.eligibility_version ~= nil and not contract.integer(response.eligibility_version))
      then
        fail("invalid_catalog")
        return
      end
      if response.unchanged then
        if
          index ~= 1
          or not known
          or response.revision ~= known
          or response.entities ~= nil
          or response.total ~= #(self.snapshot.upstreamRows or self.snapshot.rows)
          or response.pages ~= self.snapshot.pages
        then
          fail("invalid_revision_confirmation")
          return
        end
        if response.eligibility_version ~= self.snapshot.eligibilityVersion then
          -- A producer upgrade or downgrade may preserve its row hash. Do not
          -- reuse descriptors accepted under a different eligibility contract.
          self.verified = nil
          page(1, true)
          return
        end
        if
          response.eligibility_version == 1
          and (not self.supplement or (not pending.refresh_native and self.verified == generation))
        then
          complete()
          return
        end
        rows = self.snapshot.upstreamRows or self.snapshot.rows
        publish("companion", known, self.snapshot.pages, response.eligibility_version)
        return
      end
      if index == 1 then
        if
          self.snapshot
          and (
            response.revision ~= self.snapshot.upstreamRevision
            or response.eligibility_version ~= self.snapshot.eligibilityVersion
          )
        then
          self.verified = nil
        end
        expected, total, pages, eligibilityVersion =
          response.revision, response.total, response.pages, response.eligibility_version
      end
      if
        response.revision ~= expected
        or response.total ~= total
        or response.pages ~= pages
        or response.eligibility_version ~= eligibilityVersion
        or (total == 0 and (pages ~= 0 or index ~= 1))
        or (total > 0 and (pages < 1 or pages > total))
        or not append(response.entities)
        or #rows > total
        or (total > 0 and #response.entities == 0)
      then
        fail("invalid_catalog")
        return
      end
      if index < pages then
        page(index + 1)
      elseif #rows ~= total then
        fail("incomplete_catalog")
      else
        publish("companion", expected, pages, eligibilityVersion)
      end
    end)
    if not sent then
      fail("request_failed")
    end
  end
  page(1)
  return pending
end
function Catalog:read(rev, cursor, family)
  if not self.snapshot or self.verified ~= self.generation then
    return nil, "catalog_unverified"
  end
  if rev ~= self.snapshot.revision then
    return nil, "revision_changed"
  end
  local indices = self.snapshot.indices[family or "all"]
  if not indices then
    return nil, "invalid_family"
  end
  cursor = cursor or 1
  if not integer(cursor, #indices + 1) or cursor < 1 then
    return nil, "invalid_cursor"
  end
  local values, bytes, index = codec.array({}), 512, cursor
  while indices[index] and #values < 50 do
    local value = self.snapshot.rows[indices[index]]
    local size = #codec.encode(value)
    if bytes + size > PAGE_BYTES then
      break
    end
    values[#values + 1] = value
    bytes, index = bytes + size, index + 1
  end
  local result = self:_metadata(family)
  result.entities = values
  result.cursor, result.next_cursor = cursor, indices[index] and index or codec.null
  return result
end
function Catalog:choice(id, family, expectedRevision)
  if not self.snapshot or self.verified ~= self.generation then
    return nil, "catalog_unverified"
  end
  if expectedRevision and expectedRevision ~= self.snapshot.revision then
    return nil, "revision_changed"
  end
  for _, index in ipairs(self.snapshot.indices[family] or {}) do
    local row = self.snapshot.rows[index]
    if row.entity_id == id then
      return row
    end
  end
  return nil, "unsupported_endpoint"
end

return Catalog
