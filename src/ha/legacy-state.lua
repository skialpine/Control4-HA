-- Only fields read by the pinned BP Parse functions may cross a legacy wire.
local codec = require("ha.codec")
local M = {}
local fields = {
  alarm_control_panel = { "code_arm_required" },
  cover = { "current_position", "current_tilt_position", "supported_features" },
  fan = { "percentage", "percentage_step" },
  sensor = { "unit_of_measurement" },
  light = {
    "brightness",
    "effect",
    "effect_list",
    "max_color_temp_kelvin",
    "min_color_temp_kelvin",
    "supported_color_modes",
    "xy_color",
  },
  lock = { "available", "lock_battery" },
  media_player = {
    "app_name",
    "entity_picture",
    "media_album_name",
    "media_artist",
    "media_duration",
    "media_position",
    "media_title",
    "repeat",
    "shuffle",
    "volume_level",
  },
  climate = {
    "current_humidity",
    "current_temperature",
    "fan_mode",
    "fan_modes",
    "fan_state",
    "hvac_action",
    "hvac_modes",
    "max_temp",
    "min_temp",
    "preset_mode",
    "preset_modes",
    "target_temp_high",
    "target_temp_low",
    "temperature",
  },
  select = { "options" },
}
local lists = {
  effect_list = true,
  supported_color_modes = true,
  xy_color = true,
  fan_modes = true,
  hvac_modes = true,
  preset_modes = true,
  options = true,
}
local function scalar(value)
  return type(value) == "boolean" or type(value) == "number" or type(value) == "string" and #value <= 4096
end
function M.project(state, models)
  local domain = state.entity_id:match("^([^%.]+)")
  local attrs = codec.object()
  for _, key in ipairs(fields[domain] or {}) do
    local value = state.attributes[key]
    if domain == "cover" and not models["HA Blinds"] then
      break
    end
    if key == "entity_picture" then
      -- The original consumes an HA-relative path. Query strings can carry
      -- signed credentials; never broadcast them or forward external URLs.
      if
        type(value) == "string"
        and #value <= 2048
        and value:match("^/[%w/_.%-]+$")
        and not value:match("^//")
        and not value:find("..", 1, true)
      then
        attrs[key] = value
      end
    elseif lists[key] then
      if codec.isArray(value) and #value <= 512 then
        local clean = codec.array()
        for _, item in ipairs(value) do
          if not scalar(item) then
            clean = nil
            break
          end
          clean[#clean + 1] = item
        end
        attrs[key] = clean
      end
    elseif scalar(value) then
      attrs[key] = value
    end
  end
  local out = { entity_id = state.entity_id, state = state.state, attributes = attrs }
  if
    domain == "sensor"
    and type(state.last_updated) == "string"
    and #state.last_updated <= 40
    and state.last_updated:match("^%d%d%d%d%-%d%d%-%d%dT[%d:.+Z%-]+$")
  then
    out.last_updated = state.last_updated
  end
  return out
end
return M
