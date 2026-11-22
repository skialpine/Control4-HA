-- Read-only Director assessment. Keep private script bodies and settings inside Director.
local contract = require("ha.contract")
local ids = require("ha.identities")
require("lib.utils")
local prototypeSelection = require("ha.prototype-selection")
local M = {}
local roles = {
  [999] = { class = "HA_DEVICE", name = "Home Assistant connection", provider = false, new = ids.coordinatorBinding },
  [1] = { class = "RELAY", name = "Relay", provider = true, new = ids.relay },
  [200] = { class = "BUTTON_LINK", name = "On button", provider = true, new = ids.links.top },
  [201] = { class = "BUTTON_LINK", name = "Off button", provider = true, new = ids.links.bottom },
  [202] = { class = "BUTTON_LINK", name = "Toggle button", provider = true, new = ids.links.toggle },
}
local function sourceRoles(report)
  if report.family == "switch" then
    return roles
  end
  local supported = {
    [999] = roles[999],
    [200] = roles[200],
    [201] = roles[201],
    [202] = roles[202],
    [5001] = { class = "LIGHT_V2", provider = true },
  }
  if report.version == "1" then
    for _, id in ipairs({ 203, 204, 205 }) do
      supported[id] = { class = "BUTTON_LINK", provider = false }
    end
  end
  return supported
end
local function numeric(value)
  local n = tonumber(value)
  return contract.integer(n) and n or nil
end

function M.deviceLabel(name, room)
  return name .. (type(room) == "string" and room:match("%S") and (" in " .. room) or " in an unknown room")
end

function M.deviceLocation(id, fallbackName, fallbackRoom)
  local rows = C4:GetDevices({ DeviceIds = tostring(id) }) or {}
  local device = rows[id] or rows[tostring(id)]
  local name = device and device.deviceName or fallbackName or "Unknown device"
  local room = device and device.roomName or fallbackRoom
  return M.deviceLabel(name, room), device
end

local lightEvents = { [5100] = "Turned On", [5101] = "Turned Off" }

local function eventName(device, reference)
  if device and device.driverFileName == "light_v2.c4i" and lightEvents[reference.event] then
    return lightEvents[reference.event]
  end
  local got, xml = pcall(C4.GetDeviceData, C4, reference.device, "events")
  if not got or type(xml) ~= "string" or #xml > 65536 then
    return
  end
  local parsed, tree = pcall(ParseXml, "<root>" .. xml .. "</root>")
  local root = parsed and Select(tree, "root")
  local events = Select(root, "events", "event") or Select(root, "event")
  if type(events) ~= "table" then
    return
  end
  for _, event in pairs(events.id and { events } or events) do
    if type(event) == "table" and tonumber(event.id) == reference.event and type(event.name) == "string" then
      if #event.name <= 160 and event.name:match("%S") and not event.name:find("%c") then
        return event.name
      end
    end
  end
end

function M.programReference(reference, original)
  local location, device = M.deviceLocation(reference.device, original and original.name, original and original.room)
  return {
    location = location,
    event = eventName(device, reference),
    eventId = reference.event,
  }
end

function M.source(id, row)
  local package = row and ids.legacyPrototypes[row.driverFileName]
  if not package or C4:GetDeviceData(id, "model") ~= package.model or C4:GetDeviceData(id, "manufacturer") ~= "BP" then
    return nil
  end
  local version = tostring(C4:GetDeviceData(id, "version"))
  local origin = version == package.version and "Prototype" or version == "106" and "BP" or nil
  if not origin then
    return nil
  end
  return {
    id = id,
    file = row.driverFileName,
    model = package.model,
    family = package.family,
    origin = origin,
    version = version,
    room = row.roomName,
    room_id = numeric(row.roomId),
    name = row.deviceName,
  }
end

function M.sources(family)
  local found = C4:GetDevices({ C4iNames = family == "switch" and "HA.Switch.c4z" or "HA.Switch.c4z,HA.Light.c4z" })
  assert(type(found) == "table")
  local list = {}
  for key, row in pairs(found) do
    local id = numeric(key)
    if id and type(row) == "table" and not next(row.protocol or {}) then
      local candidate = M.source(id, row)
      if candidate and (not family or candidate.family == family) then
        list[#list + 1] = candidate
      end
    end
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

local function lookup(id)
  local items = C4:GetDevices({ DeviceIds = tostring(id) })
  return type(items) == "table" and (items[id] or items[tostring(id)]) or nil
end

local function endpoints(sourceId, bindingId, row, list)
  local function add(peer, direction)
    if #list >= 256 then
      return false
    end
    if type(peer) ~= "table" or not numeric(peer.deviceid) or not numeric(peer.bindingid) then
      return false
    end
    list[#list + 1] = {
      owner = sourceId,
      binding = bindingId,
      device = tonumber(peer.deviceid),
      port = tonumber(peer.bindingid),
      direction = direction,
    }
    return true
  end
  local count = #list
  for _, peer in pairs(row.boundconsumers or {}) do
    if not add(peer, "output") then
      return false
    end
  end
  local peer = Select(row, "boundprovider", "bound")
  if peer and not add(peer, "input") then
    return false
  end
  return not row.isbound or #list ~= count
end

local function bindings(report, owner)
  local items = GetDeviceBindings(owner)
  local known, seen = true, {}
  local expected = owner == report.id and sourceRoles(report) or {}
  for bindingId, row in pairs(items) do
    local id = numeric(bindingId)
    local role = expected[id]
    if not id or type(row) ~= "table" then
      return false
    end
    if role then
      local matches = false
      for _, class in pairs(row.bindingclasses or {}) do
        if class.class == role.class then
          matches = true
        end
      end
      if row.provider ~= role.provider or not matches then
        known = false
      else
        seen[id] = true
      end
    elseif owner == report.id then
      known = false
    end
    if not endpoints(owner, id, row, report.edges) then
      known = false
    end
  end
  if owner == report.id then
    for id in pairs(expected) do
      if not seen[id] then
        known = false
      end
    end
  end
  return known
end

local powerCommands = { ["Turn On"] = true, ["Turn Off"] = true, TurnOn = true, TurnOff = true }

-- Only single, unconditional power commands with empty arguments have a verified mapping.
local function powerCommand(node, depth)
  local xml = type(node.cmdcond) == "table" and node.cmdcond.xml
  if depth ~= 1 or node.enabled == false or type(xml) ~= "string" or #xml > 2048 then
    return
  end
  local ok, parsed = pcall(ParseXml, xml)
  local command = ok and Select(parsed, "devicecommand")
  if
    type(command) == "table"
    and powerCommands[command.command]
    and (command.params == nil or type(command.params) == "table" and not next(command.params))
  then
    return command.command
  end
end

-- The published GetAllCodeItems schema separates structural targets from private cmdcond XML.
local function programming(members, programs)
  local summary = { readable = false, attached = {}, incoming = {}, opaque = false }
  if type(programs) ~= "table" or type(programs.event_mgr) ~= "table" then
    return summary
  end
  local remaining = 25000
  local function visit(node, depth, location, active)
    remaining = remaining - 1
    if remaining < 0 or depth > 64 or type(node) ~= "table" then
      error("unsupported program structure")
    end
    local target = numeric(node.device)
    if target and members[target] then
      location.actionCount = location.actionCount + 1
      local command = active and powerCommand(node, depth)
      if command then
        location.commands[command] = (location.commands[command] or 0) + 1
      end
    end
    if type(node.cmdcond) == "table" and node.cmdcond.xml ~= nil and node.cmdcond.xml ~= "" then
      summary.opaque = true
    end
    if node.subitems ~= nil and type(node.subitems) ~= "table" then
      error("unsupported branch structure")
    end
    for _, child in pairs(node.subitems or {}) do
      visit(child, depth + 1, location, active)
    end
  end
  for _, event in pairs(programs.event_mgr) do
    local id, trigger = numeric(event.deviceid), tonumber(event.eventid)
    if not id or not trigger or trigger < 0 or trigger ~= math.floor(trigger) then
      return summary
    end
    local location = { device = id, event = trigger, actionCount = 0, commands = {} }
    visit(event.codeitem, 0, location, event.codeitem.enabled ~= false)
    local locations = members[id] and summary.attached or location.actionCount > 0 and summary.incoming
    if locations then
      if #locations >= 128 then
        summary.truncated = true
      else
        locations[#locations + 1] = location
      end
    end
  end
  local function order(a, b)
    return a.device == b.device and a.event < b.event or a.device < b.device
  end
  table.sort(summary.attached, order)
  table.sort(summary.incoming, order)
  summary.readable = true
  return summary
end

function M.programmingSnapshot()
  local ok, programs = pcall(C4.GetAllCodeItems, C4)
  return ok and programs or false
end

local function readProgramming(members, snapshot)
  if snapshot == nil then
    snapshot = M.programmingSnapshot()
  end
  local safe, programs = pcall(programming, members, snapshot)
  return safe and programs or { readable = false, attached = {}, incoming = {} }
end

function M.deviceProgramming(id)
  local row = lookup(id)
  if not row or next(row.protocol or {}) then
    return { readable = false, attached = {}, incoming = {} }
  end
  local members = { [id] = true }
  for key in pairs(row.proxies or {}) do
    local proxy = numeric(key)
    if not proxy then
      return { readable = false, attached = {}, incoming = {} }
    end
    members[proxy] = true
  end
  return readProgramming(members)
end

function M.assess(requested, options)
  local id = numeric(requested)
  if not id then
    return nil
  end
  local row = lookup(id)
  if row and type(row.protocol) == "table" and next(row.protocol) then
    local first = next(row.protocol)
    if next(row.protocol, first) then
      return nil
    end
    id = numeric(first)
    row = id and lookup(id)
  end
  local report = M.source(id, row)
  if not report then
    return nil
  end
  local members = { [id] = true }
  report.proxies, report.edges = {}, {}
  for key, proxy in pairs(row.proxies or {}) do
    local proxyId = numeric(key)
    if not proxyId then
      return nil
    end
    members[proxyId] = true
    report.proxies[#report.proxies + 1] = { id = proxyId, file = proxy.driverFileName }
  end
  table.sort(report.proxies, function(a, b)
    return a.id < b.id
  end)
  report.interfaces = true
  for member in pairs(members) do
    local ok, valid = pcall(bindings, report, member)
    if not ok or not valid then
      report.interfaces = false
    end
  end
  report.bindingsVerified = report.interfaces
  if report.family == "switch" and #report.proxies > 0 then
    report.interfaces = false
  end
  if report.family == "light" and (#report.proxies ~= 1 or report.proxies[1].file ~= "light_v2.c4i") then
    report.interfaces = false
  end
  table.sort(report.edges, function(a, b)
    if a.owner ~= b.owner then
      return a.owner < b.owner
    end
    if a.binding ~= b.binding then
      return a.binding < b.binding
    end
    if a.device ~= b.device then
      return a.device < b.device
    end
    return a.port < b.port
  end)
  local ok, props = pcall(GetDeviceProperties, id)
  local got, vars = pcall(C4.GetDeviceVariables, C4, id)
  local entity, variable, count = ok and type(props) == "table" and props["Entity ID"], nil, 0
  for key, item in pairs(got and type(vars) == "table" and vars or {}) do
    if item.name == "ENTITY_ID" then
      count = count + 1
      variable, report.variable_id = item.value, numeric(item.id or key)
    end
  end
  report.empty = entity == "" and count == 1 and variable == ""
  if count == 1 and entity == variable and contract.entity(entity) then
    report.entity = entity
  elseif count == 1 and contract.entity(entity) and contract.entity(variable) then
    report.selection_disagrees = true
  elseif (entity == nil or entity == false) and count == 1 and contract.entity(variable) then
    report.candidate_entity = variable
  elseif count == 0 and contract.entity(entity) then
    report.candidate_entity = entity
  end
  report.mode = ok and type(props) == "table" and prototypeSelection.mode(props["Operation Mode"]) or nil
  if report.family == "switch" and prototypeSelection.switchButtonBehavior(report.mode) and type(props) == "table" then
    local name = props["Selected Device"]
    if
      type(name) == "string"
      and #name <= 160
      and name:match("%S")
      and not name:find("%c")
      and name ~= "Not selected"
    then
      report.selectedName = name
    end
    report.ledBehavior = prototypeSelection.ledBehavior(props["LED Behavior"])
  end
  if not (options and options.skipPrograms) then
    report.programs = readProgramming(members, options and options.programming)
  end
  return report
end

function M.switchSelectionIssue(source)
  if source.selection_disagrees then
    return "Re-enter the correct Entity ID in the original switch’s Properties in Composer, then refresh the list."
  end
end

function M.destination(sourceBinding)
  return roles[sourceBinding]
end

-- Return the exact connected item, including a proxy's underlying driver.
function M.connectionPeer(id)
  local label, row = M.deviceLocation(id)
  if not row then
    return label
  end
  local protocol = row.protocol or {}
  local child = next(protocol)
  if child then
    if next(protocol, child) then
      return label
    end
    id = numeric(child)
    row = id and lookup(id) or nil
  end
  if row and type(row.driverFileName) == "string" then
    if not ids.legacyPrototypes[row.driverFileName] then
      return label, true
    end
    if M.source(id, row) then
      return label, false, "legacy"
    end
    local light = ids.packages.light
    return label,
      row.driverFileName == light.file and C4:GetDeviceData(id, "model") == light.model and tostring(
        C4:GetDeviceData(id, "version")
      ):match("^%d%d%d%d%d%d%d%d%d%d$") ~= nil
  end
  return label
end

function M.legacyCoordinator(source)
  if not source or not source.interfaces then
    return nil
  end
  local provider = numeric(C4:GetBoundProviderDevice(source.id, ids.lightCoordinatorBinding))
  if provider then
    for _, edge in ipairs(source.edges) do
      if
        edge.owner == source.id
        and edge.binding == ids.lightCoordinatorBinding
        and edge.direction == "input"
        and edge.device == provider
        and edge.port == ids.coordinatorBinding
      then
        return provider
      end
    end
  end
end

function M.switchMigrationModeIssue(source)
  if source.mode == "direct" or (source.version == "106" and source.mode == nil) then
    return nil
  end
  if source.mode == "bridge" or source.mode == "buttons" then
    return "This switch uses button events. Open Quick Setup on Home Assistant Connection and choose Migrate switch drivers."
  end
  return "Check Operation Mode in the original switch’s Properties in Composer, then refresh or reopen this review."
end

return M
