-- Exact selection readback for commissioning and migration.
local codec = require("ha.codec")
local contract = require("ha.contract")
local gesture = require("ha.gesture-contract")
local M = {}

function M.identity(config, behavior, mode)
  local load = config and config.controlled_load
  return {
    key = config and config.key or "",
    gesture = config and config.gesture_entity_id,
    control = config and config.control_id,
    device = config and config.device_id,
    load = load and load.entity_id,
    registry = load and load.registry_id,
    behavior = behavior,
    mode = mode,
  }
end

function M.matches(expected, current)
  if not expected or not current then
    return false
  end
  for _, field in ipairs({ "key", "gesture", "control", "device", "load", "registry", "behavior", "mode" }) do
    if expected[field] ~= current[field] then
      return false
    end
  end
  return true
end

function M.encode(owner, params)
  if not owner then
    return
  end
  local value = M.identity(owner.config, Properties["Button behavior"], owner:mode())
  if params and params.VERIFY_SAVED == "true" then
    value.saved = owner:hasSavedSelection()
  end
  local settings = params and params.LIGHT_SETTINGS
  if type(settings) == "string" and #settings <= 2048 then
    local expected = codec.storedObject(settings)
    value.settings_verified = not not (
      expected
      and owner.adapter
      and owner.adapter.verifyMigrationSettings
      and owner.adapter.verifyMigrationSettings(value.key, expected)
    )
  end
  local status = Properties["Driver Status"]
  value.stable = not (owner.working or owner.pending or owner.error)
  value.buttons = not not owner:usesButtons()
  if value.mode == "Buttons only" then
    value.ready = value.stable and owner.inputReady == true and status == "Buttons connected"
  else
    value.ready = value.stable and status == "Device connected" and (not value.buttons or owner.inputReady == true)
  end
  return XMLTag("selection", C4:Base64Encode(codec.encode(codec.object(value))))
end

function M.read(id, settings, verifySaved)
  local ok, value = pcall(function()
    -- The template's traced wrapper includes the request parameters.
    local params =
      { VERIFY_SAVED = verifySaved and "true" or nil, LIGHT_SETTINGS = settings and codec.encode(settings) }
    local body
    if settings then
      body = C4:SendUIRequest(id, "HA_SELECTION_IDENTITY", params)
    else
      body = SendUIRequest(id, "HA_SELECTION_IDENTITY", params)
    end
    local payload = type(body) == "string"
      and #body <= 2048
      and body:match("^<selection>([A-Za-z0-9+/]+=*)</selection>$")
    return payload and codec.storedObject(C4:Base64Decode(payload))
  end)
  if
    ok
    and value
    and type(value.key) == "string"
    and #value.key <= 255
    and type(value.ready) == "boolean"
    and type(value.stable) == "boolean"
    and type(value.buttons) == "boolean"
    and (value.mode == "Buttons only" or value.mode == "Home Assistant device" or value.mode == "Connected Control4 light")
    and (value.load == nil or contract.loadDomain(value.load))
    and (value.gesture == nil or contract.entity(value.gesture))
    and (not value.buttons or value.gesture ~= nil)
    and (value.device == nil or contract.registryId(value.device))
    and (value.control == nil or gesture.identity(value.control))
    and (value.registry == nil or contract.registryId(value.registry))
  then
    return value
  end
end

return M
