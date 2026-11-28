-- Exact standard-API operations shared by endpoint consumers and the Coordinator.
local M = {}
local function decimal(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function bounded(low, high, integral)
  return function(value)
    return decimal(value) and value >= low and value <= high and (not integral or value % 1 == 0)
  end
end
local function label(value)
  return type(value) == "string" and #value > 0 and #value <= 255 and not value:find("%c")
end
local function code(value)
  return label(value) and #value <= 64
end
local function boolean(value)
  return type(value) == "boolean"
end
local noParameters = {}
local credential = { code = code }
local percentage = bounded(0, 100, true)
local enabled = {
  fan = {
    turn_on = noParameters,
    turn_off = noParameters,
    toggle = noParameters,
    set_percentage = { percentage = percentage },
    oscillate = { oscillating = boolean },
    set_preset_mode = { preset_mode = label },
  },
  cover = {
    open_cover = noParameters,
    close_cover = noParameters,
    stop_cover = noParameters,
    toggle = noParameters,
    open_cover_tilt = noParameters,
    close_cover_tilt = noParameters,
    stop_cover_tilt = noParameters,
    set_cover_position = { position = percentage },
    set_cover_tilt_position = { tilt_position = percentage },
  },
  climate = {
    set_hvac_mode = { hvac_mode = label },
    set_fan_mode = { fan_mode = label },
    set_preset_mode = { preset_mode = label },
    set_humidity = { humidity = bounded(0, 100) },
  },
  lock = { lock = credential, unlock = credential },
  alarm_control_panel = {
    alarm_arm_home = credential,
    alarm_arm_away = credential,
    alarm_arm_night = credential,
    alarm_arm_vacation = credential,
    alarm_arm_custom_bypass = credential,
    alarm_disarm = credential,
  },
  media_player = {
    media_play = noParameters,
    media_pause = noParameters,
    media_stop = noParameters,
    media_next_track = noParameters,
    media_previous_track = noParameters,
    volume_up = noParameters,
    volume_down = noParameters,
    turn_on = noParameters,
    turn_off = noParameters,
    volume_set = { volume_level = bounded(0, 1) },
    volume_mute = { is_volume_muted = boolean },
    select_source = { source = label },
    shuffle_set = { shuffle = boolean },
    repeat_set = {
      ["repeat"] = function(value)
        return value == "off" or value == "one" or value == "all"
      end,
    },
  },
}
local temperature = { temperature = decimal }
local temperatureRange = { target_temp_low = decimal, target_temp_high = decimal }

function M.allowed(domain, action, parameters)
  local actions = enabled[domain]
  local checks = actions and actions[action]
  if domain == "climate" and action == "set_temperature" then
    checks = parameters.temperature ~= nil and temperature or temperatureRange
  end
  if not checks then
    return false
  end
  for field, value in pairs(parameters) do
    if not checks[field] or not checks[field](value) then
      return false
    end
  end
  if checks ~= credential then
    for field in pairs(checks) do
      if parameters[field] == nil then
        return false
      end
    end
  end
  return checks ~= temperatureRange or parameters.target_temp_low <= parameters.target_temp_high
end

function M.registerTimings(operations)
  for domain, actions in pairs(enabled) do
    for action in pairs(actions) do
      operations["request." .. domain .. "." .. action] = true
    end
  end
  operations["request.climate.set_temperature"] = true
end

return M
