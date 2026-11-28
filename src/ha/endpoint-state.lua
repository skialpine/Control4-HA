-- Security and media state crosses the consumer wire with an explicit projection.
local codec = require("ha.codec")
local M = {}
local fields = {
  lock = { "lock_battery", "code_format" },
  alarm_control_panel = { "supported_features", "code_format", "code_arm_required" },
  media_player = {
    "supported_features",
    "media_title",
    "media_artist",
    "media_album_name",
    "app_name",
    "media_duration",
    "media_position",
    "volume_level",
    "is_volume_muted",
    "shuffle",
    "repeat",
    "source",
  },
}
local nativeStates = {
  lock = {
    locked = true,
    unlocked = true,
    locking = true,
    unlocking = true,
    jammed = true,
    open = true,
    opening = true,
  },
  alarm_control_panel = {
    disarmed = true,
    armed_home = true,
    armed_away = true,
    armed_night = true,
    armed_vacation = true,
    armed_custom_bypass = true,
    pending = true,
    arming = true,
    disarming = true,
    triggered = true,
  },
  media_player = { on = true, off = true, idle = true, playing = true, paused = true, buffering = true, standby = true },
}
local function safeText(value)
  return type(value) == "string"
      and #value <= 255
      and not value:find("%c")
      and not value:find("://", 1, true)
      and not value:find("%?[^%s%?=]+=")
      and not value:match("^/")
      and value
    or nil
end
local function scalar(value)
  if type(value) == "boolean" or type(value) == "number" then
    return value
  end
  return safeText(value)
end
function M.project(state, domain)
  local names = fields[domain]
  if not names then
    return state
  end
  local source = state.attributes
  local projected = codec.object({ friendly_name = safeText(source.friendly_name) })
  for _, field in ipairs(names) do
    local value = source[field]
    if field == "code_format" then
      if domain == "lock" then
        projected[field] = type(value) == "string" and #value > 0 or nil
      else
        projected[field] = (value == "number" or value == "text") and value or nil
      end
    else
      projected[field] = scalar(value)
    end
  end
  if domain == "media_player" and codec.isArray(source.source_list) and #source.source_list <= 100 then
    local choices = codec.array({})
    for _, item in ipairs(source.source_list) do
      local name = safeText(item)
      if name then
        choices[#choices + 1] = name
      end
    end
    projected.source_list = choices
  end
  local label = (nativeStates[domain][state.state] or state.state == "unavailable") and state.state or "unknown"
  return codec.object({ entity_id = state.entity_id, state = label, attributes = projected })
end
return M
