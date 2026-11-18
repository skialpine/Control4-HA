local T = require("testlib")
local clock = require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local Gestures = require("ha.gestures")
local formatter = require("ha.gesture-contract")
local metrics = require("ha.performance").shared

local entity, control, device = "event.lab_buttons", "lab-control", string.rep("a", 32)
local fired, forwarded, released, acknowledgments = {}, {}, {}, {}
function C4:FireEventByID(id)
  fired[#fired + 1] = id
end
local options = {
  onOccurrence = function(gesture)
    forwarded[#forwarded + 1] = gesture
    clock.run(2)
    return gesture.role == "top"
  end,
  onCleanup = function(button)
    released[#released + 1] = button or "all"
  end,
  onAcknowledge = function(ack)
    acknowledgments[#acknowledgments + 1] = ack
  end,
}
local config = { gesture_entity_id = entity, control_id = control, device_id = device }
local function frame(second, sequence, button, action, session)
  local revision = ("2026-11-17T13:00:%02d.000420+00:00"):format(second)
  local attrs = {
    bridge_control_id = control,
    bridge_source_device_id = device,
    bridge_session_id = session or "boot-a",
    bridge_update_kind = sequence and "gesture" or "snapshot",
    bridge_contract_version = "1.1",
    bridge_acknowledgment_version = 2,
    bridge_buttons = codec.array({}),
    bridge_sources = codec.array({}),
  }
  for _, id in ipairs({ "top", "bottom", "toggle", "four", "five" }) do
    attrs.bridge_buttons[#attrs.bridge_buttons + 1] = {
      id = id,
      label = id,
      gestures = {
        { id = "press_2", kind = "press", press_count = 2, label = "Double press" },
        { id = "hold_start", kind = "hold_start", label = "Hold" },
        { id = "release", kind = "release", label = "Release" },
      },
    }
    attrs.bridge_sources[#attrs.bridge_sources + 1] = {
      id = "source-" .. id,
      button_id = id,
      ready = true,
      availability = "unknown",
    }
  end
  if sequence then
    attrs.button_id, attrs.gesture_id, attrs.event_type = button, action, action
    if action == "press_2" then
      attrs.event_type, attrs.press_count = "press", 2
    end
    attrs.gesture_session_id, attrs.gesture_sequence = attrs.bridge_session_id, sequence
    attrs.gesture_event_id = attrs.bridge_session_id .. ":" .. sequence
    -- The helper publishes occurrence time before the HA EventEntity stamps its state.
    attrs.gesture_occurred_at = ("2026-11-17T13:00:%02d.000+00:00"):format(second)
  end
  return codec.decode(codec.encode({
    entity_id = entity,
    state = sequence and revision or "unknown",
    last_updated = revision,
    attributes = attrs,
  }))
end
local g = Gestures.new(options)
g:bind(config)
T.section("exact selected baseline declares each independent button without replay")
T.eq("real-looking event before snapshot is inert", g:message("state", frame(1, 1, "four", "press_2"), true), false)
T.eq(
  "historical gesture from snapshot does not execute",
  g:message("snapshot", frame(2, 2, "four", "press_2"), false),
  false
)
T.eq("no gesture event yet", #fired, 0)
T.eq(
  "shadow source transport without readiness denies a new gesture",
  g:message("state", frame(3, 3, "five", "press_2"), false),
  false
)
T.truthy("live fifth button passes", g:message("state", frame(4, 4, "five", "press_2"), true))
T.eq("unknown role stays programming only", forwarded[#forwarded].role, nil)
T.eq("stable distinct identity retained", forwarded[#forwarded].button_id, "five")
T.eq("normal diagnostics are silent", #acknowledgments, 0)

T.section("live actions use current sequence and capability")
T.eq("duplicate", g:message("state", frame(4, 4, "five", "press_2"), true), false)
T.eq("older state", g:message("state", frame(3, 5, "five", "press_2"), true), false)
local history = frame(5, 6, "five", "press_2")
history.attributes.bridge_update_kind = "snapshot"
T.eq("live transport delivery marked snapshot does not execute", g:message("state", history, true), false)
T.eq("snapshot advanced replay floor", g:message("state", frame(6, 6, "five", "press_2"), true), false)
T.truthy(
  "a distinct sequence with identical gesture can fire",
  g:message("state", frame(6, 7, "five", "press_2"), true)
)
T.eq("button keeps programming event ID", { fired[1], fired[2] }, { fired[1], fired[1] })

T.section("only identifiable current malformed input releases held output")
T.truthy("hold starts", g:message("state", frame(8, 8, "top", "hold_start"), true))
T.eq("helper role is stable button identity", forwarded[#forwarded].role, "top")
local foreign = frame(9, 9, "top", "release")
foreign.attributes.bridge_control_id = "other"
foreign.attributes.gesture_event_id = "wrong"
T.eq("foreign malformed does not cancel", g:message("state", foreign, true), false)
T.eq("hold survives foreign input", #released, 0)
local malformed = frame(10, 10, "top", "release")
malformed.attributes.gesture_event_id = "wrong"
T.eq("owned malformed release is inert", g:message("state", malformed, true), false)
T.eq("owned malformed releases this button", released, { "top" })
T.eq("malformed did not fire an event", #fired, 3)

T.section("lost source requires a fresh baseline and excludes old sessions")
g:lost(entity)
T.eq("cannot resume on a live event alone", g:message("state", frame(11, 11, "top", "hold_start"), true), false)
T.eq("fresh historical snapshot is silent", g:message("snapshot", frame(12, 12, "top", "hold_start"), false), false)
T.eq(
  "new session on live without baseline",
  g:message("state", frame(13, 1, "top", "hold_start", "boot-b"), true),
  false
)
g:message("snapshot", frame(14, nil, nil, nil, "boot-b"), false)
T.eq(
  "delayed retired session silently rejected",
  g:message("state", frame(15, 15, "top", "hold_start", "boot-a"), true),
  false
)
T.eq(
  "retired session cannot rebaseline even with a newer timestamp",
  g:message("snapshot", frame(15, nil, nil, nil, "boot-a"), true),
  false
)
metrics:setEnabled(true)
T.truthy(
  "own fresh session accepts explicit hold",
  g:message("state", frame(16, 1, "top", "hold_start", "boot-b"), true)
)
T.eq("only the accepted fresh occurrence acknowledged", #acknowledgments, 1)
T.eq(
  "exact session and sequence",
  { acknowledgments[1].bridge_session_id, acknowledgments[1].gesture_sequence },
  { "boot-b", 1 }
)
T.truthy("actual forwarding has timestamp", acknowledgments[1].receiver_forwarded_epoch_ms ~= nil)
local lost = frame(17, nil, nil, nil, "boot-b")
lost.attributes.bridge_sources[1].ready = false
g:message("snapshot", lost, true)
T.eq("source-specific loss retires owned hold", released, { "top", "top" })
metrics:setEnabled(false)

T.section("event definitions reuse persisted identity across reorder and driver restart")
local prior = fired[1]
local g2 = Gestures.new(options)
g2:bind(config)
local renamed = frame(18, nil, nil, nil, "boot-c")
renamed.attributes.bridge_buttons[5].label = "Number Five"
renamed.attributes.bridge_buttons[1], renamed.attributes.bridge_buttons[5] =
  renamed.attributes.bridge_buttons[5], renamed.attributes.bridge_buttons[1]
g2:message("snapshot", renamed, false)
local nextPress = frame(19, 1, "five", "press_2", "boot-c")
nextPress.attributes.bridge_buttons[5].label = "Number Five"
g2:message("state", nextPress, true)
T.eq("stable ID survives rename and ordering", fired[#fired], prior)
T.eq("rename applied to native declaration", ShimEvents()[prior].name, "Number Five - 2 taps")

T.section("synchronous programming can retire the selection before forwarding")
do
  local previous = C4.FireEventByID
  function C4:FireEventByID()
    g2:bind(nil)
  end
  local forwards, acks = #forwarded, #acknowledgments
  metrics:setEnabled(true)
  T.truthy(
    "already consumed programming occurrence remains accepted",
    g2:message("state", frame(20, 2, "top", "press_2", "boot-c"), true)
  )
  T.eq("retired handler cannot forward or acknowledge", { #forwarded, #acknowledgments }, { forwards, acks })
  C4.FireEventByID = previous
  metrics:setEnabled(false)
end

T.section("missed releases retire forwarded holds without replaying history")
local guarded = Gestures.new(options)
guarded:bind(config)
guarded:message("snapshot", frame(1), false)
guarded:message("state", frame(2, 1, "top", "hold_start"), true)
local releasesBefore, firedBefore = #released, #fired
guarded:message("state", frame(3, 3, "five", "press_2"), true)
T.eq("live gap cleans up the held button", { #released, released[#released] }, { releasesBefore + 1, "top" })
T.eq("the new occurrence still fires once", #fired, firedBefore + 1)
guarded:message("state", frame(4, 4, "bottom", "hold_start"), true)
guarded:message("snapshot", frame(5, 4, "bottom", "hold_start"), false)
T.eq("same-sequence snapshot keeps a supported hold", #released, releasesBefore + 1)
guarded:message("snapshot", frame(6, 5, "bottom", "release"), false)
T.eq(
  "advancing snapshot cleans up without firing its event",
  { released[#released], #fired },
  { "bottom", firedBefore + 2 }
)
local noRelease = frame(7, 6, "top", "hold_start")
table.remove(noRelease.attributes.bridge_buttons[1].gestures, 3)
local forwardedBefore = #forwarded
guarded:message("state", noRelease, true)
T.eq(
  "hold-only source can program but cannot start a target ramp",
  { #fired, #forwarded },
  { firedBefore + 3, forwardedBefore }
)
guarded:message("state", frame(8, 7, "top", "hold_start"), true)
local removed = frame(9, 7, "top", "hold_start")
table.remove(removed.attributes.bridge_buttons[1].gestures, 3)
guarded:message("snapshot", removed, false)
T.eq(
  "withdrawn release capability cleans up the active hold",
  { #released, released[#released] },
  { releasesBefore + 3, "top" }
)

T.section("Light native programming survives reload without duplicate events on new projects")
do
  local Light = require("ha.light-adapter")
  local native = {}
  local function deliver(gesture)
    local action = Light.nativeAction(gesture)
    if action then
      native[#native + 1] = action
    end
  end
  local saved
  local n = Gestures.new({
    nativeAction = Light.nativeAction,
    publishNative = deliver,
    savedLightEvents = function()
      return saved
    end,
  })
  local function verify(id)
    config.control_id = id
    n:bind(config)
    local function send(kind, second, sequence, button)
      local data = frame(second, sequence, button, sequence and "press_2")
      data.attributes.bridge_control_id = id
      return n:message(kind, data, true)
    end
    local before, notified = #fired, #native
    send("snapshot", 1)
    send("state", 2, 1, "bottom")
    send("state", 2, 1, "bottom")
    T.eq("one native double-tap per live sequence", #native, notified + 1)
    T.eq("native bottom double action", native[#native], 3)
    local delta = #fired - before
    send("state", 3, 2, "five")
    T.eq("additional button still fires its custom program", #fired - before, delta + 1)
    return delta
  end
  T.eq("current suite custom program ID is also retained", verify(control), 1)
  T.eq("fresh Light uses native Composer trigger once", verify("new-paddle"), 0)
  saved = {
    version = 1,
    next_event_id = 1202,
    allocations = { ["original/five/press_2"] = 1200, ["original/bottom/press_2"] = 1201 },
  }
  T.eq("prototype standard tap keeps native proxy event", verify("original"), 0)
  T.eq("prototype fifth button fires its saved Composer ID", fired[#fired], 1200)
  saved.allocations["original/top/press_2"] = 1200
  T.eq("ambiguous saved ID map rejected", formatter.savedLightEvents(saved), nil)
end

T.section("Programming lists three tap counts and preserves previously allocated IDs")
do
  local events = require("lib.events")
  local namespace = "HA Gesture " .. control
  local existing = events:getOrAddEvent(namespace, "bottom/press_2", "Bottom Button Double tap", "Old description")
  local retired = events:getOrAddEvent(namespace, "bottom/press_4", "Bottom Button 4 taps", "Old description")
  local current = Gestures.new(options)
  current:bind({ gesture_entity_id = entity, control_id = control, device_id = device })
  T.eq("retired tap is removed from Composer", ShimEvents()[retired.eventId], nil)
  T.eq("retired ID remains reserved", events:getEvents()[namespace]["bottom/press_4"].eventId, retired.eventId)

  local function tapFrame(second, sequence, count)
    local data = frame(second, sequence, "bottom", count and ("press_" .. count), "sorted")
    local bottom = data.attributes.bridge_buttons[2]
    bottom.label = "Bottom Button"
    for n = 1, 5 do
      if n ~= 2 then
        bottom.gestures[#bottom.gestures + 1] = {
          id = "press_" .. n,
          kind = "press",
          press_count = n,
          label = ({ [1] = "Single tap", [3] = "Triple tap" })[n] or (n .. " taps"),
        }
      end
    end
    if count then
      data.attributes.event_type, data.attributes.press_count = "press", count
    end
    return codec.decode(codec.encode(data))
  end

  current:message("snapshot", tapFrame(24), true)
  local names = {}
  for _, row in pairs(ShimEvents()) do
    if row.name:match("^Bottom %- ") then
      names[#names + 1] = row.name
    end
  end
  table.sort(names)
  T.eq("native alphabetical sort keeps tap counts together", names, {
    "Bottom - 1 tap",
    "Bottom - 2 taps",
    "Bottom - 3 taps",
    "Bottom - Hold",
    "Bottom - Release",
  })
  T.eq("existing double-tap ID remains in use", ShimEvents()[existing.eventId].name, "Bottom - 2 taps")
  local before = #fired
  T.eq("fourth tap does not fire Programming", current:message("state", tapFrame(25, 1, 4), true), false)
  T.eq("retired taps still advance the replay floor", { #fired, current.sequence }, { before, 1 })
  T.truthy("following triple tap is delivered", current:message("state", tapFrame(26, 2, 3), true))
  T.eq("one Programming event fires", #fired, before + 1)
end

T.section("HA revision parsing normalizes timezone and rejects malformed dates")
T.eq(
  "offsets compare against the same UTC revision",
  formatter.timestamp("2026-11-17T14:00:00.1+01:00"),
  formatter.timestamp("2026-11-17T13:00:00.100000Z")
)
T.eq("reject invalid leap date", formatter.timestamp("2026-02-29T13:00:00Z"), nil)
T.truthy("accept leap date", formatter.timestamp("2028-02-29T13:00:00Z"))
T.finish()
