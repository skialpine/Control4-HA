-- Explicit selection resolution. Browsing never calls this module's preparation
-- path. The selected catalog record, not caller-supplied HA targets, owns it.
local codec = require("ha.codec")
local contract = require("ha.contract")
local operations = require("ha.operations")
local deferred = require("deferred")
local eventSelection = require("ha.event-selection")
local families = require("ha.endpoint-families")
local choices = require("ha.choices")
local M = {}

function M.directLoad(family, entity, name)
  local native = contract.endpointFamily(family)
  local domain = native and contract.endpointDomain(entity) or contract.loadDomain(entity)
  if not domain or (native and families[family].domain ~= domain) then
    return nil
  end
  return codec.object({
    version = 1,
    family = family,
    key = entity,
    name = name or "",
    input_ready = false,
    preparation = "not_required",
    controlled_load_origin = "selected_endpoint",
    controlled_load = codec.object({ entity_id = entity, domain = domain }),
  })
end

function M.query(value)
  if not codec.isObject(value) then
    return false
  end
  for key in pairs(value) do
    if key ~= "choice_id" and key ~= "revision" and key ~= "family" and key ~= "prepare" then
      return false
    end
  end
  return type(value.choice_id) == "string"
    and #value.choice_id > 0
    and #value.choice_id <= 255
    and not value.choice_id:find("%c")
    and contract.family(value.family)
    and type(value.prepare) == "boolean"
    and value.revision ~= nil
    and contract.catalogQuery(codec.object({ revision = value.revision, family = value.family }))
end
local function load(value)
  return codec.isObject(value)
    and type(value.domain) == "string"
    and value.domain == contract.endpointDomain(value.entity_id)
    and (value.available == nil or type(value.available) == "boolean")
end
function M.valid(value, arguments)
  if
    not codec.isObject(value)
    or value.version ~= 1
    or value.key ~= arguments.choice_id
    or value.family ~= arguments.family
    or type(value.name) ~= "string"
    or #value.name > 4096
    or type(value.input_ready) ~= "boolean"
  then
    return false
  end
  if contract.endpointFamily(value.family) then
    local target = value.controlled_load
    return value.preparation == "not_required"
      and value.input_ready == false
      and not (value.device_id or value.control_id or value.source_load or value.gesture_entity_id or value.manual_event or value.prototype_picker or value.prototype_mode)
      and load(target)
      and target.domain == families[value.family].domain
      and target.entity_id == value.key
      and (target.registry_id == nil or contract.registryId(target.registry_id))
      and value.controlled_load_origin == "selected_endpoint"
  end
  if
    value.prototype_picker ~= nil
    and (value.prototype_picker ~= true or value.family ~= "light" or value.preparation ~= "prepared")
  then
    return false
  end
  if
    value.prototype_mode ~= nil
    and (
      value.family ~= "light"
      or not ({ direct = true, bridge = true, buttons = true, connected = true })[value.prototype_mode]
      or type(value.prototype_mode_override) ~= "boolean"
    )
  then
    return false
  end
  if
    value.controlled_load ~= nil
    and (not load(value.controlled_load) or not contract.loadDomain(value.controlled_load.entity_id))
  then
    return false
  end
  if
    value.source_load ~= nil and (not load(value.source_load) or not contract.loadDomain(value.source_load.entity_id))
  then
    return false
  end
  if
    value.gesture_entity_id ~= nil
    and (not contract.entity(value.gesture_entity_id) or not value.gesture_entity_id:match("^event%."))
  then
    return false
  end
  if
    value.controlled_load
    and value.controlled_load_origin ~= "explicit_link"
    and value.controlled_load_origin ~= "selected_endpoint"
  then
    return false
  end
  if
    value.control_id ~= nil
    and (type(value.control_id) ~= "string" or #value.control_id == 0 or #value.control_id > 255)
  then
    return false
  end
  if value.input_ready and not value.gesture_entity_id then
    return false
  end
  if
    value.controlled_load
    and value.controlled_load_origin == "selected_endpoint"
    and value.source_load
    and value.controlled_load.entity_id ~= value.source_load.entity_id
  then
    return false
  end
  if value.manual_event ~= nil then
    return eventSelection.valid(value)
  end
  if value.preparation == "not_required" then
    return not value.device_id
      and not value.source_load
      and not value.control_id
      and (
        (
          value.controlled_load
          and value.controlled_load.entity_id == value.key
          and value.controlled_load_origin == "selected_endpoint"
          and not value.gesture_entity_id
        ) or (value.gesture_entity_id == value.key and not value.controlled_load)
      )
  end
  if type(value.device_id) ~= "string" or #value.device_id ~= 32 or not value.device_id:match("^[a-f0-9]+$") then
    return false
  end
  local endpoint = value.source_load and value.source_load.registry_id or "none"
  if value.source_load and (type(endpoint) ~= "string" or #endpoint ~= 32 or not endpoint:match("^[a-f0-9]+$")) then
    return false
  end
  if value.key ~= "device:" .. value.device_id .. ":" .. endpoint then
    return false
  end
  if value.preparation == "required" then
    return not value.controlled_load and not value.gesture_entity_id
  end
  return value.preparation == "prepared"
    and not (value.controlled_load_origin == "selected_endpoint" and not value.source_load)
end
function M.resolve(catalog, request, arguments, active)
  local result = deferred.new()
  local function fail(kind)
    result:reject({ kind = kind })
  end
  if not M.query(arguments) then
    fail("invalid_request")
    return result
  end
  if not active() then
    fail("retired")
    return result
  end
  local row, failure = catalog:choice(arguments.choice_id, arguments.family, arguments.revision)
  if not row then
    fail(failure or "unsupported_endpoint")
    return result
  end
  local config = codec.object({
    version = 1,
    key = row.entity_id,
    name = row.name,
    family = arguments.family,
    preparation = "not_required",
    input_ready = false,
  })
  local choice = row.attributes.device_choice
  if not choice then
    if row.domain == "event" then
      config.gesture_entity_id = row.entity_id
    else
      config.controlled_load =
        codec.object({ entity_id = row.entity_id, domain = row.domain, available = row.available })
      if contract.endpointFamily(arguments.family) then
        config.controlled_load.registry_id = choices.standaloneRegistry(row) or nil
      end
      config.controlled_load_origin = "selected_endpoint"
    end
    result:resolve(config)
    return result
  end
  config.device_id = choice.device_id
  config.source_load = choice.source_load
  config.preparation = "required"
  if not arguments.prepare then
    result:resolve(config)
    return result
  end
  if not active() then
    fail("retired")
    return result
  end
  local params = codec.object({
    device_id = choice.device_id,
    source_registry_id = choice.source_load and choice.source_load.registry_id or nil,
  })
  local rpc = operations.prepare(params)
  if not rpc then
    fail("invalid_request")
    return result
  end
  local sent = pcall(request, rpc, function(ok, response)
    if not active() then
      fail("retired")
      return
    end
    local current, failure = catalog:choice(arguments.choice_id, arguments.family, arguments.revision)
    if not current then
      fail(failure or "unsupported_endpoint")
      return
    end
    if not ok then
      fail(response.kind or "rejected")
      return
    end
    local prepared, invalid =
      operations.prepared(response, choice.source_load and choice.source_load.entity_id or nil, params)
    if not prepared then
      fail(invalid or "invalid_response")
      return
    end
    config.preparation = "prepared"
    config.control_id = prepared.control_id
    config.input_ready = prepared.input_ready
    config.controlled_load = prepared.controlled_load
    config.controlled_load_origin = prepared.controlled_load_origin
    config.gesture_entity_id = prepared.gesture_entity_id
    if not M.valid(codec.decode(codec.encode(config)), arguments) then
      fail("invalid_response")
      return
    end
    result:resolve(config)
  end, nil, 30000)
  if not sent then
    fail("disconnected")
  end
  return result
end
return M
