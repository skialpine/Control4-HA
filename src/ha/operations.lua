-- HA operation shapes; correlation and resource ownership live in hub/consumer.
local codec = require("ha.codec")
local contract = require("ha.contract")
local gestureContract = require("ha.gesture-contract")
local indicators = require("ha.indicators")
local effects = require("ha.light-effects")
local endpointServices = require("ha.endpoint-services")
local families = require("ha.endpoint-families")
local M = {}
local function range(value, low, high)
  return type(value) == "number" and value >= low and value <= high
end
local function tuple(value, count, low, high)
  if not codec.isArray(value) or #value ~= count then
    return false
  end
  for _, n in ipairs(value) do
    if not range(n, low, high) then
      return false
    end
  end
  return true
end
local identity = contract.registryId

-- Diagnostic acknowledgments use their own control-plane operation and never
-- occupy the request budget used by service calls or selected setup.
function M.acknowledgment(arguments)
  if
    not codec.isObject(arguments)
    or not contract.entity(arguments.entity_id)
    or not arguments.entity_id:match("^event%.")
    or not gestureContract.identity(arguments.bridge_session_id)
    or not gestureContract.sequence(arguments.gesture_sequence)
    or not range(arguments.receiver_received_epoch_ms, 0, 9007199254740991)
    or not range(arguments.receiver_processed_epoch_ms, 0, 9007199254740991)
    or (arguments.receiver_forwarded_epoch_ms ~= nil and not range(
      arguments.receiver_forwarded_epoch_ms,
      0,
      9007199254740991
    ))
    or not range(arguments.receiver_processing_ms, 0, 60000)
  then
    return nil
  end
  return codec.object({
    entity_id = arguments.entity_id,
    bridge_session_id = arguments.bridge_session_id,
    gesture_sequence = arguments.gesture_sequence,
    receiver_received_epoch_ms = arguments.receiver_received_epoch_ms,
    receiver_processed_epoch_ms = arguments.receiver_processed_epoch_ms,
    receiver_forwarded_epoch_ms = arguments.receiver_forwarded_epoch_ms,
    receiver_processing_ms = arguments.receiver_processing_ms,
  })
end

function M.prepare(arguments)
  if not codec.isObject(arguments) then
    return nil
  end
  for key in pairs(arguments) do
    if key ~= "device_id" and key ~= "source_registry_id" then
      return nil
    end
  end
  if
    not identity(arguments.device_id)
    or (arguments.source_registry_id ~= nil and not identity(arguments.source_registry_id))
  then
    return nil
  end
  return {
    type = "call_service",
    domain = "ha_gesture_bridge",
    service = "prepare_device",
    service_data = arguments,
    return_response = true,
  }
end

-- The saved registry ID distinguishes a renamed/replaced entity from the
-- original endpoint. The optional source must still belong to its saved device.
function M.registryTargets(entity, args)
  if not contract.endpointDomain(entity) or not codec.isObject(args) or not identity(args.registry_id) then
    return nil
  end
  for name in pairs(args) do
    if
      name ~= "registry_id"
      and name ~= "source_entity"
      and name ~= "source_registry_id"
      and name ~= "source_device"
    then
      return nil
    end
  end
  local wanted = codec.array({ entity })
  if args.source_entity ~= nil or args.source_registry_id ~= nil or args.source_device ~= nil then
    if
      not contract.loadDomain(args.source_entity)
      or not identity(args.source_registry_id)
      or not identity(args.source_device)
    then
      return nil
    end
    if args.source_entity ~= entity then
      wanted[2] = args.source_entity
    elseif args.source_registry_id ~= args.registry_id then
      return nil
    end
  end
  return wanted
end

function M.registryMatches(response, entity, args)
  if not codec.isObject(response) then
    return false
  end
  local function matches(id, registry, device)
    local row = response[id]
    return codec.isObject(row)
      and row.entity_id == id
      and row.id == registry
      and (not device or row.device_id == device)
      and (row.disabled_by == codec.null or row.disabled_by == nil)
      and row.platform ~= "control4"
  end
  return matches(entity, args.registry_id)
    and (not args.source_entity or matches(args.source_entity, args.source_registry_id, args.source_device))
end

local eventFields = { event_control = true, event_registry_id = true, load_entity = true, load_registry_id = true }
function M.eventRegistryTargets(entity, args)
  if
    not contract.entity(entity)
    or not entity:match("^event%.")
    or not codec.isObject(args)
    or not gestureContract.identity(args.event_control)
  then
    return nil
  end
  for key in pairs(args) do
    if not eventFields[key] then
      return nil
    end
  end
  if args.event_registry_id ~= nil and not contract.registryId(args.event_registry_id) then
    return nil
  end
  if args.load_entity ~= nil and not contract.loadDomain(args.load_entity) then
    return nil
  end
  if args.load_registry_id ~= nil and (not args.load_entity or not contract.registryId(args.load_registry_id)) then
    return nil
  end
  return codec.array({ entity, args.load_entity })
end

function M.eventReceiptMatches(receipt, entity, args)
  return codec.isObject(receipt)
    and receipt.event_entity == entity
    and receipt.event_control == args.event_control
    and contract.registryId(receipt.event_registry_id)
    and (not args.event_registry_id or args.event_registry_id == receipt.event_registry_id)
    and receipt.load_entity == args.load_entity
    and (
      (not args.load_entity and receipt.load_registry_id == nil)
      or (
        args.load_entity
        and contract.registryId(receipt.load_registry_id)
        and receipt.load_registry_id ~= receipt.event_registry_id
        and (not args.load_registry_id or args.load_registry_id == receipt.load_registry_id)
      )
    )
end

function M.eventRegistryReceipt(response, entity, args)
  if not codec.isObject(response) then
    return nil
  end
  local function entry(id)
    local row = response[id]
    return codec.isObject(row)
      and row.entity_id == id
      and row.disabled_by == codec.null
      and type(row.platform) == "string"
      and row.platform ~= ""
      and row.platform ~= "control4"
      and row
  end
  local event = entry(entity)
  if not event or event.platform ~= "ha_gesture_bridge" or event.unique_id ~= args.event_control then
    return nil
  end
  local load = args.load_entity and entry(args.load_entity)
  if args.load_entity and not load then
    return nil
  end
  local receipt = codec.object({
    event_entity = entity,
    event_control = args.event_control,
    event_registry_id = event.id,
    load_entity = args.load_entity,
    load_registry_id = load and load.id or nil,
  })
  return M.eventReceiptMatches(receipt, entity, args) and receipt or nil
end

function M.verifyTarget(entity, arguments)
  if not contract.entity(entity) or not codec.isObject(arguments) then
    return false
  end
  if entity:match("^event%.") then
    if arguments.event_control ~= nil then
      return M.eventRegistryTargets(entity, arguments) ~= nil
    end
    for key in pairs(arguments) do
      if key ~= "device" and key ~= "control" then
        return false
      end
    end
    return identity(arguments.device) and gestureContract.identity(arguments.control)
  end
  if arguments.family ~= nil then
    return contract.endpointFamily(arguments.family)
      and families[arguments.family].domain == contract.endpointDomain(entity)
      and GetTableSize(arguments) == 1
  end
  return contract.endpointDomain(entity) ~= nil
    and (next(arguments) == nil or M.registryTargets(entity, arguments) ~= nil)
end

function M.targetAvailable(entity, state, arguments)
  if not contract.state(state, entity) then
    return false
  end
  if entity:match("^event%.") then
    return state.state ~= "unavailable"
      and gestureContract.sourceReady(state.attributes, arguments.device, arguments.control)
  end
  if contract.loadDomain(entity) then
    return state.state == "on" or state.state == "off"
  end
  if arguments.family and not families.eligible(arguments.family, contract.endpointDomain(entity), state.attributes) then
    return false, "unsupported_endpoint"
  end
  return state.state ~= "unavailable" and state.state ~= "unknown"
end

function M.readLoad(entity, arguments)
  return contract.endpointDomain(entity) ~= nil and codec.isObject(arguments) and next(arguments) == nil
end

function M.build(operation, entity, arguments)
  if operation == "indicator" then
    return indicators.command(entity, arguments)
  end
  if not contract.entity(entity) or not codec.isObject(arguments) then
    return nil
  end
  if operation == "prepare" then
    return M.prepare(arguments)
  end
  if operation ~= "service" then
    return nil
  end
  for key in pairs(arguments) do
    if key ~= "action" and key ~= "parameters" then
      return nil
    end
  end
  local domain, action, parameters = contract.endpointDomain(entity), arguments.action, arguments.parameters
  if domain and not contract.loadDomain(entity) then
    if
      type(action) ~= "string"
      or not codec.isObject(parameters)
      or not endpointServices.allowed(domain, action, parameters)
    then
      return nil
    end
    return {
      type = "call_service",
      domain = domain,
      service = action,
      service_data = parameters,
      target = { entity_id = entity },
    }
  end
  if
    not domain
    or not codec.isObject(parameters)
    or (action ~= "turn_on" and action ~= "turn_off" and action ~= "toggle")
  then
    return nil
  end
  for key, value in pairs(parameters) do
    if domain ~= "light" then
      return nil
    end
    if key == "transition" then
      if not range(value, 0, 3600) then
        return nil
      end
    elseif action ~= "turn_on" then
      return nil
    elseif key == "effect" then
      if not effects.valid(value) then
        return nil
      end
    elseif key == "brightness" then
      if not range(value, 0, 255) or value ~= math.floor(value) then
        return nil
      end
    elseif key == "color_temp_kelvin" then
      if not range(value, 1, 100000) or value ~= math.floor(value) then
        return nil
      end
    elseif key == "rgb_color" then
      if not tuple(value, 3, 0, 255) then
        return nil
      end
    elseif key == "xy_color" then
      if not tuple(value, 2, 0, 1) then
        return nil
      end
    elseif key == "hs_color" then
      if not tuple(value, 2, 0, 360) or value[2] > 100 then
        return nil
      end
    else
      return nil
    end
  end
  return {
    type = "call_service",
    domain = domain,
    service = action,
    service_data = parameters,
    target = { entity_id = entity },
  }
end

-- Do not promote a successful but foreign/malformed response to readiness.
-- Resolved load/gesture capabilities get their full family validation in setup.
function M.prepared(result, entity, arguments)
  local response = codec.isObject(result) and result.response
  if codec.isObject(response) and response.version ~= nil and response.version ~= 1 then
    return nil, "unsupported_preparation_version"
  end
  if
    not codec.isObject(response)
    or response.version ~= 1
    or response.device_id ~= arguments.device_id
    or type(response.input_ready) ~= "boolean"
  then
    return nil
  end
  if arguments.source_registry_id then
    local source = response.source_load
    if
      not codec.isObject(source)
      or source.entity_id ~= entity
      or source.registry_id ~= arguments.source_registry_id
    then
      return nil
    end
  end
  if
    response.gesture_entity_id ~= nil
    and (not contract.entity(response.gesture_entity_id) or not response.gesture_entity_id:match("^event%."))
  then
    return nil
  end
  return response
end

-- A fixed diagnostic category for an already validated service RPC. No target
-- identity or parameter values become metric names.
function M.timingName(rpc)
  if rpc.domain == "ha_gesture_bridge" and rpc.service == "set_led" then
    if rpc.service_data.color and rpc.service_data.behavior then
      return "led.follow"
    end
    for _, field in ipairs({ "color", "brightness", "behavior" }) do
      if rpc.service_data[field] ~= nil then
        return "led." .. field
      end
    end
  end
  if
    rpc.type ~= "call_service" or (rpc.domain ~= "light" and rpc.domain ~= "switch" and rpc.domain ~= "input_boolean")
  then
    if rpc.type == "call_service" and rpc.target and contract.endpointDomain(rpc.target.entity_id) == rpc.domain then
      return "request." .. rpc.domain .. "." .. rpc.service
    end
    return nil
  end
  local action = rpc.service == "turn_on" and "on" or rpc.service == "turn_off" and "off" or "toggle"
  if rpc.domain == "light" and action == "on" then
    local params = rpc.service_data or {}
    if params.effect then
      action = "effect"
    elseif params.rgb_color or params.xy_color or params.hs_color then
      action = "color"
    elseif params.color_temp_kelvin then
      action = "cct"
    elseif params.brightness then
      action = "level"
    end
  end
  return "request." .. rpc.domain .. "." .. action
end

return M
