-- Assign the default Coordinator once, before any device has been selected.
local contract = require("ha.contract")
local ids = require("ha.identities")
local persist = require("lib.persist")
local log = require("lib.logging")
require("lib.bindings")

local M = {}
local KEY = "HA.CoordinatorConnected"
local coordinators = {
  ids.packages.coordinator,
  { file = "Control4.HA.Coordinator.c4z", model = "Control4.HA.Coordinator" },
}

local function alreadyConnected(device, input)
  local provider = tonumber(C4:GetBoundProviderDevice(device, input))
  if contract.integer(provider) then
    if not persist:get(KEY) then
      persist:set(KEY, true)
    end
    return true
  end
  return false
end

function M.remember(device, binding)
  if binding == contract.consumerInput(device) then
    alreadyConnected(device, binding)
  end
end

function M.connect(device)
  local input = contract.consumerInput(device)
  if not input or alreadyConnected(device, input) or persist:get(KEY) then
    return
  end
  local coordinator
  for _, package in ipairs(coordinators) do
    for id in pairs(C4:GetDevicesByC4iName(package.file) or {}) do
      local candidate = tonumber(id)
      if
        contract.integer(candidate)
        and candidate ~= device
        and C4:GetDeviceData(candidate, "model") == package.model
        and GetDeviceBindings(candidate, nil, true, nil, ids.coordinatorClass)[ids.coordinatorBinding]
      then
        if coordinator and coordinator ~= candidate then
          return
        end
        coordinator = candidate
      end
    end
  end
  if coordinator and not alreadyConnected(device, input) then
    Bind(coordinator, ids.coordinatorBinding, device, input, ids.coordinatorClass)
    alreadyConnected(device, input)
  end
end

function M.tryConnect(device)
  if not pcall(M.connect, device) then
    log:warn("Could not assign a Home Assistant Coordinator. Check Composer Connections.")
  end
end

return M
