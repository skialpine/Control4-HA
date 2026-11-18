-- Read-only Director assessment. Keep private script bodies and settings inside Director.
local contract = require("ha.contract")
local ids = require("ha.identities")
require("lib.utils")
local prototypeSelection = require("ha.prototype-selection")
local M = {}
local packages = {
  ["HA.Switch.c4z"] = { model = "HA Switch", family = "switch", versions = { ["106"] = "BP", ["107"] = "Prototype" } },
  ["HA.Light.c4z"] = { model = "HA Light", family = "light", versions = { ["106"] = "BP", ["1"] = "Prototype" } },
}
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

function M.source(id, row)
  local package = row and packages[row.driverFileName]
  if not package or C4:GetDeviceData(id, "model") ~= package.model or C4:GetDeviceData(id, "manufacturer") ~= "BP" then
    return nil
  end
  local version = tostring(C4:GetDeviceData(id, "version"))
  local origin = package.versions[version]
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

function M.sources()
  local found = C4:GetDevices({ C4iNames = "HA.Switch.c4z,HA.Light.c4z" })
  assert(type(found) == "table")
  local list = {}
  for key, row in pairs(found) do
    local id = numeric(key)
    if id and type(row) == "table" and not next(row.protocol or {}) then
      local candidate = M.source(id, row)
      if candidate then
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

-- The published GetAllCodeItems schema separates structural targets from private cmdcond XML.
local function programming(members)
  local programs = C4:GetAllCodeItems()
  local summary = { readable = false, attached = {}, incoming = {}, opaque = false }
  if type(programs) ~= "table" or type(programs.event_mgr) ~= "table" then
    return summary
  end
  local remaining = 25000
  local function visit(node, depth)
    remaining = remaining - 1
    if remaining < 0 or depth > 64 or type(node) ~= "table" then
      error("unsupported program structure")
    end
    local target = numeric(node.device)
    local referenced = target and members[target] or false
    if type(node.cmdcond) == "table" and node.cmdcond.xml ~= nil and node.cmdcond.xml ~= "" then
      summary.opaque = true
    end
    if node.subitems ~= nil and type(node.subitems) ~= "table" then
      error("unsupported branch structure")
    end
    for _, child in pairs(node.subitems or {}) do
      if visit(child, depth + 1) then
        referenced = true
      end
    end
    return referenced
  end
  for _, event in pairs(programs.event_mgr) do
    local id, trigger = numeric(event.deviceid), tonumber(event.eventid)
    if not id or not trigger or trigger < 0 or trigger ~= math.floor(trigger) then
      return summary
    end
    local location = { device = id, event = trigger }
    local references = visit(event.codeitem, 0)
    local locations = members[id] and summary.attached or references and summary.incoming
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
  elseif (entity == nil or entity == false) and count == 1 and contract.entity(variable) then
    report.candidate_entity = variable
  elseif count == 0 and contract.entity(entity) then
    report.candidate_entity = entity
  end
  report.mode = ok and type(props) == "table" and prototypeSelection.mode(props["Operation Mode"]) or nil
  if not (options and options.skipPrograms) then
    local safe, programs = pcall(programming, members)
    report.programs = safe and programs or { readable = false, attached = {}, incoming = {} }
  end
  return report
end

function M.destination(sourceBinding)
  return roles[sourceBinding]
end
return M
