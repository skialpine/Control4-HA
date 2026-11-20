-- Shared validation for the versioned Coordinator/consumer boundary; AGPL-3.0.
local codec = require("ha.codec")
local ids = require("ha.identities")
local metrics = require("ha.performance").shared
require("lib.utils")
local M = { maxEntities = 16 }
local loadDomains = { light = true, switch = true, input_boolean = true }
local otherDomains = { event = true, select = true, number = true }

function M.integer(value)
  return type(value) == "number" and value > 0 and value == math.floor(value) and value < 2147483648
end

function M.registryId(value)
  return type(value) == "string" and #value == 32 and value:match("^[a-f0-9]+$") ~= nil
end

local function entityDomain(value)
  if type(value) ~= "string" or #value > 255 then
    return nil
  end
  return value:match("^([a-z][a-z0-9_]*)%.[a-z0-9_]+$")
end

function M.entity(value)
  local domain = entityDomain(value)
  return loadDomains[domain] == true or otherDomains[domain] == true
end

function M.loadDomain(value)
  local domain = entityDomain(value)
  return loadDomains[domain] and domain or nil
end

function M.entities(value)
  if not codec.isArray(value) or #value > M.maxEntities then
    return nil
  end
  local result = {}
  for _, entity in ipairs(value) do
    if not M.entity(entity) or result[entity] then
      return nil
    end
    result[entity] = true
  end
  return result
end

function M.state(value, entity)
  return codec.isObject(value)
    and value.entity_id == entity
    and type(value.state) == "string"
    and codec.isObject(value.attributes)
end

function M.consumerInput(device)
  if not M.integer(device) then
    return nil
  end
  local inputs = GetDeviceBindings(device, nil, false, nil, ids.coordinatorClass)
  local suite, light = inputs[ids.coordinatorBinding], inputs[ids.lightCoordinatorBinding]
  if suite and light then
    return nil
  end
  if light then
    return ids.lightCoordinatorBinding, light
  elseif suite then
    return ids.coordinatorBinding, suite
  end
end

local function peerMatches(peer, device, binding, expectedClass)
  if
    type(peer) ~= "table"
    or tonumber(peer.deviceid) ~= device
    or tonumber(peer.bindingid) ~= binding
    or type(peer.boundclasses) ~= "table"
  then
    return false
  end
  for _, class in pairs(peer.boundclasses) do
    if class == expectedClass then
      return true
    end
  end
  return false
end

local function declaresLegacyClass(binding)
  for _, declared in pairs(Select(binding, "bindingclasses") or {}) do
    if Select(declared, "class") == ids.legacyCoordinatorClass then
      return true
    end
  end
  return false
end

local function retainedPair(device, provider)
  local found = C4:GetDevices({ DeviceIds = device .. "," .. provider }) or {}
  local function matches(id, expected)
    local row = found[id] or found[tostring(id)]
    return row
      and row.driverFileName == expected.file
      and not (type(row.protocol) == "table" and next(row.protocol))
      and C4:GetDeviceData(id, "model") == expected.model
  end
  return matches(device, ids.packages.light) and matches(provider, ids.packages.coordinator)
end

-- Both ends must declare the suite class and agree on the exact peer and edge.
-- The canonical upgraded pair may retain its reciprocal legacy-class edge.
local function provider(device)
  local inputId, input = M.consumerInput(device)
  if not inputId then
    return nil
  end
  local provider = tonumber(C4:GetBoundProviderDevice(device, inputId))
  if not M.integer(provider) or provider == device then
    return nil
  end
  local binding = GetDeviceBindings(provider, nil, true, nil, ids.coordinatorClass)[ids.coordinatorBinding]
  local bound = input.boundprovider and input.boundprovider.bound
  local suite = peerMatches(bound, provider, ids.coordinatorBinding, ids.coordinatorClass)
  local legacy = inputId == ids.lightCoordinatorBinding
    and peerMatches(bound, provider, ids.coordinatorBinding, ids.legacyCoordinatorClass)
  for _, peer in pairs(binding and binding.boundconsumers or {}) do
    if suite and peerMatches(peer, device, inputId, ids.coordinatorClass) then
      return provider
    elseif
      legacy
      and peerMatches(peer, device, inputId, ids.legacyCoordinatorClass)
      and declaresLegacyClass(input)
      and declaresLegacyClass(binding)
      and retainedPair(device, provider)
    then
      return provider
    end
  end
end

function M.provider(device)
  local span = metrics:start("binding.validation")
  local result = provider(device)
  metrics:finish(span, result and "ok" or "rejected")
  return result
end

local function catalogRevision(value)
  return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$") ~= nil
end
function M.catalogSensor(value)
  return entityDomain(value) == "sensor"
end
function M.catalogQuery(value)
  if not codec.isObject(value) then
    return false
  end
  for key in pairs(value) do
    if key ~= "revision" and key ~= "cursor" and key ~= "family" and key ~= "names_sensor" and key ~= "refresh" then
      return false
    end
  end
  if value.refresh ~= nil and (type(value.refresh) ~= "boolean" or value.cursor ~= nil) then
    return false
  end
  if
    value.names_sensor ~= nil
    and (value.family == nil or (value.names_sensor ~= "" and not M.catalogSensor(value.names_sensor)))
  then
    return false
  end
  if value.family ~= nil and value.family ~= "light" and value.family ~= "switch" then
    return false
  end
  if value.revision ~= nil and not catalogRevision(value.revision) then
    return false
  end
  if value.cursor ~= nil and (not M.integer(value.cursor) or value.cursor > 5001) then
    return false
  end
  return value.cursor == nil or (value.revision ~= nil and value.cursor > 1)
end
function M.catalogRow(value)
  if
    not codec.isObject(value)
    or not codec.isObject(value.attributes)
    or type(value.name) ~= "string"
    or #value.name > 4096
    or (value.available ~= nil and type(value.available) ~= "boolean")
    or (not loadDomains[value.domain] and value.domain ~= "event")
  then
    return false
  end
  if type(value.entity_id) ~= "string" or #value.entity_id > 255 then
    return false
  end
  local choice = value.attributes.device_choice
  if choice ~= nil then
    if
      not codec.isObject(choice)
      or choice.type ~= "device_choice"
      or choice.version ~= 1
      or choice.choice_id ~= value.entity_id
      or type(choice.device_id) ~= "string"
      or #choice.device_id ~= 32
      or not choice.device_id:match("^[a-f0-9]+$")
    then
      return false
    end
    local endpoint = value.entity_id:match("^device:" .. choice.device_id .. ":([a-f0-9]+)$")
    return (endpoint ~= nil and #endpoint == 32) or value.entity_id == "device:" .. choice.device_id .. ":none"
  end
  return value.entity_id:match("^" .. value.domain .. "%.[a-z0-9_]+$") ~= nil
end
function M.catalogPage(value)
  if
    not codec.isObject(value)
    or not catalogRevision(value.revision)
    or not (value.source == "native" or value.source == "companion")
    or type(value.total) ~= "number"
    or value.total < 0
    or value.total > 5000
    or value.total ~= math.floor(value.total)
    or not M.integer(value.cursor)
    or value.cursor > value.total + 1
    or not codec.isArray(value.entities)
    or #value.entities > 50
    or (value.family ~= nil and value.family ~= "light" and value.family ~= "switch")
  then
    return false
  end
  for _, item in ipairs(value.entities) do
    if not M.catalogRow(item) then
      return false
    end
  end
  local following = value.next_cursor
  return (following == codec.null and value.cursor + #value.entities == value.total + 1)
    or (
      M.integer(following)
      and following == value.cursor + #value.entities
      and following <= value.total
      and following > value.cursor
    )
end

return M
