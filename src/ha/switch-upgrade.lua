-- One explicitly confirmed operation, shared by every switch in its review.
local assess = require("ha.migration-assessment")
local codec = require("ha.codec")
local companions = require("lib.companions")
local contract = require("ha.contract")
local deferred = require("deferred")
local ids = require("ha.identities")
local installed = require("ha.installed-suite")
local legacyProfile = require("ha.legacy-driver-profile")
local compatibility = require("ha.light-compatibility")
local lighting = require("ha.migration-lighting")
local log = require("lib.logging")
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
local additionalStatus, additionalIdentity, additionalLighting, additionalLoad, approvedSceneMoves
local KEY, LIMIT = "HA.SwitchUpgrade.v1", 16
local SCENE_REMOVAL_KEY = "HA.SwitchUpgrade.SceneRemoval.v1."
local movedScenesVerified =
  "The lighting scenes already use the new driver. Choose Continue migration to finish moving control."
local LEGACY_INPUT, LEGACY_CLASS = ids.lightCoordinatorBinding, ids.legacyCoordinatorClass
local powerActions = { { "Turn On", "TurnOn" }, { "Turn Off", "TurnOff" } }
local additionalActions = { { "Turn On", "TurnOn" }, { "Turn Off", "TurnOff" }, { "Toggle", "Toggle" } }
local metrics = require("ha.performance").shared

local function traceLegacy(message, ...)
  pcall(log.trace, log, "Legacy migration " .. message, ...)
end

local function migrationCheck(passed, check)
  if not passed then
    traceLegacy("check rejected: %s", check)
  end
  return passed
end

local loadRetryMessages = {
  not_found = "Home Assistant couldn’t find the selected %s. Check that it appears and responds in Home Assistant before retrying.",
  unavailable = "The selected %s is unavailable in Home Assistant. Retry when it becomes available.",
  timeout = "Home Assistant took too long to report the state of the selected %s. Check that it responds in Home Assistant before retrying.",
  permission_denied = "The Home Assistant account couldn’t read the selected %s. Check its access before retrying.",
  disconnected = "Quick Setup couldn’t check the selected %s because Home Assistant was disconnected. Wait for it to reconnect before retrying.",
}

local function readMigrationLoad(connection, entity)
  return connection:readState(entity):next(function(state)
    if contract.state(state, entity) and state.state == "unavailable" then
      error({ migrationLoad = "unavailable" }, 0)
    end
    return state
  end, function(failure)
    if type(failure) == "table" and loadRetryMessages[failure.kind] then
      error({ migrationLoad = failure.kind }, 0)
    end
    error(failure, 0)
  end)
end

local function timeEvidence(operation, read)
  local span = metrics:start(operation)
  local work = read()
  if not span then
    return work
  end
  return work:next(function(value)
    metrics:finish(span, value == false and "rejected" or "ok")
    return value
  end, function(problem)
    local reason = type(problem) == "table" and (problem.migrationLoad or problem.kind)
    local outcome = (reason == "timeout" or reason == "disconnected" or reason == "retired") and reason or "rejected"
    metrics:finish(span, outcome)
    error(problem, 0)
  end)
end

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

local function canStartSceneRemoval(record)
  return record.phase == "prepared"
    or record.phase == "review"
    or record.phase == "attention"
    or record.phase == "cutover" and record.movingScenes == true
end

local function sceneRemovalIntent(batch, record)
  return {
    token = batch.token,
    revision = batch.revision,
    source = record.source.id,
    destination = record.destination,
    attempt = record.sceneRemovalAttempt,
  }
end

local function sceneAttemptIssue(expected, saved)
  if saved == expected then
    return nil
  elseif saved == nil then
    return "saved scene attempt missing"
  elseif not contract.integer(saved) or not contract.integer(expected) then
    return "saved scene attempt invalid"
  elseif saved < expected then
    return "saved scene attempt older than the active attempt"
  end
  return "saved scene attempt newer than the active attempt"
end

local function readDurableObject(key)
  -- The template cache acknowledges writes before Director has stored them.
  local ok, raw = pcall(C4.PersistGetValue, C4, key, true)
  if not ok then
    return nil, false, "storage read failed"
  end
  if raw == nil or raw == "" then
    return nil, true
  end
  local stored = codec.storedObject(raw)
  return stored, stored ~= nil, not stored and "stored value is invalid" or nil
end

local function restorableBatch()
  local batch = savedBatch()
  for index, record in ipairs(batch and batch.records or {}) do
    -- Builds that first introduced the removal intent saved this recheck result
    -- as a message. Preserve that result on refresh and across an upgrade.
    if record.sceneAttempted and record.phase == "prepared" and record.message == movedScenesVerified then
      record.sceneMoveVerified = true
    end
    if
      canStartSceneRemoval(record)
      and not record.sceneMoveVerified
      and record.source.family == "light"
      and record.destination
    then
      local stored, readable = readDurableObject(SCENE_REMOVAL_KEY .. index)
      if not readable or stored and codec.encode(stored) == codec.encode(sceneRemovalIntent(batch, record)) then
        record.phase = "scene_transfer"
      end
    end
  end
  return batch
end

function Upgrade.releaseBlocked()
  local ok, batch = pcall(restorableBatch)
  if not ok then
    return true
  end
  for _, record in ipairs(batch and batch.records or {}) do
    if type(record) ~= "table" or record.phase ~= "upgraded" or not record.namesVerified then
      return true
    end
  end
  return false
end

local sceneRecoveryMessage =
  "Quick Setup could not finish moving the lighting scenes and switching control to the new driver. Restore the project backup before continuing."
local previousReleaseRecovery =
  "The drivers were updated during migration. Restore the project backup before starting again."
local restoredControlRecovery =
  "The original Home Assistant connection was restored. Restore the project backup to undo any reference changes."

local function movedScenesNeedRecheck(record)
  return (record.sceneMoveVerified or record.sceneAttempted and record.source.family == "light")
    and record.message == restoredControlRecovery
end

local function needsReleaseRecheck(record)
  return record.phase == "recovery"
    and record.source.origin == "Legacy HA"
    and (
      record.message == previousReleaseRecovery
      or record.sceneAttempted and not record.movingScenes and record.message == sceneRecoveryMessage
      or movedScenesNeedRecheck(record)
    )
end

local function canRecheckSaved(record, revision, savedRevision)
  return revision
    and needsReleaseRecheck(record)
    and (revision > savedRevision or revision == savedRevision and movedScenesNeedRecheck(record))
end

local function recoveryRequired(batch, revision)
  for _, record in ipairs(batch and batch.records or {}) do
    if record.phase == "recovery" and not canRecheckSaved(record, revision, batch.revision) then
      return record.message
    elseif record.phase == "scene_transfer" then
      return sceneRecoveryMessage
    end
  end
end

local function hasMovedSceneRecovery(batch)
  for _, record in ipairs(batch.records) do
    if record.phase == "recovery" and movedScenesNeedRecheck(record) then
      return true
    end
  end
  return false
end

local function sameSource(planned, now, buttonMigration)
  return now
    and now.family == planned.family
    and (buttonMigration or now.interfaces)
    and now.file == planned.file
    and now.version == planned.version
    and now.room_id == planned.room_id
    and (buttonMigration or now.entity == planned.entity)
    and now.mode == planned.mode
    and (
      planned.origin ~= "Legacy HA"
      or (
        now.origin == planned.origin
        and now.proxies[1]
        and planned.proxies[1]
        and now.proxies[1].id == planned.proxies[1].id
        and codec.encode(now.compatibility) == codec.encode(planned.compatibility)
      )
    )
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

local function connectionPlan(source, peers, reviewedEdges, replacement)
  local mapped, labels, complete = {}, {}, source.bindingsVerified or source.interfaces
  local moved = false
  for _, edge in ipairs(reviewedEdges or source.edges) do
    if edge.binding ~= LEGACY_INPUT or edge.owner ~= source.id then
      local role = assess.destination(edge.binding, source)
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
        local alreadyMoved = replacement ~= nil and owner == replacement and port == role.new
        movable = (owner == source.id and port == edge.binding) or alreadyMoved
        moved = moved or alreadyMoved
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
  return mapped, labels, complete == true, moved
end

local function refreshConnectionPlan(record, current)
  if
    not record.connectionLabels
    or record.relayStarted
    or record.phase == "cutover"
    or (record.mappedConnections and #current.edges >= #record.source.edges)
  then
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
  -- A moved connection is absent from the original's live inventory. Re-read
  -- the reviewed consumer to verify either exact end of the planned move.
  local planned, labels, complete, moved = connectionPlan(current, {}, record.source.edges, record.destination)
  record.connectionLabels = labels
  record.mappedConnections = complete and planned or nil
  if complete then
    -- Once cutover begins, restoration must reverse this verified move too.
    record.relayStarted = moved or record.relayStarted
  end
end

local function sameStage(record, device)
  return device
    and device.family == record.source.family
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
  if record.source.origin == "Legacy HA" then
    local selection = device
      and migrationSelection.read(device.id, record.resumeSelection and record.lightSettings, record.resumeSelection)
    return sameStage(record, device)
      and (device.provider == 0 or device.provider == coordinator)
      and selection
      and selection.stable
      and (
        selection.key == ""
        or record.resumeSelection and device.provider == 0 and additionalIdentity(record, selection)
      )
  end
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
    if reference.timerScript then
      item.moveTimer = true
      item.instruction = "Move the Timer Agent action to the same event on the replacement, using the same timer."
    else
      item.instruction = "Recreate this event’s programming on the new driver and verify it in Composer."
        .. " Then remove the actions from this event on the old driver."
    end
    details[#details + 1] = item
  end
  for _, reference in ipairs(programs.incoming) do
    local item = assess.programReference(reference)
    local mapped = 0
    if not manualOnly then
      for _, action in ipairs(original.origin == "Legacy HA" and additionalActions or powerActions) do
        local name = action[1]
        local count = (reference.commands or {})[name] or 0
        if original.origin == "Legacy HA" and action[2] ~= name then
          count = count + ((reference.commands or {})[action[2]] or 0)
        end
        mapped = mapped + count
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
    if mapped == 0 or (reference.actionCount or 0) > mapped then
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
  return "Old " .. (source.family == "light" and "light" or "switch") .. " driver " .. source.id
end

local function additionalEdges(source)
  local proxy = source.proxies[1] and source.proxies[1].id
  local result = {}
  for _, edge in ipairs(source.edges) do
    local internal = edge.binding == ids.proxy
      and edge.port == ids.proxy
      and ((edge.owner == source.id and edge.device == proxy) or (edge.owner == proxy and edge.device == source.id))
    if not internal and not (edge.owner == source.id and edge.binding == 5 and edge.direction == "input") then
      result[#result + 1] = edge
    end
  end
  return result
end

local function additionalPlan(source)
  local plan = {}
  for _, edge in ipairs(additionalEdges(source)) do
    local role = assess.destination(edge.binding, source)
    if not (role and role.new and edge.owner == source.id and edge.direction == "output") then
      return nil
    end
    plan[#plan + 1] = { from = edge.binding, to = role.new, device = edge.device, port = edge.port, class = role.class }
  end
  return plan
end

local function hasProgrammingWork(programs)
  return not programs.readable or programs.truncated == true or #programs.attached + #programs.incoming > 0
end

local function approvedActions(reference)
  local names, total = codec.object({}), 0
  for position, command in pairs(reference.positions or {}) do
    local action = ({ ["Turn On"] = "TurnOn", ["Turn Off"] = "TurnOff" })[command] or command
    names[position], total = action, total + 1
  end
  return total == reference.actionCount and codec.encode(names) or nil
end

local function programmingBlock(programs, source)
  if not programs.readable or programs.truncated then
    return "Quick Setup could not read all saved programming. Refresh the list to check again."
  end
  local timers = {}
  for _, reference in ipairs(programs.attached) do
    if not reference.timerScript or timers[reference.event] then
      local item = assess.programReference(reference, source)
      return "Quick Setup cannot verify how to move the programming on "
        .. item.location
        .. " → "
        .. (item.event or "Event " .. item.eventId)
        .. ". The original stays in place."
    end
    timers[reference.event] = true
  end
  for _, reference in ipairs(programs.incoming) do
    if not approvedActions(reference) then
      local item = assess.programReference(reference)
      return "Quick Setup cannot verify an action that targets this driver from "
        .. item.location
        .. " → "
        .. (item.event or "Event " .. item.eventId)
        .. ". The original stays in place."
    end
  end
end

local function additionalProgramming(source, original, destination)
  local expected = source.programs
  if (original and hasProgrammingWork(original.programs)) or programmingBlock(expected, source) then
    return false
  end
  local current = assess.deviceProgramming(destination, source.family)
  if
    not current.readable
    or current.truncated
    or #current.attached ~= #expected.attached
    or #current.incoming ~= #expected.incoming
  then
    return false
  end
  for i, reference in ipairs(expected.attached) do
    local found = current.attached[i]
    if found.event ~= reference.event or found.timerScript ~= reference.timerScript then
      return false
    end
  end
  for i, reference in ipairs(expected.incoming) do
    local found = current.incoming[i]
    if
      found.device ~= reference.device
      or found.event ~= reference.event
      or approvedActions(found) ~= approvedActions(reference)
    then
      return false
    end
  end
  return true
end

local function view(record, preview)
  local s = record.source
  local reviewed = preview and record.reviewedLoad
  local row = {
    id = s.id,
    name = s.name or "HA Switch",
    family = s.origin == "Legacy HA" and s.family or nil,
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
    reviewedLoad = reviewed
        and { entity = reviewed.load, name = reviewed.name, area = reviewed.area, previous = reviewed.previous }
      or nil,
    tested = record.tested == true or nil,
    referencesReviewed = record.referencesReviewed == true or nil,
    unresolvedConnections = record.connectionLabels ~= nil and record.mappedConnections == nil or nil,
  }
  if s.origin == "Legacy HA" then
    row.lightType = preview and s.compatibility and s.compatibility.kind or nil
    if preview and record.lightSettings then
      row.lightSettings = {
        original = {
          kind = s.compatibility.kind,
          format = record.lightSettings.format and s.compatibility.format or nil,
          range = record.lightSettings.range and (s.compatibility.minK .. "-" .. s.compatibility.maxK) or nil,
        },
        replacement = record.lightSettings,
      }
    end
    row.lighting = {}
    row.lightingReview = record.phase == "review" and record.lightingReview or nil
    row.automaticScenes = preview
        and s.family == "light"
        and s.proxies[1]
        and lighting.directScenePlan(s.lighting, s.proxies[1].id) ~= nil
      or nil
    for _, kind in ipairs({ "scenes", "groups" }) do
      local seen = {}
      for _, references in pairs(s.lighting and s.lighting[kind] or {}) do
        for id, reference in pairs(references) do
          if not seen[id] then
            row.lighting[#row.lighting + 1] = { kind = kind, name = reference.name }
            seen[id] = true
          end
        end
      end
    end
    table.sort(row.lighting, function(a, b)
      return a.kind == b.kind and a.name < b.name or a.kind < b.kind
    end)
    row.connections = {}
    for _, edge in ipairs(additionalEdges(s)) do
      local role = assess.destination(edge.binding, s)
      local transferable = record.mappedConnections and role and role.new and edge.owner == s.id
      row.connections[#row.connections + 1] = {
        role = role and role.name or "Connection",
        target = assess.deviceLocation(edge.device),
        transfer = transferable and true or nil,
      }
      row.unresolvedConnections = row.unresolvedConnections or not transferable
    end
  end
  if record.namesVerified then
    row.replacement, row.oldDriver = s.name, record.retiredName
    for _, action in ipairs(record.powerPlan or {}) do
      local item = assess.programReference(action)
      item.command = action.label
      row.verifiedActions = row.verifiedActions or {}
      row.verifiedActions[#row.verifiedActions + 1] = item
    end
    if s.origin == "Legacy HA" and not row.tested then
      for _, reference in ipairs(s.programs.incoming) do
        local item = assess.programReference(reference)
        row.testEvents = row.testEvents or {}
        row.testEvents[#row.testEvents + 1] = item
      end
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
    batch = restorableBatch(),
    serial = 0,
  }, Upgrade)
end

-- Bind testing to the batch and exact driver pairs behind the displayed rows.
local function removalScope(batch)
  local pairs = { batch.token }
  for _, record in ipairs(batch.records) do
    if record.namesVerified then
      pairs[#pairs + 1] = record.source.id .. ":" .. (record.destination or 0)
    end
  end
  return table.concat(pairs, "|")
end

function Upgrade:state()
  local rows = {}
  local batch = self.batch
  local records = batch and batch.records or {}
  local function waitingForSceneReview(record)
    return record.phase == "review" and record.lightingReview and record.sceneAttempted
  end
  local needsNames, canReviewRemoval, waitingForLoad, interrupted = false, false, false, false
  local waitingForScenes, waitingForRelease = false, false
  for _, record in ipairs(records) do
    waitingForLoad = waitingForLoad or record.phase == "target"
    waitingForScenes = waitingForScenes or waitingForSceneReview(record)
    waitingForRelease = waitingForRelease or needsReleaseRecheck(record)
    interrupted = interrupted or record.phase == "cutover"
    if record.phase == "upgraded" or record.phase == "naming" then
      needsNames = needsNames or not record.namesVerified
      canReviewRemoval = canReviewRemoval or record.namesVerified == true
    end
  end
  local revision = not self.running
    and (waitingForLoad or interrupted or waitingForScenes or waitingForRelease)
    and installed.upgradeRevision(self.coordinator)
  for _, record in ipairs(records) do
    local row = view(record)
    if not self.running and record.phase == "scene_transfer" then
      row.state, row.message = "recovery", sceneRecoveryMessage
    elseif canRecheckSaved(record, revision, batch.revision) then
      row.state, row.message = "release_recheck", nil
    elseif revision and revision > batch.revision and waitingForSceneReview(record) then
      row.lightingReview = nil
      row.message = "The drivers were updated. Choose Continue migration to recheck the saved scenes."
    end
    rows[#rows + 1] = row
  end
  return {
    rows = rows,
    running = self.running == true,
    progress = self.running and self.progress or nil,
    saved = batch ~= nil,
    token = batch and batch.token or nil,
    needsNames = needsNames,
    canReviewRemoval = canReviewRemoval,
    removalScope = canReviewRemoval and removalScope(batch) or nil,
    releaseChanged = not self.running and waitingForLoad and revision ~= batch.revision or nil,
    interruptedCutover = interrupted and revision and revision > batch.revision or nil,
  }
end

function Upgrade:showProgress(message)
  if self.running and not self.closed and self.progress ~= message then
    self.progress = message
    self.notify(self:state())
  end
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

function Upgrade:traceSavedRecovery()
  for _, record in ipairs(self.batch and self.batch.records or {}) do
    if record.phase == "recovery" and record.cutoverStep then
      traceLegacy("saved cutover failure: %s", record.cutoverStep)
    end
  end
end

function Upgrade:checkpointSceneRemoval(record)
  local receipt = deferred.new()
  local index
  for position, row in ipairs(self.batch.records) do
    if row == record then
      index = position
      break
    end
  end
  local key = SCENE_REMOVAL_KEY .. assert(index)
  local expected = sceneRemovalIntent(self.batch, record)
  local intent = codec.encode(expected)
  local lightingProof = codec.encode(record.source.lighting)
  local normalizedProof = lighting.checkpointProof(record.source.lighting)
  local reportedNormalization
  local function savedPlanIssue()
    local saved, _, readIssue = readDurableObject(KEY)
    if not saved then
      return readIssue and "saved migration " .. readIssue or "saved migration missing"
    end
    local prior = type(saved.records) == "table" and saved.records[index]
    if type(prior) ~= "table" or type(prior.source) ~= "table" then
      return "saved driver record missing"
    elseif saved.token ~= expected.token or saved.revision ~= expected.revision then
      return "saved migration batch differs"
    elseif
      prior.gateway ~= record.gateway
      or prior.source.id ~= expected.source
      or prior.destination ~= expected.destination
    then
      return "saved scene driver identity differs"
    elseif codec.encode(prior.source.lighting) ~= lightingProof then
      if not normalizedProof or lighting.checkpointProof(prior.source.lighting) ~= normalizedProof then
        return "saved scene settings differ"
      elseif not reportedNormalization then
        pcall(log.trace, log, "Saved scene checkpoint matches after normalizing empty maps")
        reportedNormalization = true
      end
    end
    local attemptIssue = sceneAttemptIssue(expected.attempt, prior.sceneRemovalAttempt)
    if attemptIssue then
      return attemptIssue
    elseif not canStartSceneRemoval(prior) or prior.sceneMoveVerified then
      return "saved migration phase does not permit scene removal"
    end
  end
  local wroteIntent, previousStatus = false, nil
  record.phase = "scene_transfer"
  local function check(attempt)
    local status = "operation closed"
    if not self.closed then
      local planIssue = savedPlanIssue()
      if not wroteIntent and not planIssue then
        -- Record the destructive boundary independently of the full batch. A restart
        -- sees the intent even when the last full save is still the prepared record.
        persist:set(key, intent, true)
        persist:flush(key)
        wroteIntent = true
      end
      status = planIssue or "saved removal intent missing"
      if wroteIntent then
        local stored, _, readIssue = readDurableObject(key)
        if not planIssue then
          if stored and codec.encode(stored) == intent then
            pcall(log.trace, log, "Scene migration removal checkpoint verified after %d checks", attempt)
            return receipt:resolve()
          elseif readIssue then
            status = "removal intent " .. readIssue
          elseif stored then
            status = "saved removal intent differs"
          end
        end
      end
    end
    if status ~= previousStatus then
      pcall(log.trace, log, "Scene migration removal checkpoint check %d: %s", attempt, status)
      previousStatus = status
    end
    if not self.closed and attempt < 17 then
      local scheduled, timer = pcall(C4.SetTimer, C4, 125, function()
        check(attempt + 1)
      end)
      if scheduled and timer then
        return
      end
      status = status .. " (readback timer unavailable)"
    end
    pcall(log.trace, log, "Scene migration removal checkpoint unavailable after %d checks: %s", attempt, status)
    receipt:reject({ reason = "scene_checkpoint_unavailable" })
  end
  check(1)
  return receipt, function()
    if wroteIntent then
      persist:delete(key)
    end
  end
end

function Upgrade:confirmCutover(record, active)
  local receipt = deferred.new()
  local function check(attempt)
    if self.closed or not active() then
      return receipt:resolve(false)
    end
    local batch, _, readIssue = readDurableObject(KEY)
    local issue = readIssue and "saved migration " .. readIssue or "saved migration missing"
    if batch then
      issue = "saved migration batch differs"
    end
    if
      batch
      and batch.token == self.batch.token
      and batch.revision == self.batch.revision
      and type(batch.records) == "table"
    then
      issue = "saved driver record missing"
      for _, saved in ipairs(batch.records) do
        if type(saved) == "table" and type(saved.source) == "table" and saved.source.id == record.source.id then
          if saved.destination ~= record.destination or saved.gateway ~= record.gateway then
            issue = "saved cutover driver identity differs"
          else
            issue = sceneAttemptIssue(record.sceneRemovalAttempt, saved.sceneRemovalAttempt)
            if not issue then
              if saved.phase == "cutover" and saved.movingScenes == record.movingScenes then
                return receipt:resolve(true)
              end
              issue = "saved migration phase does not match cutover"
            end
          end
        end
      end
    end
    if attempt >= 17 or not C4:SetTimer(125, function()
      check(attempt + 1)
    end) then
      traceLegacy("gateway release stopped after %d checkpoint checks: %s", attempt, issue)
      receipt:resolve(false)
    end
  end
  check(1)
  return receipt
end

function Upgrade:availability()
  local records = self.batch and self.batch.records or {}
  local originals, sourceIds = {}, {}
  if self.running then
    return { count = 0, pending = true }
  end
  for _, record in ipairs(records) do
    if record.phase ~= "upgraded" and record.phase ~= "manual" then
      return { count = 0, pending = true }
    end
    local id = tostring(record.source.id)
    originals[id] = record.source.file
    sourceIds[#sourceIds + 1] = id
  end
  -- Reopening a migration only needs to know whether a saved original still exists.
  -- Assess the whole project only when looking for other migrations.
  if #sourceIds > 0 then
    local devices = C4:GetDevices({ DeviceIds = table.concat(sourceIds, ",") })
    if type(devices) == "table" then
      for key, device in pairs(devices) do
        local file = originals[tostring(key)]
        if file and type(device) == "table" and device.driverFileName == file then
          return { count = 0, pending = true }
        end
      end
    end
  end
  local count = 0
  for _, source in ipairs(assess.sources(nil, true)) do
    if originals[tostring(source.id)] then
      return { count = 0, pending = true }
    end
    if source.origin == "Legacy HA" or (source.family ~= "light" and legacyLink(source.id) == self.coordinator) then
      count = count + 1
    end
  end
  return { count = count, pending = false }
end

function Upgrade:scanReadiness()
  if not self.hub.online then
    return nil, "home_assistant"
  end
  local revision = installed.upgradeRevision(self.coordinator)
  if not revision then
    return nil, "driver_versions"
  end
  return revision
end

function Upgrade:list(evidence, revision)
  local span = metrics:start("migration.assess")
  local rows, seen, records = {}, {}, {}
  revision = revision or installed.upgradeRevision(self.coordinator)
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
          elseif not self.hub.online then
            record.message = "Wait for Home Assistant to connect, then refresh this list."
          elseif not revision then
            record.message = "Check that the Home Assistant drivers are on the same version, then refresh this list."
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
  local additional = {}
  for _, item in ipairs(assess.sources(nil, true)) do
    if item.origin == "Legacy HA" then
      additional[#additional + 1] = item
    end
  end
  local inProgress = {}
  local lightingSnapshot, ownerInventory, networkAddresses
  local reviewedSelections = {}
  for _, record in ipairs(self.batch and self.batch.records or {}) do
    inProgress[record.source.id] = true
  end
  for _, item in ipairs(additional) do
    if not inProgress[item.id] then
      programming = programming == nil and assess.programmingSnapshot() or programming
      lightingSnapshot = lightingSnapshot or lighting.snapshot()
      local source = assess.assess(item.id, { programming = programming, lightingSnapshot = lightingSnapshot })
      if source then
        local gateway = legacyProfile.gateway(source)
        local catalog = self.hub.catalog
        local load, target, targetRegistry
        if source.entity and catalog then
          load, target, targetRegistry = catalog:exactLoadChoice(source.entity, source.family)
        end
        local record =
          { source = source, phase = "ready", gateway = gateway, mappedConnections = additionalPlan(source) }
        local binaryLight = source.compatibility
          and source.compatibility.kind == "On/off"
          and contract.loadDomain(source.entity) ~= "light"
        if source.family == "light" and not binaryLight then
          record.lightSettings = compatibility.migrationSettings(source.entity, source.compatibility)
        end
        local endpointIssue
        if gateway and gateway ~= 0 and load then
          networkAddresses = networkAddresses or legacyProfile.networkAddresses()
          record.endpoint, endpointIssue =
            self:additionalEndpoint(record, networkAddresses, evidence, target, targetRegistry)
        end
        local owned, peer
        if load then
          if not ownerInventory then
            ownerInventory = evidence and evidence.inventory or project.inventory(true)
          end
          owned, peer = self:checkOwnership(
            record,
            nil,
            { entity_id = target or source.entity },
            nil,
            ownerInventory,
            evidence,
            reviewedSelections
          )
        end
        local blockedProgramming = programmingBlock(source.programs, source)
        if not self.hub.online then
          record.message = "Wait for Home Assistant to connect, then refresh this list."
        elseif not revision then
          record.message = "Check that the Home Assistant drivers are on the same version, then refresh this list."
        elseif not source.interfaces or not source.room_id or not source.name or not gateway or gateway == 0 then
          record.message = "Check the original driver and its Home Assistant connection in Composer."
        elseif not load then
          record.message = "Check the selected Home Assistant device and refresh the list."
        elseif not record.endpoint then
          record.message = endpointIssue == "device"
              and "Quick Setup could not verify the selected device in Home Assistant. Check the device and refresh the list."
            or (
              endpointIssue == "separate"
                and "The original driver uses a different Home Assistant installation. Open Quick Setup on the Coordinator for that installation."
              or "Quick Setup could not verify that both connections reach the same Home Assistant. Use the same address, port and HTTPS setting, or update HA Gesture Bridge and refresh the list."
            )
        elseif not lighting.complete(source.lighting) then
          record.message = "The saved lighting references could not be read. Refresh the list to check them again."
        elseif blockedProgramming then
          record.message = blockedProgramming
        elseif not owned then
          record.message = ownershipMessage(peer, true)
        elseif source.family == "light" and not binaryLight and not record.lightSettings then
          record.message = "This Light's saved capability settings need a verified mapping before migration."
        else
          record.reviewedLoad = {
            load = target or source.entity,
            name = load.name,
            area = load.area_name,
            previous = target and catalog:loadDetails(source.entity, true) or nil,
          }
          record.deviceName = load.name
          record.message = #source.programs.attached > 0 and "Review the programming to move before switching drivers."
            or "Prepare a replacement for review"
        end
        if not record.reviewedLoad then
          record.phase = "blocked"
        end
        records[item.id] = record
        rows[#rows + 1] = record
      end
    end
  end
  for _, record in ipairs(rows) do
    views[#views + 1] = view(record)
  end
  metrics:finish(span, "ok")
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

function Upgrade:review(selected, evidence)
  if self.running or type(selected) ~= "table" or #selected < 1 or #selected > LIMIT then
    return { error = "Choose up to 16 drivers to review." }
  end
  self.preview = nil
  local _, records, revision = self:list(evidence)
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
      device.file == ids.packages[record.source.family].file
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
  local source = record.source
  local oldLink
  if source.origin == "Legacy HA" then
    oldLink = legacyProfile.gateway(original) == record.gateway
  else
    oldLink = legacyLink(source.id) == self.coordinator
  end
  if not sameOriginal(record, original) or not oldLink then
    local changed = deferred.new()
    changed:reject("original_changed")
    return changed
  end
  record.addAttempt = (record.addAttempt or 0) + 1
  local suffix = " (new driver " .. self.batch.token .. "-" .. record.source.id .. "-" .. record.addAttempt .. ")"
  if (record.buttonBehavior or source.origin == "Legacy HA") and record.addAttempt == 1 then
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
      file = ids.packages[record.source.family].file,
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
  if record.source.origin == "Legacy HA" then
    local old = legacyProfile.gateway(original)
    if
      not sameOriginal(record, original)
      or not sameStage(record, new)
      or (old ~= 0 and old ~= record.gateway)
      or (new.provider ~= 0 and new.provider ~= self.coordinator)
    then
      return false
    end
    if new.provider == self.coordinator then
      C4:Unbind(device, new.input)
    end
    new = project.device(device)
    if not new or new.provider ~= 0 then
      return false
    end
    if old == 0 then
      Bind(record.gateway, 5, source, 5, "HOMEASSISTANT_DEVICES")
    end
    if legacyProfile.gateway(original) ~= record.gateway then
      return false
    end
    if record.relayStarted then
      if
        not relays.canRestore(record, device, { edges = additionalEdges(original) })
        or relays.move(record, device, true, function()
          self:save()
        end).error
      then
        return false
      end
    end
    return true
  end
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

function Upgrade:restoreControl(record, stagedScenes)
  if record.phase == "cutover" and record.movingScenes then
    local source = record.source
    local proxy, extraProxy = C4:GetProxyDevicesById(record.destination)
    local old = source.proxies[1] and source.proxies[1].id
    local plan = old and lighting.directScenePlan(source.lighting, old, approvedSceneMoves(record, self.batch.records))
    if plan and contract.integer(tonumber(proxy)) and not extraProxy then
      local intact, added = lighting.intactSceneStage(plan, tonumber(proxy))
      if intact then
        stagedScenes = added
      end
    end
    if stagedScenes == nil then
      record.phase, record.message = "recovery", sceneRecoveryMessage
      return false
    end
    record.movingScenes = nil
    record.sceneAttempted = stagedScenes and record.sceneAttempted or nil
  end
  local span = metrics:start("migration.restore")
  local ok, restored = pcall(self.rollback, self, record)
  metrics:finish(span, ok and restored and "ok" or "failed")
  if not ok or not restored then
    record.phase, record.message =
      "recovery", "Control could not be verified. Restore the project backup before continuing."
    return false
  end
  if record.source.origin == "Legacy HA" then
    local selection = migrationSelection.read(record.destination, record.lightSettings, true)
    record.resumeSelection = additionalIdentity(record, selection) or nil
    if
      (not record.sceneAttempted or stagedScenes)
      and not record.sceneMoveVerified
      and not record.relayStarted
      and selection
      and selection.stable
      and (selection.key == "" or record.resumeSelection)
    then
      record.phase, record.message = "attention", "The original is connected. Retry driver setup to continue."
    else
      record.phase, record.message = "recovery", restoredControlRecovery
    end
    return true
  end
  record.phase = "restored"
  record.message = (record.buttonBehavior or not self.hub.online)
      and "The original driver’s connections were restored."
    or "The old driver controls the switch again."
  if hasProgrammingWork(record.source.programs) or record.manualProgramming == "confirmed" then
    record.message = record.message
      .. " Any programming you moved still points to the new driver. Restore the project backup to undo those edits."
  end
  record.message = record.message .. " Check the Home Assistant connection before retrying."
  return true
end

function Upgrade:waitReady(record)
  local pending = deferred.new()
  local attempts = 0
  local legacy = record.source.origin == "Legacy HA"
  local selectionSpan = legacy and metrics:start("migration.selection_readback")
  local feedbackSpan = metrics:start("migration.feedback")
  local afterSelectionSpan
  local function finish(outcome)
    metrics:finish(selectionSpan, outcome)
    metrics:finish(feedbackSpan, outcome)
    metrics:finish(afterSelectionSpan, outcome)
  end
  local function reject(reason)
    if legacy then
      record.cutoverStep = "replacement feedback: " .. reason
      traceLegacy("replacement feedback failed: %s after %d checks", reason, attempts + 1)
    end
    finish(reason == "no_feedback" and "timeout" or reason == "retired" and "retired" or "rejected")
    pending:reject(reason)
  end
  local function ready()
    if not legacy then
      return replacementStatus(record) == "ready"
    end
    local selection = migrationSelection.read(record.destination, record.lightSettings, true)
    if additionalIdentity(record, selection) then
      if selectionSpan and not afterSelectionSpan then
        metrics:finish(selectionSpan, "ok")
        selectionSpan = nil
        afterSelectionSpan = metrics:start("migration.feedback_after_selection")
      end
      if selection.ready then
        metrics:finish(afterSelectionSpan, "ok")
      end
      return selection.ready
    end
    return false
  end
  local function check()
    local ok = pcall(function()
      if self.closed then
        reject("retired")
      elseif
        legacy
        and (legacyProfile.gateway(record.source) ~= 0 or contract.provider(record.destination) ~= self.coordinator)
      then
        reject("project_changed")
      elseif
        not legacy
        and (
          installed.upgradeRevision(self.coordinator, record.destination) ~= self.batch.revision
          or legacyLink(record.source.id) ~= 0
          or contract.provider(record.destination) ~= self.coordinator
        )
      then
        reject("project_changed")
      elseif ready() then
        if
          legacy
          and installed.upgradeRevision(self.coordinator, record.destination, record.source.family)
            ~= self.batch.revision
        then
          reject("project_changed")
        else
          finish("ok")
          pending:resolve(true)
        end
      elseif attempts >= 16 then
        reject("no_feedback")
      else
        attempts = attempts + 1
        local pollSpan = metrics:start("migration.feedback_poll_interval")
        local callback = check
        if pollSpan then
          callback = function()
            metrics:finish(pollSpan, self.closed and "retired" or "ok")
            check()
          end
        end
        if not SetTimer("HA.SwitchUpgrade.Readiness", 500, callback) then
          reject("readback_unavailable")
        end
      end
    end)
    if not ok then
      reject("readback_unavailable")
    end
  end
  check()
  return pending
end

function Upgrade:checkReplacement(record, requireReady, evidence, verifyAllScenes, verifiedProxy)
  local source, device = record.source, record.destination
  local new = device and project.device(device)
  local proxy, extraProxy
  if device then
    proxy, extraProxy = C4:GetProxyDevicesById(device)
    proxy = tonumber(proxy)
  end
  if source.origin == "Legacy HA" then
    local referencesVerified = not verifyAllScenes and verifiedProxy ~= nil and proxy == verifiedProxy
    if
      migrationCheck(
        new and new.family == source.family and new.room_id == source.room_id,
        "replacement family and room"
      )
      and migrationCheck(contract.integer(proxy) and not extraProxy, "replacement proxy")
      and migrationCheck(installed.upgradeRevision(self.coordinator, device, source.family), "replacement release")
      and migrationCheck(contract.provider(device) == self.coordinator, "replacement Coordinator binding")
      and migrationCheck(additionalStatus(record), "replacement target and feedback")
      and migrationCheck(
        referencesVerified or additionalLighting(record, proxy, self.batch.records, verifyAllScenes),
        "replacement lighting references"
      )
      and migrationCheck(additionalProgramming(source, nil, device), "replacement programming references")
      and migrationCheck(
        referencesVerified
          or self:checkOwnership(record, device, { entity_id = additionalLoad(record) }, nil, nil, evidence),
        "replacement target ownership"
      )
      and migrationCheck(
        record.mappedConnections and relays.transferred(record, device),
        "replacement connection transfer"
      )
      and migrationCheck(not relays.destinationIssue(record, device, false), "replacement connections verified")
    then
      return new, proxy
    end
    return
  end
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

function Upgrade:finishRecordNames(record, tested, evidence, verifiedProxy)
  local source = record.source
  -- The replacement check below verifies live scene membership separately.
  local original = assess.assess(source.id, { skipLighting = true })
  local new, proxy = self:checkReplacement(record, not record.buttonBehavior, evidence, nil, verifiedProxy)
  if source.origin == "Legacy HA" then
    if
      not migrationCheck(new, "replacement before naming")
      or not migrationCheck(sameSource(source, original), "original identity before naming")
      or not migrationCheck(legacyProfile.gateway(original) == 0, "original gateway released before naming")
      or not migrationCheck(not hasProgrammingWork(original.programs), "original programming before naming")
      or not migrationCheck(#additionalEdges(original) == 0, "original connections moved before naming")
    then
      return false
    end
    if original.name == source.name then
      RenameDevice(source.proxies[1].id, record.retiredName)
    end
    if
      not migrationCheck(
        C4:GetDeviceDisplayName(source.proxies[1].id) == record.retiredName,
        "retired driver name readback"
      )
    then
      return false
    end
    if C4:GetDeviceDisplayName(proxy) ~= source.name then
      RenameDevice(proxy, source.name)
    end
    if
      not migrationCheck(C4:GetDeviceDisplayName(proxy) == source.name, "replacement driver name readback")
      or not migrationCheck(
        contract.provider(record.destination) == self.coordinator,
        "replacement binding after naming"
      )
      or not migrationCheck(additionalStatus(record), "replacement feedback after naming")
    then
      return false
    end
    record.phase, record.namesVerified = "upgraded", true
    record.message = "New driver connected and feedback verified."
    self:save()
    traceLegacy("verified: names, replacement connection and confirmed feedback. Ready for testing.")
    return true
  end
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

function Upgrade:finishNames(token, manual, tested, evidence)
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
      local ok, finished, reason = pcall(self.finishRecordNames, self, record, nil, evidence)
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

function Upgrade:reviewRemoval(tested, referencesReviewed, evidence, scope)
  if self.running or not self.batch then
    return { error = "Confirm that you tested the new drivers and reviewed their programming." }
  end
  local recovery = recoveryRequired(self.batch)
  if recovery then
    return { error = recovery }
  end
  if scope ~= removalScope(self.batch) then
    return { error = "Refresh migration status before continuing." }
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
      local new, proxy = self:checkReplacement(record, true, evidence, true)
      local original = assess.assess(source.id)
      if not new or C4:GetDeviceDisplayName(proxy) ~= source.name or type(rowsById) ~= "table" then
        row.message = "Keep this driver until its replacement and project details are verified."
      elseif not (rowsById[source.id] or rowsById[tostring(source.id)]) then
        row.state = "removed"
        row.message = "Removed from Control4."
      elseif source.origin == "Legacy HA" then
        if
          migrationCheck(sameSource(source, original), "original identity during removal review")
          and migrationCheck(original.name == record.retiredName, "retired name during removal review")
          and migrationCheck(legacyProfile.gateway(original) == 0, "original gateway released during removal review")
          and migrationCheck(#additionalEdges(original) == 0, "original connections clear during removal review")
          and migrationCheck(
            additionalProgramming(source, original, new.id),
            "programming verified during removal review"
          )
        then
          row.state, row.message = "ready", "Ready to remove in Composer."
        else
          row.message = "Keep this driver until its connections and programming are verified."
        end
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
      if source.origin == "Legacy HA" then
        traceLegacy("old driver removal review: %s", row.state)
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

function additionalLoad(record)
  return record.endpoint and record.endpoint.entity or record.source.entity
end

function additionalIdentity(record, value)
  local target = additionalLoad(record)
  return value
    and value.stable
    and value.mode == "Home Assistant device"
    and value.key == target
    and value.load == target
    and not value.buttons
    and value.saved == true
    and (not record.lightSettings or value.settings_verified == true)
end

function additionalStatus(record, requireReady)
  local value = migrationSelection.read(record.destination, record.lightSettings, true)
  return additionalIdentity(record, value) and (requireReady == false or value.ready)
end

function approvedSceneMoves(record, records)
  local approved = {}
  for _, peer in ipairs(records or {}) do
    local sibling = peer.source
    if
      peer ~= record
      and peer.destination
      and sibling.origin == "Legacy HA"
      and sibling.family == "light"
      and lighting.complete(sibling.lighting)
      and #sibling.proxies == 1
    then
      local destination = project.device(peer.destination)
      if
        destination
        and (
          sameStage(peer, destination)
          or peer.namesVerified
            and destination.name == sibling.name
            and destination.family == sibling.family
            and destination.room_id == sibling.room_id
        )
      then
        local peerProxy, extra = C4:GetProxyDevicesById(peer.destination)
        peerProxy = tonumber(peerProxy)
        if contract.integer(peerProxy) and not extra then
          approved[sibling.id], approved[sibling.proxies[1].id] = peer.destination, peerProxy
        end
      end
    end
  end
  return approved
end

function additionalLighting(record, proxy, records, verifyAllScenes)
  local source, replacement = record.source, record.destination
  local old = source.proxies[1].id
  local savedScenes = lighting.complete(source.lighting) and source.lighting.members.scenes or nil
  local full = verifyAllScenes and source.family == "light"
  local span = metrics:start(full and "migration.scene_verify_all" or "migration.scene_verify")
  local current =
    lighting.read({ [source.id] = true, [old] = true, [replacement] = true, [proxy] = true }, nil, savedScenes, full)
  local approved = approvedSceneMoves(record, records)
  local verified, issue = lighting.compare(source.lighting, current, old, proxy, source.id, replacement, approved)
  metrics:finish(span, verified and "ok" or "rejected")
  return verified, issue, approved, current
end

function Upgrade:additionalEndpoint(record, addresses, evidence, target, targetRegistry)
  local connection = self.hub.connection
  local current = connection and connection.config and legacyProfile.canonicalOrigin(connection.config.origin)
  local legacy
  if self.hub.installation then
    local relation
    relation, legacy, current = self.hub.installation:relation(record.gateway, evidence, addresses)
    if relation ~= "same" then
      return nil, relation == "separate" and "separate" or "connection"
    end
  elseif
    not current
    or not self.hub.online
    or legacyProfile.gatewayOrigin(record.gateway, addresses or legacyProfile.networkAddresses()) ~= current
  then
    return nil, "connection"
  end
  local catalog = self.hub.catalog
  if not catalog then
    return nil, "device"
  end
  local _, _, registry, known = catalog:loadDetails(record.source.entity, true)
  if not known then
    return nil, "device"
  end
  if record.endpoint and record.endpoint.entity then
    local _
    _, target, targetRegistry = catalog:exactLoadChoice(record.source.entity, record.source.family)
    if target ~= record.endpoint.entity then
      return nil, "device"
    end
  end
  if target and (not registry or not targetRegistry) then
    return nil, "device"
  end
  return codec.object({
    origin = current,
    source_origin = legacy ~= current and legacy or nil,
    entity = target,
    source_registry = target and registry or nil,
    registry = targetRegistry or registry,
    unregistered = not registry or nil,
  })
end

local function sameEndpoint(expected, current)
  return expected
    and current
    and expected.origin == current.origin
    and expected.source_origin == current.source_origin
    and expected.entity == current.entity
    and expected.source_registry == current.source_registry
    and expected.registry == current.registry
    and expected.unregistered == current.unregistered
end

function Upgrade:applyAdditional(record, device, evidence)
  self:showProgress("Checking the project and Home Assistant connection…")
  local installation = self.hub.installation
  local function freshScope(operation)
    if installation then
      return timeEvidence(operation, function()
        local sources = {}
        for _, source in ipairs(assess.sources(nil, true)) do
          if source.origin == "Legacy HA" then
            sources[#sources + 1] = { file = source.file, legacy_provider = legacyProfile.gateway(source) }
          end
        end
        return installation:prepare(sources, record.gateway)
      end)
    end
    local work = deferred.new()
    work:resolve({})
    return work
  end
  if installation and not evidence then
    return freshScope("migration.preflight_installation"):next(function(result)
      if not self.closed then
        return self:applyAdditional(record, device, result)
      end
    end)
  end
  local source, target = record.source, additionalLoad(record)
  -- Read the original topology before using the saved scene and connection plans.
  local original, new = assess.assess(source.id, { skipLighting = true }), project.device(device)
  local proxy, extraProxy = C4:GetProxyDevicesById(device)
  proxy = tonumber(proxy)
  if record.phase == "cutover" then
    traceLegacy("stopped: interrupted cutover")
    error("Interrupted legacy cutover")
  end
  record.cutoverStep = nil
  if programmingBlock(source.programs, source) then
    traceLegacy("check rejected: saved programming")
    record.phase, record.message =
      "recovery",
      "Quick Setup cannot verify the saved programming for this replacement. Restore the project backup to undo staging and any Composer edits."
    self:save()
    return
  end
  if not lighting.complete(source.lighting) then
    traceLegacy("check rejected: saved lighting snapshot incomplete")
    record.phase, record.message =
      "recovery",
      "Quick Setup cannot verify all saved lighting references for this replacement. Restore the project backup before trying again."
    self:save()
    return
  end
  if not sameEndpoint(record.endpoint, self:additionalEndpoint(record, nil, evidence)) then
    traceLegacy("check rejected: approved Home Assistant endpoint")
    record.phase, record.message =
      "attention",
      "Quick Setup could not verify the original Home Assistant connection and device. Check the connection and retry driver setup."
    self:save()
    return
  end
  assert(
    migrationCheck(sameOriginal(record, original), "original before migration")
      and migrationCheck(blankStage(record, new, self.coordinator), "staged replacement identity")
      and migrationCheck(contract.integer(proxy) and not extraProxy, "replacement has exactly one proxy")
      and migrationCheck(legacyProfile.gateway(original) == record.gateway, "original gateway still connected")
      and migrationCheck(
        installed.upgradeRevision(self.coordinator, device, source.family) == self.batch.revision,
        "staged driver release"
      ),
    "Review the staged legacy driver again."
  )
  local verification = metrics:start("migration.dependencies")
  self:showProgress("Checking saved scenes and project references…")
  local ok, issue, approvedMoves, currentLighting = additionalLighting(record, proxy, self.batch.records)
  if record.sceneMoveVerified and not ok then
    metrics:finish(verification, "rejected")
    record.phase, record.message = "recovery", restoredControlRecovery
    self:save()
    return
  end
  local references = source.lighting and source.lighting.members
  local referencesMoved = ok and references and (next(references.scenes) or next(references.groups))
  local scenePlan = not ok
    and source.family == "light"
    and lighting.directScenePlan(source.lighting, source.proxies[1].id, approvedMoves)
  if scenePlan then
    local intact, hasAddition, compatible = lighting.intactSceneStage(scenePlan, proxy, currentLighting)
    local eligible = intact
      and compatible
      and (
        not record.sceneAttempted and not hasAddition
        or record.sceneAttempted and (hasAddition or record.sceneAttempted ~= self.batch.revision)
      )
    pcall(
      log.trace,
      log,
      "Scene migration resume: %s. Original members verified: %s. Staged addition: %s. Staged settings eligible: %s.",
      eligible and "eligible" or "manual review",
      tostring(intact == true),
      tostring(hasAddition == true),
      tostring(compatible == true)
    )
    scenePlan = eligible and scenePlan
  end
  local function connectionIssue(live)
    if not record.mappedConnections or not relays.canRestore(record, device, { edges = additionalEdges(live) }) then
      traceLegacy("check rejected: saved connections cannot be restored")
      return "Review the old and new driver connections in Composer before moving control."
    end
    for _, edge in ipairs(additionalEdges(live)) do
      local role = assess.destination(edge.binding, source)
      if not (role and role.new and edge.owner == source.id and edge.direction == "output") then
        traceLegacy("check rejected: unreviewed original connection")
        return "An unreviewed connection is still present on the original driver."
      end
    end
    local problem = relays.destinationIssue(record, device, false)
    migrationCheck(not problem, "replacement connection layout")
    return problem
  end
  local function lightingIssue(message)
    return message
      .. " In Composer, open Agents → Advanced Lighting or the listed load group. Replace "
      .. source.name
      .. " with "
      .. record.name
      .. " and keep the saved settings, then return to Quick Setup to check your changes."
  end
  record.lightingReview = nil
  if not additionalProgramming(source, original, device) then
    traceLegacy("check rejected: current programming references")
    issue = "In Composer Programming, move the listed actions to the new driver, then recheck."
  elseif not ok and not scenePlan then
    traceLegacy("stopped for scene review: automatic scene transfer unavailable")
    record.lightingReview = true
    issue = lightingIssue(issue)
  else
    issue = connectionIssue(original)
  end
  metrics:finish(verification, issue and "rejected" or "ok")
  if issue then
    record.phase, record.message = "review", issue
    self:save()
    return
  end
  record.message = nil
  traceLegacy("initial checks passed. Scene transfer: %s", scenePlan and "required" or "complete")
  local function verifyRegistry(operation)
    local endpoint = record.endpoint
    return timeEvidence(operation, function()
      return self.hub.catalog:verifyLoadRegistry(
        target,
        endpoint.registry,
        endpoint.unregistered,
        endpoint.entity and source.entity,
        endpoint.source_registry
      )
    end)
  end
  local function readApprovedLoad(scope, retried)
    local checkedScope = scope and reply(scope) or freshScope("migration.preflight_installation")
    local state = timeEvidence("migration.preflight_state", function()
      return readMigrationLoad(self.hub.connection, target)
    end)
    local registry = verifyRegistry("migration.preflight_registry"):next(function(matches)
      assert(
        migrationCheck(matches, "Home Assistant registry identity"),
        "The reviewed Home Assistant device could not be verified."
      )
    end)
    return deferred.all({ state, registry, checkedScope }):next(function(results)
      traceLegacy("Home Assistant state and registry reads completed")
      return { state = results[1], evidence = results[3] }
    end, function(failures)
      local failure = failures[1]
      local kind = type(failure) == "table" and failure.migrationLoad
      if kind == "timeout" and not retried and not self.closed and not failures[2] and not failures[3] then
        traceLegacy("Home Assistant state read timed out before cutover. Checking state and identity again.")
        return readApprovedLoad(nil, true)
      end
      traceLegacy(
        "Home Assistant evidence read failed: %s",
        loadRetryMessages[kind] and kind
          or failures[1] and "load state"
          or failures[2] and "registry lookup"
          or failures[3] and "installation identity"
          or "request rejected"
      )
      error(failures[1] or failures, 0)
    end)
  end
  local function verifyStage(state, scope)
    local live, staged = assess.assess(source.id, { skipLighting = true }), project.device(device)
    assert(
      migrationCheck(
        contract.state(state, target) and (state.state == "on" or state.state == "off"),
        "live Home Assistant load state"
      )
        and migrationCheck(sameOriginal(record, live), "original identity before cutover")
        and migrationCheck(blankStage(record, staged, self.coordinator), "replacement identity before cutover")
        and migrationCheck(legacyProfile.gateway(live) == record.gateway, "original gateway before cutover")
        and migrationCheck(
          sameEndpoint(record.endpoint, self:additionalEndpoint(record, nil, scope)),
          "Home Assistant endpoint before cutover"
        )
        and migrationCheck(
          installed.upgradeRevision(self.coordinator, device, source.family) == self.batch.revision,
          "driver release before cutover"
        )
        and migrationCheck(additionalProgramming(source, live, device), "programming before cutover")
        and not connectionIssue(live)
        and migrationCheck(
          self:checkOwnership(record, device, { entity_id = target }, nil, nil, scope),
          "target ownership before cutover"
        ),
      "The project or Home Assistant target changed."
    )
    traceLegacy("project preflight verified before gateway release")
    return staged
  end
  local previousSceneAttempt = not not record.sceneAttempted
  local function moveScenes()
    self:showProgress("Moving the saved scenes to the new driver…")
    local span = metrics:start("migration.scene_move")
    local clearRemovalIntent
    local function readyForRemoval()
      return not self.closed
        and legacyProfile.gateway(source) == 0
        and contract.provider(device) == self.coordinator
        and additionalStatus(record)
    end
    return lighting
      .moveDirectScenes(
        scenePlan,
        source.proxies[1].id,
        proxy,
        function()
          return not self.closed
        end,
        previousSceneAttempt,
        function()
          if not readyForRemoval() then
            local rejected = deferred.new()
            rejected:reject({ reason = "replacement_feedback_lost" })
            return rejected
          end
          local receipt
          receipt, clearRemovalIntent = self:checkpointSceneRemoval(record)
          return receipt
        end,
        readyForRemoval
      )
      :next(function(result)
        metrics:finish(span, result.moved and "ok" or "rejected")
        if self.closed then
          return false
        end
        record.movingScenes = nil
        if result.moved then
          record.phase = "scene_transfer"
          assert(additionalLighting(record, proxy, self.batch.records), "The moved scenes could not be verified.")
          assert(additionalStatus(record), "Replacement feedback was lost after the scene transfer.")
          record.sceneMoveVerified = true
          return true
        end
        pcall(
          log.warn,
          log,
          "Advanced Lighting migration stopped. Check: %s. Differing fields: %s.",
          result.reason,
          result.fields or "none identified"
        )
        if result.originalScenesVerified then
          if clearRemovalIntent then
            clearRemovalIntent()
          end
          record.sceneAttempted = result.stagedAddition and record.sceneAttempted or nil
          if self:restoreControl(record, result.stagedAddition) then
            if result.reason ~= "scene_checkpoint_unavailable" and result.reason ~= "replacement_feedback_lost" then
              record.lightingReview = true
              record.phase, record.message =
                "review",
                lightingIssue(
                  result.scene and ("Check " .. result.scene .. " in Composer.")
                    or "Quick Setup could not verify an automatic scene move."
                )
            end
          end
        else
          record.movingScenes = true
          record.phase, record.message = "recovery", sceneRecoveryMessage
        end
        self:save()
        return false
      end)
  end
  local function cutover(staged)
    self:showProgress("Moving control to the new driver…")
    if referencesMoved then
      record.sceneMoveVerified = true
    end
    if scenePlan then
      -- Make the scene attempt durable with the gateway checkpoint. Director can
      -- still return this batch when the later removal intent must be checked.
      record.sceneAttempted, record.movingScenes = self.batch.revision, true
      record.sceneRemovalAttempt = (record.sceneRemovalAttempt or 0) + 1
    end
    record.phase = "cutover"
    record.cutoverStep = "bind replacement to Coordinator"
    self:save()
    local function releaseGateway(active)
      record.cutoverStep = "release original gateway"
      return self:confirmCutover(record, active):next(function(confirmed)
        if
          not confirmed
          or not active()
          or self.closed
          or not migrationCheck(legacyProfile.gateway(source) == record.gateway, "original gateway before release")
        then
          return false
        end
        local verified, _, _, evidence = additionalLighting(record, proxy, self.batch.records, true)
        if scenePlan then
          local intact, _, compatible = lighting.intactSceneStage(scenePlan, proxy, evidence)
          verified = intact and compatible
        end
        if not migrationCheck(verified, "lighting before gateway release") then
          return false
        end
        traceLegacy("cutover checkpoint saved. Releasing the original gateway.")
        C4:Unbind(source.id, 5)
        return migrationCheck(legacyProfile.gateway(source) == 0, "original gateway released")
      end)
    end
    local work
    if record.resumeSelection then
      work = releaseGateway(function()
        local live = project.device(device)
        return live
          and live.provider == 0
          and additionalIdentity(record, migrationSelection.read(device, record.lightSettings, true))
      end):next(function(released)
        assert(released and not self.closed, "The original gateway could not be released for the saved selection.")
        self:bindReplacement(device, source.room_id, staged.input)
      end)
    else
      if staged.provider == 0 then
        self:bindReplacement(device, source.room_id, staged.input)
      end
      traceLegacy("replacement Coordinator binding verified")
      record.cutoverStep = "send replacement selection"
      work = self.hub.transfer:directLoad(device, source.family, target, record.deviceName, record.lightSettings, {
        beforeApply = releaseGateway,
        applied = function()
          return not self.closed and legacyProfile.gateway(source) == 0 and additionalStatus(record, false)
        end,
      })
    end
    return work
      :next(function()
        self:showProgress("Waiting for the new driver to report its state…")
        traceLegacy("replacement selection accepted. Waiting for feedback.")
        record.cutoverStep = "read replacement feedback"
        return self:waitReady(record)
      end, function(problem)
        local reason = type(problem) == "table" and problem.kind
        if
          type(problem) == "table"
          and problem.step ~= "releasing"
          and (reason == "timeout" or reason == "configuration_unconfirmed" or reason == "target_changed")
        then
          local step = problem.step
          record.cutoverStep = "send replacement selection: " .. reason .. (step and " (" .. step .. ")" or "")
        end
        traceLegacy("check rejected: %s", record.cutoverStep)
        error(problem, 0)
      end)
      :next(function()
        if not self.closed then
          self:showProgress("Verifying the new driver and its project references…")
          traceLegacy("replacement feedback verified")
          record.cutoverStep = "read Home Assistant evidence after cutover"
          return deferred
            .all({
              verifyRegistry("migration.post_cutover_registry"),
              freshScope("migration.post_cutover_installation"),
            })
            :next(nil, function(failures)
              local failed = failures[1] and "registry lookup" or "installation identity"
              record.cutoverStep = "read Home Assistant evidence after cutover: " .. failed
              traceLegacy("post-cutover evidence read failed: %s", failed)
              error(failures, 0)
            end)
        end
      end)
      :next(function(proof)
        if self.closed then
          return
        end
        local function verify(passed, check)
          if not passed then
            record.cutoverStep = check
          end
          return migrationCheck(passed, check)
        end
        record.cutoverStep = "verify project references after cutover"
        local current = assess.assess(source.id, { skipLighting = true })
        local liveProxy, otherProxy = C4:GetProxyDevicesById(device)
        assert(
          verify(proof[1], "Home Assistant registry after cutover")
            and verify(tonumber(liveProxy) == proxy and not otherProxy, "replacement proxy after cutover")
            and verify(sameOriginal(record, current), "original identity after cutover")
            and verify(legacyProfile.gateway(current) == 0, "original gateway after cutover")
            and verify(contract.provider(device) == self.coordinator, "replacement provider after cutover")
            and verify(
              installed.upgradeRevision(self.coordinator, device, source.family) == self.batch.revision,
              "driver release after cutover"
            )
            and verify(additionalStatus(record), "replacement state after cutover")
            and verify(
              sameEndpoint(record.endpoint, self:additionalEndpoint(record, nil, proof[2])),
              "Home Assistant endpoint after cutover"
            )
            and verify(scenePlan or additionalLighting(record, proxy, self.batch.records), "lighting after cutover")
            and verify(additionalProgramming(source, current, device), "programming after cutover")
            and verify(
              self:checkOwnership(record, device, { entity_id = target }, nil, nil, proof[2]),
              "target ownership after cutover"
            )
            and verify(not connectionIssue(current), "connection layout after cutover"),
          "The replacement or its project references changed during cutover."
        )
        local sceneWork = scenePlan and moveScenes() or reply(true)
        return sceneWork:next(function(scenesVerified)
          if scenesVerified and not self.closed then
            return proof[2]
          end
        end)
      end)
      :next(function(scope)
        if not scope or self.closed then
          return
        end
        if next(record.mappedConnections) then
          record.cutoverStep = "transfer remaining connections"
          local moved = relays.move(record, device, false, function()
            record.relayStarted = true
            self:save()
          end)
          assert(migrationCheck(not moved.error, "connection transfer"), moved.error)
        end
        traceLegacy("cutover verified. Applying driver names.")
        self:showProgress("Applying driver names…")
        record.cutoverStep = nil
        record.phase = "naming"
        record.retiredName = oldDriverName(source)
        self:save()
        -- Reuse the cutover proof only when no scene or connection writes
        -- intervened. Independently resumed naming always reads it again.
        local verifiedProxy = not scenePlan and not next(record.mappedConnections) and proxy or nil
        self:finishRecordNames(record, nil, scope, verifiedProxy)
      end)
  end
  local function reviewSettings(message)
    if not self.closed then
      record.phase, record.message = "review", message
      self:save()
    end
  end
  local feedbackMessage = "In Home Assistant, check that the light is available and supports the settings you reviewed."
    .. " The original stays connected. Return to Quick Setup to check your changes."
  local observed = readApprovedLoad(evidence)
  return observed:next(function(proof)
    if self.closed then
      return
    end
    local state = proof.state
    if not record.lightSettings then
      return cutover(verifyStage(state, proof.evidence))
    end
    local staged = verifyStage(state, proof.evidence)
    if not compatibility.migrationFeedback(target, record.lightSettings, state) then
      traceLegacy("check rejected: Home Assistant feedback for reviewed light settings")
      return reviewSettings(feedbackMessage)
    end
    if record.resumeSelection then
      return cutover(staged)
    end
    if staged.provider == 0 then
      -- A blank child needs the Coordinator link to save settings. Its load
      -- remains unselected until the original has released control.
      self:bindReplacement(device, source.room_id, staged.input)
    end
    return self.hub.transfer:stageLightSettings(device, target, record.lightSettings):next(function()
      if self.closed then
        return
      end
      return readApprovedLoad():next(function(current)
        if self.closed then
          return
        end
        if not compatibility.migrationFeedback(target, record.lightSettings, current.state) then
          traceLegacy("check rejected: Home Assistant feedback after staging light settings")
          return reviewSettings(feedbackMessage)
        end
        return cutover(verifyStage(current.state, current.evidence))
      end)
    end, function()
      traceLegacy("check rejected: replacement light settings readback")
      return reviewSettings(
        "Quick Setup could not verify the settings on the new driver. The original stays connected."
          .. " Check the new driver’s settings before retrying."
      )
    end)
  end)
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
        return readMigrationLoad(self.hub.connection, source.entity)
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
        issue = "Finish migrating " .. label .. " first, then check the connections again."
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

local function checkOwnership(self, record, device, load, buttons, ownerInventory, evidence, reviewedSelections)
  local catalog, loadKeys, loadRegistry = self.hub.catalog
  if load then
    if catalog then
      local original = record.endpoint and record.endpoint.entity and record.source.entity
      loadKeys = catalog:endpointKeys({ load.entity_id, original })
      if not loadKeys then
        return false
      end
    else
      loadKeys = { [load.entity_id] = true }
    end
    loadRegistry = load.registry_id
    if catalog and not loadRegistry then
      local _, _, registry = catalog:loadDetails(load.entity_id, record.source.origin == "Legacy HA")
      loadRegistry = registry
    end
  end
  local unresolvedLegacy
  local peers = ownerInventory or project.inventory(true)
  if self.hub.installation and evidence then
    self.hub.installation:classify(peers, evidence)
  end
  for _, peer in ipairs(peers) do
    local provider = peer.legacy and peer.legacy_provider or peer.provider
    local sameCoordinator = not contract.integer(provider) or provider == self.coordinator
    if
      not peer.other_installation
      and peer.id ~= record.source.id
      and peer.id ~= device
      and provider ~= 0
      and peer.selected ~= ""
    then
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
        local verified = reviewedSelections and reviewedSelections[peer.id]
        if verified == nil then
          local span = metrics:start("migration.ownership_read")
          verified = migrationSelection.read(peer.id)
          verified = (verified and verified.stable and verified.key == peer.selected) and verified or false
          metrics:finish(span, verified and "ok" or "rejected")
          if reviewedSelections then
            reviewedSelections[peer.id] = verified
          end
        end
        if not verified then
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

function Upgrade:checkOwnership(record, device, load, buttons, ownerInventory, evidence, reviewedSelections)
  local span = metrics:start("migration.ownership")
  local owned, peer, unresolved =
    checkOwnership(self, record, device, load, buttons, ownerInventory, evidence, reviewedSelections)
  metrics:finish(span, owned and "ok" or "rejected")
  return owned, peer, unresolved
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
  self.progress = "Checking the project and Home Assistant connection…"
  if not pcall(self.save, self) then
    self.running, self.progress = false, nil
    return { error = "Could not save migration progress. Check the project, then try again." }
  end
  local nextWork = deferred.new()
  nextWork:resolve()
  for _, record in ipairs(self.batch.records) do
    if
      record.phase ~= "upgraded"
      and record.phase ~= "naming"
      and record.phase ~= "manual"
      and record.phase ~= "target"
    then
      local cutover
      nextWork = nextWork
        :next(function()
          if self.closed or recoveryRequired(self.batch) then
            return
          end
          self:showProgress("Preparing the new driver…")
          local staging = metrics:start("migration.stage")
          return self:destination(record):next(function(device)
            metrics:finish(staging, "ok")
            cutover = metrics:start("migration.cutover")
            if record.source.origin == "Legacy HA" then
              return self:applyAdditional(record, device)
            end
            if record.buttonBehavior then
              return self:applyButtons(record, device, reviewed and reviewed[record.source.id])
            end
            return self:apply(record, device, reviewed and reviewed[record.source.id])
          end, function(problem)
            metrics:finish(staging, "failed")
            error(problem, 0)
          end)
        end)
        :next(function()
          local phase = record.phase
          local blocked = phase == "review" or phase == "attention" or phase == "recovery" or phase == "restored"
          local outcome = phase == "upgraded" and "ok" or blocked and "rejected" or "accepted"
          metrics:finish(cutover, outcome)
          if record.source.origin == "Legacy HA" and not self.closed then
            traceLegacy("run finished in phase %s", record.phase)
          end
        end)
        :next(nil, function(problem)
          metrics:finish(cutover, "failed")
          if self.closed then
            return
          end
          local loadRetry = type(problem) == "table" and loadRetryMessages[problem.migrationLoad]
          if record.source.origin == "Legacy HA" then
            traceLegacy(
              "run failed in phase %s%s",
              record.phase,
              record.cutoverStep and ": " .. record.cutoverStep or ""
            )
          end
          if record.phase == "cutover" then
            local restored = self:restoreControl(record)
            if record.source.origin == "Legacy HA" then
              traceLegacy("original gateway recovery: %s", restored and "verified" or "unverified")
            end
          elseif record.phase == "scene_transfer" then
            record.movingScenes = true
            record.phase, record.message = "recovery", sceneRecoveryMessage
          elseif record.phase == "naming" then
            record.message = "Check the old and new driver names in Composer, then finish naming again."
          elseif record.phase == "adding" then
            record.message = "Look for “"
              .. record.name
              .. "” in this room in Composer, then return to Quick Setup to continue."
          elseif problem == "original_changed" then
            record.phase, record.message =
              "attention", "Check the original driver’s name, room and Home Assistant connection in Composer."
          elseif loadRetry then
            local family = record.source.family == "light" and "light" or "switch"
            record.phase, record.message = "attention", loadRetry:format(family)
          else
            record.phase, record.message =
              "attention", "The old driver remains in place. Check the Home Assistant connection and new driver."
          end
          self:save()
        end)
    end
  end
  local function finish()
    if not self.closed then
      self.running = false
      self.progress = nil
      self:save()
      RefreshNavs()
    end
  end
  nextWork:next(finish, function()
    self.running, self.progress = false, nil
    if not self.closed then
      pcall(self.notify, self:state())
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

local function reviewedPlan(record)
  local plan = {}
  for key, value in pairs(record) do
    if key == "source" then
      plan.source = {}
      for field, fact in pairs(value) do
        if field ~= "lighting" then
          plan.source[field] = fact
        end
      end
    else
      plan[key] = value
    end
  end
  return plan
end

function Upgrade:start(token, backup, evidence)
  if require("ha.release-install").pending() then
    return { error = "Finish the saved driver update before starting migration." }
  end
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
  local _, latest, revision = self:list(evidence)
  if revision ~= preview.revision or not revision then
    return { error = "The installed release changed. Review the drivers again." }
  end
  for _, record in ipairs(preview.records) do
    local current = latest[record.source.id]
    if current and current.source.mode == "bridge" then
      current.reviewedLoad = migrationLoadPreview(self.hub.catalog, current.source)
    end
    local unchanged = current and codec.encode(current) == codec.encode(record)
    if not unchanged and current and record.source.origin == "Legacy HA" then
      unchanged = codec.encode(reviewedPlan(current)) == codec.encode(reviewedPlan(record))
        and lighting.compare(record.source.lighting, current.source.lighting)
    end
    if not unchanged then
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

function Upgrade:stagedReleaseIssue(revision, restoredRecord)
  local batch = self.batch
  if not batch or #batch.records == 0 then
    return "no_saved_migration"
  end
  if not revision or revision < batch.revision or revision == batch.revision and not hasMovedSceneRecovery(batch) then
    return "release_not_newer"
  end
  for _, record in ipairs(batch.records) do
    local source, device = record.source, record.destination
    if record == restoredRecord then
      if installed.upgradeRevision(self.coordinator, device) ~= revision then
        return "replacement_release", source.id
      end
    elseif
      source.origin == "Legacy HA"
      and (
        record.phase == "prepared"
        or record.phase == "review"
        or record.phase == "attention"
        or needsReleaseRecheck(record)
      )
    then
      local original = assess.assess(source.id, { skipPrograms = true })
      local replacement = device and project.device(device)
      if
        not migrationCheck(device, "saved replacement exists")
        or not migrationCheck(record.endpoint, "saved Home Assistant endpoint exists")
        or not migrationCheck(record.mappedConnections, "saved connections exist")
        or not migrationCheck(not record.relayStarted, "saved stage has not begun moving connections")
        or not migrationCheck(lighting.complete(source.lighting), "saved lighting snapshot")
        or not migrationCheck(not programmingBlock(source.programs, source), "saved programming after release update")
        or not migrationCheck(sameOriginal(record, original), "original identity after release update")
        or not migrationCheck(original.bindingsVerified, "original bindings after release update")
        or not migrationCheck(
          legacyProfile.gateway(original) == record.gateway,
          "original gateway after release update"
        )
        or not migrationCheck(
          blankStage(record, replacement, self.coordinator),
          "replacement identity after release update"
        )
        or not migrationCheck(
          installed.upgradeRevision(self.coordinator, device, source.family) == revision,
          "replacement release after update"
        )
        or not migrationCheck(
          relays.canRestore(record, device, { edges = additionalEdges(original) }),
          "recoverable connections after release update"
        )
        or not migrationCheck(
          not relays.destinationIssue(record, device, false),
          "replacement connections after release update"
        )
      then
        return "staged_project", source.id
      end
      if record.sceneMoveVerified or movedScenesNeedRecheck(record) then
        local proxy, other = C4:GetProxyDevicesById(device)
        if
          not migrationCheck(
            contract.integer(tonumber(proxy)) and not other,
            "replacement scene proxy after release update"
          )
          or not migrationCheck(
            additionalLighting(record, tonumber(proxy), batch.records),
            "saved scene membership after release update"
          )
        then
          return "staged_lighting", source.id
        end
      elseif record.sceneAttempted then
        local proxy, other = C4:GetProxyDevicesById(device)
        proxy = tonumber(proxy)
        local plan = source.proxies[1]
          and lighting.directScenePlan(source.lighting, source.proxies[1].id, approvedSceneMoves(record, batch.records))
        if
          not migrationCheck(plan, "saved scene transfer plan")
          or not migrationCheck(contract.integer(proxy) and not other, "replacement scene proxy after release update")
        then
          return "staged_lighting", source.id
        end
        if
          not migrationCheck(lighting.intactSceneStage(plan, proxy), "saved scene membership after release update")
        then
          return "staged_lighting", source.id
        end
      end
      traceLegacy("saved stage verified on the updated release")
    elseif record.phase == "attention" and not record.buttonBehavior and source.origin ~= "Legacy HA" then
      local original, replacement = assess.assess(source.id), device and project.device(device)
      local selection = replacement and status(device, source)
      if not sameOriginal(record, original) then
        return "original_identity", source.id
      elseif not original.bindingsVerified or codec.encode(source.edges) ~= codec.encode(original.edges) then
        return "original_connections", source.id
      elseif hasProgrammingWork(original.programs) then
        return "original_programming", source.id
      elseif legacyLink(source.id) ~= self.coordinator then
        return "original_coordinator", source.id
      elseif record.relayStarted or not record.mappedConnections then
        return "saved_connections", source.id
      elseif not sameStage(record, replacement) then
        return "replacement_identity", source.id
      elseif replacement.provider ~= 0 and replacement.provider ~= self.coordinator then
        return "replacement_coordinator", source.id
      elseif selection ~= "blank" and selection ~= "reserved" then
        return "replacement_selection", source.id
      elseif installed.upgradeRevision(self.coordinator, device) ~= revision then
        return "replacement_release", source.id
      elseif not expectedRelays(record, original) or connectionPeerIssue(record) then
        return "connection_plan", source.id
      elseif relays.destinationIssue(record, device, false) then
        return "replacement_connections", source.id
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
        return "saved_stage", source.id
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
        return "staged_project", source.id
      end
    end
  end
end

function Upgrade:recheckStagedRelease(revision, restoredRecord)
  local issue = self:stagedReleaseIssue(revision, restoredRecord)
  if issue then
    traceLegacy("saved release recheck rejected: %s", issue)
    return false, issue
  end
  local recovered = false
  for _, record in ipairs(self.batch.records) do
    if canRecheckSaved(record, revision, self.batch.revision) then
      record.sceneMoveVerified = movedScenesNeedRecheck(record) or nil
      record.message = record.sceneMoveVerified and movedScenesVerified
        or "The saved migration checks passed. Choose Continue migration to proceed."
      record.phase, record.lightingReview = "prepared", nil
      recovered = true
    end
  end
  self.batch.revision = revision
  self:save()
  traceLegacy("saved release recheck accepted")
  return true, recovered
end

function Upgrade:resume(token, confirmed)
  if self.running or not self.batch then
    return self:state()
  end
  self.batch = restorableBatch() or self.batch
  if token ~= self.batch.token then
    for _, record in ipairs(self.batch.records) do
      if record.source.origin == "Legacy HA" then
        return { error = "Refresh migration status before continuing." }
      end
    end
  end
  local revision = installed.upgradeRevision(self.coordinator)
  local recovery = recoveryRequired(self.batch, revision)
  if recovery then
    return { error = recovery }
  end
  for _, record in ipairs(self.batch.records) do
    if record.source.origin == "Legacy HA" and record.phase == "cutover" and confirmed == nil then
      self:restoreControl(record)
      self:save()
      return self:state()
    end
  end
  local checkingMovedScenes = revision == self.batch.revision and hasMovedSceneRecovery(self.batch)
  if revision ~= self.batch.revision or checkingMovedScenes then
    if revision and revision > self.batch.revision then
      for _, record in ipairs(self.batch.records) do
        if record.phase == "cutover" then
          if token ~= self.batch.token or confirmed ~= nil then
            return { error = "Refresh migration status before restoring the original connections." }
          end
          if self:restoreControl(record) then
            if record.source.origin ~= "Legacy HA" and self:recheckStagedRelease(revision, record) then
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
      return { error = "Wait for Home Assistant to reconnect before continuing." }
    end
    local rechecked, result
    if
      (checkingMovedScenes or revision and revision > self.batch.revision)
      and token == self.batch.token
      and confirmed == nil
    then
      rechecked, result = self:recheckStagedRelease(revision)
    end
    if not rechecked then
      return {
        error = result == "staged_lighting"
            and "Quick Setup could not verify the saved lighting scenes. In Composer, check the scene members and settings, then check the saved migration again."
          or "The saved migration could not be verified on this suite release. Check the original and replacement in Composer before continuing.",
      }
    end
    if result == true then
      return self:state()
    end
    for _, record in ipairs(self.batch.records) do
      if record.source.origin == "Legacy HA" and (record.phase == "prepared" or record.phase == "review") then
        return self:run()
      end
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
