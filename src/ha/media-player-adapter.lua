-- Media Service transport and confirmed Now Playing feedback.
require("drivers-common-public.global.lib")
local bit = require("bit")
local contract = require("ha.contract")
local Endpoint = require("ha.endpoint-adapter")
local values = require("lib.values")

local PROXY, ROOM_OUTPUT = 5001, 7000
local features = {
  media_pause = 1,
  volume_set = 4,
  volume_mute = 8,
  media_previous_track = 16,
  media_next_track = 32,
  turn_on = 128,
  turn_off = 256,
  volume_up = 1024,
  volume_down = 1024,
  select_source = 2048,
  media_stop = 4096,
  media_play = 16384,
  shuffle_set = 32768,
  repeat_set = 262144,
}
local labels = {
  playing = "Playing",
  paused = "Paused",
  buffering = "Buffering",
  idle = "Idle",
  on = "On",
  off = "Off",
  standby = "Standby",
}
local dashboardButtons = {
  { "SKIP_REV", "media_previous_track", "SkipRev" },
  { "PLAY", "media_play", "Play" },
  { "PAUSE", "media_pause", "Pause" },
  { "STOP", "media_stop", "Stop" },
  { "SKIP_FWD", "media_next_track", "SkipFwd" },
}
local transport = {
  PULSE_VOL_UP = "volume_up",
  PULSE_VOL_DOWN = "volume_down",
  ON = "turn_on",
}
for _, button in ipairs(dashboardButtons) do
  transport[button[1]] = button[2]
end

local function has(state, action)
  return state and bit.band(state.features, features[action]) ~= 0
end

local function bounded(value, maximum)
  return type(value) == "number" and value >= 0 and value <= maximum and value or nil
end

local function displayText(value)
  if type(value) == "string" and #value <= 256 and not value:find("%c") and not value:find("://", 1, true) then
    return value
  end
  return ""
end

local function decode(state, attrs)
  local label = labels[state]
  if not label then
    return nil
  end
  local availableFeatures = contract.integer(attrs.supported_features) and attrs.supported_features or 0
  local active = state == "playing" or state == "paused" or state == "buffering" or state == "on"
  local selectedVolume = bounded(attrs.volume_level, 1)
  local muted, shuffle
  if type(attrs.is_volume_muted) == "boolean" then
    muted = attrs.is_volume_muted
  end
  if type(attrs.shuffle) == "boolean" then
    shuffle = attrs.shuffle
  end
  local sources = {}
  if bit.band(availableFeatures, features.select_source) ~= 0 and type(attrs.source_list) == "table" then
    for i = 1, math.min(#attrs.source_list, 64) do
      local source = displayText(attrs.source_list[i])
      if source ~= "" then
        sources[source] = true
      end
    end
  end
  return {
    label = label,
    state = state,
    features = availableFeatures,
    title = active and displayText(attrs.media_title) or "",
    artist = active and displayText(attrs.media_artist) or "",
    album = active and displayText(attrs.media_album_name) or "",
    app = active and displayText(attrs.app_name) or "",
    duration = active and bounded(attrs.media_duration, 864000) or nil,
    position = active and bounded(attrs.media_position, 864000) or nil,
    volume = selectedVolume and math.floor(selectedVolume * 100 + 0.5) or nil,
    muted = muted,
    shuffle = shuffle,
    repeatMode = attrs["repeat"] == "all" and "all" or attrs["repeat"] == "one" and "one" or "off",
    source = displayText(attrs.source),
    sources = sources,
  }
end

local function same(current, previous)
  for key, value in pairs(current) do
    if key ~= "sources" and previous[key] ~= value then
      return false
    end
  end
  for key in pairs(previous) do
    if current[key] == nil then
      return false
    end
  end
  for source in pairs(current.sources) do
    if not previous.sources[source] then
      return false
    end
  end
  for source in pairs(previous.sources) do
    if not current.sources[source] then
      return false
    end
  end
  return true
end

local function sendEvent(name, args, params)
  C4:SendToProxy(PROXY, "SEND_EVENT", {
    NAME = name,
    EVTARGS = args,
    NAVID = params and params.NAVID or nil,
    ROOMS = params and params.ROOMID or nil,
  }, "COMMAND")
end

local function dashboard(state, params)
  local labels = {}
  for _, button in ipairs(dashboardButtons) do
    local key, action, label = unpack(button)
    if
      has(state, action)
      and (key ~= "PLAY" or state.state ~= "playing")
      and (key ~= "PAUSE" or state.state == "playing" or state.state == "buffering")
    then
      labels[#labels + 1] = label
    end
  end
  sendEvent("DashboardChanged", XMLTag("Items", table.concat(labels, " ")), params)
end

local function queue(state, params)
  local repeatMode = state and state.repeatMode
  local repeatSupported = has(state, "repeat_set") == true
  sendEvent(
    "QueueChanged",
    XMLTag("NowPlaying", {
      can_shuffle = has(state, "shuffle_set") == true and state.shuffle ~= nil,
      can_repeat = repeatSupported,
      can_repeat_one = repeatSupported,
      shufflemode = state and state.shuffle == true or false,
      repeatmode = repeatMode == "all",
      repeatonemode = repeatMode == "one",
    }),
    params
  )
end

local function timeLabel(seconds)
  seconds = math.floor(seconds)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function progress(state, params)
  local duration = state and state.duration or 0
  local position = state and math.min(state.position or 0, duration) or 0
  sendEvent(
    "ProgressChanged",
    XMLTag({
      length = duration,
      offset = position,
      label = duration > 0 and (timeLabel(position) .. " / -" .. timeLabel(duration - position)) or "",
    }),
    params
  )
end

local function publish(current, previous)
  local state = current or {}
  values:update("MEDIA_TITLE", state.title or "", "STRING")
  values:update("MEDIA_ARTIST", state.artist or "", "STRING")
  values:update("MEDIA_ALBUM", state.album or "", "STRING")
  values:update("MEDIA_APP_NAME", state.app or "", "STRING")
  values:update("Media source", state.source or "", "STRING")
  C4:SendToProxy(PROXY, "UPDATE_MEDIA_INFO", {
    STATE = state.state or "offline",
    TITLE = state.title ~= "" and state.title or state.app or "",
    ARTIST = state.artist or "",
    ALBUM = state.album or "",
    IMAGEURL = "",
  }, "COMMAND", true)
  for name, action in pairs({
    has_discrete_volume_control = "volume_set",
    has_up_down_volume_control = "volume_up",
    has_discrete_mute_control = "volume_mute",
    has_toggle_mute_control = "volume_mute",
  }) do
    local enabled = has(current, action) == true
    if not previous or enabled ~= (has(previous, action) == true) then
      C4:SendToProxy(ROOM_OUTPUT, "CAPABILITIES_CHANGED", { NAME = name, VALUE = enabled }, "NOTIFY")
    end
  end
  if state.volume ~= nil and (not previous or previous.volume ~= state.volume) then
    C4:SendToProxy(PROXY, "VOLUME_LEVEL_CHANGED", { LEVEL = state.volume, OUTPUT = ROOM_OUTPUT }, "NOTIFY")
  end
  if state.muted ~= nil and (not previous or previous.muted ~= state.muted) then
    C4:SendToProxy(PROXY, "MUTE_CHANGED", { MUTE = state.muted, OUTPUT = ROOM_OUTPUT }, "NOTIFY")
  end
  dashboard(current)
  progress(current)
  queue(current)
end

local function install(owner)
  local function send(state, action, params)
    return has(state, action) and owner:command(action, params or {}) or false
  end
  local function proxy(_, command, params)
    local state = owner:confirmed()
    if command == "GetDashboard" or command == "GetQueue" then
      if command == "GetQueue" then
        queue(state, params)
      end
      dashboard(state, params)
      progress(state, params)
    elseif command == "DEVICE_SELECTED" then
      if state and (state.state == "off" or state.state == "standby") then
        send(state, "turn_on")
      end
      dashboard(state, params)
      progress(state, params)
    elseif command == "DEVICE_DESELECTED" or command == "OFF" then
      return send(state, has(state, "media_stop") and "media_stop" or "turn_off")
    elseif transport[command] then
      return send(state, transport[command])
    elseif command == "GET_VOLUME_LEVEL" then
      return state and state.volume
    elseif command == "GET_HAS_DISCRETE_VOLUME" then
      return has(state, "volume_set") == true
    elseif command == "SET_VOLUME_LEVEL" then
      local level = bounded(tonumber(params.LEVEL), 100)
      return level ~= nil and send(state, "volume_set", { volume_level = level / 100 })
    elseif command == "MUTE_ON" or command == "MUTE_OFF" then
      return send(state, "volume_mute", { is_volume_muted = command == "MUTE_ON" })
    elseif command == "MUTE" or command == "MUTE_TOGGLE" then
      return state ~= nil and state.muted ~= nil and send(state, "volume_mute", { is_volume_muted = not state.muted })
    elseif command == "ToggleShuffle" then
      return state ~= nil and state.shuffle ~= nil and send(state, "shuffle_set", { shuffle = not state.shuffle })
    elseif command == "ToggleRepeat" or command == "ToggleRepeatOne" then
      local mode = command == "ToggleRepeat" and "all" or "one"
      return state ~= nil and send(state, "repeat_set", { ["repeat"] = state.repeatMode == mode and "off" or mode })
    elseif command == "SELECT_SOURCE" then
      local source = params.Source
      return state ~= nil and state.sources[source] == true and send(state, "select_source", { source = source })
    end
  end
  owner:handle(RFP, PROXY, proxy)
  owner:handle(RFP, ROOM_OUTPUT, function(binding, command, params)
    if
      command == "SET_VOLUME_LEVEL"
      or command == "GET_VOLUME_LEVEL"
      or command == "GET_HAS_DISCRETE_VOLUME"
      or command == "MUTE_ON"
      or command == "MUTE_OFF"
      or command == "MUTE"
      or command == "MUTE_TOGGLE"
      or command == "PULSE_VOL_UP"
      or command == "PULSE_VOL_DOWN"
    then
      return proxy(binding, command, params)
    end
  end)
  owner:handle(EC, "Select_Source", function(params)
    return proxy(PROXY, "SELECT_SOURCE", params)
  end)
end

return {
  new = function()
    return Endpoint.new({
      family = "media_player",
      supports = function(entity)
        return contract.endpointDomain(entity) == "media_player"
      end,
      decode = decode,
      same = same,
      publish = publish,
      install = install,
    })
  end,
}
