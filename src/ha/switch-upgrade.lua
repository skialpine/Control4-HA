-- One explicitly confirmed operation, shared by every switch in its review.
local assess = require("ha.migration-assessment")
local codec = require("ha.codec")
local companions = require("lib.companions")
local contract = require("ha.contract")
local deferred = require("deferred")
local ids = require("ha.identities")
local installed = require("ha.installed-suite")
local migrationSelection = require("ha.migration-selection")
local page = require("lib.ui.page")
local persist = require("lib.persist")
local project = require("ha.commissioning-project")
local prototype = require("ha.prototype-selection")
local relays = require("ha.migration-relays")
local selection = require("ha.selection")
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

local function recoveryRequired(batch)
  for _, record in ipairs(batch and batch.records or {}) do
    if record.phase == "recovery" then
      return record.message
    end
  end
end

local function sameSource(planned, now, buttonMigration)
  return now
    and now.family == "switch"
    and (buttonMigration or now.interfaces)
    and now.file == planned.file
    and now.version == planned.version
    and now.room_id == planned.room_id
    and (buttonMigration or now.entity == planned.entity)
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

local function connectionPlan(source, peers)
  local mapped, labels, complete = {}, {}, source.bindingsVerified or source.interfaces
  for _, edge in ipairs(source.edges) do
    if edge.binding ~= LEGACY_INPUT or edge.owner ~= source.id then
      local role = assess.destination(edge.binding)
      if not peers[edge.device] then
        peers[edge.device] = { assess.connectionPeer(edge.device) }
      end
      local name, installedPeer, reason = unpack(peers[edge.device])
      local movable = role
        and role.provider
        and edge.owner == source.id
        and edge.direction == "output"
        and installedPeer
        and source.bindingsVerified
      if movable then
        local owner, port = relays.provider(edge.device, edge.port, role.class)
        movable = owner == source.id and port == edge.binding
      end
      if movable then
        mapped[#mapped + 1] =
          { from = edge.binding, to = role.new, device = edge.device, port = edge.port, class = role.class }
      else
        complete = false
      end
      labels[#labels + 1] = {
        role = role and role.name or "Connection",
        target = name,
        transfer = movable == true,
        migratePeerFirst = reason == "legacy" or nil,
      }
    else
      if not peers[edge.device] then
        peers[edge.device] = { assess.connectionPeer(edge.device) }
      end
      local name = peers[edge.device][1]
      labels[#labels + 1] = { role = "Home Assistant connection", target = name, transfer = true }
    end
  end
  return mapped, labels, complete == true
end

local function refreshConnectionPlan(record, current)
  if not record.connectionLabels or record.mappedConnections then
    return
  end
  local reviewed = {}
  for _, edge in ipairs(record.source.edges) do
    reviewed[codec.encode(edge)] = true
  end
  for _, edge in ipairs(current.edges) do
    if not reviewed[codec.encode(edge)] then
      return
    end
  end
  local planned, labels, complete = connectionPlan(current, {})
  record.connectionLabels = labels
  if complete then
    record.mappedConnections = planned
  end
end

local function sameStage(record, device)
  return device
    and device.family == "switch"
    and device.room_id == record.source.room_id
    and (device.name == record.name or (record.stageNames and device.name == record.source.name))
end

local function sameOriginal(record, current)
  return sameSource(record.source, current, record.buttonBehavior)
    and (current.name == record.source.name or (record.stageNames and current.name == record.retiredName))
    and current.entity == record.source.entity
end

local function expectedRelays(record, current)
  if record.relayStarted or record.mappedConnections then
    return relays.canRestore(record, record.destination, current)
  end
  return sameRelayPlan(record.source, current)
end

local function connectionPeerIssue(record)
  for _, edge in ipairs(record.mappedConnections or {}) do
    local name, eligible = assess.connectionPeer(edge.device)
    if not eligible then
      return "Review the connection to " .. name .. " in Composer, then recheck migration."
    end
  end
end

local function ownershipMessage(peer, originalConnected)
  local label = peer and peer.name and assess.deviceLabel(peer.name, peer.room)
  local instruction = label and ("In Composer, check the Home Assistant device used by " .. label .. ".")
    or "In Composer, check whether another Home Assistant driver uses this device."
  return instruction
    .. " Resolve any duplicate control before continuing."
    .. (originalConnected and " The original stays connected." or "")
end

local function reply(promiseValue)
  local promise = deferred.new()
  promise:resolve(promiseValue)
  return promise
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

local function manualWork(source, record)
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
  if record and record.connectionLabels and not record.mappedConnections then
    return "Check the unresolved connections in Composer. The original driver stays connected."
  end
  for _, edge in ipairs(source.edges) do
    if edge.binding ~= LEGACY_INPUT and (edge.binding ~= 1 or edge.direction ~= "output") then
      local planned = false
      for _, link in ipairs(record and record.mappedConnections or {}) do
        if
          edge.owner == source.id
          and edge.direction == "output"
          and edge.device == link.device
          and edge.binding == link.from
          and edge.port == link.port
        then
          planned = true
          break
        end
      end
      if not planned then
        return "Move the remaining connections to the replacement in Composer, then check again."
      end
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

local function buttonIdentity(record, config)
  local mode = record.source.mode == "buttons" and "Buttons only" or "Home Assistant device"
  return migrationSelection.identity(config, record.buttonBehavior, mode)
end

local function buttonStatus(record, recovery)
  local current = migrationSelection.read(record.destination)
  if not current then
    return "unknown"
  end
  if not recovery and not current.stable then
    return "unknown"
  end
  local expected = record.buttonIdentity
  if current.key == "" then
    return (recovery or (expected and current.behavior == expected.behavior and current.mode == expected.mode))
        and "blank"
      or "occupied"
  end
  if recovery and expected then
    -- This is still the recorded selection if someone changed only its mode.
    current.behavior, current.mode = expected.behavior, expected.mode
  end
  if not migrationSelection.matches(expected, current) then
    return "occupied"
  end
  return current.ready and (not expected.gesture or current.buttons) and "ready" or "matching"
end

local function replacementStatus(record, recovery)
  if record.buttonBehavior then
    return buttonStatus(record, recovery)
  end
  return status(record.destination, record.source)
end

local function blankStage(record, device, coordinator)
  return sameStage(record, device)
    and device.selected == ""
    and (device.provider == 0 or device.provider == coordinator)
    and (record.buttonBehavior ~= nil or status(device.id, record.source) == "blank")
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
      .. " Then remove the actions from this event on the old driver."
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
            action = name,
            count = count,
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
  local reviewed = preview and record.reviewedLoad
  local row = {
    id = s.id,
    name = s.name or "HA Switch",
    room = s.room,
    device = record.deviceName,
    state = record.phase == "upgraded" and not record.namesVerified and "naming" or record.phase,
    message = record.message,
    replacement = record.name,
    hadProgramming = hasProgrammingWork(s.programs),
    buttonBehavior = record.buttonBehavior,
    copiedSettings = record.copiedSettings == true or nil,
    ledBehavior = record.buttonBehavior and s.ledBehavior or nil,
    selectedDevice = record.buttonBehavior and s.selectedName or nil,
    relayMigration = record.relayMigration,
    connections = record.connectionLabels,
    connectionsVerified = s.bindingsVerified == true or s.interfaces == true,
    connectedAutomatically = record.connectedAutomatically == true or nil,
    targetToConfirm = record.phase == "target" and record.targetToConfirm or nil,
    reviewedLoad = reviewed and { entity = reviewed.load, name = reviewed.name, area = reviewed.area } or nil,
    tested = record.tested == true or nil,
    referencesReviewed = record.referencesReviewed == true or nil,
    unresolvedConnections = record.connectionLabels ~= nil and record.mappedConnections == nil or nil,
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
  if record.phase == "review" or (record.phase == "manual" and record.stageNames) then
    row.oldDriver = record.stageNames and record.retiredName or nil
    local proxy = record.destination and tonumber((C4:GetProxyDevicesById(record.destination)))
    local name = proxy and C4:GetDeviceDisplayName(proxy)
    if type(name) == "string" and name:match("%S") then
      row.replacement = name
      row.namesPrepared = record.stageNames and name == s.name or nil
    end
  end
  if preview or record.phase == "review" or record.phase == "manual" then
    local confirm = record.manualProgramming == "waiting"
    row.confirmProgramming = confirm or nil
    local programs = confirm and (record.manualReferences or s.programs) or record.remainingPrograms or s.programs
    local details = worklist(programs, s, confirm)
    if record.missingPowerActions then
      details = {}
      for _, action in ipairs(record.missingPowerActions) do
        local item = assess.programReference(action)
        item.action, item.count, item.addOnly = action.label, action.count, true
        item.instruction = action.count == 1 and ("Add " .. action.label .. " on the new driver.")
          or ("Add %d %s actions on the new driver."):format(action.count, action.label)
        details[#details + 1] = item
      end
    end
    row.details = details
    if #details > 0 then
      row.programming = "found"
    elseif confirm or not programs.readable or programs.truncated then
      row.programming = "check"
    else
      row.programming = "none"
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
  local needsNames, canReviewRemoval, waitingForLoad, interrupted = false, false, false, false
  for _, record in ipairs(batch and batch.records or {}) do
    waitingForLoad = waitingForLoad or record.phase == "target"
    interrupted = interrupted or record.phase == "cutover"
    if record.phase == "upgraded" or record.phase == "naming" then
      needsNames = needsNames or not record.namesVerified
      canReviewRemoval = canReviewRemoval or record.namesVerified == true
    end
  end
  local revision = not self.running and (waitingForLoad or interrupted) and installed.upgradeRevision(self.coordinator)
  return {
    rows = rows,
    running = self.running == true,
    saved = batch ~= nil,
    token = batch and batch.token or nil,
    needsNames = needsNames,
    canReviewRemoval = canReviewRemoval,
    releaseChanged = not self.running and waitingForLoad and revision ~= batch.revision or nil,
    interruptedCutover = interrupted and revision and revision > batch.revision or nil,
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
    if (record.phase ~= "upgraded" and record.phase ~= "manual") or present[record.source.id] then
      pending = true
      break
    end
  end
  return { count = count, pending = pending }
end

function Upgrade:list()
  local rows, seen, records = {}, {}, {}
  local revision = installed.upgradeRevision(self.coordinator)
  local staged = {}
  for _, record in ipairs(self.batch and self.batch.records or {}) do
    if record.phase == "manual" then
      staged[record.source.id] = true
    end
  end
  local programming, peers = nil, {}
  for _, item in ipairs(assess.sources("switch")) do
    -- Leave devices on other Coordinators to their own upgrade workflow.
    if not staged[item.id] and legacyLink(item.id) == self.coordinator then
      if programming == nil then
        programming = assess.programmingSnapshot()
      end
      local source = assess.assess(item.id, { programming = programming })
      if source then
        local behavior = prototype.switchButtonBehavior(source.mode)
        local record = { source = source, phase = "ready", buttonBehavior = behavior }
        local modeIssue = not behavior and assess.switchMigrationModeIssue(source) or nil
        if
          not source.room_id
          or (not behavior and (not source.entity or not source.interfaces))
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
          if source.entity then
            seen[source.entity] = item.id
          end
          if modeIssue then
            record.message = modeIssue
          elseif not revision or not self.hub.online then
            record.message = "Connect Home Assistant and update all installed drivers to the same release."
          elseif not behavior and not contract.loadDomain(source.entity) then
            record.message = "Check this switch’s selected device in Composer, then refresh the list."
          elseif not behavior then
            record.destination, record.message = reserve(source)
          end
          if record.message then
            record.phase = "blocked"
          end
        end
        if record.phase == "ready" then
          local edges, labels, complete = connectionPlan(source, peers)
          record.connectionLabels = labels
          if complete then
            record.mappedConnections = edges
          end
          if behavior then
            record.message =
              "Uses button events. Quick Setup can add the new driver and guide you through the Composer changes."
          else
            record.message = manualWork(source, record) and "Prepare a replacement for review" or "Ready to migrate"
          end
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

local function migrationLoadPreview(catalog, source)
  local id = catalog and catalog:gestureChoice(source.entity)
  local row = id and catalog:choice(id, "switch")
  local device = row and row.attributes.device_choice
  local load = device and device.source_load
  if load and contract.loadDomain(load.entity_id) and contract.registryId(load.registry_id) then
    local name, area = catalog:loadDetails(load.entity_id)
    return { key = id, load = load.entity_id, registry = load.registry_id, name = name, area = area }
  end
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
    if record.source.mode == "bridge" then
      record.reviewedLoad = migrationLoadPreview(self.hub.catalog, record.source)
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
    if #candidates == 1 and blankStage(record, candidate, self.coordinator) then
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
  if record.buttonBehavior and record.addAttempt == 1 then
    local shortSuffix = " (new driver)"
    record.name = page.cut(record.source.name, 128 - #shortSuffix) .. shortSuffix
    if #preparedInRoom(record) == 0 then
      suffix = shortSuffix
    end
  end
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
  local selection = replacementStatus(record, true)
  if
    (selection ~= "blank" and selection ~= "reserved" and selection ~= "matching" and selection ~= "ready")
    or not expectedRelays(record, original)
    or (record.relayStarted and relays.destinationIssue(record, device, true))
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

function Upgrade:restoreControl(record)
  local ok, restored = pcall(self.rollback, self, record)
  if not ok or not restored then
    record.phase, record.message =
      "recovery", "Control could not be verified. Restore the project backup before continuing."
    return false
  end
  record.phase = "restored"
  record.message = (record.buttonBehavior or not self.hub.online)
      and "The original driver’s connections were restored."
    or "The old driver controls the switch again."
  if hasProgrammingWork(record.source.programs) or record.manualProgramming == "confirmed" then
    record.message = record.message
      .. " Any programming you moved still points to the new driver. Restore the project backup to undo those edits."
  end
  record.message = record.message .. " To retry, check the Home Assistant connection, then choose Recheck and continue."
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
      elseif replacementStatus(record) == "ready" then
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

function Upgrade:checkReplacement(record, requireReady)
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
  then
    if record.buttonBehavior then
      if
        type(new.selected) == "string"
        and new.selected ~= ""
        and (not record.buttonSelection or record.buttonSelection == new.selected)
        and (not requireReady or (replacementStatus(record) == "ready" and relays.transferred(record, device)))
      then
        return new, proxy
      end
    elseif status(device, source) == "ready" and relays.transferred(record, device) then
      return new, proxy
    end
  end
end

local function verifiedManualTarget(record, device)
  local actual = migrationSelection.read(device.id)
  local source = record.source
  local expectedMode = source.mode == "buttons" and "Buttons only" or "Home Assistant device"
  if
    actual
    and actual.ready
    and (not actual.gesture or actual.buttons)
    and actual.key == device.selected
    and actual.behavior == record.buttonBehavior
    and actual.mode == expectedMode
    and (not source.entity or (source.entity:match("^event%.") and actual.gesture == source.entity) or (contract.loadDomain(
      source.entity
    ) and actual.load == source.entity))
    and (not record.buttonIdentity or migrationSelection.matches(record.buttonIdentity, actual))
  then
    return actual
  end
end

function Upgrade:finishRecordNames(record, tested)
  local source = record.source
  local original = assess.assess(source.id)
  local new, proxy = self:checkReplacement(record, not record.buttonBehavior)
  if
    not sameSource(source, original, record.buttonBehavior)
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
  if
    not (original.bindingsVerified or (not record.buttonBehavior and original.interfaces))
    or #original.edges > 0
    or hasProgrammingWork(original.programs)
    or (not record.buttonBehavior and not havePowerActions(record, new.id))
  then
    return false, "Review the original driver's connections and Programming in Composer, then apply the name again."
  end
  if record.buttonBehavior then
    local identity = verifiedManualTarget(record, new)
    if not identity or not relays.transferred(record, new.id) then
      return false
    end
    local issue = self:manualOwnershipIssue(record, new.id, identity)
    if issue then
      return false, issue
    end
    record.buttonIdentity, record.buttonSelection = identity, identity.key
  else
    record.phase = "naming"
  end
  record.retiredName = retiredName
  record.message = "Saving the original name on the new driver…"
  self:save()
  if original.name ~= retiredName then
    RenameDevice(source.id, retiredName)
  end
  original = assess.assess(source.id)
  if not sameSource(source, original, record.buttonBehavior) or original.name ~= retiredName then
    return false
  end
  if C4:GetDeviceDisplayName(proxy) ~= source.name then
    RenameDevice(proxy, source.name)
  end
  local updated, updatedProxy = self:checkReplacement(record, true)
  if not updated or updatedProxy ~= proxy or C4:GetDeviceDisplayName(proxy) ~= source.name then
    return false
  end
  record.namesVerified = true
  record.tested = tested == true or record.tested
  record.phase = "upgraded"
  record.message = record.tested and "Original name saved on the new driver. Testing confirmed by the installer."
    or "New driver connected and feedback verified."
  self:save()
  return true
end

function Upgrade:finishCutover(record)
  record.phase, record.message = "naming", "The new driver is connected. Finish saving its name."
  self:save()
  local finished, reason = self:finishRecordNames(record)
  if not finished then
    record.message = reason or "Check the old and new driver names in Composer, then finish naming again."
    self:save()
  end
end

function Upgrade:finishNames(token, manual, tested)
  if self.running or not self.batch then
    return self:state()
  end
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  if manual ~= nil then
    if tested ~= true or token ~= self.batch.token or not contract.integer(manual) then
      return { error = "Refresh migration status and confirm you tested the new driver before naming it." }
    end
    for _, record in ipairs(self.batch.records) do
      if record.source.id == manual and record.phase == "manual" then
        if record.relayMigration and not relays.transferred(record, record.destination) then
          return {
            error = "Check that the relay connections use the replacement before applying the original name.",
          }
        end
        local ok, finished, reason = pcall(self.finishRecordNames, self, record, tested)
        if not ok or not finished then
          record.message = reason
            or (
              record.retiredName
                and "Check that both drivers are visible in their original room, then try applying the original name again."
              or "Disconnect the old driver from Home Assistant and select the device on the new driver. Then try applying the original name again."
            )
          self:save()
        end
        RefreshNavs()
        return self:state()
      end
    end
    return { error = "Refresh migration status to see the latest driver names." }
  end
  for _, record in ipairs(self.batch.records) do
    if (record.phase == "upgraded" or record.phase == "naming") and not record.namesVerified then
      local ok, finished, reason = pcall(self.finishRecordNames, self, record)
      if not ok or not finished then
        record.message = reason or "Check the old and new driver names in Composer, then finish naming again."
      end
    end
  end
  self:save()
  RefreshNavs()
  return self:state()
end

function Upgrade:moveManualRelays(token, id, confirmed)
  if self.running or not self.batch or token ~= self.batch.token or not contract.integer(id) then
    return { error = "Refresh migration status before moving the relay connections." }
  end
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  for _, record in ipairs(self.batch.records) do
    local source = record.source
    if source.id == id and record.phase == "manual" and record.relayMigration == "available" then
      local original, new = assess.assess(id, { skipPrograms = true }), self:checkReplacement(record)
      if
        not sameSource(source, original, true)
        or not original.bindingsVerified
        or (original.name ~= source.name and not (record.stageNames and original.name == record.retiredName))
        or legacyLink(id) ~= 0
        or not sameStage(record, new)
        or not relays.canRestore(record, new.id, original)
      then
        return {
          error = "Disconnect the old driver from Home Assistant and save the device on the replacement. If a relay connects somewhere else, review it in Composer.",
        }
      end
      local actual = confirmed == true and verifiedManualTarget(record, new)
      if not actual then
        return {
          error = "Confirm the replacement uses the original Home Assistant device and is reporting its current state.",
        }
      end
      local issue = self:manualOwnershipIssue(record, new.id, actual) or connectionPeerIssue(record)
      if issue then
        return { error = issue }
      end
      record.buttonIdentity, record.buttonSelection = actual, actual.key
      local result = relays.move(record, new.id, false, function()
        self:save()
      end)
      if result.error or not relays.transferred(record, new.id) then
        return {
          error = result.error
            or "Control4 could not verify the relay connections. Check them in Composer and try again.",
        }
      end
      record.relayMigration = "moved"
      self:save()
      return self:state()
    end
  end
  return { error = "Refresh migration status to see whether these relay connections still need to move." }
end

function Upgrade:reviewRemoval(tested, referencesReviewed)
  if self.running or not self.batch then
    return { error = "Confirm that you tested the new drivers and reviewed their programming." }
  end
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  for _, record in ipairs(self.batch.records) do
    if
      record.namesVerified
      and ((not record.tested and tested ~= true) or (not record.referencesReviewed and referencesReviewed ~= true))
    then
      return {
        error = "Confirm testing and review scenes and programming before checking old drivers for removal.",
      }
    end
  end
  local changed = false
  for _, record in ipairs(self.batch.records) do
    if record.namesVerified and (not record.tested or not record.referencesReviewed) then
      if record.buttonBehavior and not record.buttonIdentity then
        local new = self:checkReplacement(record)
        local identity = new and verifiedManualTarget(record, new)
        if identity and relays.transferred(record, new.id) then
          record.buttonIdentity, record.buttonSelection = identity, identity.key
        end
      end
      record.tested, record.referencesReviewed, changed = true, true, true
    end
  end
  if changed then
    self:save()
  end
  local rows = {}
  for _, record in ipairs(self.batch.records) do
    if record.namesVerified then
      local source = record.source
      local row = { id = source.id, name = record.retiredName, room = source.room, state = "blocked" }
      local rowsById = C4:GetDevices({ DeviceIds = tostring(source.id) })
      local new, proxy = self:checkReplacement(record, true)
      local original = assess.assess(source.id)
      if not new or C4:GetDeviceDisplayName(proxy) ~= source.name or type(rowsById) ~= "table" then
        row.message = "Keep this driver until its replacement and project details are verified."
      elseif not (rowsById[source.id] or rowsById[tostring(source.id)]) then
        row.state = "removed"
        row.message = "Removed from Control4."
      elseif not record.buttonBehavior and not havePowerActions(record, record.destination) then
        row.message = "Keep this driver. Check the migrated actions on the new driver, then check removal again."
      elseif
        sameSource(source, original, record.buttonBehavior)
        and (original.interfaces or (record.buttonBehavior and original.bindingsVerified))
        and original.name == record.retiredName
        and legacyLink(source.id) == 0
        and #original.edges == 0
        and (
          (record.buttonBehavior and not hasProgrammingWork(original.programs))
          or (not record.buttonBehavior and not manualWork(original))
        )
      then
        row.state = "ready"
        row.message = "Ready to remove in Composer."
      else
        row.message = record.buttonBehavior
            and "Control4 could not verify this old driver is unused. In Composer, check its Connections, Programming and scenes for references before deleting it."
          or "Keep this driver and check its name, connections and programming."
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

function Upgrade:stageProgrammingNames(record)
  local source, device = record.source, record.destination
  local original, replacement = assess.assess(source.id), project.device(device)
  local proxy = tonumber((C4:GetProxyDevicesById(device)))
  assert(
    sameOriginal(record, original)
      and sameStage(record, replacement)
      and contract.integer(proxy)
      and legacyLink(source.id) == self.coordinator
      and contract.provider(device) == self.coordinator,
    "Could not verify the old and new drivers before naming them."
  )
  local retired = record.retiredName or oldDriverName(source)
  for _, peer in ipairs(project.inventory()) do
    if
      peer.id ~= source.id
      and peer.id ~= device
      and peer.room_id == source.room_id
      and type(peer.name) == "string"
      and (peer.name:lower() == source.name:lower() or peer.name:lower() == retired:lower())
    then
      assert(not record.stageNames, "Resolve the duplicate driver name in this room, then recheck migration.")
      return
    end
  end
  -- Keep the temporary identity and the intended names in the same checkpoint.
  -- Resume recognizes either side of each rename if Director reloads between them.
  if not record.stageNames then
    record.stageNames, record.retiredName = true, retired
    self:save()
  end
  if original.name ~= retired then
    RenameDevice(source.id, retired)
  end
  local renamed = assess.assess(source.id)
  assert(sameOriginal(record, renamed) and renamed.name == retired, "Could not verify the old driver name.")
  if C4:GetDeviceDisplayName(proxy) ~= source.name then
    RenameDevice(proxy, source.name)
  end
  replacement = project.device(device)
  assert(
    sameStage(record, replacement) and C4:GetDeviceDisplayName(proxy) == source.name,
    "Could not verify the new driver name."
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
  refreshConnectionPlan(record, current)
  local bindAfterRelease = false
  if new.provider == 0 then
    local selected = status(device, source)
    local canResume = record.phase == "restored" or (record.phase == "cutover" and legacyLink(source.id) == 0)
    bindAfterRelease = canResume and (selected == "matching" or selected == "ready")
    assert(
      selected == "blank" or selected == "reserved" or bindAfterRelease,
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
    local manual = manualWork(current, record)
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
      self:stageProgrammingNames(record)
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
  local catalog = self.hub.catalog
  local verified = catalog and not catalog:hasVerifiedSnapshot() and catalog:refresh(false) or reply()
  return verified
    :next(function()
      if not self.closed then
        return self.hub.connection:readState(source.entity)
      end
    end)
    :next(function(state)
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
          and not manualWork(check, record)
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
      local load = { entity_id = source.entity }
      local owns, peer, legacyLoadUnknown = self:checkOwnership(record, device, load)
      local issue
      if legacyLoadUnknown then
        local label = peer.name and assess.deviceLabel(peer.name, peer.room) or "the other switch with button events"
        issue = "Finish migrating " .. label .. " first, then choose Recheck and continue."
      elseif not owns then
        issue = ownershipMessage(peer, old == self.coordinator)
      end
      issue = issue or connectionPeerIssue(record) or relays.destinationIssue(record, device, false)
      if issue and record.phase ~= "cutover" then
        record.phase, record.message = "attention", issue
        self:save()
        return
      end
      assert(not issue, issue)
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
            and not manualWork(beforeRelays, record)
            and havePowerActions(record, device)
            and legacyLink(source.id) == 0
            and sameStage(record, replacement)
            and replacement.provider == self.coordinator
            and installed.upgradeRevision(self.coordinator, device) == self.batch.revision
            and status(device, source) == "ready"
            and self:checkOwnership(record, device, load),
          "The project changed while checking feedback."
        )
        local changed = connectionPeerIssue(record)
        assert(not changed, changed)
        local moved = relays.move(record, device, false, function()
          record.relayStarted = true
          self:save()
        end)
        assert(not moved.error, moved.error)
        self:finishCutover(record)
      end)
    end)
end

function Upgrade:resolveButtonDevice(record)
  local hub, source = self.hub, record.source
  if not (hub.catalog and source.entity and source.entity:match("^event%.")) then
    return reply()
  end
  return hub.connection
    :readState(source.entity)
    :next(function(state)
      if not contract.state(state, source.entity) then
        return
      end
      if state.state == "unavailable" then
        error({ kind = "unavailable" }, 0)
      end
      local attrs = state.attributes
      local physical = attrs and attrs.bridge_source_device_id
      if
        not contract.registryId(physical)
        or not (attrs.bridge_contract_version == "1.0" or attrs.bridge_contract_version == "1.1")
      then
        return
      end
      local liveLoad = attrs.bridge_load
      if liveLoad == codec.null then
        liveLoad = nil
      elseif liveLoad ~= nil and (not codec.isObject(liveLoad) or not contract.loadDomain(liveLoad.entity_id)) then
        return
      end
      return hub.catalog:refresh(false):next(function(meta)
        local id = hub.catalog:legacySwitchChoice(physical, source.entity, meta.revision)
        if not id then
          return
        end
        return selection
          .resolve(
            hub.catalog,
            function(...)
              return hub:_request(...)
            end,
            codec.object({ choice_id = id, family = "switch", revision = meta.revision, prepare = true }),
            function()
              local old = legacyLink(source.id)
              return not self.closed
                and hub.online
                and (old == self.coordinator or (record.phase == "cutover" and old == 0))
            end
          )
          :next(function(config)
            if
              config.device_id ~= physical
              or config.gesture_entity_id ~= source.entity
              or config.control_id ~= attrs.bridge_control_id
              or not config.input_ready
            then
              return
            end
            if source.mode == "bridge" then
              local load = config.controlled_load
              if
                not load
                or (liveLoad and liveLoad.entity_id ~= load.entity_id)
                or (not liveLoad and config.controlled_load_origin ~= "selected_endpoint")
              then
                return
              end
            end
            return config
          end)
      end)
    end)
    :next(nil, function(failure)
      local kind = type(failure) == "table" and failure.kind
      if
        not hub.online
        or kind == "timeout"
        or kind == "disconnected"
        or kind == "read_failed"
        or kind == "retired"
        or kind == "unavailable"
      then
        error(failure, 0) -- Leave the row retryable if the Home Assistant read fails.
      end
      return nil
    end)
end

local function loadLabel(hub, entity)
  local function label(value)
    return type(value) == "string" and #value <= 160 and value:match("%S") and not value:find("%c") and value or nil
  end
  local name, area = hub.catalog:loadDetails(entity)
  area = label(area)
  if label(name) then
    return reply({ name = name, area = area })
  end
  return hub.connection:readState(entity):next(function(state)
    local friendly = contract.state(state, entity) and label(state.attributes.friendly_name) or nil
    return { name = friendly, area = area }
  end, function()
    return { area = area }
  end)
end

function Upgrade:checkOwnership(record, device, load, buttons)
  local catalog, loadKeys, loadRegistry = self.hub.catalog
  if load then
    if catalog then
      loadKeys = catalog:endpointKeys({ load.entity_id })
      if not loadKeys then
        return false
      end
    else
      loadKeys = { [load.entity_id] = true }
    end
    loadRegistry = load.registry_id
    if catalog and not loadRegistry then
      local _, _, registry = catalog:loadDetails(load.entity_id)
      loadRegistry = registry
    end
  end
  local unresolvedLegacy
  for _, peer in ipairs(project.inventory()) do
    local provider = peer.legacy and peer.legacy_provider or peer.provider
    local sameCoordinator = not contract.integer(provider) or provider == self.coordinator
    if peer.id ~= record.source.id and peer.id ~= device and provider ~= 0 and peer.selected ~= "" then
      if not peer.selected then
        return false, peer
      elseif peer.legacy then
        local event = peer.selected:match("^event%.")
        local ownsLoad = peer.legacy_mode ~= "buttons" and peer.legacy_mode ~= "connected"
        -- The old bridge exposes its event, but its saved linked load is
        -- private to the driver and need not match current event metadata.
        if buttons and peer.selected == buttons.gesture_entity_id then
          return false, peer
        elseif load and ownsLoad then
          if event then
            unresolvedLegacy = unresolvedLegacy or peer
          elseif loadKeys[peer.selected] then
            return false, peer
          end
        end
      else
        local verified = migrationSelection.read(peer.id)
        if not verified or not verified.stable or verified.key ~= peer.selected then
          return false, peer
        end
        if load and verified.mode == "Home Assistant device" and verified.load then
          local comparable = loadRegistry and verified.registry
          if
            (comparable and loadRegistry == verified.registry)
            or ((sameCoordinator or not comparable) and loadKeys[verified.load])
          then
            return false, peer
          end
        end
        if buttons and verified.buttons then
          local comparable = buttons.device_id and buttons.control_id and verified.device and verified.control
          if
            (comparable and buttons.device_id == verified.device and buttons.control_id == verified.control)
            or ((sameCoordinator or not comparable) and verified.gesture == buttons.gesture_entity_id)
          then
            return false, peer
          end
        end
      end
    end
  end
  if unresolvedLegacy then
    return false, unresolvedLegacy, true
  end
  return true
end

function Upgrade:manualOwnershipIssue(record, device, actual)
  local load = actual.mode == "Home Assistant device"
      and actual.load
      and { entity_id = actual.load, registry_id = actual.registry }
    or nil
  local buttons = actual.buttons
      and { gesture_entity_id = actual.gesture, device_id = actual.device, control_id = actual.control }
    or nil
  local owns, peer = self:checkOwnership(record, device, load, buttons)
  if not owns then
    return ownershipMessage(peer)
  end
end

local function matchesReviewedLoad(reviewed, config)
  local load = config.controlled_load
  return reviewed
    and config.controlled_load_origin == "selected_endpoint"
    and config.key == reviewed.key
    and load
    and load.entity_id == reviewed.load
    and load.registry_id == reviewed.registry
end

function Upgrade:transferButtonDevice(record, device, config)
  local original = assess.assess(record.source.id)
  local new = project.device(device)
  local old = legacyLink(record.source.id)
  assert(
    not self.closed
      and sameOriginal(record, original)
      and sameStage(record, new)
      and original.bindingsVerified
      and not hasProgrammingWork(original.programs)
      and expectedRelays(record, original)
      and installed.upgradeRevision(self.coordinator, device) == self.batch.revision
      and (old == self.coordinator or (old == 0 and record.phase == "cutover"))
      and (new.provider == 0 or new.provider == self.coordinator),
    "original_changed"
  )
  if
    old == self.coordinator
    and original.mode == "bridge"
    and not migrationSelection.matches(record.approvedButtonIdentity, record.buttonIdentity)
    and not matchesReviewedLoad(record.reviewedLoad, config)
  then
    local identity = record.buttonIdentity
    return loadLabel(self.hub, identity.load):next(function(labels)
      if self.closed then
        return
      end
      record.phase, record.message = "target", nil
      record.targetToConfirm = {
        name = labels.name,
        area = labels.area,
        entity = identity.load,
        key = C4:Hash("SHA256", codec.encode(codec.object(identity)), { return_encoding = "HEX" }),
      }
      self:save()
    end)
  end
  local current = buttonStatus(record)
  assert(
    current == "blank" or ((old == 0 or new.provider == 0) and (current == "ready" or current == "matching")),
    "The replacement selection changed."
  )
  local load = record.source.mode ~= "buttons" and config.controlled_load or nil
  local ownerVerified, peer, legacyLoadUnknown = self:checkOwnership(record, device, load, config)
  if not ownerVerified and old == self.coordinator then
    record.phase, record.message = legacyLoadUnknown and "manual" or "attention", ownershipMessage(peer, true)
    self:save()
    return
  end
  assert(ownerVerified, "Another Control4 driver could be using this Home Assistant device.")
  local issue = connectionPeerIssue(record) or relays.destinationIssue(record, device, false)
  if issue and old == self.coordinator then
    record.phase, record.message = "attention", issue
    self:save()
    return
  end
  assert(not issue, issue)
  record.targetToConfirm = nil
  record.phase, record.message = "cutover", "Connecting the matching Home Assistant device…"
  self:save()
  if old == self.coordinator then
    C4:Unbind(record.source.id, LEGACY_INPUT)
    assert(legacyLink(record.source.id) == 0, "Could not verify that the original released control.")
  end
  if new.provider == 0 then
    self:bindReplacement(device, record.source.room_id, new.input)
  end
  return (current == "blank" and self.hub.transfer:preparedSwitch(device, config) or reply())
    :next(function()
      return self:waitReady(record)
    end)
    :next(function()
      if self.closed then
        return
      end
      local confirmed = assess.assess(record.source.id)
      assert(
        sameOriginal(record, confirmed)
          and confirmed.bindingsVerified
          and expectedRelays(record, confirmed)
          and not hasProgrammingWork(confirmed.programs)
          and legacyLink(record.source.id) == 0
          and sameStage(record, project.device(device))
          and buttonStatus(record) == "ready"
          and self:checkOwnership(record, device, load, config),
        "The connections changed."
      )
      local changed = connectionPeerIssue(record)
      assert(not changed, changed)
      local moved = relays.move(record, device, false, function()
        record.relayStarted = true
        self:save()
      end)
      assert(not moved.error, moved.error)
      record.connectedAutomatically, record.relayMigration, record.buttonSelection = true, "moved", config.key
      if load then
        local name = self.hub.catalog:loadDetails(load.entity_id)
        record.deviceName = type(name) == "string" and name:match("%S") and not name:find("%c") and page.cut(name, 160)
          or load.entity_id
      end
      self:finishCutover(record)
    end)
end

function Upgrade:applyButtons(record, device, reviewed)
  local source, phase = record.source, record.phase
  local old, new = legacyLink(source.id), project.device(device)
  local original = assess.assess(source.id)
  assert(
    sameOriginal(record, original)
      and sameStage(record, new)
      and installed.upgradeRevision(self.coordinator, device) == self.batch.revision
      and (new.provider == 0 or new.provider == self.coordinator),
    "original_changed"
  )
  if phase == "cutover" then
    return self:resolveButtonDevice(record):next(function(config)
      assert(
        config and migrationSelection.matches(record.buttonIdentity, buttonIdentity(record, config)),
        "The Home Assistant selection changed during migration."
      )
      return self:transferButtonDevice(record, device, config)
    end)
  end
  assert(old == self.coordinator, "original_changed")
  refreshConnectionPlan(record, original)
  record.source.selectedName, record.source.ledBehavior = original.selectedName, original.ledBehavior
  if not record.copiedSettings then
    assert(blankStage(record, new, self.coordinator), "The replacement already has a selection.")
    if new.provider == 0 then
      self:bindReplacement(device, source.room_id, new.input)
    end
    local ok, result = pcall(SendUIRequest, device, "HA_SWITCH_COPY_SETTINGS", { SOURCE = tostring(source.id) })
    record.copiedSettings = ok and result == "<upgrade>copied</upgrade>"
  end
  if
    record.mappedConnections
    and original.bindingsVerified
    and expectedRelays(record, original)
    and not relays.transferred(record, device)
  then
    record.relayMigration = "available"
  end
  if hasProgrammingWork(original.programs) then
    self:stageProgrammingNames(record)
    record.phase, record.manualProgramming = "review", "required"
    record.remainingPrograms = original.programs
    record.message = "Review the programming that uses the original driver. The original stays connected."
    self:save()
    return
  end
  if (record.manualProgramming or hasProgrammingWork(source.programs)) and record.manualProgramming ~= "confirmed" then
    if reviewed and record.manualProgramming == "waiting" then
      record.manualProgramming = "confirmed"
    else
      self:stageProgrammingNames(record)
      record.phase, record.manualProgramming = "review", "waiting"
      record.manualReferences = source.programs
      record.message = "Confirm the programming uses the replacement. The original stays connected."
      self:save()
      return
    end
  end
  record.remainingPrograms = nil
  if not record.mappedConnections or not record.copiedSettings then
    record.phase = "manual"
    record.message = record.mappedConnections and "Check the copied settings in Composer. The original stays connected."
      or "Check the connections marked in the review. The original stays connected."
    self:save()
    return
  end
  return self:resolveButtonDevice(record):next(function(config)
    if self.closed then
      return
    end
    if not config then
      if phase == "restored" then
        record.phase, record.message =
          "attention", "Quick Setup could not reverify the Home Assistant selection. The original stays connected."
      else
        record.phase, record.message =
          "manual", "Quick Setup could not verify the Home Assistant selection. The original stays connected."
      end
      self:save()
      return
    end
    local identity = buttonIdentity(record, config)
    if new.selected ~= "" and not migrationSelection.matches(record.buttonIdentity, identity) then
      record.phase, record.message =
        "attention", "Check the saved Home Assistant device on the replacement. The original stays connected."
      self:save()
      return
    end
    record.buttonIdentity = identity
    return self:transferButtonDevice(record, device, config)
  end)
end

function Upgrade:run(reviewed)
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  self.running = true
  self:save()
  local nextWork = deferred.new()
  nextWork:resolve()
  for _, record in ipairs(self.batch.records) do
    if
      record.phase ~= "upgraded"
      and record.phase ~= "naming"
      and record.phase ~= "manual"
      and record.phase ~= "target"
    then
      nextWork = nextWork
        :next(function()
          if self.closed or recoveryRequired(self.batch) then
            return
          end
          return self:destination(record):next(function(device)
            if record.buttonBehavior then
              return self:applyButtons(record, device, reviewed and reviewed[record.source.id])
            end
            return self:apply(record, device, reviewed and reviewed[record.source.id])
          end)
        end)
        :next(nil, function(problem)
          if self.closed then
            return
          end
          if record.phase == "cutover" then
            self:restoreControl(record)
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

function Upgrade:approveTarget(token, id, key, accepted)
  if
    self.running
    or not self.batch
    or token ~= self.batch.token
    or not contract.integer(id)
    or type(key) ~= "string"
    or type(accepted) ~= "boolean"
    or installed.upgradeRevision(self.coordinator) ~= self.batch.revision
  then
    return { error = "Refresh migration status before confirming the Home Assistant load." }
  end
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  for _, record in ipairs(self.batch.records) do
    if
      record.source.id == id
      and record.phase == "target"
      and record.buttonIdentity
      and record.targetToConfirm
      and record.targetToConfirm.key == key
    then
      if not accepted then
        record.buttonIdentity, record.approvedButtonIdentity, record.targetToConfirm = nil, nil, nil
        record.phase, record.message =
          "manual", "Use Device Setup in Composer to choose the device. The original stays connected."
        self:save()
        return self:state()
      end
      record.approvedButtonIdentity, record.phase = record.buttonIdentity, "prepared"
      return self:run()
    end
  end
  return { error = "Refresh migration status to see the current Home Assistant load." }
end

function Upgrade:recheckConnections(token, id)
  if
    self.running
    or not self.batch
    or token ~= self.batch.token
    or not contract.integer(id)
    or installed.upgradeRevision(self.coordinator) ~= self.batch.revision
  then
    return { error = "Refresh migration status before rechecking connections." }
  end
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  for _, record in ipairs(self.batch.records) do
    if
      record.source.id == id
      and record.phase == "manual"
      and record.connectionLabels
      and not record.mappedConnections
      and legacyLink(id) == self.coordinator
    then
      record.phase = "prepared"
      return self:run()
    end
  end
  return { error = "Recheck connections while the original driver is still connected." }
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
      if record.phase ~= "manual" and (record.phase ~= "upgraded" or not record.namesVerified) then
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
    if current and current.source.mode == "bridge" then
      current.reviewedLoad = migrationLoadPreview(self.hub.catalog, current.source)
    end
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

function Upgrade:recheckStagedRelease(revision, restoredRecord)
  local batch = self.batch
  if not revision or revision <= batch.revision or #batch.records == 0 then
    return false
  end
  for _, record in ipairs(batch.records) do
    local source, device = record.source, record.destination
    if record == restoredRecord then
      if installed.upgradeRevision(self.coordinator, device) ~= revision then
        return false
      end
    elseif record.phase ~= "upgraded" or not record.namesVerified then
      if
        record.phase ~= "target"
        or not record.buttonBehavior
        or record.copiedSettings ~= true
        or not record.targetToConfirm
        or not record.buttonIdentity
        or record.targetToConfirm.entity ~= record.buttonIdentity.load
        or not device
        or not record.mappedConnections
        or record.relayStarted
        or legacyLink(source.id) ~= self.coordinator
        or installed.upgradeRevision(self.coordinator, device) ~= revision
      then
        return false
      end
      local original, replacement = assess.assess(source.id), project.device(device)
      if
        not sameOriginal(record, original)
        or not original.bindingsVerified
        or codec.encode(source.edges) ~= codec.encode(original.edges)
        or hasProgrammingWork(original.programs)
        or not blankStage(record, replacement, self.coordinator)
        or buttonStatus(record) ~= "blank"
        or connectionPeerIssue(record)
        or relays.destinationIssue(record, device, false)
      then
        return false
      end
    end
  end
  batch.revision = revision
  self:save()
  return true
end

function Upgrade:resume(token, confirmed)
  if self.running or not self.batch then
    return self:state()
  end
  self.batch = savedBatch() or self.batch
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  local revision = installed.upgradeRevision(self.coordinator)
  if revision ~= self.batch.revision then
    if revision and revision > self.batch.revision then
      for _, record in ipairs(self.batch.records) do
        if record.phase == "cutover" then
          if token ~= self.batch.token or confirmed ~= nil then
            return { error = "Refresh migration status before restoring the original connections." }
          end
          if self:restoreControl(record) then
            if self:recheckStagedRelease(revision, record) then
              return self:state()
            end
            record.phase, record.message =
              "recovery",
              "The original driver’s connections were restored."
                .. " Restore the project backup before starting a new migration on the updated drivers."
          end
          self:save()
          return self:state()
        end
      end
    end
    if not self.hub.online then
      return { error = "Wait for Home Assistant to reconnect, then choose Recheck and continue." }
    end
    if token ~= self.batch.token or confirmed ~= nil or not self:recheckStagedRelease(revision) then
      return {
        error = "The saved migration could not be verified on this suite release. Check the original and replacement in Composer before continuing.",
      }
    end
    return self:state()
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
