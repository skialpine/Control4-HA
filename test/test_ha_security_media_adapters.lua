local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
local operations = require("ha.operations")
local projection = require("ha.endpoint-state")
local values = require("lib.values")
require("drivers-common-public.global.handlers")

local notes, requests, results, events = {}, {}, {}, {}
function C4:SendToProxy(binding, command, params)
  notes[#notes + 1] = { binding = binding, command = command, params = params }
end
function C4:FireEventByID(id)
  events[#events + 1] = id
end

local function notification(command)
  for i = #notes, 1, -1 do
    if notes[i].command == command then
      return notes[i].params
    end
  end
  return {}
end

local function navigatorEvent(name)
  for i = #notes, 1, -1 do
    local note = notes[i]
    if note.command == "SEND_EVENT" and note.params.NAME == name then
      return note.params
    end
  end
  return {}
end

local function bind(owner, target)
  local consumer = { readiness = {} }
  function consumer:_current()
    return true
  end
  function consumer.readiness:view(entity)
    return { evidence_ready = entity == target }
  end
  function consumer:request(operation, entity, args)
    local promise = deferred.new()
    requests[#requests + 1] = {
      rpc = assert(operations.build(operation, entity, args)),
      promise = promise,
    }
    return promise
  end
  owner:bind(consumer, target, function(status)
    results[#results + 1] = status
  end)
end

local function state(owner, kind, entity, label, attributes)
  local domain = entity:match("^[^.]+")
  owner:message(
    kind,
    projection.project(
      codec.object({
        entity_id = entity,
        state = label,
        attributes = codec.object(attributes or {}),
      }),
      domain
    )
  )
end

T.section("Native Lock uses only the selected endpoint and reports confirmed feedback")
local lock = require("ha.lock-adapter").new()
lock:start()
bind(lock, "lock.fixture")
T.eq("no lock request before feedback", ReceivedFromProxy(5001, "LOCK"), false)
state(lock, "snapshot", "lock.foreign", "locked")
T.eq("foreign lock does not update native state", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "unknown")
state(lock, "snapshot", "lock.fixture", "unlocked", { lock_battery = 0 })
T.eq("unlocked", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "unlocked")
T.eq("zero battery is a reported critical state", notification("BATTERY_STATUS_CHANGED").BATTERY_STATUS, "critical")
T.eq("native toggle transitions from confirmed unlocked", ReceivedFromProxy(5001, "TOGGLE"), true)
T.eq(
  "exact target and service",
  { requests[1].rpc.target.entity_id, requests[1].rpc.service },
  { "lock.fixture", "lock" }
)
requests[1].promise:resolve({})
T.eq("acceptance does not publish locked state", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "unlocked")
state(lock, "state", "lock.fixture", "locking")
T.eq(
  "transition maps to native unknown and explicit label",
  notification("LOCK_STATUS_CHANGED").LAST_ACTION_DESCRIPTION,
  "Locking"
)
state(lock, "state", "lock.fixture", "jammed")
T.eq("jam is a native fault", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "fault")
T.eq("jam condition true", TestCondition("IS_JAMMED"), true)
state(lock, "state", "lock.fixture", "jammed")
T.eq("one jam event for one transition", events, { 1000 })
state(lock, "state", "lock.fixture", "unavailable")
T.eq("unavailable clears jam confirmation", TestCondition("IS_JAMMED"), false)
T.eq("no inferred access action from stale state", ReceivedFromProxy(5001, "UNLOCK"), false)
state(lock, "snapshot", "lock.fixture", "locked", { code_format = "^[0-9]{4}$" })
T.eq("native unlock delegates default code to Home Assistant", ReceivedFromProxy(5001, "UNLOCK"), true)
T.eq("no code copied to the driver", requests[2].rpc.service_data, {})
requests[2].promise:reject({ kind = "rejected" })
T.eq(
  "lock advises where to verify code settings",
  values:getValue("Last Command Result").value,
  "Check the lock and its default code in Home Assistant."
)
state(lock, "state", "lock.fixture", "opening", { lock_battery = 50 })
T.eq("opening remains unknown to the native Lock", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "unknown")
T.eq("50 percent is a battery warning", notification("BATTERY_STATUS_CHANGED").BATTERY_STATUS, "warning")
state(lock, "state", "lock.fixture", "open", { lock_battery = 51 })
T.eq("open maps to a native unlocked Lock", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "unlocked")
T.eq("51 percent is a normal battery", notification("BATTERY_STATUS_CHANGED").BATTERY_STATUS, "normal")
T.eq("explicit Lock accepts the open endpoint", ReceivedFromProxy(5001, "LOCK"), true)
T.eq("explicit Lock has one selected target", requests[3].rpc.target, { entity_id = "lock.fixture" })
state(lock, "state", "lock.fixture", "locked", { lock_battery = -1 })
T.eq("confirmed lock feedback reaches the native Lock", notification("LOCK_STATUS_CHANGED").LOCK_STATUS, "locked")
T.eq("invalid battery level is ignored", notification("BATTERY_STATUS_CHANGED").BATTERY_STATUS, "normal")
lock:message("readiness", { entity_id = "lock.fixture", transport = false })
requests[3].promise:reject({ kind = "timeout" })
T.eq("connection loss retires pending lock outcomes", results, { "accepted", "rejected" })
T.eq("connection loss marks the lock unavailable", values:getValue("Available").value, false)
T.eq("lock commands pause until fresh feedback", ReceivedFromProxy(5001, "LOCK"), false)
state(lock, "snapshot", "lock.fixture", "jammed")
T.eq("recovering into an existing jam does not fire another event", events, { 1000 })
lock:destroy()
T.eq("destroy removes native lock control", ReceivedFromProxy(5001, "LOCK"), nil)

T.section("A superseded security reply cannot replace the current result")
notes, requests, results = {}, {}, {}
lock = require("ha.lock-adapter").new()
lock:start()
bind(lock, "lock.fixture")
state(lock, "snapshot", "lock.fixture", "unlocked", { code_format = "^[0-9]{4}$" })
values:update("Last Command Result", "", "STRING")
T.truthy("an older lock command can be followed by unlock", ReceivedFromProxy(5001, "LOCK"))
T.truthy("unlock sends immediately on a known target", ReceivedFromProxy(5001, "UNLOCK"))
requests[2].promise:resolve({})
requests[1].promise:reject({ kind = "rejected" })
T.eq("newer acceptance remains current", results, { "accepted" })
T.falsy(
  "an older rejection does not show a default-code warning",
  tostring(values:getValue("Last Command Result").value):find("default code", 1, true)
)
lock:destroy()

T.section("Alarm guards credentials, exact target, and stale outcomes")
notes, requests, results = {}, {}, {}
local alarm = require("ha.alarm-adapter").new()
alarm:start()
bind(alarm, "alarm_control_panel.fixture")
local policy = { supported_features = 3, code_format = "number", code_arm_required = true }
state(alarm, "snapshot", "alarm_control_panel.fixture", "disarmed", policy)
T.eq("initial snapshot is state initialization", notification("PARTITION_STATE_INIT").STATE, "DISARMED_READY")
T.eq("supported modes reported", values:getValue("Supported arm modes").value, "Home, Away")
T.eq("native code prompt", notification("CODE_REQUIRED").CODE_REQUIRED_TO_ARM, true)
T.eq(
  "unsupported native mode",
  ReceivedFromProxy(5002, "PARTITION_ARM", { ArmType = "Night", UserCode = "7913" }),
  false
)
T.eq("no request for invalid partition", ReceivedFromProxy(5001, "PARTITION_ARM", { ArmType = "Home" }), nil)
T.eq("required code unavailable", ReceivedFromProxy(5002, "PARTITION_ARM", { ArmType = "Home" }), false)
T.eq("native missing-code prompt", notification("ARM_FAILED").ACTION, "keypad")
T.eq("malformed code", ReceivedFromProxy(5002, "PARTITION_ARM", { ArmType = "Home", UserCode = "bad-input" }), false)
T.eq("only explicit valid action may send", #requests, 0)
DEBUGPRINT = true
local captured, captureError, logs = T.capture(function()
  T.eq(
    "code submitted via native prompt",
    ReceivedFromProxy(5002, "PARTITION_ARM", {
      ArmType = "Away",
      UserCode = "07913",
      InterfaceID = "fixture-interface",
    }),
    true
  )
  T.eq(
    "the panel binding cannot arm a partition",
    ReceivedFromProxy(5001, "PARTITION_ARM", { ArmType = "Home", UserCode = "913079" }),
    nil
  )
  T.eq(
    "the panel binding cannot disarm a partition",
    ReceivedFromProxy(5001, "PARTITION_DISARM", { UserCode = "913079" }),
    nil
  )
end)
DEBUGPRINT = false
T.check("debug capture completed", captured, captureError)
T.eq("synthetic code is absent from debug logs", logs:find("07913", 1, true), nil)
T.eq("the wrongly routed synthetic code is absent from debug logs", logs:find("913079", 1, true), nil)
T.eq("only the valid partition command dispatches", #requests, 1)
local arm = requests[1]
T.eq("code stays unchanged in service data", arm.rpc.service_data, { code = "07913" })
T.eq(
  "target and mode match",
  { arm.rpc.target.entity_id, arm.rpc.service },
  { "alarm_control_panel.fixture", "alarm_arm_away" }
)
arm.promise:reject({ kind = "rejected" })
T.eq("rejection reports back to the origin", notification("ARM_FAILED").INTERFACE_ID, "fixture-interface")
ReceivedFromProxy(5002, "PARTITION_ARM", { ArmType = "Away", UserCode = "07913" })
local stale = requests[2]
bind(alarm, "alarm_control_panel.replacement")
stale.promise:reject({ kind = "timeout" })
T.eq("stale rejection is ignored", results, { "rejected" })
state(alarm, "snapshot", "alarm_control_panel.replacement", "armed_away", policy)
state(alarm, "state", "alarm_control_panel.replacement", "triggered", policy)
T.eq("triggered state is native", notification("PARTITION_STATE").STATE, "ALARM")
T.eq("disarm cannot send without required code", ReceivedFromProxy(5002, "PARTITION_DISARM"), false)
T.eq("disarm after prompt", ReceivedFromProxy(5002, "PARTITION_DISARM", { UserCode = "07913" }), true)
T.eq("disarm targets replacement", requests[3].rpc.target.entity_id, "alarm_control_panel.replacement")
requests[3].promise:resolve({})
T.eq("disarm acceptance does not clear triggered state", notification("PARTITION_STATE").STATE, "ALARM")
state(alarm, "state", "alarm_control_panel.replacement", "disarmed", policy)
T.eq("confirmed disarm clears triggered state", notification("PARTITION_STATE").STATE, "DISARMED_READY")
alarm:destroy()

T.section("Alarm modes and connection recovery follow native partition feedback")
notes, requests, results = {}, {}, {}
alarm = require("ha.alarm-adapter").new()
alarm:start()
bind(alarm, "alarm_control_panel.fixture")
T.eq("the panel initializes its native partition", notification("PARTITION_ENABLED").ENABLED, "true")
T.eq("offline partition cannot arm", ReceivedFromProxy(5002, "PARTITION_ARM", { ArmType = "Home" }), false)
local modes = {
  { "Home", "home", 1 },
  { "Away", "away", 2 },
  { "Night", "night", 4 },
  { "Vacation", "vacation", 32 },
  { "Custom Bypass", "custom_bypass", 16 },
}
for i, mode in ipairs(modes) do
  local label, action, bit = unpack(mode)
  local policyForMode = { supported_features = bit }
  state(alarm, "snapshot", "alarm_control_panel.fixture", "disarmed", policyForMode)
  T.eq(label .. " is the only available mode", values:getValue("Supported arm modes").value, label)
  T.eq(label .. " without a code", ReceivedFromProxy(5002, "PARTITION_ARM", { ArmType = label }), true)
  T.eq(
    label .. " sends the exact mode without credentials",
    { requests[i].rpc.service, requests[i].rpc.service_data },
    {
      "alarm_arm_" .. action,
      {},
    }
  )
  requests[i].promise:resolve({})
  T.eq(label .. " acceptance leaves confirmed state disarmed", values:getValue("State").value, "Disarmed")
  state(alarm, "state", "alarm_control_panel.fixture", "armed_" .. action, policyForMode)
  T.eq(label .. " reaches the named native arm state", notification("PARTITION_STATE").TYPE, label)
end
state(alarm, "state", "alarm_control_panel.fixture", "arming")
T.eq("arming reports exit delay", notification("PARTITION_STATE").STATE, "EXIT_DELAY")
state(alarm, "state", "alarm_control_panel.fixture", "pending")
T.eq("pending reports entry delay", notification("PARTITION_STATE").STATE, "ENTRY_DELAY")
state(alarm, "state", "alarm_control_panel.fixture", "disarming")
T.eq("disarm transition keeps native armed state", notification("PARTITION_STATE").STATE, "ARMED")
state(alarm, "state", "alarm_control_panel.fixture", "armed_away", { code_format = "text" })
T.eq("text-based panels advertise a required disarm code", notification("PARTITION_STATE").CODE_REQUIRED_TO_CLEAR, true)
T.eq(
  "native prompt preserves a text code",
  ReceivedFromProxy(5002, "PARTITION_DISARM", { UserCode = "Fixture Code" }),
  true
)
T.eq("only the current disarm submits its text code", requests[#requests].rpc.service_data, { code = "Fixture Code" })
requests[#requests].promise:reject({ kind = "timeout" })
T.eq("active timeout leaves the alarm armed", values:getValue("State").value, "Armed away")
alarm:message("readiness", { entity_id = "alarm_control_panel.fixture", transport = false })
T.eq("loss marks the native partition offline", notification("PARTITION_STATE_INIT").STATE, "OFFLINE")
T.eq("offline panel cannot disarm", ReceivedFromProxy(5002, "PARTITION_DISARM", { UserCode = "Fixture Code" }), false)
state(alarm, "snapshot", "alarm_control_panel.fixture", "disarmed")
T.eq("restored snapshot initializes the native partition", notification("PARTITION_STATE_INIT").STATE, "DISARMED_READY")
T.eq("restored snapshot does not replay the last action", #requests, 6)
alarm:destroy()

T.section("Media dashboard, playback payloads and exact source selection")
notes, requests, results = {}, {}, {}
local media = require("ha.media-player-adapter").new()
media:start()
bind(media, "media_player.fixture")
state(media, "snapshot", "media_player.fixture", "playing", {
  supported_features = 1 + 4 + 8 + 2048 + 4096 + 32768 + 262144,
  volume_level = 0,
  is_volume_muted = false,
  shuffle = false,
  media_title = "Fixture Track",
  media_artist = "Fixture Artist",
  media_album_name = "https://artwork.invalid/ignored?secret=synthetic",
  entity_picture = "/api/media_player_proxy/ignored?token=synthetic",
  source_list = codec.array({ "Radio", "Line In", "/secret" }),
  source = "Line In",
  media_position = 3,
  media_duration = 60,
})
T.eq("Now Playing retains supported text and omits media URLs", notification("UPDATE_MEDIA_INFO"), {
  STATE = "playing",
  TITLE = "Fixture Track",
  ARTIST = "Fixture Artist",
  ALBUM = "",
  IMAGEURL = "",
})
T.eq("volume readback preserves zero", ReceivedFromProxy(7000, "GET_VOLUME_LEVEL"), 0)
ReceivedFromProxy(5001, "GetDashboard")
T.eq("dashboard shows only Pause and Stop", notes[#notes - 1].params.EVTARGS, "<Items>Pause Stop</Items>")
T.eq("discrete volume accepts bounded level", ReceivedFromProxy(7000, "SET_VOLUME_LEVEL", { LEVEL = 40 }), true)
T.eq("normalized volume", requests[1].rpc.service_data, { volume_level = 0.4 })
T.eq("invalid level rejected", ReceivedFromProxy(7000, "SET_VOLUME_LEVEL", { LEVEL = -1 }), false)
T.eq("unsupported skip rejected", ReceivedFromProxy(5001, "SKIP_FWD"), false)
T.eq("valid source forwarded", ExecuteCommand("Select Source", { Source = "Radio" }), true)
T.eq("exact source parameter", requests[2].rpc.service_data, { source = "Radio" })
T.eq("unlisted source rejected", ExecuteCommand("Select Source", { Source = "Line Out" }), false)
T.eq("unsafe source rejected", ExecuteCommand("Select Source", { Source = "/secret" }), false)
T.eq("mute uses reported unmuted state", ReceivedFromProxy(5001, "MUTE"), true)
T.eq("mute payload", requests[3].rpc.service_data, { is_volume_muted = true })
T.eq("shuffle uses reported false", ReceivedFromProxy(5001, "ToggleShuffle"), true)
T.eq("shuffle payload", requests[4].rpc.service_data, { shuffle = true })
T.eq("repeat one supported", ReceivedFromProxy(5001, "ToggleRepeatOne"), true)
T.eq("repeat payload", requests[5].rpc.service_data, { ["repeat"] = "one" })
state(media, "state", "media_player.fixture", "idle", { media_title = "Stale title" })
T.eq("idle clears stale Now Playing", notification("UPDATE_MEDIA_INFO").TITLE, "")
T.eq("capability loss drops source choices", ExecuteCommand("Select Source", { Source = "Radio" }), false)
media:destroy()

T.section("Media transport, room audio and Navigator readback use fresh state")
notes, requests, results = {}, {}, {}
media = require("ha.media-player-adapter").new()
media:start()
bind(media, "media_player.fixture")
local powered = 128 + 256
state(media, "snapshot", "media_player.fixture", "standby", { supported_features = powered })
ReceivedFromProxy(5001, "DEVICE_SELECTED")
T.eq("selecting a standby player asks Home Assistant to turn on", requests[1].rpc.service, "turn_on")
requests[1].promise:resolve({})
T.eq("accepted power does not promote standby to on", values:getValue("State").value, "Standby")
T.eq("deselection uses power off if stop is unavailable", ReceivedFromProxy(5001, "DEVICE_DESELECTED"), true)
T.eq("deselection requests power off", requests[2].rpc.service, "turn_off")
requests[2].promise:resolve({})
local active = {
  supported_features = powered + 1 + 4 + 8 + 16 + 32 + 1024 + 2048 + 4096 + 16384 + 32768 + 262144,
  volume_level = 0.419,
  is_volume_muted = true,
  shuffle = true,
  ["repeat"] = "all",
  app_name = "Fixture App",
  media_artist = "Fixture Artist",
  media_album_name = "Fixture Album",
  media_duration = 75,
  media_position = 91,
  source = "Radio",
  source_list = codec.array({ "Radio", "Line In" }),
}
state(media, "state", "media_player.fixture", "playing", active)
T.eq("the current app supplies title if no track is reported", notification("UPDATE_MEDIA_INFO").TITLE, "Fixture App")
T.eq("the current album has safe source text", values:getValue("MEDIA_ALBUM").value, "Fixture Album")
T.eq("the current source appears in Programming", values:getValue("Media source").value, "Radio")
T.eq("volume uses the room output and rounds to the nearest level", notification("VOLUME_LEVEL_CHANGED"), {
  LEVEL = 42,
  OUTPUT = 7000,
})
T.eq("room output exposes the reported volume", ReceivedFromProxy(7000, "GET_VOLUME_LEVEL"), 42)
T.eq("room output reports support for discrete volume", ReceivedFromProxy(7000, "GET_HAS_DISCRETE_VOLUME"), true)
T.eq("confirmed mute uses the room output", notification("MUTE_CHANGED"), { MUTE = true, OUTPUT = 7000 })
ReceivedFromProxy(5001, "GetQueue", { NAVID = "fixture-nav", ROOMID = "fixture-room" })
for _, eventName in ipairs({ "QueueChanged", "DashboardChanged", "ProgressChanged" }) do
  local event = navigatorEvent(eventName)
  T.eq(eventName .. " targets the requesting Navigator and room", { event.NAVID, event.ROOMS }, {
    "fixture-nav",
    "fixture-room",
  })
end
T.eq(
  "playing mode shows Pause and both track directions",
  navigatorEvent("DashboardChanged").EVTARGS,
  "<Items>SkipRev Pause Stop SkipFwd</Items>"
)
T.truthy(
  "queue exposes confirmed shuffle in the native response",
  navigatorEvent("QueueChanged").EVTARGS:find("shufflemode", 1, true)
)
T.truthy(
  "progress clamps to the track duration",
  navigatorEvent("ProgressChanged").EVTARGS:find("1:15 / -0:00", 1, true)
)
state(media, "state", "media_player.fixture", "paused", active)
T.eq(
  "paused mode shows Play without Pause",
  navigatorEvent("DashboardChanged").EVTARGS,
  "<Items>SkipRev Play Stop SkipFwd</Items>"
)
state(media, "state", "media_player.fixture", "buffering", active)
T.eq("buffering mode shows its reported state", values:getValue("State").value, "Buffering")
local commands = {
  { 5001, "PLAY", "media_play" },
  { 5001, "PAUSE", "media_pause" },
  { 5001, "SKIP_FWD", "media_next_track" },
  { 5001, "SKIP_REV", "media_previous_track" },
  { 5001, "STOP", "media_stop" },
  { 5001, "OFF", "media_stop" },
  { 7000, "PULSE_VOL_UP", "volume_up" },
  { 7000, "PULSE_VOL_DOWN", "volume_down" },
  { 7000, "MUTE_OFF", "volume_mute", { is_volume_muted = false } },
  { 7000, "MUTE_ON", "volume_mute", { is_volume_muted = true } },
  { 7000, "MUTE_TOGGLE", "volume_mute", { is_volume_muted = false } },
  { 5001, "ToggleShuffle", "shuffle_set", { shuffle = false } },
  { 5001, "ToggleRepeat", "repeat_set", { ["repeat"] = "off" } },
  { 5001, "ToggleRepeatOne", "repeat_set", { ["repeat"] = "one" } },
}
for i, row in ipairs(commands) do
  local binding, native, action, parameters = unpack(row)
  T.eq(native .. " dispatches once", ReceivedFromProxy(binding, native), true)
  local request = requests[i + 2]
  T.eq(native .. " sends one service and targets the selected player", {
    request.rpc.service,
    request.rpc.target.entity_id,
    request.rpc.service_data,
  }, { action, "media_player.fixture", parameters or {} })
  request.promise:resolve({})
end
T.eq("room audio does not handle player transport commands", ReceivedFromProxy(7000, "PLAY"), nil)
T.eq("service acceptance does not replace buffering feedback", values:getValue("State").value, "Buffering")
T.eq("service acceptance does not replace confirmed mute", notification("MUTE_CHANGED").MUTE, true)
T.eq("source preview exact-match rejects different case", ExecuteCommand("Select Source", { Source = "radio" }), false)
T.eq("foreign player state cannot change Now Playing", values:getValue("MEDIA_APP_NAME").value, "Fixture App")
state(media, "state", "media_player.foreign", "playing", { app_name = "Foreign App" })
T.eq("the local player still owns the current track", values:getValue("MEDIA_APP_NAME").value, "Fixture App")
media:message("readiness", { entity_id = "media_player.fixture", transport = false })
T.eq("loss clears Now Playing", notification("UPDATE_MEDIA_INFO").STATE, "offline")
T.eq("loss removes room volume", ReceivedFromProxy(7000, "GET_VOLUME_LEVEL"), nil)
T.eq("loss blocks Play", ReceivedFromProxy(5001, "PLAY"), false)
T.eq("loss clears active source", values:getValue("Media source").value, "")
state(media, "snapshot", "media_player.fixture", "on", { supported_features = 16384 })
T.eq("fresh feedback restores normal control", ReceivedFromProxy(5001, "PLAY"), true)
T.eq("warm player recovery does not add a command by itself", #requests, #commands + 3)
media:destroy()
T.eq("destroy removes the room control handler", ReceivedFromProxy(7000, "MUTE_ON"), nil)

T.section("Coordinator allowlist rejects malformed credentials and media parameters")
for _, case in ipairs({
  { "alarm_control_panel.fixture", "alarm_trigger", {} },
  { "alarm_control_panel.fixture", "alarm_arm_away", { code = 119 } },
  { "alarm_control_panel.fixture", "alarm_disarm", { code = "line\nfeed" } },
  { "lock.fixture", "lock", { entity_id = "lock.foreign" } },
  { "lock.fixture", "alarm_disarm", {} },
  { "media_player.fixture", "play_media", { media_content_id = "fixture" } },
  { "media_player.fixture", "volume_set", { volume_level = 1.01 } },
  { "media_player.fixture", "volume_mute", { is_volume_muted = "false" } },
  { "media_player.fixture", "repeat_set", { ["repeat"] = "loop" } },
}) do
  local entity, action, params = unpack(case)
  T.eq(
    entity .. " rejects invalid " .. action,
    operations.build(
      "service",
      entity,
      codec.object({
        action = action,
        parameters = codec.object(params),
      })
    ),
    nil
  )
end
T.finish()
