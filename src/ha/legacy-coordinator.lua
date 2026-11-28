-- Scoped predecessor traffic on the Coordinator's shared provider.
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
  if not device then
    return
  end
  local rows = C4:GetDevices({ DeviceIds = tostring(device) }) or {}
  local row = rows[device] or rows[tostring(device)]
  if not row then
    return
  end
  local model = C4:GetDeviceData(device, "model")
  local manufacturer = C4:GetDeviceData(device, "manufacturer")
  local version = C4:GetDeviceData(device, "version")
  local prototype = ids.legacyPrototypes[row.driverFileName]
  if prototype and model == prototype.model and manufacturer == "BP" and tostring(version) == prototype.version then
    return model, true
  end
  return services.family(row.driverFileName, model, manufacturer, version)
end

local function verifiedSuite(owner, peer, outputs)
  local device = tonumber(peer.deviceid)
  if not contract.integer(device) or contract.provider(device, outputs) ~= owner then
    return false
  end
  local rows = C4:GetDevices({ DeviceIds = tostring(device) }) or {}
  local row = rows[device] or rows[tostring(device)]
  local model = C4:GetDeviceData(device, "model")
  for family, package in pairs(ids.packages) do
    if family ~= "coordinator" and row and row.driverFileName == package.file and model == package.model then
      return SendUIRequest(device, "HA_LEGACY_WIRE", {}) == "<legacy_wire>ignore-v1</legacy_wire>"
    end
  end
  return false
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

-- Every recipient parses the shared packet. An unknown recipient invalidates
-- the group. The Base logs incoming parameters before parsing when Debug Mode
-- is on, so a valid plan can temporarily be ineligible to publish.
local function statePlan(previous, change)
  local owner = tonumber(C4:GetDeviceID())
  local peers = boundPeers(owner)
  if type(peers) ~= "table" then
    return {}
  end
  local selected, recipients, scopeOwners, seen, scoped, outputs = {}, {}, {}, {}, {}, {}
  local accepted, logging = change == nil, false
  local function select(entity, model)
    selected[entity] = selected[entity] or {}
    selected[entity][model] = true
  end
  for _, peer in pairs(peers) do
    local device = reciprocalPeer(owner, peer)
    local model, prototype = family(device)
    if not model then
      if not verifiedSuite(owner, peer, outputs) then
        return {}
      end
      recipients[#recipients + 1] = "suite:" .. peer.deviceid
    elseif seen[device] then
      return {}
    else
      seen[device] = true
      local properties = GetDeviceProperties(device)
      logging = logging or properties["Debug Mode"] ~= "Off"
      local entity = properties["Entity ID"]
      if prototype then
        local requested = previous[device]
        if change and change.device == device then
          if change.entity ~= nil and (entity ~= change.entity or not contract.loadDomain(entity)) then
            return {}
          end
          requested, accepted = change.entity, true
        end
        if requested and entity == requested and contract.loadDomain(entity) then
          scoped[device] = entity
          select(entity, "prototype")
          scopeOwners[entity] = scopeOwners[entity] or {}
          scopeOwners[entity][#scopeOwners[entity] + 1] = device
        end
        recipients[#recipients + 1] = device .. ":prototype"
      else
        if not services.selected(model, entity) then
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
        recipients[#recipients + 1] = device .. ":" .. model .. ":" .. entity .. ":" .. auxiliary
      end
    end
  end
  if not accepted then
    return {}
  end
  table.sort(recipients)
  return selected, recipients, scopeOwners, scoped, logging
end

function Legacy.new(hub)
  return setmetatable({ connection = hub.connection, hub = hub, epoch = 0, scoped = {} }, Legacy)
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
  if self.connection.state == "connected" then
    self:refresh()
  else
    self.hub:watchLegacy({})
  end
end

function Legacy:service(binding, params)
  if self.destroyed or self.connection.state ~= "connected" or binding ~= ids.coordinatorBinding then
    return
  end
  local originalRequest, prototypeRequest = services.request(params)
  local request = originalRequest or prototypeRequest
  if not request then
    return
  end
  local epoch, generation = self.epoch, self.connection.generation
  local owner = tonumber(C4:GetDeviceID())
  local peers = boundPeers(owner)
  if type(peers) ~= "table" then
    return
  end
  local target, authorized = request.target.entity_id, nil
  for _, peer in pairs(peers) do
    local device = reciprocalPeer(owner, peer)
    local model, prototype = family(device)
    if not model then
      if not verifiedSuite(owner, peer) then
        return
      end
    else
      local properties = GetDeviceProperties(device)
      if prototype then
        if prototypeRequest and properties["Entity ID"] == target and self.scoped[device] == target then
          authorized = prototypeRequest
        end
      else
        if not services.selected(model, properties["Entity ID"]) then
          return
        end
        local property = originalRequest and services.property(model, request.domain, request.service)
        if
          property
          and properties[property] == target
          and (property ~= "Mode Selection Entity ID" or properties["Mode States Enabled"] == "True")
          and (property ~= "Clear Hold Entity ID" or properties["Hold Modes Enabled"] == "True")
        then
          authorized = originalRequest
        end
      end
    end
  end
  if
    authorized
    and not self.destroyed
    and self.connection.state == "connected"
    and self.epoch == epoch
    and self.connection.generation == generation
  then
    self.hub:legacyService(authorized)
  end
end

function Legacy:destroy()
  self.destroyed = true
end

function Legacy:currentPlan(change)
  local ok, selected, recipients, owners, scoped, logging = pcall(statePlan, self.scoped, change)
  if not ok or not recipients then
    return {}, nil
  end
  self.scoped = scoped
  local topology = self.connection.generation .. ":" .. self.epoch .. ":" .. table.concat(recipients, ",")
  local stamps = {}
  for entity in pairs(selected) do
    local members = owners[entity] or {}
    table.sort(members)
    stamps[entity] = topology .. ":" .. table.concat(members, ",")
  end
  return stamps, selected, logging
end

function Legacy:refresh(requested, change)
  local connected = self.connection.state == "connected"
  if self.destroyed or not (connected or change) then
    return
  end
  local stamps, selected = self:currentPlan(change)
  if not connected or (change and not selected) then
    return
  end
  self.hub:watchLegacy(stamps, requested, requested and not stamps[requested])
end

local function scopedDevice(value)
  local device = type(value) == "string" and #value <= 10 and tonumber(value)
  return contract.integer(device) and tostring(device) == value and device or nil
end

function Legacy:request(binding, params)
  if binding ~= ids.coordinatorBinding or type(params) ~= "table" or type(params.entity) ~= "string" then
    return
  end
  if GetTableSize(params) == 1 then
    self:refresh(params.entity)
    return
  end
  local device = scopedDevice(params.consumer_id)
  if
    GetTableSize(params) ~= 3
    or not device
    or not contract.loadDomain(params.entity)
    or type(params.active_entities) ~= "string"
    or #params.active_entities > 512
  then
    return
  end
  local ok, active = pcall(codec.decode, params.active_entities)
  if ok and codec.isArray(active) and #active == 1 and active[1] == params.entity then
    self:refresh(params.entity, { device = device, entity = params.entity })
  end
end

function Legacy:release(binding, params)
  if binding ~= ids.coordinatorBinding or type(params) ~= "table" or GetTableSize(params) ~= 1 then
    return
  end
  local device = scopedDevice(params.consumer_id)
  if device and self.scoped[device] then
    self.scoped[device] = nil
    self:refresh()
  end
end

function Legacy:connectionStatus(binding, force)
  if self.destroyed or binding ~= ids.coordinatorBinding then
    return
  end
  local connected = self.connection.state == "connected"
  if not force and self.reportedConnected == connected then
    return
  end
  local owner = tonumber(C4:GetDeviceID())
  for _, peer in pairs(boundPeers(owner) or {}) do
    local _, prototype = family(reciprocalPeer(owner, peer))
    if prototype then
      self.reportedConnected = connected
      C4:SendToProxy(ids.coordinatorBinding, "HA_CONNECTION_STATUS", { CONNECTED = tostring(connected) })
      return
    end
  end
end

function Legacy:deliver(kind, state, expected)
  if self.destroyed or self.connection.state ~= "connected" then
    return
  end
  local stamps, selected, logging = self:currentPlan()
  if logging then
    -- Keep the approved watches while logging is temporarily enabled. Only a
    -- fresh plan with logging disabled may publish the next state.
    return
  end
  if stamps[state.entity_id] ~= expected then
    self.hub:watchLegacy(stamps)
    return
  end
  local projection = stateProjection.project(state, selected[state.entity_id])
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
