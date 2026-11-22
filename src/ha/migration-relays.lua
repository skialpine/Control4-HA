-- Transfer only the exact provider connections recorded in a reviewed migration.
local ids = require("ha.identities")
local codec = require("ha.codec")
require("lib.bindings")
local M = {}

function M.provider(device, port, class)
  local row = GetDeviceBindings(device, nil, false, nil, class or "RELAY")[port]
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

local function connections(cp)
  if cp.mappedConnections then
    return cp.mappedConnections
  end
  local found = {}
  for _, edge in ipairs(cp.source.edges) do
    if edge.binding == 1 and edge.owner == cp.source.id and edge.direction == "output" then
      found[#found + 1] = { device = edge.device, port = edge.port, from = 1, to = ids.relay, class = "RELAY" }
    end
  end
  return found
end

local function key(edge)
  return tostring(edge.device) .. "." .. tostring(edge.port)
end

function M.canRestore(cp, replacement, current)
  local original = cp.source
  local planned = {}
  for _, edge in ipairs(connections(cp)) do
    local peer, pin = M.provider(edge.device, edge.port, edge.class)
    local id = key(edge)
    if
      not (
        (peer == original.id and pin == edge.from)
        or (peer == replacement and pin == edge.to)
        or (peer == 0 and cp.pending and cp.pending[id] == true)
      )
    then
      return false
    end
    planned[id] = edge.from
  end
  for _, edge in ipairs(current.edges) do
    if
      edge.owner == original.id
      and edge.direction == "output"
      and (cp.mappedConnections or edge.binding == 1)
      and planned[key(edge)] ~= edge.binding
    then
      return false
    end
  end
  return true
end

function M.transferred(cp, replacement)
  for _, edge in ipairs(connections(cp)) do
    local peer, pin = M.provider(edge.device, edge.port, edge.class)
    if peer ~= replacement or pin ~= edge.to then
      return false
    end
  end
  return true
end

function M.destinationIssue(cp, replacement, undo)
  local device = undo and cp.source.id or replacement
  local reviewed = {}
  for _, edge in ipairs(connections(cp)) do
    local port = undo and edge.from or edge.to
    local destination = GetDeviceBindings(device, nil, true, nil, edge.class)[port]
    if not destination or tonumber(destination.deviceid) ~= device or not destination.provider then
      return undo and "An original driver connection port could not be verified."
        or "A replacement connection port could not be verified."
    end
    reviewed[port] = reviewed[port] or {}
    reviewed[port][key(edge)] = true
  end
  if undo then
    return
  end
  local bindings = GetDeviceBindings(replacement)
  local input = bindings[ids.coordinatorBinding]
  if not input or tonumber(input.deviceid) ~= replacement or input.provider ~= false then
    return "Control4 could not verify the replacement's connections. Recheck migration."
  end
  for port, binding in pairs(bindings) do
    if port ~= ids.coordinatorBinding and port ~= ids.proxy then
      local found = false
      for _, peer in pairs(binding.boundconsumers or {}) do
        found = true
        if not (reviewed[port] and reviewed[port][key({ device = peer.deviceid, port = peer.bindingid })]) then
          return "Review the extra connections on the replacement in Composer, then recheck migration."
        end
      end
      if binding.boundprovider or (binding.isbound and not found) then
        return "Review the extra connections on the replacement in Composer, then recheck migration."
      end
    end
  end
end

function M.move(cp, me, undo, save)
  local issue = M.destinationIssue(cp, me, undo)
  if issue then
    return { error = issue }
  end
  local original = cp.source
  for _, edge in ipairs(connections(cp)) do
    local fromId, fromPort, toId, toPort = original.id, edge.from, me, edge.to
    if undo then
      fromId, fromPort, toId, toPort = toId, toPort, fromId, fromPort
    end
    local device, port = edge.device, edge.port
    local peer, pin = M.provider(device, port, edge.class)
    cp.pending = cp.pending or codec.object({})
    local edgeKey = key(edge)
    local prior = cp.pending[edgeKey]
    if peer == toId and pin == toPort then
      -- Already reached the requested topology before an interruption.
    elseif (peer == fromId and pin == fromPort) or (peer == 0 and prior == true) then
      cp.completed_revision = nil
      cp.pending[edgeKey] = true
      save()
      if peer ~= 0 then
        C4:Unbind(device, port)
      end
      if M.provider(device, port, edge.class) ~= 0 then
        return { error = "A connection could not be disconnected. Inspect it in Composer and resume." }
      end
      Bind(toId, toPort, device, port, edge.class)
      peer, pin = M.provider(device, port, edge.class)
      if peer ~= toId or pin ~= toPort then
        return {
          error = "The new connection was not verified. Inspect the saved plan and resume or restore.",
        }
      end
    else
      return { error = "A device now connects elsewhere. Review it in Composer before resuming." }
    end
    if cp.pending[edgeKey] then
      cp.pending[edgeKey] = nil
      save()
    end
  end
  return {}
end

return M
