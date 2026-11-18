-- Explicit selected-device commissioning on the shared Coordinator provider.
local codec = require("ha.codec")
local contract = require("ha.contract")
local ids = require("ha.identities")
local project = require("ha.commissioning-project")
local companions = require("lib.companions")
local persist = require("lib.persist")
local deferred = require("deferred")
local metrics = require("ha.performance").shared
local Commissioning = {}
Commissioning.__index = Commissioning
local KEY, MAX_BATCH, MAX_RECORDS = "HA.Commissioning", 16, 1000

local function failure(kind)
  local work = deferred.new()
  work:reject({ kind = kind })
  return work
end

local function failureKind(value)
  return type(value) == "table" and value.kind or "project_unavailable"
end

local function attention(kind)
  return { status = "needs_attention", reason = kind }
end

local function validName(value)
  return type(value) == "string" and #value <= 128 and value:match("%S") ~= nil and not value:find("%c")
end

local function requested(input)
  if type(input) ~= "table" or not contract.catalogQuery(codec.object({ revision = input.revision })) then
    return nil
  end
  local choices = input.choices
  if not input.revision or type(choices) ~= "table" or #choices < 1 or #choices > MAX_BATCH then
    return nil
  end
  local result = { revision = input.revision, choices = {} }
  for index in pairs(choices) do
    if not contract.integer(index) or index > #choices then
      return nil
    end
  end
  for _, choice in ipairs(choices) do
    if
      type(choice) ~= "table"
      or type(choice.choice_id) ~= "string"
      or #choice.choice_id < 1
      or #choice.choice_id > 255
      or choice.choice_id:find("%c")
      or not project.file(choice.family)
      or not contract.integer(choice.room_id)
      or (choice.name ~= nil and not validName(choice.name))
    then
      return nil
    end
    result.choices[#result.choices + 1] = {
      choice_id = choice.choice_id,
      family = choice.family,
      room_id = choice.room_id,
      name = choice.name,
    }
  end
  return result
end

local function endpointKeys(row)
  local choice = row.attributes.device_choice
  local source = choice and choice.source_load
  local canonical = source and source.entity_id or row.entity_id
  local keys = { [canonical] = true, [row.entity_id] = true }
  for _, alias in ipairs(row.entity_aliases or {}) do
    keys[alias] = true
  end
  return canonical, keys
end

local function receipts()
  local raw = persist:get(KEY, nil, true)
  local saved = raw == nil and codec.object({}) or codec.storedObject(raw)
  assert(saved, "Invalid commissioning receipts")
  for endpoint, row in pairs(saved) do
    assert(
      #endpoint <= 255
        and codec.isObject(row)
        and type(row.operation) == "string"
        and (row.phase == "pending" or row.phase == "added" or row.phase == "complete")
        and (row.phase == "pending" or contract.integer(row.device_id))
        and project.file(row.family)
        and contract.integer(row.room_id)
        and validName(row.name),
      "Invalid commissioning receipt"
    )
  end
  return saved
end

local function save(saved)
  persist:set(KEY, codec.encode(saved), true)
  persist:flush(KEY)
end

function Commissioning.new(catalog, configure)
  assert(type(configure) == "function", "A commissioning configuration adapter is required")
  return setmetatable({ catalog = catalog, configure = configure, serial = 0 }, Commissioning)
end

function Commissioning:rooms()
  return project.rooms()
end

function Commissioning:_item(choice, rooms, devices, saved)
  local row = self.catalog:choice(choice.choice_id, choice.family)
  if not row then
    return nil, "unsupported_endpoint"
  end
  local roomName = project.roomName(rooms, choice.room_id)
  if not roomName then
    return nil, "room_changed"
  end
  local physical = row.attributes.device_choice
  local name = choice.name or (physical and physical.name) or row.name
  if not validName(name) then
    return nil, "name_required"
  end
  local canonical, keys = endpointKeys(row)
  local gesture = physical and physical.gesture_entity_id
  local item = {
    choice = choice,
    domain = row.domain,
    endpoint = canonical,
    keys = keys,
    -- A prototype may store the gesture entity even when its load was selected.
    -- Several loads can share that gesture entity, so it only flags legacy review.
    legacy_gesture = contract.entity(gesture) and gesture:match("^event%.") and gesture or nil,
    source_name = (physical and physical.name) or row.name,
    name = name,
    room_id = choice.room_id,
    room_name = roomName,
    family = choice.family,
  }
  for key in pairs(keys) do
    if saved[key] then
      if item.receipt_key then
        return nil, "multiple_receipts"
      end
      item.receipt_key = key
    end
  end
  item.receipt_key = item.receipt_key or canonical
  item.decision, item.device_id, item.reason =
    project.decide(item, devices, saved[item.receipt_key], tonumber(C4:GetDeviceID()))
  if item.decision == "add" and choice.family == "light" and not project.lightPackageReady(devices) then
    item.decision, item.reason = "review", "light_package_required"
  end
  item.display_name, item.display_family = name, choice.family
  item.display_room_id, item.display_room_name = choice.room_id, roomName
  if item.decision == "keep" or (item.decision == "review" and item.device_id) then
    for _, device in ipairs(devices) do
      if device.id == item.device_id then
        item.display_name = device.name or name
        item.display_family = device.family or choice.family
        item.display_room_id = device.room_id or choice.room_id
        item.display_room_name = project.roomName(rooms, device.room_id) or ""
        break
      end
    end
  end
  return item
end

local function view(item)
  return {
    choice_id = item.choice.choice_id,
    source_name = item.source_name,
    family = item.display_family,
    name = item.display_name,
    room_id = item.display_room_id,
    room_name = item.display_room_name,
    decision = item.decision,
    device_id = item.device_id,
    reason = item.reason,
  }
end

function Commissioning:_items(input)
  local rooms, devices, saved = self:rooms(), project.inventory(), receipts()
  local items, selected, proposed = {}, {}, {}
  for _, choice in ipairs(input.choices) do
    local item, problem = self:_item(choice, rooms, devices, saved)
    if not item then
      return nil, problem
    end
    for key in pairs(item.keys) do
      if selected[key] then
        return nil, "duplicate_selection"
      end
      selected[key] = true
    end
    local label = tostring(item.display_room_id) .. "\0" .. item.display_name:lower()
    if proposed[label] and (item.decision == "add" or proposed[label] == "add") then
      return nil, "duplicate_name"
    end
    proposed[label] = item.decision
    items[#items + 1] = item
  end
  return items
end

function Commissioning:preview(input)
  local safe = requested(input)
  if not safe or self.destroyed or self.running then
    return failure(not safe and "invalid_request" or self.destroyed and "retired" or "busy")
  end
  self.plan = nil
  self.serial = self.serial + 1
  local sequence = self.serial
  local span = metrics:start("commissioning.preview")
  local pending = self.catalog:refresh():next(function(metadata)
    if self.destroyed or self.serial ~= sequence then
      return failure("retired")
    end
    if metadata.revision ~= safe.revision then
      return failure("revision_changed")
    end
    local items, problem = self:_items(safe)
    if not items then
      return failure(problem)
    end
    local id = C4:Hash("SHA256", tostring(self) .. ":" .. C4:GetTime() .. ":" .. sequence)
    local rows = {}
    for _, item in ipairs(items) do
      rows[#rows + 1] = view(item)
    end
    self.plan = { id = id, input = safe, items = items }
    return { id = id, items = rows }
  end)
  return pending:next(function(result)
    metrics:finish(span, "ok")
    return result
  end, function(err)
    metrics:finish(span, "failed")
    return failure(failureKind(err))
  end)
end

local function sameSelection(approved, actual)
  return actual
    and approved.endpoint == actual.endpoint
    and approved.domain == actual.domain
    and approved.source_name == actual.source_name
    and approved.legacy_gesture == actual.legacy_gesture
    and approved.receipt_key == actual.receipt_key
    and approved.room_name == actual.room_name
    and codec.encode(approved.keys) == codec.encode(actual.keys)
end

local function same(approved, actual)
  return sameSelection(approved, actual) and codec.encode(view(approved)) == codec.encode(view(actual))
end

function Commissioning:_bind(item, need, deviceId, revision)
  if self.destroyed then
    return attention("retired")
  end
  local device = project.device(deviceId)
  if not device or not project.matches(device, item) or device.selected == nil then
    return attention("project_changed")
  end
  local coordinator = tonumber(C4:GetDeviceID())
  if
    not (device.provider == 0 or device.provider == coordinator)
    or (device.selected ~= "" and not item.keys[device.selected])
  then
    return attention("project_changed")
  end
  if device.provider == 0 then
    need.consumer = device.input
    local span = metrics:start("commissioning.bind")
    local ok, bound = pcall(companions.bindSelected, companions, need, deviceId, function()
      return contract.provider(deviceId) == coordinator
    end, true)
    metrics:finish(span, ok and bound and "ok" or "failed")
    if not ok or not bound then
      return attention("bind_unconfirmed")
    end
  end
  if item.keys[device.selected] then
    return { device_id = deviceId }
  end
  local work = self.configure(deviceId, {
    choice_id = item.choice.choice_id,
    source_name = item.source_name,
    family = item.family,
    revision = revision,
    prepare = true,
  })
  if type(work) ~= "table" or type(work.next) ~= "function" then
    return attention("configuration_unconfirmed")
  end
  return work:next(function()
    if self.destroyed then
      return attention("retired")
    end
    local confirmed = project.device(deviceId)
    if
      not confirmed
      or not project.matches(confirmed, item)
      or confirmed.provider ~= coordinator
      or confirmed.selected ~= item.choice.choice_id
    then
      return attention("configuration_unconfirmed")
    end
    return { device_id = deviceId }
  end, function(err)
    return attention(failureKind(err))
  end)
end

function Commissioning:_deploy(item, operation)
  if item.decision == "keep" then
    return { status = "kept", device_id = item.device_id }
  end
  local key, saved = item.receipt_key, receipts()
  if not saved[key] then
    local count = 0
    for _ in pairs(saved) do
      count = count + 1
    end
    if count >= MAX_RECORDS then
      return attention("receipt_limit")
    end
  end
  local need = {
    binding = ids.coordinatorBinding,
    class = ids.coordinatorClass,
    file = project.file(item.family),
    name = item.name,
    room = item.room_id,
  }
  local record = codec.object({
    operation = operation,
    phase = item.device_id and "added" or "pending",
    name = item.name,
    family = item.family,
    room_id = item.room_id,
    device_id = item.device_id,
  })
  saved[key] = record
  save(saved)
  local function remember(added)
    local current = receipts()
    local receipt = current[key]
    if receipt and receipt.operation == operation and receipt.phase == "pending" then
      if added and contract.integer(added.id) then
        receipt.device_id, receipt.phase = added.id, "added"
      elseif not added then
        -- Callback ID zero is an affirmative failure. Missing callbacks never
        -- enter this branch and leave the persisted request unresolved.
        current[key] = nil
      end
      save(current)
    end
  end
  local function complete(outcome)
    if outcome.reason then
      return outcome
    end
    local deviceId = outcome.device_id
    local current = receipts()
    local receipt = current[key]
    if not receipt or receipt.operation ~= operation or receipt.device_id ~= deviceId then
      return attention("project_changed")
    end
    receipt.phase = "complete"
    save(current)
    return { status = item.decision == "resume" and "resumed" or "added", device_id = deviceId }
  end
  local function bind(deviceId)
    if self.destroyed then
      return attention("retired")
    end
    return self.catalog
      :refresh()
      :next(function(metadata)
        if item.decision == "add" and item.family == "light" then
          local added = project.device(deviceId)
          if not added or added.file ~= need.file then
            return attention("light_add_unverified")
          end
        end
        local current = self:_item(item.choice, self:rooms(), project.inventory(), receipts())
        if not sameSelection(item, current) or current.decision ~= "resume" or current.device_id ~= deviceId then
          return attention("preview_changed")
        end
        return self:_bind(item, need, deviceId, metadata.revision)
      end, function(err)
        return attention(failureKind(err))
      end)
      :next(complete)
  end
  if item.device_id then
    return bind(item.device_id)
  end
  local span = metrics:start("commissioning.add")
  local ok, work = pcall(companions.addSelected, companions, need, function(added)
    -- A late receipt only records evidence. A retired operation never binds
    -- or initializes that device; the next approved preview reconciles it.
    pcall(remember, added)
  end)
  if not ok then
    metrics:finish(span, "failed")
    return attention("add_unconfirmed")
  end
  return work:next(function(added)
    metrics:finish(span, added and "ok" or "rejected")
    remember(added)
    if not added then
      return attention("add_rejected")
    end
    if self.destroyed then
      return attention("retired")
    end
    return bind(added.id):next(function(result)
      if result.reason then
        return result
      end
      return companions:afterAdd():next(function()
        return result
      end)
    end)
  end, function()
    metrics:finish(span, "timeout")
    return attention("add_unconfirmed")
  end)
end

function Commissioning:execute(id)
  local plan = self.plan
  if self.destroyed or self.running or not plan or id ~= plan.id then
    return failure(self.destroyed and "retired" or self.running and "busy" or "preview_required")
  end
  for _, item in ipairs(plan.items) do
    if item.decision == "review" then
      return failure("review_required")
    end
  end
  self.plan, self.running = nil, true
  local span = metrics:start("commissioning.execute")
  local pending = self.catalog:refresh():next(function(metadata)
    if self.destroyed then
      return failure("retired")
    end
    if metadata.revision ~= plan.input.revision then
      return failure("revision_changed")
    end
    local actual = self:_items(plan.input)
    for index, approved in ipairs(plan.items) do
      if not actual or not same(approved, actual[index]) then
        return failure("preview_changed")
      end
    end
    local stopped, index = false, 0
    return deferred
      .map(plan.items, function(approved)
        index = index + 1
        if stopped then
          local skipped = deferred.new()
          skipped:resolve({ choice_id = approved.choice.choice_id, status = "not_started" })
          return skipped
        end
        -- The first item can use the preflight snapshot. Director callbacks
        -- and preparation can change eligibility by the time we start others.
        local verified
        if index == 1 then
          verified = deferred.new()
          verified:resolve(actual[1])
        else
          verified = self.catalog:refresh():next(function()
            return self:_item(approved.choice, self:rooms(), project.inventory(), receipts())
          end)
        end
        return verified
          :next(function(item)
            if self.destroyed then
              return attention("retired")
            end
            if not same(approved, item) then
              return attention("preview_changed")
            end
            return self:_deploy(item, id)
          end)
          :next(function(result)
            result.choice_id = approved.choice.choice_id
            stopped = result.status == "needs_attention"
            return result
          end, function(err)
            stopped = true
            return { choice_id = approved.choice.choice_id, status = "needs_attention", reason = failureKind(err) }
          end)
      end)
      :next(function(result)
        return { items = result, complete = not stopped }
      end)
  end)
  return pending:next(function(result)
    self.running = false
    metrics:finish(span, result.complete and "ok" or "failed")
    return result
  end, function(err)
    self.running = false
    metrics:finish(span, "failed")
    return failure(failureKind(err))
  end)
end

function Commissioning:destroy()
  self.destroyed, self.plan = true, nil
end

return Commissioning
