-- A requested migration uses the current replacement. No discovery, init or binding callback starts it.
local assess = require("ha.migration-assessment")
local contract = require("ha.contract")
local codec = require("ha.codec")
local persist = require("lib.persist")
local ids = require("ha.identities")
require("lib.bindings")
local KEY = "HA.SwitchMigration.v1"
local M = {}

local function destinationName(id)
  local rows = C4:GetDevices({ DeviceIds = tostring(id) }) or {}
  local row = rows[id] or rows[tostring(id)] or {}
  return string.format(
    "%s · %s (device %d)",
    row.deviceName or "Home Assistant Switch",
    row.roomName or "Room unknown",
    id
  )
end

local function lines(report, replacement)
  local text = {
    string.format(
      "%s · %s (device %d, %s version %s)",
      report.name or report.model,
      report.room or "Room unknown",
      report.id,
      report.origin,
      report.version
    ),
    "Home Assistant device: " .. (report.entity or "Selection could not be verified."),
  }
  if report.candidate_entity then
    text[#text + 1] = "One source reported "
      .. report.candidate_entity
      .. ". Check the old driver’s Entity ID before saving."
  end
  for _, p in ipairs(report.proxies) do
    text[#text + 1] = "Control4 proxy " .. p.id .. " · " .. tostring(p.file)
  end
  if report.family == "light" then
    for _, edge in ipairs(report.edges) do
      text[#text + 1] = string.format(
        "Current connection: device %d, connection %d to device %d, connection %d.",
        edge.owner,
        edge.binding,
        edge.device,
        edge.port
      )
    end
    text[#text + 1] = report.interfaces and "Update this Light in place and verify its existing device and proxy."
      or "This Light has a different or unreadable interface. Check its project backup and proxy before planning an update."
  else
    if replacement then
      text[#text + 1] = "Replacement: " .. destinationName(replacement) .. "."
    end
    for _, edge in ipairs(report.edges) do
      local role = assess.destination(edge.binding)
      text[#text + 1] = string.format(
        "%s: old connection %d → device %d, connection %d%s.",
        role and role.name or "Unknown connection",
        edge.binding,
        edge.device,
        edge.port,
        role and ("; replacement connection " .. role.new) or ""
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
      text[#text + 1] = "Saved button behavior: " .. names[report.mode] .. ". Check this setting on the replacement."
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
      text[#text + 1] = (key == "attached" and "Program on old device" or "Other program targeting old device")
        .. ": device "
        .. ref.device
        .. ", event "
        .. ref.event
        .. "."
    end
  end
  if report.programs.truncated then
    text[#text + 1] =
      "Only the first 128 locations in each direction are listed. Inspect the remaining programs in Composer."
  end
  text[#text + 1] = report.programs.readable
      and "Check scene membership, agent settings and references inside program arguments in Composer."
    or "Programming could not be read. Check programs on the old device and other devices, scenes and agents in Composer."
  if not report.interfaces then
    text[#text + 1] = "Some connections could not be verified. Compare both devices in Composer."
  end
  return text
end

local function saved()
  local raw = persist:get(KEY, nil, true)
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

local function exclusive(source, me)
  local rows = C4:GetDevices({ C4iNames = ids.packages.switch.file })
  if type(rows) ~= "table" then
    return false
  end
  for raw, row in pairs(rows) do
    local id = tonumber(raw)
    if id ~= me and row.driverFileName == ids.packages.switch.file and not next(row.protocol or {}) then
      if
        SendUIRequest(id, "HA_MIGRATION_CLAIM", { SOURCE = source.id, ENTITY = source.entity })
        ~= "<migration>available</migration>"
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
local function relayProvider(device, port)
  local row = GetDeviceBindings(device, nil, false, nil, "RELAY")[port]
  if not row or tonumber(row.deviceid) ~= device then
    return nil
  end
  local peer = Select(row, "boundprovider", "bound")
  local id = tonumber(C4:GetBoundProviderDevice(device, port))
  if id == 0 and not peer and not row.isbound then
    return 0, 0
  end
  if peer and tonumber(peer.deviceid) == id then
    return id, tonumber(peer.bindingid)
  end
end

local function ready(owner, entity)
  local conf = owner.config
  if not conf or not conf.controlled_load or conf.controlled_load.entity_id ~= entity or owner.working then
    return false
  end
  local facts = owner.consumer.readiness:view(entity)
  return facts.evidence_ready and facts.available and owner:mode() == "Home Assistant device"
end

local function progress(cp, owner)
  local source, me = cp.source, cp.replacement
  local now = assess.assess(source.id, { skipPrograms = true })
  local oldInactive = sameOrigin(source, now) and now.empty and tonumber(C4:GetBoundProviderDevice(source.id, 999)) == 0
  local blank = not owner.config and not owner.pending and not owner.working
  local oldCount, newCount, interrupted, unrelated = 0, 0, 0, 0
  for _, edge in ipairs(source.edges) do
    if edge.binding == 1 and edge.owner == source.id and edge.direction == "output" then
      local id, port = relayProvider(edge.device, edge.port)
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
  local direct = contract.loadDomain(source.entity) ~= nil
  local active = ready(owner, source.entity)
  local result = {
    phase = "staged",
    lines = lines(source, me),
    source_name = (source.name or source.model) .. " (device " .. source.id .. ")",
    replacement_name = destinationName(me),
    entity = source.entity,
    move_count = oldCount + interrupted,
    restore_count = newCount + interrupted,
    can_check = direct and not cp.checked and now and now.entity == source.entity,
    can_configure = cp.checked == true and oldInactive and blank,
    can_transfer = cp.checked == true and oldInactive and active and oldCount + interrupted > 0 and unrelated == 0,
    can_rollback = blank and newCount + interrupted > 0 and unrelated == 0,
  }
  if unrelated > 0 then
    result.message = "A saved relay now connects elsewhere. Check its current connection in Composer before continuing."
  elseif not direct then
    result.message =
      "Keep the original switch active. Verify its saved button device, linked load and indicator settings manually in Home Assistant and Composer."
  elseif not cp.checked then
    result.message = "Check Home Assistant from this replacement while the original switch still controls its device."
  elseif result.can_rollback then
    result.message =
      "The replacement has no selected device. You can restore its saved relay connections to the original switch."
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
  else
    result.message =
      "Check scenes, button links and programming in Composer and test after reload. Keep the original switch and backup until these checks pass."
  end
  if newCount + interrupted > 0 and not blank then
    result.rollback_help =
      "To restore the original relay connections, first clear the device selection on this replacement, then refresh the review."
  end
  return result
end

local function moveRelays(cp, me, undo, owner)
  local original = cp.source
  local destination = GetDeviceBindings(me, nil, true, nil, "RELAY")[ids.relay]
  if not destination or tonumber(destination.deviceid) ~= me or not destination.provider then
    return { error = "The replacement relay could not be verified." }
  end
  local fromId, fromPort, toId, toPort = original.id, 1, me, ids.relay
  if undo then
    fromId, fromPort, toId, toPort = toId, toPort, fromId, fromPort
  end
  local function save()
    persist:set(KEY, codec.encode(cp), true)
  end
  for _, edge in ipairs(original.edges) do
    if edge.binding == 1 and edge.owner == original.id and edge.direction == "output" then
      local device, port = edge.device, edge.port
      local peer, pin = relayProvider(device, port)
      cp.pending = cp.pending or codec.object({})
      local edgeKey = tostring(device) .. "." .. tostring(port)
      local prior = cp.pending[edgeKey]
      if peer == toId and pin == toPort then
      -- Already reached the requested topology before an interruption.
      elseif (peer == fromId and pin == fromPort) or (peer == 0 and prior == true) then
        cp.pending[edgeKey] = true
        save()
        if peer ~= 0 then
          C4:Unbind(device, port)
        end
        if relayProvider(device, port) ~= 0 then
          return { error = "A relay could not be disconnected. Inspect its current connection and resume." }
        end
        Bind(toId, toPort, device, port, "RELAY")
        peer, pin = relayProvider(device, port)
        if peer ~= toId or pin ~= toPort then
          return {
            error = "The new relay connection was not verified. Inspect the saved plan and resume or restore.",
          }
        end
      else
        return { error = "A relay now connects elsewhere. Review it in Composer before resuming." }
      end
      if cp.pending[edgeKey] then
        cp.pending[edgeKey] = nil
        save()
      end
    end
  end
  local result = progress(cp, owner)
  result.message = undo
      and "Original relay connections verified. Restore the old Entity ID and Home Assistant connection, then test it. Restore the project backup for private settings or programming."
    or "Relay connections verified. Check scenes, buttons, both directions of programming and the replacement after reload before retiring the old switch."
  return result
end

local function changeOwner(owner, action, params, cp, me)
  if action ~= "transfer" and action ~= "rollback" and action ~= "configure" then
    return { error = "Choose a migration action." }
  end
  if params.confirmed ~= true then
    return { error = "Review the connection changes and confirm to continue." }
  end
  local original, now = cp.source, assess.assess(cp.source.id, { skipPrograms = true })
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
  elseif owner.config or owner.pending or owner.working then
    return { error = "Clear this replacement’s device selection before restoring the old relay connections." }
  end
  return moveRelays(cp, me, undo, owner)
end

local function verifyAvailability(owner, cp, done)
  local source = assess.assess(cp.source.id, { skipPrograms = true })
  if
    not sameOrigin(source, cp.source)
    or source.entity ~= cp.source.entity
    or not contract.loadDomain(source.entity)
  then
    return { error = "Keep the original switch connected. Check its selected device and review the plan again." }
  end
  owner.consumer:request("verify_target", source.entity, codec.object({})):next(function()
    local checkpoint = saved()
    if not checkpoint or checkpoint.source.id ~= source.id then
      done({ error = "Reopen the saved plan." })
      return
    end
    checkpoint.checked = true
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
          cfg
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
        return cp and progress(cp, owner) or { phase = "choose", sources = assess.sources() }
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
        local possible = family == "switch"
          and source.family == "switch"
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
          message = possible
              and "Saving this plan records the old switch and its connections on this replacement. The old switch keeps control."
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
          or not now.entity
          or now.family ~= "switch"
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
      done({ error = "The project could not be verified. Check the connections in Composer and reopen the saved plan." })
    elseif response then
      done(response)
    end
  end)
end
return M
