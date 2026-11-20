-- Original BP service envelopes, as emitted by the eleven pinned consumers.
local codec = require("ha.codec")
local operations = require("ha.operations")
local M = {}
local empty = {}
local services = {
  alarm_control_panel = {
    alarm_arm_home = { code = true },
    alarm_arm_away = { code = true },
    alarm_arm_night = { code = true },
    alarm_arm_vacation = { code = true },
    alarm_arm_custom_bypass = { code = true },
    alarm_disarm = { code = true },
  },
  light = { turn_on = { brightness = true, effect = true, xy_color = true }, turn_off = empty },
  switch = { turn_on = empty, turn_off = empty },
  lock = { lock = { code = true }, unlock = { code = true } },
  cover = {
    open_cover = empty,
    close_cover = empty,
    stop_cover = empty,
    open_cover_tilt = empty,
    close_cover_tilt = empty,
    stop_cover_tilt = empty,
    set_cover_position = { position = true },
    set_cover_tilt_position = { position = true },
  },
  fan = {
    turn_on = { percentage = true },
    turn_off = empty,
    increase_speed = empty,
    decrease_speed = empty,
    set_percentage = { percentage = true },
  },
  media_player = {
    turn_on = empty,
    turn_off = empty,
    media_play = empty,
    media_pause = empty,
    media_stop = empty,
    media_next_track = empty,
    media_previous_track = empty,
    repeat_set = { ["repeat"] = true },
    shuffle_set = { shuffle = true },
    volume_set = { volume_level = true },
  },
  climate = {
    set_hvac_mode = { hvac_mode = true },
    set_fan_mode = { fan_mode = true },
    set_preset_mode = { preset_mode = true },
    set_temperature = { temperature = true, target_temp_high = true, target_temp_low = true },
  },
  button = { press = empty },
  select = { select_option = { option = true } },
}
services.input_boolean = services.switch

local families = {
  ["HA Alarm Panel"] = { "102", "alarm_control_panel" },
  ["HA Binary Sensor"] = { "102", "binary_sensor" },
  ["HA Blinds"] = { "102", "cover" },
  ["HA Fan"] = { "104", "fan" },
  ["HA Garage Door"] = { "101", "cover" },
  ["HA Generic Sensor"] = { "110", "sensor" },
  ["HA Light"] = { "106", "light" },
  ["HA Lock"] = { "102", "lock" },
  ["HA Media Player"] = { "102", "media_player" },
  ["HA Switch"] = { "106", "switch" },
  ["HA Thermostat"] = { "108", "climate" },
}

function M.family(file, model, manufacturer, version)
  local spec = families[model]
  if not spec or manufacturer ~= "BP" or tostring(version) ~= spec[1] then
    return nil
  end
  if file == model:gsub(" ", ".") .. ".c4z" or (model == "HA Fan" and file == "HA.Fan.9-speed.c4z") then
    return model
  end
end

local function domainOf(entity)
  return type(entity) == "string" and #entity <= 255 and entity:match("^([a-z][a-z0-9_]*)%.[a-z0-9_]+$")
end

function M.selected(model, entity)
  local domain = domainOf(entity)
  return families[model] and (families[model][2] == domain or (model == "HA Switch" and domain == "input_boolean"))
end

-- A trusted original can only target its own primary or enabled auxiliary
-- selection. The shared wire establishes project target scope, not sender ID.
function M.property(model, domain, service)
  if model == "HA Thermostat" then
    if domain == "select" then
      return "Mode Selection Entity ID"
    end
    if domain == "button" then
      return "Clear Hold Entity ID"
    end
  end
  if model == "HA Garage Door" and service ~= "open_cover" and service ~= "close_cover" then
    return nil
  end
  if families[model][2] == domain or (model == "HA Switch" and domain == "input_boolean") then
    return "Entity ID"
  end
end

local function originalRequest(raw)
  local fields = services[raw.domain] and services[raw.domain][raw.service]
  if not fields then
    return nil
  end
  for field, value in pairs(raw.service_data) do
    if not fields[field] then
      return nil
    end
    if field == "xy_color" then
      if not codec.isArray(value) or #value ~= 2 or not tonumber(value[1]) or not tonumber(value[2]) then
        return nil
      end
    elseif type(value) ~= "number" and type(value) ~= "string" and type(value) ~= "boolean" then
      return nil
    end
  end
  raw.type = "call_service"
  return raw
end

function M.request(params)
  if type(params) ~= "table" or type(params.JSON) ~= "string" or GetTableSize(params) ~= 1 then
    return nil
  end
  local ok, raw = pcall(codec.decode, params.JSON)
  if not ok or not codec.isObject(raw) or not codec.isObject(raw.target) or not codec.isObject(raw.service_data) then
    return nil
  end
  if GetTableSize(raw) ~= 4 or GetTableSize(raw.target) ~= 1 or domainOf(raw.target.entity_id) ~= raw.domain then
    return nil
  end
  local prototype = operations.build(
    "service",
    raw.target.entity_id,
    codec.object({
      action = raw.service,
      parameters = raw.service_data,
    })
  )
  return originalRequest(raw), prototype
end

return M
