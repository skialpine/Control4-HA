-- Restore the completed DeviceSelection written by the prototype's
-- device_activation module. A displayed entity or a choice without a matching
-- preparation result cannot stand in for the saved physical selection.
local codec = require("ha.codec")
local contract = require("ha.contract")
local gesture = require("ha.gesture-contract")
local selection = require("ha.selection")
local M = {}

local modes = {
  ["Control HA Device"] = "direct",
  Direct = "direct",
  ["Control HA Device with Button Events"] = "bridge",
  ["Gesture Bridge"] = "bridge",
  ["Programming Events Only"] = "buttons",
  ["Gestures Only"] = "buttons",
  ["Control Connected C4 Light"] = "connected",
  ["C4 Button Controller"] = "connected",
}
function M.mode(label)
  return modes[label]
end

local registry = contract.registryId

local function load(value, requireRegistry)
  if
    type(value) ~= "table"
    or not contract.loadDomain(value.entity_id)
    or value.domain ~= contract.loadDomain(value.entity_id)
    or type(value.available) ~= "boolean"
    or ((requireRegistry or value.registry_id ~= nil) and not registry(value.registry_id))
  then
    return nil
  end
  return codec.object({
    entity_id = value.entity_id,
    registry_id = value.registry_id,
    domain = value.domain,
    available = value.available,
  })
end

function M.restore(saved, property, primary, override)
  local mode = modes[property]
  local choice = type(saved) == "table" and saved.choice
  local result = type(saved) == "table" and saved.result
  if
    not mode
    or type(choice) ~= "table"
    or type(result) ~= "table"
    or choice.type ~= "device_choice"
    or choice.version ~= 1
    or result.version ~= 1
    or not registry(choice.device_id)
    or result.device_id ~= choice.device_id
    or type(choice.name) ~= "string"
    or not choice.name:match("%S")
    or #choice.name > 1024
    or choice.name:find("%c")
    or type(result.input_ready) ~= "boolean"
    or (choice.kind ~= "switch" and choice.kind ~= "dimmer" and choice.kind ~= "remote")
  then
    return nil
  end
  local source = load(choice.source_load, true)
  local preparedSource = load(result.source_load, true)
  if
    (choice.source_load ~= nil or result.source_load ~= nil)
    and (
      not source
      or not preparedSource
      or source.entity_id ~= preparedSource.entity_id
      or source.registry_id ~= preparedSource.registry_id
    )
  then
    return nil
  end
  local loadTarget = load(result.controlled_load)
  local origin, event, control = result.controlled_load_origin, result.gesture_entity_id, result.control_id
  if
    (result.controlled_load ~= nil and not loadTarget)
    or ((loadTarget ~= nil) ~= (origin ~= nil))
    or (origin == "selected_endpoint" and (not source or source.entity_id ~= loadTarget.entity_id or source.registry_id ~= loadTarget.registry_id))
    or ((event ~= nil) ~= (control ~= nil))
    or (event and (not contract.entity(event) or not event:match("^event%.") or not gesture.identity(control)))
    or (choice.gesture_entity_id ~= nil and choice.gesture_entity_id ~= event)
    or (override ~= nil and type(override) ~= "boolean")
  then
    return nil
  end
  local expected = loadTarget and loadTarget.entity_id
  if mode ~= "direct" and event then
    expected = event
  end
  if not expected or expected ~= primary then
    return nil
  end
  local config = codec.object({
    version = 1,
    family = "light",
    key = choice.choice_id,
    name = choice.name,
    device_id = choice.device_id,
    preparation = "prepared",
    input_ready = result.input_ready,
    source_load = source,
    controlled_load = loadTarget,
    controlled_load_origin = origin,
    gesture_entity_id = event,
    control_id = control,
    prototype_picker = true,
    prototype_mode = mode,
    prototype_mode_override = override == true,
  })
  if selection.valid(config, { family = "light", choice_id = choice.choice_id }) then
    return config
  end
end

-- Only read the exact registry entries that establish the saved target and
-- original source. An unresolved explicit link has no authority over a relay.
function M.proof(config)
  local target = config.controlled_load
  if not target or not registry(target.registry_id) then
    return nil
  end
  local args = codec.object({ registry_id = target.registry_id })
  if config.source_load then
    args.source_entity = config.source_load.entity_id
    args.source_registry_id = config.source_load.registry_id
    args.source_device = config.device_id
  end
  return args
end

return M
