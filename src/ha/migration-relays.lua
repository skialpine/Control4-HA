-- Transfer only the exact relay edges recorded in the reviewed migration.
local ids = require("ha.identities")
local codec = require("ha.codec")
require("lib.bindings")
local M = {}

function M.provider(device, port)
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

function M.canRestore(cp, replacement, current)
  local original = cp.source
  local planned = {}
  local function key(edge)
    return tostring(edge.device) .. "." .. tostring(edge.port)
  end
  for _, edge in ipairs(original.edges) do
    if edge.binding == 1 and edge.owner == original.id and edge.direction == "output" then
      local peer, pin = M.provider(edge.device, edge.port)
      local id = key(edge)
      if
        not (
          (peer == original.id and pin == 1)
          or (peer == replacement and pin == ids.relay)
          or (peer == 0 and cp.pending and cp.pending[id] == true)
        )
      then
        return false
      end
      planned[id] = true
    end
  end
  for _, edge in ipairs(current.edges) do
    if edge.binding == 1 and edge.owner == original.id and edge.direction == "output" and not planned[key(edge)] then
      return false
    end
  end
  return true
end

function M.transferred(cp, replacement)
  for _, edge in ipairs(cp.source.edges) do
    if edge.binding == 1 and edge.owner == cp.source.id and edge.direction == "output" then
      local peer, pin = M.provider(edge.device, edge.port)
      if peer ~= replacement or pin ~= ids.relay then
        return false
      end
    end
  end
  return true
end

function M.move(cp, me, undo, save)
  local original = cp.source
  local destination = GetDeviceBindings(me, nil, true, nil, "RELAY")[ids.relay]
  if not destination or tonumber(destination.deviceid) ~= me or not destination.provider then
    return { error = "The replacement relay could not be verified." }
  end
  local fromId, fromPort, toId, toPort = original.id, 1, me, ids.relay
  if undo then
    fromId, fromPort, toId, toPort = toId, toPort, fromId, fromPort
  end
  for _, edge in ipairs(original.edges) do
    if edge.binding == 1 and edge.owner == original.id and edge.direction == "output" then
      local device, port = edge.device, edge.port
      local peer, pin = M.provider(device, port)
      cp.pending = cp.pending or codec.object({})
      local edgeKey = tostring(device) .. "." .. tostring(port)
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
        if M.provider(device, port) ~= 0 then
          return { error = "A relay could not be disconnected. Inspect its current connection and resume." }
        end
        Bind(toId, toPort, device, port, "RELAY")
        peer, pin = M.provider(device, port)
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
  return {}
end

return M
