-- One Coordinator-owned read-only dataset. Template promises carry concurrent
-- callers; only metadata/pages leave this owner, never another persistent cache.
local codec = require("ha.codec")
local deferred = require("deferred")
local contract = require("ha.contract")
local Choices = require("ha.choices")
local NativeCatalog = require("ha.native-catalog")
local operations = require("ha.operations")
local metrics = require("ha.performance").shared
require("lib.utils")
local Catalog = {}
Catalog.__index = Catalog
local MAX_ROWS, MAX_BYTES, MAX_PAGES, PAGE_BYTES = 5000, 4194304, 256, 16384
local NATIVE_BROWSE_MS = 30000
local function integer(value, maximum)
  return type(value) == "number" and value >= 0 and value == math.floor(value) and value <= maximum
end
local function revision(value)
  return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$") ~= nil
end

local function copyFields(source, omitted)
  local copy = codec.object({})
  for key, value in pairs(source) do
    if key ~= omitted then
      copy[key] = value
    end
  end
  return copy
end

local function revisionRow(item, encoded)
  local choice = item.attributes.device_choice
  local load = choice and choice.source_load
  local liveLoad = codec.isObject(load) and load.available ~= nil
  if item.available == nil and not liveLoad then
    return encoded
  end
  local stable = copyFields(item, "available")
  if liveLoad then
    stable.attributes = copyFields(item.attributes)
    stable.attributes.device_choice = copyFields(choice)
    stable.attributes.device_choice.source_load = copyFields(load, "available")
  end
  return codec.encode(stable)
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
    local age = C4:GetTime() - self.snapshot.checkedAt
    if age >= 0 and age < NATIVE_BROWSE_MS then
      pending:resolve(self:_metadata())
      return pending
    end
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
  local function append(values, limit)
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
      if #rows >= (limit or MAX_ROWS) or bytes > MAX_BYTES then
        return false
      end
      seen[value.entity_id] = true
      rows[#rows + 1] = value
    end
    return true
  end
  local function complete()
    self.verified, self.pending = generation, nil
    self.snapshot.checkedAt = C4:GetTime()
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
      if not codec.isArray(values) or #values > NativeCatalog.maxCandidates then
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
  local function requestPage(index, known, callback)
    local sent = pcall(self.request, {
      type = "call_service",
      domain = "ha_gesture_bridge",
      service = "get_devices",
      service_data = { page = index, revision = known or nil },
      return_response = true,
    }, callback)
    if not sent then
      fail("request_failed")
    end
  end
  local function publish(source, upstreamRevision, pages, eligibilityVersion, nativeRevision)
    if not active() then
      return
    end
    local function publishValues(values, nativeValues)
      if not active() then
        return
      end
      local indices = { all = {}, light = {}, switch = {}, quick_lighting = {}, quick_light = {}, quick_switch = {} }
      table.sort(values, function(a, b)
        return a.entity_id < b.entity_id
      end)
      local bytes, revisionRows, gestureChoices, buttonChoices, byId = 0, {}, {}, {}, {}
      for index, item in ipairs(values) do
        byId[item.entity_id] = index
        local encoded = codec.encode(item)
        local size = #encoded
        bytes = bytes + size
        if size > PAGE_BYTES - 512 or bytes > MAX_BYTES then
          fail("invalid_endpoint_metadata")
          return
        end
        revisionRows[index] = revisionRow(item, encoded)
        for _, family in ipairs(item.families) do
          indices[family][#indices[family] + 1] = index
        end
        if #item.families > 0 then
          if #indices.all == MAX_ROWS then
            fail("invalid_endpoint_metadata")
            return
          end
          indices.all[#indices.all + 1] = index
          local gesture = Choices.gestureEntity(item)
          if gesture then
            -- A button-only companion row and a native load are two ways to
            -- find one control, even when the companion hides its load.
            local choices = item.domain == "event" and buttonChoices or gestureChoices
            local previous = choices[gesture]
            if previous == nil then
              choices[gesture] = item
            elseif previous then
              local canonical = Choices.endpointKeys(item)
              local _, keys = Choices.endpointKeys(previous)
              if not keys[canonical] then
                choices[gesture] = false
              elseif item.attributes.device_choice and not previous.attributes.device_choice then
                choices[gesture] = item
              end
            end
          end
          local preferred = Choices.suggestedFamily(item)
          if preferred == "light" or preferred == "switch" then
            indices.quick_lighting[#indices.quick_lighting + 1] = index
            local category = indices["quick_" .. preferred]
            category[#category + 1] = index
          end
        end
      end
      -- The companion's transfer revision includes load availability. Keep it
      -- for coherent paging, and hash the local draft from structural data.
      local prefix = source .. ":" .. tostring(eligibilityVersion or 0)
      local fingerprint = C4:Hash("SHA256", prefix .. "[" .. table.concat(revisionRows, ",") .. "]")
      if not self.snapshot or self.snapshot.revision ~= fingerprint then
        self.snapshot = {
          source = source,
          gestureChoices = gestureChoices,
          buttonChoices = buttonChoices,
          revision = fingerprint,
          indices = indices,
          byId = byId,
          eligibilityVersion = eligibilityVersion,
        }
      end
      self.snapshot.rows, self.snapshot.upstreamRows, self.snapshot.pages =
        values, upstreamRevision and rows or nil, pages
      local hiddenLoads = {}
      for _, item in ipairs(nativeValues or {}) do
        if Choices.hiddenMigrationLoad(item) then
          hiddenLoads[item.entity_id] = item
        end
      end
      self.snapshot.hiddenLoads = hiddenLoads
      self.snapshot.upstreamRevision = upstreamRevision
      self.snapshot.nativeRevision = nativeRevision
      complete()
    end
    local function ready(values)
      if not active() then
        return
      end
      if source == "companion" and self.supplement then
        readNative(function(nativeRows)
          decorate(nativeRows, function(filtered)
            if not active() then
              return
            end
            local function finish()
              publishValues(Choices.merge(values, filtered), filtered)
            end
            if not nativeRevision then
              return finish()
            end
            -- The helper's proof must surround the native state and registry reads.
            requestPage(1, upstreamRevision, function(ok, result)
              if not active() then
                return
              end
              if not ok then
                return fail(result.kind or "rejected")
              end
              local proof = codec.isObject(result) and result.response
              if
                not codec.isObject(proof)
                or proof.version ~= 1
                or proof.eligibility_version ~= eligibilityVersion
                or proof.page ~= 1
                or proof.revision ~= upstreamRevision
                or proof.native_revision ~= nativeRevision
                or proof.pages ~= pages
                or proof.total ~= #rows
                or proof.unchanged ~= true
                or proof.entities ~= nil
              then
                return fail("revision_changed")
              end
              finish()
            end)
          end, true)
        end)
      else
        publishValues(values, source == "native" and values or nil)
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
      if not append(values, NativeCatalog.maxCandidates) then
        fail("invalid_filtered_catalog")
        return
      end
      publish("native")
    end)
  end
  local expected, total, pages, eligibilityVersion, nativeRevision
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
    requestPage(index, known, function(ok, result)
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
        or (response.native_revision ~= nil and not revision(response.native_revision))
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
          and (
            not self.supplement
            or (
              self.verified == generation
              and (
                (response.native_revision ~= nil and response.native_revision == self.snapshot.nativeRevision)
                or (
                  response.native_revision == nil
                  and self.snapshot.nativeRevision == nil
                  and not pending.refresh_native
                )
              )
            )
          )
        then
          complete()
          return
        end
        rows = self.snapshot.upstreamRows or self.snapshot.rows
        publish("companion", known, self.snapshot.pages, response.eligibility_version, response.native_revision)
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
        expected, total, pages, eligibilityVersion, nativeRevision =
          response.revision, response.total, response.pages, response.eligibility_version, response.native_revision
      end
      if
        response.revision ~= expected
        or response.total ~= total
        or response.pages ~= pages
        or response.eligibility_version ~= eligibilityVersion
        or response.native_revision ~= nativeRevision
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
        publish("companion", expected, pages, eligibilityVersion, nativeRevision)
      end
    end)
  end
  page(1)
  return pending
end
function Catalog:hasVerifiedSnapshot(expectedRevision)
  return self.snapshot ~= nil
    and self.verified == self.generation
    and (expectedRevision == nil or self.snapshot.revision == expectedRevision)
end

function Catalog:gestureChoice(gesture, row)
  if self:hasVerifiedSnapshot() then
    local match = self.snapshot.gestureChoices[gesture]
    if row and row.domain == "event" or not row and match == nil then
      local buttons = self.snapshot.buttonChoices
      match = buttons and buttons[gesture]
    end
    if match and not row then
      return match.entity_id
    elseif match then
      local canonical = Choices.endpointKeys(row)
      local _, keys = Choices.endpointKeys(match)
      return keys[canonical] and row.entity_id or nil
    end
  end
end

function Catalog:read(rev, cursor, family)
  if not self:hasVerifiedSnapshot() then
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
  if not self:hasVerifiedSnapshot() then
    return nil, "catalog_unverified"
  end
  if expectedRevision and expectedRevision ~= self.snapshot.revision then
    return nil, "revision_changed"
  end
  local row = self.snapshot.rows[self.snapshot.byId[id]]
  if row then
    for _, eligible in ipairs(row.families) do
      if eligible == family then
        return row
      end
    end
  end
  return nil, "unsupported_endpoint"
end

-- Resolve a saved legacy target using the same verified visible light wrapper
-- preferred by discovery when it fits the installed driver's family.
function Catalog:exactLoadChoice(entity, family)
  if not self:hasVerifiedSnapshot() or not contract.loadDomain(entity) then
    return
  end
  local hidden = self.snapshot.hiddenLoads[entity]
  local eligibility = hidden and Choices.hiddenMigrationLoad(hidden)
  if eligibility and eligibility[family] then
    local wrapper = eligibility.wrappers and eligibility.wrappers[family]
    if wrapper then
      return wrapper, wrapper.entity_id, Choices.standaloneRegistry(wrapper)
    end
    return hidden
  end
  local match
  for _, index in ipairs(self.snapshot.indices[family] or {}) do
    local row = self.snapshot.rows[index]
    local device = row.attributes.device_choice
    local load = device and device.source_load
    if (load and load.entity_id == entity) or (not device and row.entity_id == entity) then
      if match then
        return
      end
      match = row
    end
  end
  return match
end

function Catalog:legacySwitchChoice(device, event, revision)
  if not self:hasVerifiedSnapshot() or revision ~= self.snapshot.revision then
    return nil
  end
  local match
  for _, index in ipairs(self.snapshot.indices.switch) do
    local row = self.snapshot.rows[index]
    local choice = row.attributes.device_choice
    if
      choice
      and choice.device_id == device
      and (not choice.gesture_entity_id or choice.gesture_entity_id == event)
    then
      if match then
        return nil
      end
      match = row.entity_id
    end
  end
  return match
end

function Catalog:endpointKeys(identities)
  if not self:hasVerifiedSnapshot() then
    return nil
  end
  local keys = {}
  for _, value in ipairs(identities) do
    keys[value] = true
  end
  -- Discovery has already resolved same-entity aliases. Match against the
  -- input identities so related choices cannot authorize an unrelated load.
  for _, row in ipairs(self.snapshot.rows) do
    local _, aliases = Choices.endpointKeys(row)
    for _, value in ipairs(identities) do
      if aliases[value] then
        for alias in pairs(aliases) do
          keys[alias] = true
        end
        break
      end
    end
  end
  return keys
end

-- Use the exact load. The fourth result distinguishes a registry miss from
-- a row without verified registry evidence.
function Catalog:loadDetails(entity, includeHidden)
  if not self:hasVerifiedSnapshot() then
    return
  end
  local hidden = includeHidden and self.snapshot.hiddenLoads[entity]
  if hidden then
    local registry, observed = Choices.standaloneRegistry(hidden)
    return hidden.name, hidden.area_name, registry, observed
  end
  for _, row in ipairs(self.snapshot.rows) do
    local choice = row.attributes.device_choice
    local source = choice and choice.source_load
    if row.entity_id == entity and not choice then
      local registry, observed = Choices.standaloneRegistry(row)
      return row.name, row.area_name, registry, observed
    elseif source and source.entity_id == entity then
      local registry = contract.registryId(source.registry_id) and source.registry_id or nil
      return source.name, choice.area, registry, registry ~= nil
    end
  end
end

function Catalog:verifyLoadRegistry(entity, registry, unregistered, sourceEntity, sourceRegistry)
  local result = deferred.new()
  local generation = self.generation
  if
    not contract.loadDomain(entity)
    or (unregistered == true and registry ~= nil)
    or (unregistered ~= true and not contract.registryId(registry))
    or (
      sourceEntity
      and (unregistered or not contract.loadDomain(sourceEntity) or not contract.registryId(sourceRegistry))
    )
  then
    result:resolve(false)
    return result
  end
  local args = { registry_id = registry, source_entity = sourceEntity, source_registry_id = sourceRegistry }
  self.request(
    { type = "config/entity_registry/get_entries", entity_ids = codec.array({ entity, sourceEntity }) },
    function(ok, response)
      local match = false
      if ok and generation == self.generation and codec.isObject(response) then
        if unregistered == true then
          match = response[entity] == codec.null
        else
          match = operations.registryMatches(response, entity, args)
            and (not sourceEntity or Choices.matchesLightWrapper(response[entity], sourceEntity, sourceRegistry))
        end
      end
      result:resolve(match)
    end
  )
  return result
end

return Catalog
