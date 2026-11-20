-- One explicitly confirmed operation, shared by every switch in its review.
local assess = require("ha.migration-assessment")
local codec = require("ha.codec")
local companions = require("lib.companions")
local contract = require("ha.contract")
local deferred = require("deferred")
local ids = require("ha.identities")
local installed = require("ha.installed-suite")
local page = require("lib.ui.page")
local persist = require("lib.persist")
local project = require("ha.commissioning-project")
local relays = require("ha.migration-relays")
require("lib.bindings")

local Upgrade = {}
Upgrade.__index = Upgrade
local KEY, LIMIT = "HA.SwitchUpgrade.v1", 16
local LEGACY_INPUT, LEGACY_CLASS = ids.lightCoordinatorBinding, ids.legacyCoordinatorClass
local powerActions = { { "Turn On", "TurnOn" }, { "Turn Off", "TurnOff" } }

local function checkpoint(batch)
  persist:set(KEY, codec.encode(batch), true)
end

local function savedBatch()
  local raw = persist:get(KEY, nil, true)
  if raw ~= nil then
    local saved = codec.storedObject(raw)
    assert(saved and type(saved.records) == "table", "Unreadable Switch migration checkpoint")
    return saved
  end
end

local function sameSource(planned, now)
  return now
    and now.family == "switch"
    and now.interfaces
    and now.file == planned.file
    and now.version == planned.version
    and now.room_id == planned.room_id
    and now.entity == planned.entity
    and now.mode == planned.mode
end

local function sameRelayPlan(planned, now)
  local function edges(report)
    local found = {}
    for _, edge in ipairs(report.edges) do
      if edge.binding == 1 and edge.direction == "output" then
        found[#found + 1] = edge
      end
    end
    return codec.encode(found)
  end
  return edges(planned) == edges(now)
end

local function sameStage(record, device)
  return device and device.family == "switch" and device.room_id == record.source.room_id and device.name == record.name
end

local function sameOriginal(record, current)
  return sameSource(record.source, current) and current.name == record.source.name
end

local function expectedRelays(record, current)
  if record.relayStarted then
    return relays.canRestore(record, record.destination, current)
  end
  return sameRelayPlan(record.source, current)
end

local function legacyLink(source)
  local row = GetDeviceBindings(source, nil, false, nil, LEGACY_CLASS)[LEGACY_INPUT]
  if not row or tonumber(row.deviceid) ~= source then
    return nil
  end
  local peer = Select(row, "boundprovider", "bound")
  local bound = tonumber(C4:GetBoundProviderDevice(source, LEGACY_INPUT))
  if bound == 0 and not peer and not row.isbound then
    return 0
  end
  if
    bound
    and bound > 0
    and tonumber(Select(peer, "deviceid")) == bound
    and tonumber(Select(peer, "bindingid")) == ids.coordinatorBinding
  then
    return bound
  end
end

local function direct(source)
  return contract.loadDomain(source.entity) and not assess.switchMigrationModeIssue(source)
end

local function manualWork(source)
  local modeIssue = assess.switchMigrationModeIssue(source)
  if modeIssue then
    return modeIssue
  end
  if not contract.loadDomain(source.entity) then
    return "Check this switch’s selected device in Composer, then refresh the list."
  end
  local programs = source.programs
  if not programs.readable or programs.truncated then
    return "Review this switch’s programming in Composer, then check again."
  end
  local count = #programs.attached + #programs.incoming
  if count > 0 then
    return "programming"
  end
  for _, edge in ipairs(source.edges) do
    if edge.binding ~= LEGACY_INPUT and (edge.binding ~= 1 or edge.direction ~= "output") then
      return "Move the linked keypad buttons to the replacement, then check again."
    end
  end
end

local function programCounts(programs)
  local counts = {}
  for _, reference in ipairs(programs.incoming) do
    local commands = reference.commands or {}
    local power = {}
    for _, action in ipairs(powerActions) do
      local label, savedCommand = action[1], action[2]
      power[savedCommand] = (commands[label] or 0) + (commands[savedCommand] or 0)
    end
    counts[reference.device .. ":" .. reference.event] = power
  end
  return counts
end

local function planPowerActions(source, destination)
  local counts, plan = programCounts(destination), {}
  for _, reference in ipairs(source.incoming) do
    local key = reference.device .. ":" .. reference.event
    for _, action in ipairs(powerActions) do
      local from, to = action[1], action[2]
      local count = (reference.commands or {})[from] or 0
      if count > 0 then
        plan[#plan + 1] = {
          device = reference.device,
          event = reference.event,
          label = from,
          command = to,
          minimum = ((counts[key] or {})[to] or 0) + count,
        }
      end
    end
  end
  return plan
end

local function havePowerActions(record, destination)
  if not next(record.powerPlan or {}) then
    return true
  end
  local programs = assess.deviceProgramming(destination)
  if not programs.readable or programs.truncated then
    return false
  end
  local counts = programCounts(programs)
  local missing = {}
  for _, required in ipairs(record.powerPlan) do
    local key = required.device .. ":" .. required.event
    local needed = required.minimum - ((counts[key] or {})[required.command] or 0)
    if needed > 0 then
      missing[#missing + 1] =
        { device = required.device, event = required.event, label = required.label, count = needed }
    end
  end
  return #missing == 0, missing
end

local function status(device, source, reservationOnly)
  local ok, reply = pcall(SendUIRequest, device, "HA_SWITCH_UPGRADE_STATUS", {
    SOURCE = tostring(source.id),
    ENTITY = source.entity,
    RESERVATION_ONLY = reservationOnly and "true" or nil,
  })
  return ok and type(reply) == "string" and reply:match("^<upgrade>(%a+)</upgrade>$") or "unknown"
end

local function reserve(source, destination)
  local found
  for raw in pairs(C4:GetDevicesByC4iName(ids.packages.switch.file) or {}) do
    local id = tonumber(raw)
    if not contract.integer(id) then
      return nil, "An installed replacement could not be verified."
    end
    if id ~= destination then
      local device = project.device(id)
      if not device then
        return nil, "An installed replacement could not be verified."
      end
      local provider = contract.provider(id)
      local foreign = provider and provider ~= tonumber(C4:GetDeviceID())
      local current = status(id, source, foreign)
      if current == "ready" or current == "matching" then
        return nil, "Another Control4 switch already controls this Home Assistant device."
      end
      if current == "unknown" then
        return nil, "Check the existing Home Assistant Switch drivers before migrating."
      end
      if current == "reserved" then
        if foreign then
          return nil, "The prepared replacement uses a different Home Assistant connection."
        end
        if found then
          return nil, "More than one replacement already has a plan for this switch."
        end
        found = id
      end
    end
  end
  return found
end

local function unverifiedActions(reference)
  local mapped = 0
  for _, action in ipairs(powerActions) do
    mapped = mapped + ((reference.commands or {})[action[1]] or 0)
  end
  return mapped == 0 or (reference.actionCount or 0) > mapped
end

local function requiresProgrammingConfirmation(programs)
  if not programs.readable or programs.truncated or #programs.attached > 0 then
    return true
  end
  for _, reference in ipairs(programs.incoming) do
    if unverifiedActions(reference) then
      return true
    end
  end
  return false
end

local function worklist(programs, original, manualOnly)
  local details = {}
  for _, reference in ipairs(programs.attached) do
    local item = assess.programReference(reference, original)
    item.instruction = "Recreate this event’s programming on the new driver and verify it in Composer."
    details[#details + 1] = item
  end
  for _, reference in ipairs(programs.incoming) do
    local item = assess.programReference(reference)
    if not manualOnly then
      for _, action in ipairs(powerActions) do
        local name = action[1]
        local count = (reference.commands or {})[name] or 0
        if count > 0 then
          details[#details + 1] = {
            location = item.location,
            event = item.event,
            eventId = item.eventId,
            instruction = count == 1 and ("Change the " .. name .. " action to use the new driver.")
              or ("Change all %d %s actions to use the new driver."):format(count, name),
          }
        end
      end
    end
    if unverifiedActions(reference) then
      item.instruction = "Review the actions that reference the old driver and verify their replacements in Composer."
      details[#details + 1] = item
    end
  end
  return details
end

local function oldDriverName(source)
  local suffix = " (old driver " .. source.id .. ")"
  if type(source.name) == "string" and #source.name + #suffix <= 128 then
    return source.name .. suffix
  end
  return "Old switch driver " .. source.id
end

local function hasProgrammingWork(programs)
  return not programs.readable or programs.truncated == true or #programs.attached + #programs.incoming > 0
end

local function view(record, preview)
  local s = record.source
  local row = {
    id = s.id,
    name = s.name or "HA Switch",
    room = s.room,
    device = record.deviceName,
    state = record.phase == "upgraded" and not record.namesVerified and "naming" or record.phase,
    message = record.message,
    replacement = record.name,
    hadProgramming = hasProgrammingWork(s.programs),
  }
  if record.namesVerified then
    row.replacement, row.oldDriver = s.name, record.retiredName
    for _, action in ipairs(record.powerPlan or {}) do
      local item = assess.programReference(action)
      item.command = action.label
      row.verifiedActions = row.verifiedActions or {}
      row.verifiedActions[#row.verifiedActions + 1] = item
    end
  elseif record.phase == "ready" then
    row.replacement = nil
    row.finalName = s.name
  end
  if record.phase == "review" then
    local proxy = record.destination and tonumber((C4:GetProxyDevicesById(record.destination)))
    local name = proxy and C4:GetDeviceDisplayName(proxy)
    if type(name) == "string" and name:match("%S") then
      row.replacement = name
    end
  end
  if preview or record.phase == "review" then
    local confirm = record.manualProgramming == "waiting"
    row.confirmProgramming = confirm or nil
    local programs = confirm and (record.manualReferences or s.programs) or record.remainingPrograms or s.programs
    local details = worklist(programs, s, confirm)
    if record.missingPowerActions then
      details = {}
      for _, action in ipairs(record.missingPowerActions) do
        local item = assess.programReference(action)
        item.instruction = action.count == 1 and ("Add " .. action.label .. " on the new driver.")
          or ("Add %d %s actions on the new driver."):format(action.count, action.label)
        details[#details + 1] = item
      end
    end
    row.details = details
    if preview or record.phase == "review" then
      if #details > 0 then
        row.programming = "found"
      elseif confirm or not programs.readable or programs.truncated then
        row.programming = "check"
      else
        row.programming = "none"
      end
    end
  end
  return row
end

function Upgrade.new(hub, notify)
  return setmetatable({
    hub = hub,
    notify = notify,
    coordinator = tonumber(C4:GetDeviceID()),
    batch = savedBatch(),
    serial = 0,
  }, Upgrade)
end

function Upgrade:state()
  local rows = {}
  local batch = self.batch
  if batch then
    for _, record in ipairs(batch.records) do
      rows[#rows + 1] = view(record)
    end
  end
  local needsNames, canReviewRemoval = false, false
  for _, record in ipairs(batch and batch.records or {}) do
    if record.phase == "upgraded" or record.phase == "naming" then
      needsNames = needsNames or not record.namesVerified
      canReviewRemoval = canReviewRemoval or record.namesVerified == true
    end
  end
  return {
    rows = rows,
    running = self.running == true,
    saved = batch ~= nil,
    token = batch and batch.token or nil,
    needsNames = needsNames,
    canReviewRemoval = canReviewRemoval,
  }
end

function Upgrade:save()
  local saved = savedBatch()
  if saved and saved.token == self.batch.token then
    local receipts = {}
    for _, row in ipairs(saved.records) do
      if row.addReceipt and (row.phase == "prepared" or row.phase == "pending") then
        receipts[row.source.id] = row
      end
    end
    for _, row in ipairs(self.batch.records) do
      local receipt = receipts[row.source.id]
      if row.phase == "adding" and receipt and receipt.name == row.name then
        row.destination, row.phase, row.addReceipt = receipt.destination, receipt.phase, true
      end
    end
  end
  checkpoint(self.batch)
  self.notify(self:state())
end

function Upgrade:availability()
  local count, present = 0, {}
  for _, source in ipairs(assess.sources("switch")) do
    present[source.id] = true
    if legacyLink(source.id) == self.coordinator then
      count = count + 1
    end
  end
  local pending = self.running == true
  for _, record in ipairs(self.batch and self.batch.records or {}) do
    if record.phase ~= "upgraded" or present[record.source.id] then
      pending = true
      break
    end
  end
  return { count = count, pending = pending }
end

function Upgrade:list()
  local rows, seen, records = {}, {}, {}
  local revision = installed.upgradeRevision(self.coordinator)
  local programming
  for _, item in ipairs(assess.sources("switch")) do
    -- Leave devices on other Coordinators to their own upgrade workflow.
    if legacyLink(item.id) == self.coordinator then
      if programming == nil then
        programming = assess.programmingSnapshot()
      end
      local source = assess.assess(item.id, { programming = programming })
      if source then
        local record = { source = source, phase = "ready" }
        local modeIssue = assess.switchMigrationModeIssue(source)
        if
          not source.entity
          or not source.room_id
          or not source.interfaces
          or type(source.name) ~= "string"
          or not source.name:match("%S")
        then
          record.phase, record.message =
            "blocked",
            modeIssue or assess.switchSelectionIssue(source) or "Check this switch’s selected device and connections."
        elseif seen[source.entity] then
          local prior = records[seen[source.entity]]
          prior.phase, prior.message = "blocked", "More than one older switch uses this Home Assistant device."
          record.phase, record.message = prior.phase, prior.message
        else
          seen[source.entity] = item.id
          if modeIssue then
            record.message = modeIssue
          elseif not contract.loadDomain(source.entity) then
            record.message = "Check this switch’s selected device in Composer, then refresh the list."
          elseif not revision or not self.hub.online then
            record.message = "Connect Home Assistant and update all installed drivers to the same release."
          else
            record.destination, record.message = reserve(source)
          end
          if record.message then
            record.phase = "blocked"
          end
        end
        if record.phase == "ready" then
          local need = manualWork(source)
          record.message = need and "Prepare a replacement for review" or "Ready to migrate"
          local existing = record.destination and project.device(record.destination)
          record.name = existing and existing.name or page.cut(source.name, 105) .. " (new driver)"
        end
        records[item.id] = record
        rows[#rows + 1] = record
      end
    end
  end
  local views = {}
  for _, record in ipairs(rows) do
    views[#views + 1] = view(record)
  end
  return views, records, revision
end

function Upgrade:review(selected)
  if self.running or type(selected) ~= "table" or #selected < 1 or #selected > LIMIT then
    return { error = "Choose up to 16 drivers to review." }
  end
  self.preview = nil
  local _, records, revision = self:list()
  local chosen, rows, seen = {}, {}, {}
  for _, id in ipairs(selected) do
    local record = contract.integer(id) and records[id]
    if not record or record.phase ~= "ready" or seen[id] then
      return { error = "The selected drivers changed. Refresh the list and review them again." }
    end
    seen[id] = true
    chosen[#chosen + 1], rows[#rows + 1] = record, view(record, true)
  end
  self.serial = self.serial + 1
  local token = tostring(C4:GetTime()) .. "-" .. self.serial
  self.preview = { token = token, revision = revision, records = chosen }
  return { token = token, rows = rows }
end

local function preparedInRoom(record)
  local matches = {}
  for _, device in ipairs(project.inventory()) do
    if
      device.file == ids.packages.switch.file
      and device.room_id == record.source.room_id
      and type(device.name) == "string"
      and device.name:lower() == record.name:lower()
    then
      matches[#matches + 1] = device
    end
  end
  return matches
end

function Upgrade:destination(record)
  local id = record.destination
  if id then
    local ready = deferred.new()
    ready:resolve(id)
    return ready
  end
  if record.phase == "adding" then
    local candidates = record.addNameWasFree and preparedInRoom(record) or {}
    local candidate = candidates[1]
    if
      #candidates == 1
      and candidate.name == record.name
      and candidate.family == "switch"
      and candidate.selected == ""
      and (candidate.provider == 0 or candidate.provider == self.coordinator)
      and status(candidate.id, record.source) == "blank"
    then
      record.destination, record.phase = candidate.id, "prepared"
      self:save()
      return companions:afterAdd():next(function()
        return record.destination
      end)
    end
    local missing = deferred.new()
    missing:reject("Check the prepared driver in Composer before continuing.")
    return missing
  end
  local original = assess.assess(record.source.id, { skipPrograms = true })
  if not sameOriginal(record, original) or legacyLink(record.source.id) ~= self.coordinator then
    local changed = deferred.new()
    changed:reject("original_changed")
    return changed
  end
  record.addAttempt = (record.addAttempt or 0) + 1
  local suffix = " (new driver " .. self.batch.token .. "-" .. record.source.id .. "-" .. record.addAttempt .. ")"
  record.name = page.cut(record.source.name, 128 - #suffix) .. suffix
  assert(#preparedInRoom(record) == 0, "The replacement name is already used in this room.")
  record.addNameWasFree, record.addReceipt = true, nil
  record.phase = "adding"
  self:save()
  local token, name = self.batch.token, record.name
  local function remember(added)
    if added and not contract.integer(added.id) then
      return
    end
    local saved = self.closed and savedBatch() or self.batch
    if not saved or saved.token ~= token then
      return
    end
    -- A late receipt only records Director's result for this exact attempt.
    for _, prior in ipairs(saved.records) do
      if prior.source.id == record.source.id and prior.phase == "adding" and prior.name == name then
        local destination, phase = added and added.id, added and "prepared" or "pending"
        prior.destination, prior.phase, prior.addReceipt = destination, phase, true
        checkpoint(saved)
        record.destination, record.phase, record.addReceipt = destination, phase, true
        return
      end
    end
  end
  return companions
    :addSelected({
      file = ids.packages.switch.file,
      room = record.source.room_id,
      name = record.name,
    }, remember)
    :next(function(added)
      remember(added)
      if not record.destination then
        error("Control4 could not add the replacement.")
      end
      return companions:afterAdd():next(function()
        return record.destination
      end)
    end)
end

function Upgrade:rollback(record)
  local device, source = record.destination, record.source.id
  local new = project.device(device)
  local original = assess.assess(source)
  local old = legacyLink(source)
  if
    not sameOriginal(record, original)
    or not sameStage(record, new)
    or (old ~= 0 and old ~= self.coordinator)
    or (new.provider ~= 0 and new.provider ~= self.coordinator)
  then
    return false
  end
  local selection = status(device, record.source)
  if
    (selection ~= "blank" and selection ~= "reserved" and selection ~= "matching" and selection ~= "ready")
    or not expectedRelays(record, original)
  then
    return false
  end
  if new.provider == self.coordinator then
    C4:Unbind(device, new.input)
    new = project.device(device)
  end
  -- A late configuration can never control HA after its link is removed.
  if not new or new.provider ~= 0 then
    return false
  end
  if old == 0 then
    Bind(self.coordinator, ids.coordinatorBinding, source, LEGACY_INPUT, LEGACY_CLASS)
  end
  if legacyLink(source) ~= self.coordinator then
    return false
  end
  if record.relayStarted then
    return not relays.move(record, device, true, function()
      self:save()
    end).error
  end
  return true
end

function Upgrade:waitReady(record)
  local pending = deferred.new()
  local attempts = 0
  local function check()
    local ok = pcall(function()
      if self.closed then
        pending:reject("retired")
      elseif
        installed.upgradeRevision(self.coordinator, record.destination) ~= self.batch.revision
        or legacyLink(record.source.id) ~= 0
        or contract.provider(record.destination) ~= self.coordinator
      then
        pending:reject("project_changed")
      elseif status(record.destination, record.source) == "ready" then
        pending:resolve(true)
      elseif attempts >= 16 then
        pending:reject("no_feedback")
      else
        attempts = attempts + 1
        if not SetTimer("HA.SwitchUpgrade.Readiness", 500, check) then
          pending:reject("readback_unavailable")
        end
      end
    end)
    if not ok then
      pending:reject("readback_unavailable")
    end
  end
  check()
  return pending
end

function Upgrade:checkReplacement(record)
  local source, device = record.source, record.destination
  local new = device and project.device(device)
  local proxy = device and tonumber((C4:GetProxyDevicesById(device)))
  if
    new
    and new.family == "switch"
    and new.room_id == source.room_id
    and contract.integer(proxy)
    and installed.upgradeRevision(self.coordinator, device)
    and contract.provider(device) == self.coordinator
    and status(device, source) == "ready"
    and relays.transferred(record, device)
  then
    return new, proxy
  end
end

function Upgrade:finishRecordNames(record)
  local source = record.source
  local original = assess.assess(source.id)
  local new, proxy = self:checkReplacement(record)
  if
    not sameSource(source, original)
    or not new
    or legacyLink(source.id) ~= 0
    or type(source.name) ~= "string"
    or not source.name:match("%S")
  then
    return false
  end
  local retiredName = record.retiredName or oldDriverName(source)
  if
    (original.name ~= source.name and original.name ~= retiredName)
    or (new.name ~= record.name and new.name ~= source.name)
  then
    return false
  end
  record.retiredName = retiredName
  record.phase = "naming"
  record.message = "Saving the original name on the new driver…"
  self:save()
  if original.name ~= retiredName then
    RenameDevice(source.id, retiredName)
  end
  original = assess.assess(source.id)
  if not sameSource(source, original) or original.name ~= retiredName then
    return false
  end
  if C4:GetDeviceDisplayName(proxy) ~= source.name then
    RenameDevice(proxy, source.name)
  end
  local updated, updatedProxy = self:checkReplacement(record)
  if not updated or updatedProxy ~= proxy or C4:GetDeviceDisplayName(proxy) ~= source.name then
    return false
  end
  record.namesVerified = true
  record.phase = "upgraded"
  record.message = "New driver connected and feedback verified."
  self:save()
  return true
end

function Upgrade:finishNames()
  if self.running or not self.batch then
    return self:state()
  end
  for _, record in ipairs(self.batch.records) do
    if (record.phase == "upgraded" or record.phase == "naming") and not record.namesVerified then
      local ok, finished = pcall(self.finishRecordNames, self, record)
      if not ok or not finished then
        record.message = "Check the old and new driver names in Composer, then finish naming again."
      end
    end
  end
  self:save()
  RefreshNavs()
  return self:state()
end

function Upgrade:reviewRemoval(tested)
  if tested ~= true or self.running or not self.batch then
    return { error = "Confirm that you tested the new drivers and reviewed their programming." }
  end
  local rows = {}
  for _, record in ipairs(self.batch.records) do
    if record.namesVerified then
      local source = record.source
      local row = { id = source.id, name = record.retiredName, room = source.room, state = "blocked" }
      local rowsById = C4:GetDevices({ DeviceIds = tostring(source.id) })
      local new, proxy = self:checkReplacement(record)
      local original = assess.assess(source.id)
      if not new or C4:GetDeviceDisplayName(proxy) ~= source.name or type(rowsById) ~= "table" then
        row.message = "Keep this driver until its replacement and project details are verified."
      elseif not (rowsById[source.id] or rowsById[tostring(source.id)]) then
        row.state = "removed"
        row.message = "Removed from Control4."
      elseif not havePowerActions(record, record.destination) then
        row.message = "Keep this driver. Check the migrated actions on the new driver, then check removal again."
      elseif
        sameSource(source, original)
        and original.name == record.retiredName
        and legacyLink(source.id) == 0
        and #original.edges == 0
        and not manualWork(original)
      then
        row.state = "ready"
        row.message = "Ready to remove in Composer."
      else
        row.message = "Keep this driver and check its name, connections and programming."
      end
      rows[#rows + 1] = row
    end
  end
  return { rows = rows }
end

function Upgrade:bindReplacement(device, room, input)
  local need = {
    binding = ids.coordinatorBinding,
    class = ids.coordinatorClass,
    consumer = input,
    room = room,
  }
  assert(
    companions:bindSelected(need, device, function()
      return contract.provider(device) == self.coordinator
    end, true),
    "Could not verify the replacement’s Home Assistant connection."
  )
end

function Upgrade:apply(record, device, reviewed)
  local source = record.source
  local new = project.device(device)
  local current = assess.assess(source.id)
  if
    not sameOriginal(record, current)
    or not sameStage(record, new)
    or self.closed
    or installed.upgradeRevision(self.coordinator, device) ~= self.batch.revision
    or (new.provider ~= 0 and new.provider ~= self.coordinator)
  then
    error("The project changed. Check the source and replacement in Composer.")
  end
  local bindAfterRelease = false
  if new.provider == 0 then
    local selected = status(device, source)
    bindAfterRelease = record.phase == "restored" and (selected == "matching" or selected == "ready")
    assert(
      selected == "blank"
        or selected == "reserved"
        or bindAfterRelease
        or (
          record.phase == "cutover"
          and legacyLink(source.id) == 0
          and (selected == "matching" or selected == "ready")
        ),
      "The replacement already has a selection."
    )
    if not bindAfterRelease then
      self:bindReplacement(device, source.room_id, new.input)
    end
  end
  if record.phase ~= "cutover" then
    if not record.manualProgramming and requiresProgrammingConfirmation(source.programs) then
      record.manualProgramming = "required"
    end
    if requiresProgrammingConfirmation(current.programs) then
      record.manualProgramming = "required"
      if current.programs.readable and not current.programs.truncated then
        record.manualReferences = current.programs
      end
    end
    if not record.powerPlan then
      local expected = planPowerActions(source.programs, { incoming = {} })
      if #expected == 0 then
        record.powerPlan = expected
        self:save()
      else
        local destination = assess.deviceProgramming(device)
        if destination.readable and not destination.truncated then
          record.powerPlan = planPowerActions(source.programs, destination)
          self:save()
        end
      end
    end
    local manual = manualWork(current)
    record.missingPowerActions = nil
    if not manual and not record.powerPlan then
      manual = "Control4 could not check the new driver’s programming. Check the staged driver and try again."
    elseif not manual then
      local matched, missing = havePowerActions(record, device)
      if not matched then
        record.missingPowerActions = missing
        manual = missing and "Add the missing actions below, then check programming again."
          or "Control4 could not read the new driver’s programming. Check programming again."
      end
    end
    if manual and record.manualProgramming == "waiting" then
      record.manualProgramming = "required"
    elseif not manual and record.manualProgramming and record.manualProgramming ~= "confirmed" then
      if reviewed and record.manualProgramming == "waiting" then
        record.manualProgramming, record.manualReferences = "confirmed", nil
        self:save()
      else
        record.manualProgramming = "waiting"
        manual = "Confirm that the programming you reviewed now uses the new driver."
      end
    end
    if manual then
      record.phase, record.message = "review", manual ~= "programming" and manual or nil
      record.remainingPrograms = current.programs
      self:save()
      return
    end
    record.remainingPrograms = nil
  end
  if not direct(source) then
    error("Review the original switch’s button configuration.")
  end
  return self.hub.connection:readState(source.entity):next(function(state)
    if self.closed then
      return
    end
    assert(
      contract.state(state, source.entity) and (state.state == "on" or state.state == "off"),
      "Home Assistant could not verify the selected switch."
    )
    local check = assess.assess(source.id)
    assert(
      sameOriginal(record, check)
        and not manualWork(check)
        and havePowerActions(record, device)
        and expectedRelays(record, check),
      "Review the original switch’s programming or connections."
    )
    local name = type(state.attributes) == "table" and state.attributes.friendly_name
    if type(name) == "string" and #name <= 1024 and not name:find("%c") then
      record.deviceName = name
    end
    local old, selected = legacyLink(source.id), status(device, source)
    local destination = project.device(device)
    assert(sameStage(record, destination), "The replacement’s name or room changed.")
    local linked = destination.provider == self.coordinator and contract.provider(device) == self.coordinator
    local detached = bindAfterRelease and not linked and destination.provider == 0
    local another, problem = reserve(source, device)
    assert(
      not another
        and not problem
        and (linked or detached)
        and installed.upgradeRevision(self.coordinator, device) == self.batch.revision,
      "The suite changed or another replacement is using this device."
    )
    assert(old == self.coordinator or (old == 0 and record.phase == "cutover"), "The original connection changed.")
    assert(
      selected == "blank"
        or selected == "reserved"
        or ((old == 0 or detached) and (selected == "matching" or selected == "ready")),
      "The replacement selection changed."
    )
    record.phase, record.message = "cutover", "Connecting the new driver and checking feedback…"
    self:save()
    if old == self.coordinator then
      C4:Unbind(source.id, LEGACY_INPUT)
      assert(legacyLink(source.id) == 0, "Could not verify that the original released control.")
    end
    if detached then
      self:bindReplacement(device, source.room_id, destination.input)
    end
    local work = (selected == "matching" or selected == "ready") and self:waitReady(record)
      or self.hub.transfer:directSwitch(device, source.entity, record.deviceName):next(function()
        return self:waitReady(record)
      end)
    return work:next(function()
      if self.closed then
        return
      end
      local beforeRelays = assess.assess(source.id)
      local replacement = project.device(device)
      assert(
        sameOriginal(record, beforeRelays)
          and expectedRelays(record, beforeRelays)
          and not manualWork(beforeRelays)
          and havePowerActions(record, device)
          and legacyLink(source.id) == 0
          and sameStage(record, replacement)
          and replacement.provider == self.coordinator
          and installed.upgradeRevision(self.coordinator, device) == self.batch.revision
          and status(device, source) == "ready",
        "The project changed while checking feedback."
      )
      local moved = relays.move(record, device, false, function()
        record.relayStarted = true
        self:save()
      end)
      assert(not moved.error, moved.error)
      record.phase, record.message = "naming", "The new driver is connected. Finish saving its name."
      self:save()
      if not self:finishRecordNames(record) then
        record.message = "Check the old and new driver names in Composer, then finish naming again."
        self:save()
      end
    end)
  end)
end

function Upgrade:run(reviewed)
  self.running = true
  self:save()
  local nextWork = deferred.new()
  nextWork:resolve()
  for _, record in ipairs(self.batch.records) do
    if record.phase ~= "upgraded" and record.phase ~= "naming" then
      nextWork = nextWork
        :next(function()
          if self.closed then
            return
          end
          return self:destination(record):next(function(device)
            return self:apply(record, device, reviewed and reviewed[record.source.id])
          end)
        end)
        :next(nil, function(problem)
          if self.closed then
            return
          end
          if record.phase == "cutover" then
            local ok, restored = pcall(self.rollback, self, record)
            if ok and restored then
              record.phase = "restored"
              record.message = "The old driver controls the switch again."
              if hasProgrammingWork(record.source.programs) or record.manualProgramming == "confirmed" then
                record.message = record.message
                  .. " Any programming you moved still points to the new driver. Restore the project backup to undo those edits."
              end
              record.message = record.message
                .. " To retry, check the Home Assistant connection, then choose Recheck and continue."
            else
              record.phase, record.message =
                "recovery", "Control could not be verified. Restore the project backup before continuing."
            end
          elseif record.phase == "naming" then
            record.message = "Check the old and new driver names in Composer, then finish naming again."
          elseif record.phase == "adding" then
            record.message = "Look for “"
              .. record.name
              .. "” in this room in Composer, then choose Recheck and continue."
          elseif problem == "original_changed" then
            record.phase, record.message =
              "attention",
              "Check the original driver’s name, room and Home Assistant connection in Composer, then choose Recheck and continue."
          else
            record.phase, record.message =
              "attention", "The old driver remains in place. Check the Home Assistant connection and new driver."
          end
          self:save()
        end)
    end
  end
  nextWork:next(function()
    if not self.closed then
      self.running = false
      self:save()
      RefreshNavs()
    end
  end)
  return self:state()
end

function Upgrade:start(token, backup)
  local preview = self.preview
  if self.running or backup ~= true or not preview or token ~= preview.token then
    return { error = "Review the drivers and confirm your backup before starting." }
  end
  local selected = {}
  for _, record in ipairs(preview.records) do
    selected[record.source.id] = true
  end
  local outstanding = {}
  if self.batch then
    for _, record in ipairs(self.batch.records) do
      if record.phase ~= "upgraded" or not record.namesVerified then
        return { error = "Finish or recover the saved migration before starting another." }
      end
      local id = record.source.id
      local rows = C4:GetDevices({ DeviceIds = tostring(id) })
      if type(rows) ~= "table" then
        return { error = "Check the old driver removal status before starting another migration." }
      end
      if not selected[id] and (rows[id] or rows[tostring(id)]) then
        outstanding[#outstanding + 1] = record
      end
    end
  end
  local _, latest, revision = self:list()
  if revision ~= preview.revision or not revision then
    return { error = "The installed release changed. Review the drivers again." }
  end
  for _, record in ipairs(preview.records) do
    local current = latest[record.source.id]
    if not current or codec.encode(current) ~= codec.encode(record) then
      return { error = "The project changed. Review the drivers again before starting." }
    end
  end
  for _, record in ipairs(preview.records) do
    record.phase = "pending"
  end
  for _, record in ipairs(outstanding) do
    preview.records[#preview.records + 1] = record
  end
  self.batch, self.preview = preview, nil
  return self:run()
end

function Upgrade:resume(token, confirmed)
  if self.running or not self.batch then
    return self:state()
  end
  self.batch = savedBatch() or self.batch
  if installed.upgradeRevision(self.coordinator) ~= self.batch.revision then
    return { error = "Restore the saved suite release before resuming this migration." }
  end
  for _, record in ipairs(self.batch.records) do
    if record.phase == "recovery" then
      return { error = record.message }
    end
  end
  local reviewed = {}
  if confirmed ~= nil then
    if type(confirmed) ~= "table" or #confirmed > LIMIT or token ~= self.batch.token then
      return { error = "Refresh the migration status before confirming programming." }
    end
    local waiting = {}
    for _, record in ipairs(self.batch.records) do
      if record.phase == "review" and record.manualProgramming == "waiting" then
        waiting[record.source.id] = true
      end
    end
    for _, id in ipairs(confirmed) do
      if not contract.integer(id) or not waiting[id] or reviewed[id] then
        return { error = "Refresh the migration status before confirming programming." }
      end
      reviewed[id] = true
    end
  end
  return self:run(reviewed)
end

function Upgrade:destroy()
  self.closed = true
  pcall(CancelTimer, "HA.SwitchUpgrade.Readiness")
end

return Upgrade
