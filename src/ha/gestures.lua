-- Register declared programming events and consume only current live occurrences.
local codec = require("ha.codec")
local contract = require("ha.contract")
local gestureContract = require("ha.gesture-contract")
local metrics = require("ha.performance").shared
local events = require("lib.events")
local LRU = require("lib.lru")

local Gestures = {}
Gestures.__index = Gestures

function Gestures.new(options)
  local self =
    setmetatable({ options = options or {}, registered = {}, held = {}, sequence = 0, generation = 0 }, Gestures)
  -- Remove retired tap rows from Composer while reserving their persisted IDs.
  local stored = events:getEvents()
  for namespace, records in pairs(stored) do
    if type(namespace) == "string" and namespace:match("^HA Gesture ") and type(records) == "table" then
      for key, record in pairs(records) do
        if
          gestureContract.retiredTap(key)
          and type(record) == "table"
          and type(record.eventId) == "number"
          and record.eventId >= 10
          and record.eventId <= 999
        then
          C4:DeleteEvent(record.eventId)
        end
      end
    end
  end
  local saved = gestureContract.savedLightEvents(self.options.savedLightEvents and self.options.savedLightEvents())
  for key, id in pairs(saved or {}) do
    if gestureContract.retiredTap(key) then
      C4:DeleteEvent(id)
    end
  end
  return self
end

function Gestures:cleanup(button)
  if button then
    if not self.held[button] then
      return
    end
    self.held[button] = nil
  elseif next(self.held) then
    self.held = {}
  else
    return
  end
  if self.options.onCleanup then
    self.options.onCleanup(button)
  end
end

function Gestures:lost(entity)
  if entity and entity ~= self.entity then
    return
  end
  self.generation = self.generation + 1
  self.baseline, self.capabilitySummary = false, nil
  self:cleanup()
end

function Gestures:bind(config)
  self:lost()
  local entity = config and config.gesture_entity_id
  local control = config and config.control_id
  local device = config and config.device_id
  if not (contract.entity(entity) and entity:match("^event%.") and gestureContract.identity(control)) then
    entity, control, device = nil, nil, nil
  end
  if control ~= self.control or device ~= self.device then
    self.session, self.revision, self.sequence, self.registered = nil, nil, 0, {}
    self.retired = LRU:new(32)
  end
  self.entity, self.control, self.device = entity, control, device
end

function Gestures:declare(definitions)
  local changed = {}
  for event, definition in pairs(definitions) do
    local existing = self.registered[event]
    if gestureContract.programmable(definition) and (not existing or existing.name ~= definition.name) then
      changed[#changed + 1] = event
    end
  end
  if #changed == 0 then
    return true
  end
  table.sort(changed)
  local namespace = "HA Gesture " .. self.control
  local stored = events:getEvents()
  local previous = stored[namespace] or {}
  -- Template dynamic event IDs occupy 10–999. Static state events start at
  -- 1000, and prior assignments must remain available for old programming.
  local saved = gestureContract.savedLightEvents(self.options.savedLightEvents and self.options.savedLightEvents())
  if not saved then
    return false
  end
  local function originalID(event)
    return saved[self.control .. "/" .. event]
  end
  local allocated, required = 0, 0
  for _, group in pairs(stored) do
    for _, event in pairs(group) do
      if type(event) == "table" and event.eventId then
        allocated = allocated + 1
      end
    end
  end
  for _, event in ipairs(changed) do
    if
      not previous[event]
      and not originalID(event)
      and not (self.options.nativeAction and self.options.nativeAction(definitions[event]))
    then
      required = required + 1
    end
  end
  if allocated + required > 990 then
    return false
  end
  for _, event in ipairs(changed) do
    local name = definitions[event].name
    local description = "When NAME reports " .. name
    local old = previous[event]
    local alreadyNamed = old and old.name == name and old.description == description
    local native = self.options.nativeAction and self.options.nativeAction(definitions[event])
    local legacy = not native and originalID(event) or nil
    if legacy then
      -- Old Light used the native proxy for standard paddles even though it
      -- reserved IDs for them. Only its other gestures had custom programs.
      local added = C4:AddEvent(legacy, name, description)
      if added == false then
        return false
      end
    end
    local record
    if old or not (native or legacy) then
      record = events:getOrAddEvent(namespace, event, name, description)
      if not record or not record.eventId then
        return false
      end
      if not self.registered[event] and alreadyNamed then
        C4:AddEvent(record.eventId, name, description)
      end
    end
    self.registered[event] = { name = name, id = record and record.eventId, legacy = legacy }
  end
  return true
end

function Gestures:message(kind, data, evidenceReady)
  if not self.entity or data.entity_id ~= self.entity then
    return false
  end
  if kind == "failure" then
    self:lost(self.entity)
    return false
  end
  if kind ~= "state" and kind ~= "snapshot" then
    return false
  end
  local attrs, generation = data.attributes, self.generation
  if
    codec.isObject(attrs)
    and (
      (attrs.bridge_control_id and attrs.bridge_control_id ~= codec.null and attrs.bridge_control_id ~= self.control)
      or (
        self.device
        and attrs.bridge_source_device_id
        and attrs.bridge_source_device_id ~= codec.null
        and attrs.bridge_source_device_id ~= self.device
      )
    )
  then
    return false
  end
  local revision = gestureContract.timestamp(data.last_updated)
  if revision and self.revision and revision < self.revision then
    return false
  end
  local function malformed()
    if revision then
      self.revision = revision
    end
    -- A current selected source can invalidate its own held output even when
    -- the occurrence is unusable. Foreign control identities were rejected.
    local button = codec.isObject(attrs) and attrs.button_id
    self:cleanup(self.held[button] and button or nil)
    return false
  end
  if data.state == "unavailable" then
    if revision then
      self.revision = revision
    end
    self:lost(self.entity)
    return false
  end
  local span = metrics:start("gesture.validate_program")
  if
    not revision
    or not codec.isObject(attrs)
    or attrs.bridge_control_id ~= self.control
    or (self.device and attrs.bridge_source_device_id ~= self.device)
    or type(attrs.bridge_contract_version) ~= "string"
    or not attrs.bridge_contract_version:match("^1%.%d+$")
    or not gestureContract.identity(attrs.bridge_session_id)
    or (attrs.bridge_update_kind ~= "snapshot" and attrs.bridge_update_kind ~= "gesture")
  then
    metrics:finish(span, "rejected")
    return malformed()
  end
  local live = kind == "state" and attrs.bridge_update_kind == "gesture"
  local session = attrs.bridge_session_id
  if self.session and session ~= self.session and (live or revision == self.revision or self.retired:get(session)) then
    metrics:finish(span, "rejected")
    return false
  end
  if
    live
    and session == self.session
    and gestureContract.sequence(attrs.gesture_sequence)
    and attrs.gesture_sequence <= self.sequence
  then
    metrics:finish(span, "retired")
    return false
  end
  local measure = live and metrics.enabled and self.options.onAcknowledge and attrs.bridge_acknowledgment_version == 2
  local receivedTick, receivedEpoch
  if measure then
    local tickOk, tick = pcall(metrics.clock)
    local epochOk, epoch = pcall(C4.GetTime, C4)
    if tickOk and epochOk and type(tick) == "number" and type(epoch) == "number" then
      receivedTick, receivedEpoch = tick, epoch
    end
  end
  local definitions, ready, releases = gestureContract.capabilities(attrs)
  if not definitions then
    metrics:finish(span, "rejected")
    return malformed()
  end
  local sequence, event = gestureContract.history(data, definitions, live)
  if not sequence then
    metrics:finish(span, "rejected")
    return malformed()
  end
  if live and (not self.baseline or session ~= self.session or sequence <= self.sequence or not evidenceReady) then
    metrics:finish(span, "retired")
    return false
  end
  if session ~= self.session then
    self:cleanup()
    if generation ~= self.generation then
      metrics:finish(span, "retired")
      return false
    end
    if self.session then
      self.retired:set(self.session, true)
    end
    self.session, self.sequence = session, 0
  end
  -- A skipped live sequence or newer snapshot can hide a physical release.
  local missed = sequence > self.sequence + (live and 1 or 0)
  for button in pairs(self.held) do
    if missed or not ready[button] or not releases[button] then
      self:cleanup(button)
    end
  end
  if generation ~= self.generation then
    metrics:finish(span, "retired")
    return false
  end
  local declared = self:declare(definitions)
  if generation ~= self.generation then
    metrics:finish(span, "retired")
    return false
  end
  self.revision, self.sequence = revision, math.max(self.sequence, sequence)
  if not live then
    -- Use the same validated definitions and availability as programming.
    -- Snapshot summaries do not add work to the live button delivery path.
    local summaries, length = {}, 0
    for _, button in ipairs(attrs.bridge_buttons) do
      local names = {}
      for _, gesture in ipairs(button.gestures) do
        if gestureContract.programmable(gesture) then
          names[#names + 1] = gesture.label
        end
      end
      local line = #names > 0
          and (button.label .. ": " .. table.concat(names, ", ") .. (ready[button.id] and "" or " (unavailable)"))
        or nil
      if line then
        length = length + #line + 2
        if length > 4096 then
          summaries[#summaries + 1] = "More button presses are available in Programming."
          break
        end
        summaries[#summaries + 1] = line
      end
    end
    self.capabilitySummary = table.concat(summaries, ". ")
    self.baseline = declared
  end
  local occurrence = event and definitions[event]
  if not declared or not occurrence or not ready[occurrence.button_id] then
    metrics:finish(span, declared and "ok" or "rejected")
    return false
  end
  metrics:finish(span, "ok")
  local button = occurrence.button_id
  if occurrence.kind == "hold_start" and releases[button] then
    self.held[button] = true
  elseif occurrence.kind == "release" then
    self.held[button] = nil
  elseif occurrence.kind == "press" then
    self:cleanup(button)
  end
  local function current()
    return generation == self.generation and session == self.session and sequence == self.sequence
  end
  if not current() or not gestureContract.programmable(occurrence) then
    return false
  end
  local publish = metrics:start("gesture.publish")
  local customID = self.registered[event].id
  if customID then
    C4:FireEventByID(customID)
  end
  local legacy = self.registered[event] and self.registered[event].legacy
  if current() and legacy then
    C4:FireEventByID(legacy)
  end
  if current() and self.options.publishNative and (occurrence.kind ~= "hold_start" or releases[button]) then
    self.options.publishNative(occurrence)
  end
  metrics:finish(publish, "ok")
  if not current() then
    return true
  end
  local forwarded
  if self.options.onOccurrence and (occurrence.kind ~= "hold_start" or releases[button]) then
    local forward = metrics:start("gesture.forward")
    forwarded = self.options.onOccurrence(occurrence)
    metrics:finish(forward, "ok")
  end
  if receivedTick and current() then
    local tickOk, tick = pcall(metrics.clock)
    local epochOk, epoch = pcall(C4.GetTime, C4)
    if tickOk and epochOk and type(tick) == "number" and type(epoch) == "number" then
      -- Diagnostics failures cannot change gesture delivery or trigger a retry.
      pcall(self.options.onAcknowledge, {
        entity_id = data.entity_id,
        bridge_session_id = session,
        gesture_sequence = sequence,
        receiver_received_epoch_ms = receivedEpoch,
        receiver_processed_epoch_ms = epoch,
        receiver_forwarded_epoch_ms = forwarded == true and epoch or nil,
        receiver_processing_ms = tick - receivedTick,
      })
    end
  end
  if current() and self.options.onDelivered then
    pcall(self.options.onDelivered, event, sequence)
  end
  return true
end

return Gestures
