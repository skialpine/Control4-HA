-- A requested migration uses the current replacement. No discovery, init or binding callback starts it.
local assess = require("ha.migration-assessment")
local contract = require("ha.contract")
local codec = require("ha.codec")
local installedSuite = require("ha.installed-suite")
local relays = require("ha.migration-relays")
local persist = require("lib.persist")
local ids = require("ha.identities")
local prototype = require("ha.prototype-selection")
local project = require("ha.commissioning-project")
require("lib.bindings")
local KEY = "HA.SwitchMigration.v1"
local ALIGN = "Update the installed Home Assistant drivers to the same release, then select Refresh review."
local M = {}
local SAME_COORDINATOR =
  "Connect the original and replacement to the same Home Assistant Connection in Composer, then check again."

local function lightingLines(references, text)
  for _, kind in ipairs({ "scenes", "groups" }) do
    local label = kind == "scenes" and "Advanced Lighting scenes" or "Load groups"
    local rows = references and references[kind]
    if not rows then
      text[#text + 1] = label .. " could not be verified."
    else
      local names, seen = {}, {}
      for _, dependencies in pairs(rows) do
        for id, dependency in pairs(dependencies) do
          if not seen[id] then
            seen[id], names[#names + 1] = true, dependency.name
          end
        end
      end
      table.sort(names)
      if #names > 0 then
        text[#text + 1] = label .. " · " .. table.concat(names, ", ")
      end
    end
  end
end

local function lines(report, replacement)
  local text = {
    ("%s (%s version %s)"):format(
      assess.deviceLabel(report.name or report.model, report.room),
      report.origin,
      report.version
    ),
    "Home Assistant device: " .. (report.selectedName or report.entity or "Selection could not be verified."),
  }
  local selectionIssue = assess.switchSelectionIssue(report)
  if selectionIssue and report.family == "switch" then
    text[#text + 1] = selectionIssue
  elseif report.candidate_entity then
    text[#text + 1] = "One source reported "
      .. report.candidate_entity
      .. ". Check the old driver’s Entity ID before saving."
  end
  if report.origin == "Legacy HA" then
    for _, edge in ipairs(report.edges) do
      local role = assess.destination(edge.binding, report)
      if role and role.name then
        text[#text + 1] = role.name .. " → " .. assess.deviceLocation(edge.device)
      end
    end
    lightingLines(report.lighting, text)
  else
    for _, p in ipairs(report.proxies) do
      local label = assess.deviceLocation(p.id, report.name or report.model, report.room)
      text[#text + 1] = "Control4 proxy for " .. label .. " · " .. tostring(p.file)
    end
  end
  if report.origin ~= "Legacy HA" and report.family == "light" then
    for _, edge in ipairs(report.edges) do
      text[#text + 1] = string.format(
        "Current connection from %s, connection %d to %s, connection %d.",
        (assess.deviceLocation(edge.owner, report.name or report.model, report.room)),
        edge.binding,
        (assess.deviceLocation(edge.device)),
        edge.port
      )
    end
    text[#text + 1] = report.interfaces and "Update this Light in place and verify its existing device and proxy."
      or "This Light has a different or unreadable interface. Check its project backup and proxy before planning an update."
  elseif report.origin ~= "Legacy HA" then
    if replacement then
      text[#text + 1] = "Replacement is " .. assess.deviceLocation(replacement, "Home Assistant Switch") .. "."
    end
    for _, edge in ipairs(report.edges) do
      local role = assess.destination(edge.binding, report)
      text[#text + 1] = string.format(
        "%s uses old connection %d to %s, connection %d%s.",
        role and role.name or "Unknown connection",
        edge.binding,
        (assess.deviceLocation(edge.device)),
        edge.port,
        role and role.new and ("; replacement connection " .. role.new) or ""
      )
    end
    text[#text + 1] = "Programming: replace Turn On and Turn Off with the matching actions on the new switch."
    if report.mode then
      local names = {
        direct = "Control linked device only",
        bridge = "Control device and report presses",
        buttons = "Buttons only",
        connected = "Connected Control4 light",
      }
      text[#text + 1] = "Saved button behavior: " .. names[report.mode] .. "."
    end
    if report.version == "107" then
      text[#text + 1] =
        "Also check Toggle, on/off conditions, each saved button gesture, indicator settings and colors. Check each action’s button and value."
    end
    text[#text + 1] = "Check programs that read ENTITY_ID against the original variable (ID "
      .. tostring(report.variable_id or "unknown")
      .. "). Verify each replacement variable by meaning."
  end
  for _, key in ipairs({ "attached", "incoming" }) do
    for _, ref in ipairs(report.programs[key]) do
      local location = assess.programReference(ref, key == "attached" and report or nil)
      text[#text + 1] = (key == "attached" and "Program on old device" or "Other program targeting old device")
        .. " · "
        .. location.location
        .. " · "
        .. (location.event or ("Event " .. location.eventId))
        .. "."
    end
  end
  if report.programs.truncated then
    text[#text + 1] =
      "Only the first 128 locations in each direction are listed. Inspect the remaining programs in Composer."
  end
  if report.origin == "Legacy HA" then
    text[#text + 1] = report.programs.readable and "Check references inside program arguments in Composer."
      or "Programming could not be read. Check programs on the old driver and related devices and agents in Composer."
  else
    text[#text + 1] = report.programs.readable
        and "Check scene membership, agent settings and references inside program arguments in Composer."
      or "Programming could not be read. Check programs on the old device and other devices, scenes and agents in Composer."
  end
  if not report.interfaces then
    text[#text + 1] = "Some connections could not be verified. Compare both devices in Composer."
  end
  return text
end

local function parseSaved(raw)
  if raw == nil then
    return nil
  end
  local data = codec.storedObject(raw)
  assert(
    data
      and data.version == 1
      and contract.integer(data.replacement)
      and codec.isObject(data.source)
      and contract.integer(data.source.id),
    "invalid checkpoint"
  )
  return data
end

local function saved()
  return parseSaved(persist:get(KEY, nil, true))
end

local reviewedRaw, reviewVisible

function M.reviewAvailable(family, configured)
  if not configured then
    return true
  end
  if family == "switch" then
    local readable, raw = pcall(persist.get, persist, KEY, nil, true)
    -- Keep recovery visible if the saved plan cannot be read.
    if not readable then
      return true
    end
    if raw == nil then
      reviewedRaw, reviewVisible = nil, false
    elseif raw ~= reviewedRaw then
      local valid, checkpoint = pcall(parseSaved, raw)
      reviewedRaw = raw
      reviewVisible = not valid or not contract.integer(checkpoint.completed_revision)
    end
    return reviewVisible
  end
  return false
end

local function exclusive(source, me)
  local owner = contract.provider(me)
  local rows = C4:GetDevices({ C4iNames = ids.packages.switch.file })
  if type(rows) ~= "table" then
    return false
  end
  for raw, row in pairs(rows) do
    local id = tonumber(raw)
    if id ~= me and row.driverFileName == ids.packages.switch.file and not next(row.protocol or {}) then
      local provider = contract.provider(id)
      if
        SendUIRequest(id, "HA_MIGRATION_CLAIM", {
          SOURCE = source.id,
          ENTITY = source.entity,
          RESERVATION_ONLY = owner and provider and owner ~= provider and "true" or nil,
        }) ~= "<migration>available</migration>"
      then
        return false
      end
    end
  end
  return true
end

local function sameOrigin(a, b)
  return a
    and b
    and a.id == b.id
    and a.file == b.file
    and a.version == b.version
    and a.room_id == b.room_id
    and a.interfaces
    and b.interfaces
end
local function ready(owner, entity)
  local conf = owner.config
  if not conf or not conf.controlled_load or conf.controlled_load.entity_id ~= entity or owner.working then
    return false
  end
  local facts = owner.consumer.readiness:view(entity)
  return facts.evidence_ready and facts.available and owner:mode() == "Home Assistant device"
end

local function checkOriginalProof(cp, current)
  local source = cp.source
  local link = tonumber(C4:GetBoundProviderDevice(source.id, ids.lightCoordinatorBinding))
  local provider = assess.legacyCoordinator(current)
  local changed = current and (not sameOrigin(source, current) or (current.entity and current.entity ~= source.entity))
  if cp.checked and (changed or (provider and provider ~= cp.verified_provider)) then
    cp.checked, cp.verified_provider, cp.completed_revision = nil, nil, nil
    persist:set(KEY, codec.encode(cp), true)
  end
  return provider, link
end

local function progress(cp, owner)
  local source, me = cp.source, cp.replacement
  local now = assess.assess(source.id, { skipPrograms = true })
  local currentProvider, oldLink = checkOriginalProof(cp, now)
  local oldInactive = sameOrigin(source, now) and now.empty and oldLink == 0
  local blank = not owner.config and not owner.pending and not owner.working
  local oldCount, newCount, interrupted, unrelated = 0, 0, 0, 0
  for _, edge in ipairs(source.edges) do
    if edge.binding == 1 and edge.owner == source.id and edge.direction == "output" then
      local id, port = relays.provider(edge.device, edge.port)
      if id == source.id and port == 1 then
        oldCount = oldCount + 1
      elseif id == me and port == ids.relay then
        newCount = newCount + 1
      elseif id == 0 and cp.pending and cp.pending[tostring(edge.device) .. "." .. tostring(edge.port)] then
        interrupted = interrupted + 1
      else
        unrelated = unrelated + 1
      end
    end
  end
  local modeIssue = assess.switchMigrationModeIssue(source) or (now and assess.switchMigrationModeIssue(now))
  local direct = sameOrigin(source, now) and contract.loadDomain(source.entity) ~= nil and not modeIssue
  local active = ready(owner, source.entity)
  local provider = contract.provider(me)
  local revision = provider and installedSuite.upgradeRevision(provider, me)
  local linkedOrDisabling = now and now.entity == source.entity and (currentProvider == provider or oldLink == 0)
  local checked = cp.checked == true
    and provider ~= nil
    and cp.verified_provider == provider
    and (oldInactive or linkedOrDisabling)
  local readyToComplete = direct and checked and oldInactive and active and oldCount + interrupted + unrelated == 0
  local completed = revision ~= nil and readyToComplete and cp.completed_revision == revision
  local result = {
    phase = "staged",
    lines = lines(source, me),
    source_name = assess.deviceLabel(source.name or source.model, source.room),
    replacement_name = assess.deviceLocation(me, "Home Assistant Switch"),
    entity = source.entity,
    move_count = oldCount + interrupted,
    restore_count = newCount + interrupted,
    revision = revision,
    can_check = revision ~= nil
      and direct
      and not checked
      and currentProvider == provider
      and now.entity == source.entity,
    can_configure = revision ~= nil and direct and checked and oldInactive and blank,
    can_transfer = revision ~= nil
      and direct
      and checked
      and oldInactive
      and active
      and oldCount + interrupted > 0
      and unrelated == 0,
    can_complete = revision ~= nil and readyToComplete and not completed,
    completed = completed,
    can_rollback = blank and newCount + interrupted > 0 and unrelated == 0,
  }
  if unrelated > 0 then
    result.message = "A saved relay now connects elsewhere. Check its current connection in Composer before continuing."
  elseif result.can_rollback then
    result.message =
      "The replacement has no selected device. You can restore its saved relay connections to the original switch."
  elseif not provider then
    result.message = SAME_COORDINATOR
  elseif not revision then
    result.message = ALIGN
  elseif completed then
    result.message = "Migration verified for "
      .. result.replacement_name
      .. " on suite version "
      .. revision
      .. ". Keep the project backup for recovery."
  elseif not direct then
    result.message = modeIssue
      or "Keep the original switch active. Verify its saved button device, linked load and indicator settings manually in Home Assistant and Composer."
  elseif not checked then
    result.message = now
        and now.entity
        and now.entity ~= source.entity
        and "The original switch’s Home Assistant device changed. Restore the saved device in Composer, then refresh this review."
      or currentProvider == provider and "Check Home Assistant from this replacement while the original switch still controls its device."
      or SAME_COORDINATOR
  elseif not oldInactive then
    result.message =
      "Home Assistant responded. Disconnect the old switch’s Home Assistant link and clear its Entity ID in Composer, then refresh this review."
  elseif blank then
    result.message =
      "The old switch is disconnected. Choose Use saved Home Assistant device to set up this replacement."
  elseif not active then
    result.message = "Verify the saved device in Device Setup, then refresh this review to check the connections."
  elseif result.can_transfer then
    result.message = "Verify the replacement’s on/off response. You can then move the listed relay connections."
  elseif result.can_complete then
    result.message =
      "Test the replacement after reload. Check its scenes, button links and programming, then mark the migration verified."
  end
  if newCount + interrupted > 0 and not blank then
    result.rollback_help =
      "To restore the original relay connections, first clear the device selection on this replacement, then refresh the review."
  end
  return result
end

local function moveRelays(cp, me, undo, owner)
  local outcome = relays.move(cp, me, undo, function()
    persist:set(KEY, codec.encode(cp), true)
  end)
  if outcome.error then
    return outcome
  end
  local result = progress(cp, owner)
  if undo then
    result.message =
      "Original relay connections verified. Restore the old Entity ID and Home Assistant connection, then test it. Restore the project backup for private settings or programming."
  end
  return result
end

local function changeOwner(owner, action, params, cp, me)
  if action ~= "transfer" and action ~= "rollback" and action ~= "configure" and action ~= "complete" then
    return { error = "Choose a migration action." }
  end
  if params.confirmed ~= true then
    return { error = "Review the connection changes and confirm to continue." }
  end
  local original, now = cp.source, assess.assess(cp.source.id, { skipPrograms = true })
  checkOriginalProof(cp, now)
  if not sameOrigin(original, now) then
    return { error = "The old switch or its connections changed. Check the saved plan before continuing." }
  end
  local planned = {}
  for _, edge in ipairs(original.edges) do
    if edge.binding == 1 and edge.owner == original.id then
      planned[edge.device .. "." .. edge.port] = true
    end
  end
  for _, edge in ipairs(now.edges) do
    if edge.binding == 1 and edge.owner == original.id and not planned[edge.device .. "." .. edge.port] then
      return {
        error = "A new relay connection was added to the old switch. Review the project before moving connections.",
      }
    end
  end
  local undo = action == "rollback"
  if not undo then
    local modeIssue = assess.switchMigrationModeIssue(original) or assess.switchMigrationModeIssue(now)
    if modeIssue then
      return { error = modeIssue }
    end
    local provider = contract.provider(me)
    if not provider or (cp.checked and cp.verified_provider ~= provider) then
      return { error = SAME_COORDINATOR }
    end
    if not installedSuite.upgradeRevision(provider, me) then
      return progress(cp, owner)
    end
    if not exclusive(original, me) then
      return {
        error = "Another replacement may already control this device. Review existing switches before continuing.",
      }
    end
    if not cp.checked then
      return { error = "Check Home Assistant from this replacement before disconnecting the original." }
    end
    if not now.empty or tonumber(C4:GetBoundProviderDevice(now.id, 999)) ~= 0 then
      return {
        error = "Disconnect the old switch’s Home Assistant link and clear its Entity ID in Composer before moving connections.",
      }
    end
    if action == "configure" then
      if ready(owner, original.entity) then
        return progress(cp, owner)
      end
      if
        owner.config
        or owner.pending
        or owner.working
        or not contract.loadDomain(original.entity)
        or (Properties["Manual entity ID"] or "") ~= ""
      then
        return { error = "Use Device Setup to verify the intended device and any saved button settings." }
      end
      UpdateProperty("Manual entity ID", original.entity, true)
      local view = progress(cp, owner)
      view.message =
        "Checking the saved Home Assistant device. Verify its status and on/off response in Device Setup before moving relay connections."
      return view
    end
    if not ready(owner, original.entity) then
      return {
        error = "Choose the saved device on this switch and verify that it is available before moving connections.",
      }
    end
    if action == "complete" then
      local view = progress(cp, owner)
      if view.completed then
        return view
      end
      if not view.can_complete then
        return {
          error = "Verify the replacement and finish the listed connection changes before marking migration complete.",
        }
      end
      cp.completed_revision = view.revision
      persist:set(KEY, codec.encode(cp), true)
      return progress(cp, owner)
    end
  elseif owner.config or owner.pending or owner.working then
    return { error = "Clear this replacement’s device selection before restoring the old relay connections." }
  end
  return moveRelays(cp, me, undo, owner)
end

local function verifyAvailability(owner, cp, done)
  local provider = contract.provider(cp.replacement)
  local revision = provider and installedSuite.upgradeRevision(provider, cp.replacement)
  if not revision then
    return progress(cp, owner)
  end
  local source = assess.assess(cp.source.id, { skipPrograms = true })
  if
    not sameOrigin(source, cp.source)
    or source.entity ~= cp.source.entity
    or not contract.loadDomain(source.entity)
  then
    return { error = "Keep the original switch connected. Check its selected device and review the plan again." }
  end
  local modeIssue = assess.switchMigrationModeIssue(cp.source) or assess.switchMigrationModeIssue(source)
  if modeIssue then
    return { error = modeIssue }
  end
  if assess.legacyCoordinator(source) ~= provider then
    return { error = SAME_COORDINATOR }
  end
  owner.consumer:request("verify_target", source.entity, codec.object({})):next(function()
    local checkpoint = saved()
    if not checkpoint or checkpoint.source.id ~= source.id then
      done({ error = "Reopen the saved plan." })
      return
    end
    if
      contract.provider(cp.replacement) ~= provider
      or installedSuite.upgradeRevision(provider, cp.replacement) ~= revision
    then
      done(progress(checkpoint, owner))
      return
    end
    local current = assess.assess(source.id, { skipPrograms = true })
    if
      not sameOrigin(source, current)
      or current.entity ~= source.entity
      or assess.switchMigrationModeIssue(current)
      or assess.legacyCoordinator(current) ~= provider
    then
      done(progress(checkpoint, owner))
      return
    end
    checkpoint.checked, checkpoint.verified_provider = true, provider
    persist:set(KEY, codec.encode(checkpoint), true)
    done(progress(checkpoint, owner))
  end, function()
    done({
      error = "The replacement could not reach the saved device. Keep the original connected and check Home Assistant before retrying.",
    })
  end)
  return nil
end

function M.install(register, family, current)
  local preview, ticket = nil, 0
  if family == "switch" then
    UIR.suppressDebug.HA_SWITCH_COPY_SETTINGS = true
    UIR.HA_SWITCH_COPY_SETTINGS = function(params)
      local owner, id = current(), params and tonumber(params.SOURCE)
      if not owner or owner.pending or owner.working or owner.config or not contract.integer(id) then
        return
      end
      local source = assess.assess(id, { skipPrograms = true })
      local behavior = source and source.family == "switch" and prototype.switchButtonBehavior(source.mode)
      local coordinator = behavior and tonumber(C4:GetBoundProviderDevice(id, ids.lightCoordinatorBinding))
      local replacement = coordinator and coordinator > 0 and project.device(tonumber(C4:GetDeviceID()))
      if not replacement or replacement.provider ~= coordinator or replacement.room_id ~= source.room_id then
        return
      end
      local existing, led = Properties["Button behavior"], Properties["LED Behavior"]
      if
        (existing ~= "Automatic" and existing ~= behavior)
        or (source.ledBehavior and led ~= "Use Device Setting" and led ~= source.ledBehavior)
      then
        return
      end
      UpdateProperty("Button behavior", behavior, true)
      if source.ledBehavior then
        UpdateProperty("LED Behavior", source.ledBehavior)
      end
      if
        Properties["Button behavior"] == behavior
        and (not source.ledBehavior or Properties["LED Behavior"] == source.ledBehavior)
      then
        return "<upgrade>copied</upgrade>"
      end
    end
    UIR.suppressDebug.HA_SWITCH_UPGRADE_STATUS = true
    UIR.HA_SWITCH_UPGRADE_STATUS = function(params)
      local owner, cp = current(), saved()
      local id, entity = params and tonumber(params.SOURCE), params and params.ENTITY
      local function reply(state)
        return "<upgrade>" .. state .. "</upgrade>"
      end
      if not owner or not contract.integer(id) or not contract.entity(entity) or owner.pending or owner.working then
        return reply("unknown")
      end
      if params.RESERVATION_ONLY == "true" then
        return reply(cp and cp.source.id == id and "reserved" or "occupied")
      end
      local cfg = owner.config
      if cfg then
        if cfg.controlled_load and cfg.controlled_load.entity_id == entity then
          return reply(ready(owner, entity) and "ready" or "matching")
        end
        return reply("occupied")
      end
      if cp then
        return reply(cp.source.id == id and cp.source.entity == entity and "reserved" or "occupied")
      end
      return reply("blank")
    end
    UIR.suppressDebug.HA_MIGRATION_CLAIM = true
    UIR.HA_MIGRATION_CLAIM = function(params)
      local cp, owner = saved(), current()
      if
        not owner
        or not params
        or not contract.integer(tonumber(params.SOURCE))
        or not contract.entity(params.ENTITY)
        or owner.pending
        or owner.working
      then
        return "<migration>unknown</migration>"
      end
      local cfg = owner.config
      if
        (cp and cp.source.id == tonumber(params.SOURCE))
        or (
          params.RESERVATION_ONLY ~= "true"
          and cfg
          and (
            cfg.key == params.ENTITY
            or cfg.gesture_entity_id == params.ENTITY
            or cfg.controlled_load and cfg.controlled_load.entity_id == params.ENTITY
          )
        )
      then
        return "<migration>in-use</migration>"
      end
      return "<migration>available</migration>"
    end
  end
  register("HA_MIGRATION", "HA_MIGRATION_RESULT", function(owner, params, done)
    local function run()
      local me, action = C4:GetDeviceID(), params.action
      if action == "open" then
        local cp = family == "switch" and saved()
        return cp and progress(cp, owner) or { phase = "choose", sources = assess.sources(nil, true) }
      end
      if action == "cancel" then
        if preview and preview.token == params.token then
          preview = nil
        end
        return { phase = "closed", message = "Review closed." }
      end
      if action == "preview" then
        local source = assess.assess(params.source)
        if not source then
          return { error = "The old driver could not be identified. Refresh the list and choose it again." }
        end
        ticket = ticket + 1
        local token = tostring(params.request) .. "-" .. ticket
        preview = { source = source, token = token }
        local modeIssue = source.family == "switch" and assess.switchMigrationModeIssue(source)
        local possible = family == "switch"
          and source.origin ~= "Legacy HA"
          and source.family == "switch"
          and not modeIssue
          and source.entity
          and source.interfaces
          and source.room_id
          and not owner.config
          and not owner.pending
        return {
          phase = "preview",
          token = token,
          can_save = possible and true or false,
          lines = lines(source, family == "switch" and me or nil),
          message = source.origin == "Legacy HA"
              and "This review shows what the old driver uses. Leave it in place while you check its connections and programming in Composer."
            or possible and "Saving this plan records the old switch and its connections on this replacement. The old switch keeps control."
            or modeIssue
            or family ~= "switch" and source.family == "switch" and "Open this review on an unconfigured Home Assistant Switch to prepare a replacement."
            or source.family == "switch" and "Resolve the selection or connection details and start from an unconfigured replacement before saving."
            or nil,
        }
      end
      if family ~= "switch" then
        return { error = "Use an unconfigured Home Assistant Switch to save a migration plan." }
      end
      local cp = saved()
      if action == "save" then
        if not preview or preview.token ~= params.token or params.backup ~= true then
          return { error = "Review the plan and confirm a project backup before saving." }
        end
        if cp then
          if cp.source.id == preview.source.id and cp.replacement == me then
            return progress(cp, owner)
          end
          return { error = "This switch already has a saved plan. Resume it before starting another." }
        end
        local original = preview.source
        local now = assess.assess(original.id)
        if
          not sameOrigin(original, now)
          or original.origin == "Legacy HA"
          or not now.entity
          or now.family ~= "switch"
          or assess.switchMigrationModeIssue(now)
          or owner.config
          or owner.pending
          or owner.working
          or codec.encode(original) ~= codec.encode(now)
        then
          return { error = "The project changed. Review a fresh preview before saving." }
        end
        if not exclusive(original, me) then
          return {
            error = "Another replacement may already own this switch. Check existing switches and saved plans before continuing.",
          }
        end
        cp = { version = 1, replacement = me, source = original }
        persist:set(KEY, codec.encode(cp), true)
        preview = nil
        return progress(cp, owner)
      end
      if not cp or cp.replacement ~= me then
        return { error = "Review and save a plan on this replacement first." }
      end
      if action == "status" then
        return progress(cp, owner)
      end
      if action == "check" then
        return verifyAvailability(owner, cp, done)
      end
      return changeOwner(owner, action, params, cp, me)
    end
    local ok, response = pcall(run)
    if not ok then
      done({
        error = "The project could not be verified. Check the connections in Composer and reopen the saved plan.",
      })
    elseif response then
      done(response)
    end
  end)
end
return M
