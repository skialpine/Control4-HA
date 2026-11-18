-- Scoped original BP traffic on the Coordinator’s shared provider.
local codec = require("ha.codec")
local contract = require("ha.contract")
local services = require("ha.legacy-services")
local stateProjection = require("ha.legacy-state")
local ids = require("ha.identities")

local Legacy = {}
Legacy.__index = Legacy
local CLASS, CONSUMER = ids.legacyCoordinatorClass, ids.lightCoordinatorBinding
local function legacyClass(peer)
  if type(peer) ~= "table" or type(peer.boundclasses) ~= "table" then
    return false
  end
  local key, class = next(peer.boundclasses)
  return class == CLASS and next(peer.boundclasses, key) == nil
end

local function reciprocalPeer(owner, peer)
  if not legacyClass(peer) or tonumber(peer.bindingid) ~= CONSUMER then
    return nil
  end
  local device = tonumber(peer.deviceid)
  if not contract.integer(device) or device == owner then
    return nil
  end
  local input = GetDeviceBindings(device, nil, false, nil, CLASS)[CONSUMER]
  local reverse = input and input.boundprovider and input.boundprovider.bound
  if
    not legacyClass(reverse)
    or tonumber(reverse.deviceid) ~= owner
    or tonumber(reverse.bindingid) ~= ids.coordinatorBinding
    or tonumber(C4:GetBoundProviderDevice(device, CONSUMER)) ~= owner
  then
    return nil
  end
  return device
end

local function family(device)
  local rows = C4:GetDevices({ DeviceIds = tostring(device) }) or {}
  local row = rows[device] or rows[tostring(device)]
  return row
    and services.family(
      row.driverFileName,
      C4:GetDeviceData(device, "model"),
      C4:GetDeviceData(device, "manufacturer"),
      C4:GetDeviceData(device, "version")
    )
end

local function verifiedSuite(owner, peer)
  local device = tonumber(peer.deviceid)
  if not contract.integer(device) or contract.provider(device) ~= owner then
    return false
  end
  local rows = C4:GetDevices({ DeviceIds = tostring(device) }) or {}
  local row = rows[device] or rows[tostring(device)]
  local model = C4:GetDeviceData(device, "model")
  local function matches(package)
    return row and row.driverFileName == package.file and model == package.model
  end
  return (matches(ids.packages.light) or matches(ids.packages.switch))
    and SendUIRequest(device, "HA_LEGACY_WIRE", {}) == "<legacy_wire>ignore-v1</legacy_wire>"
end

local function boundPeers(owner)
  local binding
  for _, record in pairs(Select(C4:GetBindingsByDevice(owner), "bindings") or {}) do
    if tonumber(record.bindingid) == ids.coordinatorBinding then
      if binding or record.provider ~= true then
        return nil
      end
      binding = record
    end
  end
  return binding and binding.boundconsumers
end

-- Every recipient parses the shared packet. Only this audited group may
-- receive projected states. The Base logs incoming parameters before parsing
-- when Debug Mode is on. An unknown recipient invalidates the entire group.
local function statePlan()
  local owner = tonumber(C4:GetDeviceID())
  local peers = boundPeers(owner)
  if type(peers) ~= "table" then
    return {}
  end
  local selected, stamp, seen = {}, {}, {}
  local function select(entity, model)
    selected[entity] = selected[entity] or {}
    selected[entity][model] = true
  end
  for _, peer in pairs(peers) do
    local device = reciprocalPeer(owner, peer)
    local model = device and family(device)
    if not model then
      if not verifiedSuite(owner, peer) then
        return {}
      end
      stamp[#stamp + 1] = "suite:" .. peer.deviceid
    elseif seen[device] then
      return {}
    else
      seen[device] = true
      local properties = GetDeviceProperties(device)
      local entity = properties["Entity ID"]
      if properties["Debug Mode"] ~= "Off" or not services.selected(model, entity) then
        return {}
      end
      select(entity, model)
      local auxiliary = ""
      if model == "HA Thermostat" and properties["Mode States Enabled"] == "True" then
        auxiliary = properties["Mode Selection Entity ID"]
        if type(auxiliary) ~= "string" or #auxiliary > 255 or not auxiliary:match("^select%.[a-z0-9_]+$") then
          return {}
        end
        select(auxiliary, model)
      end
      stamp[#stamp + 1] = device .. ":" .. model .. ":" .. entity .. ":" .. auxiliary
    end
  end
  table.sort(stamp)
  return selected, table.concat(stamp, ",")
end

function Legacy.new(hub)
  return setmetatable({ connection = hub.connection, hub = hub, epoch = 0 }, Legacy)
end

-- Read the current configured IDs only for the explicitly requested entity
-- list. A suite Light also declares input 999 but its saved BP property can
-- be stale. Suite selections come from the Hub instead.
function Legacy:linkedEntities()
  local owner, entities = tonumber(C4:GetDeviceID()), {}
  for _, peer in pairs(boundPeers(owner) or {}) do
    local device = reciprocalPeer(owner, peer)
    if device and not contract.consumerInput(device) then
      local ok, properties = pcall(GetDeviceProperties, device)
      local entity = ok and properties and properties["Entity ID"]
      if type(entity) == "string" and #entity <= 255 and entity:match("^[a-z][a-z0-9_]*%.[a-z0-9_]+$") then
        entities[entity] = true
      end
    end
  end
  return entities
end

function Legacy:bindingChanged()
  self.epoch = self.epoch + 1
  self.hub:watchLegacy({}, nil)
end

function Legacy:service(binding, params)
  if self.destroyed or self.connection.state ~= "connected" or binding ~= ids.coordinatorBinding then
    return
  end
  local request = services.request(params)
  if not request then
    return
  end
  local epoch, generation = self.epoch, self.connection.generation
  local owner = tonumber(C4:GetDeviceID())
  local peers = boundPeers(owner)
  if type(peers) ~= "table" then
    return
  end
  local target, matched = request.target.entity_id, false
  for _, peer in pairs(peers) do
    local device = reciprocalPeer(owner, peer)
    local model = device and family(device)
    if not model then
      if not verifiedSuite(owner, peer) then
        return
      end
    else
      local properties = GetDeviceProperties(device)
      if not services.selected(model, properties["Entity ID"]) then
        return
      end
      local property = services.property(model, request.domain, request.service)
      if
        property
        and properties[property] == target
        and (property ~= "Mode Selection Entity ID" or properties["Mode States Enabled"] == "True")
        and (property ~= "Clear Hold Entity ID" or properties["Hold Modes Enabled"] == "True")
      then
        matched = true
      end
    end
  end
  if
    matched
    and not self.destroyed
    and self.connection.state == "connected"
    and self.epoch == epoch
    and self.connection.generation == generation
  then
    self.hub:legacyService(request)
  end
end

function Legacy:destroy()
  self.destroyed = true
end

function Legacy:currentPlan()
  local ok, selected, stamp = pcall(statePlan)
  if not ok or not stamp then
    return {}
  end
  return selected, self.connection.generation .. ":" .. self.epoch .. ":" .. stamp
end

function Legacy:refresh(requested)
  if self.destroyed or self.connection.state ~= "connected" then
    return
  end
  local selected, stamp = self:currentPlan()
  self.hub:watchLegacy(selected, stamp, requested, requested and not selected[requested])
end

function Legacy:request(binding, params)
  if
    binding ~= ids.coordinatorBinding
    or type(params) ~= "table"
    or GetTableSize(params) ~= 1
    or type(params.entity) ~= "string"
  then
    return
  end
  self:refresh(params.entity)
end

function Legacy:deliver(kind, state, expected)
  if self.destroyed or self.connection.state ~= "connected" then
    return
  end
  local selected, stamp = self:currentPlan()
  local models = selected[state.entity_id]
  if stamp ~= expected or not models then
    self.hub:watchLegacy(selected, stamp)
    return
  end
  local projection = stateProjection.project(state, models)
  if kind == "snapshot" then
    C4:SendToProxy(ids.coordinatorBinding, "RECEIEVE_STATE", { response = codec.encode(projection) })
  elseif kind == "state" then
    C4:SendToProxy(
      ids.coordinatorBinding,
      "RECEIEVE_EVENT",
      { data = codec.encode({ event = { data = { new_state = projection } } }) }
    )
  end
  return true
end

return Legacy
