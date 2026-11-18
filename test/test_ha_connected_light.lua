local T = require("testlib")
local F = require("c4_fixtures")
local FakeProxy = require("light_proxy_fake")
local Adapter = require("ha.light-adapter")
local Setup = require("ha.setup")
local ids = require("ha.identities")
local metrics = require("ha.performance").shared
local persist = require("lib.persist")

local clock = F.virtualClock()
local proxy = FakeProxy.install(clock, { links = ids.lightLinks })
local me = C4:GetDeviceID()
local light, group, branch, replacement = 21, 31, 41, 51
local appBinding = ids.targetLinks.app
local names = { [light] = "Bedroom", [group] = "Evening Lights", [branch] = "Hall", [replacement] = "Kitchen" }
local function capabilities(dims, ramps, stops, color)
  return (
    "<DynamicCapabilities><dimmer>%s</dimmer><ramp_level>%s</ramp_level>"
    .. "<supports_brightness_stop>%s</supports_brightness_stop><supports_color>%s</supports_color>"
    .. "<color_rate_max>8000</color_rate_max></DynamicCapabilities>"
  ):format(tostring(dims), tostring(ramps), tostring(stops), tostring(color))
end
local vars = {
  [light] = { [1000] = "false", [1001] = "0", [1200] = "0.32,0.33,0", [6661] = capabilities(true, true, false, true) },
  [group] = { [1000] = "true", [1001] = "62", [6661] = capabilities(true, true, true, false) },
  [branch] = { [1000] = "true", [6661] = capabilities(false, false, false, false) },
  [replacement] = { [1000] = "true", [1001] = "18", [6661] = capabilities(true, false, false, false) },
}
local providers, requests, paddles, paddlePeers, reads = {}, {}, {}, {}, 0
local rootModel, rootUsesSuiteBinding
local failedReleases, onReleaseFailure = 0, nil
local lookupFailures, onPaddlePush = 0, nil
local read = C4.GetDeviceVariable
local sendProxy = C4.SendToProxy
function C4:GetDeviceVariable(device, variable)
  if vars[device] then
    reads = reads + 1
    return vars[device][variable]
  end
  return read(self, device, variable)
end
function C4:GetBindingsByDevice(device)
  if device == me and lookupFailures > 0 then
    lookupFailures = lookupFailures - 1
    error("binding query failed")
  end
  local bindings = {}
  if device == me then
    for id, provider in pairs(providers) do
      bindings[#bindings + 1] = {
        bindingid = id,
        provider = false,
        bindingclasses = { { class = "BUTTON_LINK" } },
        boundprovider = { bound = { deviceid = provider, bindingid = id + 600 } },
      }
    end
  elseif device == group - 1 and rootUsesSuiteBinding then
    bindings[1] = {
      bindingid = ids.lightCoordinatorBinding,
      provider = false,
      bindingclasses = { { class = ids.coordinatorClass } },
    }
  end
  return { bindings = bindings }
end
local getDeviceData = C4.GetDeviceData
function C4:GetDeviceData(id, key)
  if id == group - 1 and key == "model" then
    return rootModel
  end
  return getDeviceData(self, id, key)
end
function C4:GetBoundProviderDevice(device, binding)
  return device == me and providers[binding] or 0
end
function C4:GetProxyDevicesById(device)
  if device == me then
    return FakeProxy.PROXY_DEVICE
  elseif device == group - 1 then
    return group
  elseif names[device] then
    return device
  end
end
function C4:GetDeviceDisplayName(id)
  return names[id]
end
function C4:SendToDevice(id, command, parameters)
  requests[#requests + 1] = { id = id, command = command, parameters = parameters }
end
function C4:SendToProxy(id, command, parameters, kind, ...)
  if id >= 203 and id <= 205 and kind == "COMMAND" then
    paddles[#paddles + 1] = { id, command }
    paddlePeers[#paddlePeers + 1] = { providers[id], command }
    if command == "DO_PUSH" and onPaddlePush then
      local callback = onPaddlePush
      onPaddlePush = nil
      callback()
    end
    if command == "DO_RELEASE" and failedReleases > 0 then
      failedReleases = failedReleases - 1
      local callback = onReleaseFailure
      onReleaseFailure = nil
      if callback then
        callback()
      end
      return false
    end
    return
  end
  return sendProxy(self, id, command, parameters, kind, ...)
end
local function observe(id, variable, value)
  vars[id][variable] = value
  OnWatchedVariableChanged(id, variable, value)
end
local function last()
  return requests[#requests]
end
local adapter = Adapter.new()
adapter:start()
Properties =
  { ["Button behavior"] = "Automatic", ["Manual entity ID"] = "", ["Driver Status"] = "", ["Next step"] = "" }
persist:delete("HA.DeviceSelection")
persist:set("max_on_level", 50)
local setup = Setup.new("light", nil, adapter)
metrics:reset()
metrics:setEnabled(true)

T.section("Linked app is independent of Home Assistant and mirrors a confirmed native preset")
providers[appBinding], providers[ids.targetLinks.top], providers[ids.targetLinks.bottom] = light, branch, group - 1
setup:start()
T.eq("no HA selection required for local app", setup:view().status, "Device connected")
T.eq("explicit target wins over independent paddle targets", setup:view().target, "Bedroom")
T.eq("initial state is from native target", proxy.level, 0)
T.eq("target ramp advertised", proxy.caps.ramp_level, true)
T.eq("unsupported stop hidden", proxy.caps.supports_brightness_stop, false)
T.eq("only app target is watched", OWVC[branch], nil)
proxy:appOn(100)
T.eq("Navigator uses target's nighttime preset", last(), { id = light, command = "ON", parameters = {} })
T.eq("request does not change displayed level", proxy.level, 0)
observe(light, 1001, "23")
T.eq("level without On evidence leaves light off", proxy.level, 0)
observe(light, 1000, "true")
T.eq("confirmed target reports its nighttime level", proxy.level, 23)
T.eq("no follow-up full-brightness send", #requests, 1)
adapter:lost()
proxy:send("DYNAMIC_OFF")
T.eq("HA loss cannot disable the app route", last().command, "OFF")
T.eq("Off request leaves native confirmation authoritative", proxy.level, 23)

T.section("Explicit level, ramp, group and color commands are delegated exactly")
proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 37, RATE = 0 })
T.eq("explicit slider level stays exact", last(), { id = light, command = "SET_LEVEL", parameters = { LEVEL = 37 } })
proxy:send("RAMP_TO_LEVEL", { LEVEL = 74, TIME = 820 })
T.eq(
  "target owns timed ramp",
  last(),
  { id = light, command = "RAMP_TO_LEVEL", parameters = { LEVEL = 74, TIME = 820 } }
)
proxy:send("SET_BRIGHTNESS_STOP")
T.eq("stop is suppressed when unavailable", #requests, 4)
proxy:send(
  "SET_COLOR_TARGET",
  { LIGHT_COLOR_TARGET_X = 0.41, LIGHT_COLOR_TARGET_Y = 0.39, LIGHT_COLOR_TARGET_RATE = 500 }
)
T.eq("explicit color is delegated", last().command, "SET_COLOR_TARGET")
T.eq("explicit color does not publish optimistic feedback", proxy.color.x, 0.32)
proxy:send("PUSH_SCENE", { SCENE_ID = "1" })
proxy:send("ACTIVATE_SCENE", { SCENE_ID = "1" })
T.eq("local scene path never commands the connected target", #requests, 5)

T.section("Named On modes and their automatic color follow-up leave the target in control")
proxy:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 42, BRIGHTNESS_PRESET_LEVEL = 80 })
proxy:send("UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = 6,
  COLOR_PRESET_ORIGIN = 1,
  COLOR_PRESET_COLOR_X = 0.42,
  COLOR_PRESET_COLOR_Y = 0.4,
  COLOR_PRESET_COLOR_MODE = 0,
  COLOR_FADE_PRESET_ID = 7,
  COLOR_FADE_PRESET_ORIGIN = 1,
  COLOR_FADE_PRESET_COLOR_X = 0.43,
  COLOR_FADE_PRESET_COLOR_Y = 0.4,
  COLOR_FADE_PRESET_COLOR_MODE = 0,
})
proxy:appOn(80)
clock.run(18)
T.eq("custom Navigator On sends once and skips local On color", #requests, 6)
T.eq("named On mode still delegates logical On", last().command, "ON")
proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 55, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 90, RATE = 0 })
T.eq("unrelated preset selection requests its exact explicit level", last().parameters.LEVEL, 55)

T.section("Paddle links retain independent native button targets")
T.eq(
  "single tap follows its own link",
  adapter:gesture({ role = "top", kind = "press", press_count = 1, button_id = "top" }),
  true
)
T.eq(
  "bottom hold uses its distinct link",
  adapter:gesture({ role = "bottom", kind = "hold_start", button_id = "bottom" }),
  true
)
adapter:releaseGesture("foreign")
T.eq("foreign cleanup cannot release the held bottom", #paddles, 3)
adapter:releaseGesture("bottom")
T.eq("press and release use original role", paddles, {
  { 203, "DO_PUSH" },
  { 203, "DO_CLICK" },
  { 204, "DO_PUSH" },
  { 204, "DO_RELEASE" },
})
T.eq(
  "multi-press remains a programming occurrence",
  adapter:gesture({ role = "top", kind = "press", press_count = 3, button_id = "top" }),
  false
)
T.eq("paddle forwarding never commands app target directly", #requests, 7)
proxy:link(200, "DO_PUSH")
proxy:link(200, "DO_CLICK")
T.eq("Control4 keypad input follows the same independent paddle route", paddles[6], { 203, "DO_CLICK" })

T.section("failed hold cleanup retries only on the original binding")
local heldButton = { role = "bottom", kind = "hold_start", button_id = "bottom" }
adapter:gesture(heldButton)
failedReleases = 1
adapter:releaseGesture("bottom")
local attempts = #paddles
clock.run(1000)
T.eq("transient release failure retries once", { #paddles, paddles[#paddles] }, { attempts + 1, { 204, "DO_RELEASE" } })
adapter:gesture(heldButton)
failedReleases = 1
adapter:releaseGesture("bottom")
attempts = #paddles
local originalPeer = providers[ids.targetLinks.bottom]
providers[ids.targetLinks.bottom] = replacement
clock.run(1000)
T.eq("late retry cannot release the replacement peer", #paddles, attempts)
providers[ids.targetLinks.bottom] = originalPeer

T.section("Leaving connected mode still releases an active keypad hold after a transient send failure")
proxy:link(ids.lightLinks.bottom, "DO_PUSH")
T.eq("the native keypad starts a hold on the original output", paddles[#paddles], { 204, "DO_PUSH" })
failedReleases = 1
Properties["Button behavior"] = "Buttons only"
setup:propertyChanged()
attempts = #paddles
T.eq("leaving connected mode first tries to release the bound output", paddles[attempts], { 204, "DO_RELEASE" })
T.falsy("the disabled paddle rejects a new hold", adapter:gesture(heldButton))
clock.run(99)
T.eq("cleanup observes the existing delay before retry", #paddles, attempts)
clock.run(1)
T.eq("cleanup retries only the original release while disabled", { #paddles, paddles[#paddles] }, {
  attempts + 1,
  { 204, "DO_RELEASE" },
})
clock.run(1000)
T.eq("a successful release ends cleanup", #paddles, attempts + 1)
Properties["Button behavior"] = "Automatic"
setup:propertyChanged()
adapter:gesture(heldButton)
failedReleases = 1
Properties["Button behavior"] = "Buttons only"
setup:propertyChanged()
attempts = #paddles
providers[ids.targetLinks.bottom] = replacement
clock.run(1000)
T.eq("a rebind while disabled cannot send the retry to a replacement dimmer", #paddles, attempts)
providers[ids.targetLinks.bottom] = originalPeer
Properties["Button behavior"] = "Automatic"
setup:propertyChanged()

T.section("A failed release still retries when its send callback retires connected mode")
proxy:link(ids.lightLinks.bottom, "DO_PUSH")
failedReleases = 2
attempts = #paddles
onReleaseFailure = function()
  Properties["Button behavior"] = "Buttons only"
  setup:propertyChanged()
end
proxy:link(ids.lightLinks.bottom, "DO_RELEASE")
T.eq("the send callback has switched operating modes", setup:mode(), "Buttons only")
T.eq("the release and its immediate cleanup both used the original output", #paddles, attempts + 2)
clock.run(100)
T.eq("the in-flight release retries on the original binding", { #paddles, paddles[#paddles] }, {
  attempts + 3,
  { 204, "DO_RELEASE" },
})
Properties["Button behavior"] = "Automatic"
setup:propertyChanged()

T.section("If a tap changes peers during dispatch, the replacement receives no command")
local bottomTarget = ids.targetLinks.bottom
attempts = #paddlePeers
onPaddlePush = function()
  providers[bottomTarget] = replacement
end
T.falsy(
  "the tap does not complete across the rebind",
  adapter:gesture({
    role = "bottom",
    kind = "press",
    press_count = 1,
    button_id = "bottom",
  })
)
T.eq("only the original peer received the start of the tap", {
  #paddlePeers,
  paddlePeers[attempts + 1],
}, { attempts + 1, { originalPeer, "DO_PUSH" } })
providers[bottomTarget] = originalPeer
adapter:releaseGesture("bottom")

T.section("A transient binding lookup failure cannot leave the old light watched")
proxy:link(ids.lightLinks.bottom, "DO_PUSH")
local oldFeedback = OWVC[light][1001]
attempts = #paddlePeers
lookupFailures = 1
Properties["Button behavior"] = "Buttons only"
T.truthy("mode change completes even when release validation throws", pcall(setup.propertyChanged, setup))
T.eq("the failed lookup does not send to an unverified target", #paddlePeers, attempts)
T.eq("the old light's watchers are detached", OWVC[light], nil)
oldFeedback(light, 1001, "47")
T.falsy("old feedback cannot make the proxy online in Buttons only", adapter.light.online)
clock.run(100)
T.eq("the retry reads the binding again and releases only the original peer", {
  #paddlePeers,
  paddlePeers[#paddlePeers],
}, { attempts + 1, { originalPeer, "DO_RELEASE" } })
Properties["Button behavior"] = "Automatic"
setup:propertyChanged()
observe(light, 1001, "23")

T.section("An exhausted release reports one command result")
proxy:link(ids.lightLinks.bottom, "DO_PUSH")
attempts = #paddles
failedReleases = 4
Properties["Button behavior"] = "Buttons only"
setup:propertyChanged()
local releaseResults, publishResult = {}, adapter.onResult
adapter.onResult = function(status)
  releaseResults[#releaseResults + 1] = status
  publishResult(status)
end
clock.run(599)
T.eq("no failure is published while a retry remains", releaseResults, {})
clock.run(1)
T.eq("four failed attempts publish one diagnostic", { #paddles, releaseResults }, {
  attempts + 4,
  { "connected_release_failed" },
})
T.eq(
  "the existing command result explains what to check",
  Variables["Last Command Result"],
  "The driver could not send the button release. Check the linked light and its button connection in Composer."
)
failedReleases = 1
adapter.connected:release()
clock.run(1000)
T.eq("further cleanup failure for the same hold does not repeat the diagnostic", #releaseResults, 1)
adapter.connected:release()
Properties["Button behavior"] = "Automatic"
setup:propertyChanged()

T.section("Rebinding retires old app listeners and supports a group proxy")
local late = OWVC[light][1001]
providers[appBinding] = group - 1
observe(light, 1001, "99")
T.eq("feedback from old binding cannot apply before its change event", proxy.level, 23)
proxy:send("ON")
T.eq("no command to stale target before binding event", #requests, 7)
setup:bindingsChanged(appBinding)
T.eq("group protocol binding resolves to its light proxy", setup:view().target, "Evening Lights")
T.eq("group's own state supplies app level", proxy.level, 62)
T.eq("old watcher registrations retired", OWVC[light], nil)
late(light, 1001, "99")
T.eq("late old callback cannot publish", proxy.level, 62)
proxy:send("TOGGLE")
T.eq("group owns toggle", last(), { id = group, command = "TOGGLE", parameters = {} })
proxy:send("SET_BRIGHTNESS_STOP")
T.eq("verified native stop stops group rather than resending guessed level", last().command, "SET_BRIGHTNESS_STOP")
proxy:mark()
proxy:send("SYNCHRONIZE")
local confirmed = false
for _, note in ipairs(proxy.notes) do
  confirmed = confirmed or note.cmd == "LIGHT_BRIGHTNESS_CHANGED"
end
T.eq("native sync resends unchanged confirmed state", confirmed, true)

T.section("Unbound or conflicting app targets do not follow a random paddle")
providers[appBinding] = nil
setup:bindingsChanged(appBinding)
T.eq("distinct paddle bindings need an explicit app link", setup:view().status, "Choose a connected light")
local prior = #requests
proxy:send("ON")
T.eq("ambiguous app sends nothing", #requests, prior)
providers[ids.targetLinks.bottom] = branch
setup:bindingsChanged(ids.targetLinks.bottom)
T.eq("one physical paddle target can provide the app target", setup:view().target, "Hall")
proxy:send("SET_LEVEL", { LEVEL = 43 })
T.eq("binary linked light receives power only", last(), { id = branch, command = "ON", parameters = {} })
local priorReads = reads
clock.run(20000)
T.eq("healthy native connection does not poll", reads, priorReads)
providers[appBinding], vars[replacement][1000] = replacement, nil
setup:bindingsChanged(appBinding)
T.eq("missing proxy variables retain the named link for setup", setup:view().target, "Kitchen")
T.eq("uninitialized target has separate readiness", setup:view().status, "Waiting for connected light")
vars[replacement][1000] = "true"
clock.run(500)
T.eq("bounded startup retry watches native variables when they appear", proxy.level, 18)

T.section("Connected targets exclude both suite identities without excluding legacy Light")
ShimSetDevices({
  [group - 1] = { driverFileName = "HA.Light.c4z", deviceName = "HA Light" },
  [group] = { driverFileName = "HA.Light.c4z", deviceName = "HA Light", protocol = { [group - 1] = {} } },
})
providers[appBinding], rootModel, rootUsesSuiteBinding = group - 1, "HA Light", true
setup:bindingsChanged(appBinding)
prior = #requests
proxy:send("ON")
T.eq("canonical suite proxy is not watched or controlled", { #requests, OWVC[group] }, { prior })
providers[appBinding] = replacement
setup:bindingsChanged(appBinding)
providers[appBinding], rootModel, rootUsesSuiteBinding = group - 1, "Control4.HA.Light", false
setup:bindingsChanged(appBinding)
proxy:send("ON")
T.eq("interim suite proxy is not watched or controlled", { #requests, OWVC[group] }, { prior })
providers[appBinding] = replacement
setup:bindingsChanged(appBinding)
providers[appBinding], rootModel = group - 1, "HA Light"
setup:bindingsChanged(appBinding)
proxy:send("ON")
T.eq(
  "legacy Light with the shared model remains a valid local target",
  last(),
  { id = group, command = "ON", parameters = {} }
)
providers[appBinding] = replacement
setup:bindingsChanged(appBinding)
T.section("The scene wrapper delegates timed steps and cancels them when the target changes")
local scene = { SCENE_ID = "89" }
providers[appBinding] = light
setup:bindingsChanged(appBinding)
observe(light, 1001, "23")
observe(light, 1000, "true")
proxy:send("PUSH_SCENE", {
  SCENE_ID = scene.SCENE_ID,
  ELEMENTS = "<elements><element><brightness>72</brightness><brightnessRate>400</brightnessRate>"
    .. "<colorEnabled>True</colorEnabled><brightnessEnabled>True</brightnessEnabled>"
    .. "<colorX>0.41</colorX><colorY>0.39</colorY><colorRate>300</colorRate></element>"
    .. "<element><delay>600</delay><level>40</level></element></elements>",
})
prior = #requests
proxy:send("ACTIVATE_SCENE", scene)
T.eq(
  "wrapped elements use the target's native color and brightness commands",
  { requests[prior + 1].command, last() },
  { "SET_COLOR_TARGET", { id = light, command = "RAMP_TO_LEVEL", parameters = { LEVEL = 72, TIME = 400 } } }
)
T.eq("color rate stays separate from brightness rate", requests[prior + 1].parameters.LIGHT_COLOR_TARGET_RATE, 300)
T.eq("scene command waits for native feedback before displaying the new level", proxy.level, 23)
clock.run(999)
T.eq("second element waits for both its delay and the previous rate", #requests, prior + 2)
providers[appBinding] = replacement
setup:bindingsChanged(appBinding)
clock.run(3000)
T.eq("old scene steps do not reach a replacement target", #requests, prior + 2)
providers[appBinding] = group - 1
setup:bindingsChanged(appBinding)
proxy:send("PUSH_SCENE", {
  SCENE_ID = scene.SCENE_ID,
  ELEMENTS = "<element><level>30</level></element>",
})
proxy:send("RAMP_SCENE_DOWN", { SCENE_ID = scene.SCENE_ID, RATE = 2000 })
T.eq(
  "interactive scenes use group target ramp",
  last(),
  { id = group, command = "RAMP_TO_LEVEL", parameters = { LEVEL = 0, TIME = 2000 } }
)
proxy:send("STOP_SCENE_RAMP", scene)
T.eq("interactive stop forwards to a target that supports it", last().command, "SET_BRIGHTNESS_STOP")
local previousPersist = PersistData
PersistData = {
  LightScenes = {
    ["91"] = {
      xml = "<element><level>100</level></element><element><delay>500</delay><level>0</level></element>",
      flash = true,
      ignore = false,
    },
  },
}
prior = #requests
proxy:send("ACTIVATE_SCENE", { SCENE_ID = 91 })
clock.run(1000)
T.eq("same-instance saved flash reaches the linked group on each cycle", {
  requests[prior + 1].parameters.LEVEL,
  requests[prior + 2].parameters.LEVEL,
  requests[prior + 3].parameters.LEVEL,
}, { 100, 0, 100 })
proxy:send("SET_LEVEL", { LEVEL = 58 })
clock.run(6000)
T.eq("manual command cancels the linked flash", { #requests, last().parameters.LEVEL }, { prior + 4, 58 })
PersistData = previousPersist
providers[appBinding] = replacement
setup:bindingsChanged(appBinding)
prior = #requests
proxy:send("RAMP_SCENE_UP", { SCENE_ID = 89, RATE = 2000 })
clock.run(500)
T.eq(
  "linked dimmer without native ramp receives bounded level steps",
  { #requests, last().command, last().parameters.LEVEL },
  { prior + 2, "SET_LEVEL", 43 }
)
proxy:send("STOP_RAMP_SCENE", { SCENE_ID = 89 })
clock.run(2000)
T.eq("stopping a linked software ramp leaves the last step in place", #requests, prior + 2)
proxy:send("CLEAR_ALL_SCENES")

T.section("The library owns native keypad settings and groups in connected mode")
providers[appBinding] = light
setup:bindingsChanged(appBinding)
proxy:send("SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "a1b2c3" })
T.eq(
  "keypad color is saved without inventing the unset color",
  { adapter.light.settings:buttonColors(0) },
  { "a1b2c3" }
)

proxy:mark()
proxy:link(200, "REQUEST_BUTTON_COLORS")
T.eq("a linked keypad receives only known colors", proxy:toldLink(200, "BUTTON_COLORS"), { { ON_COLOR = "a1b2c3" } })
proxy:send("SET_BUTTON_COLOR", { BUTTON_ID = "0", OFF_COLOR = "223344" })
proxy:mark()
proxy:link(200, "REQUEST_BUTTON_COLORS")
T.eq("a linked keypad receives both configured colors", proxy:toldLink(200, "BUTTON_COLORS"), {
  { ON_COLOR = "a1b2c3", OFF_COLOR = "223344" },
})

local loadGroup, driverGroup = 9172, 9173
proxy:send("JOIN_GROUP", { GROUP_ID = loadGroup, KEEP_SYNC = true })
T.eq("library stores synced load group", adapter.light.groups:all()[tostring(loadGroup)], true)
prior = #requests
proxy:send("ON")
T.eq(
  "a synced load group receives the command once",
  { #requests, last().id, last().command },
  { prior + 1, loadGroup, "ON" }
)
proxy:send("GROUP_SET_LEVEL", { GROUP_ID = loadGroup, LEVEL = 35 })
T.eq("member command reaches the actual connected light once", { #requests, last() }, {
  prior + 2,
  { id = light, command = "SET_LEVEL", parameters = { LEVEL = 35 } },
})
proxy:send("GROUP_START_RAMP", { GROUP_ID = loadGroup, RAMP_UP = "true", RATE = 1000 })
T.eq("hold rate still uses the library's distance scaling", last(), {
  id = light,
  command = "RAMP_TO_LEVEL",
  parameters = { LEVEL = 100, TIME = 770 },
})
proxy:send("LEAVE_GROUP", { GROUP_ID = loadGroup })
T.eq("load group leave removes membership", adapter.light.groups:all()[tostring(loadGroup)], nil)

EC.LIGHT_GROUP_JOIN({ GROUP_ID = driverGroup, MEMBER_ID = "member" })
T.eq(
  "group driver receives the member's actual state on join",
  { last().id, last().command },
  { driverGroup, "LIGHT_GROUP_STATE" }
)
prior = #requests
EC.LIGHT_GROUP_COMMAND({ GROUP_ID = driverGroup, KIND = "level", LEVEL = 44, RATE = 250 })
T.eq("group driver's resolved level reaches the target once", { #requests, last() }, {
  prior + 1,
  { id = light, command = "RAMP_TO_LEVEL", parameters = { LEVEL = 44, TIME = 250 } },
})
T.eq("group level stays unconfirmed until the target reports", proxy.level, 23)
EC.LIGHT_GROUP_COMMAND({ GROUP_ID = driverGroup, KIND = "color", X = 0.41, Y = 0.39, RATE = 250 })
T.eq("group color remains a color command", { last().id, last().command }, { light, "SET_COLOR_TARGET" })
prior = #requests
EC.LIGHT_GROUP_COMMAND({ GROUP_ID = driverGroup, KIND = "level", LEVEL = 51, X = 0.42, Y = 0.38, RATE = 250 })
T.eq("a combined group command forwards each supported aspect exactly once", {
  #requests,
  requests[prior + 1].command,
  requests[prior + 1].parameters.LIGHT_COLOR_TARGET_X,
  last(),
}, {
  prior + 2,
  "SET_COLOR_TARGET",
  0.42,
  { id = light, command = "RAMP_TO_LEVEL", parameters = { LEVEL = 51, TIME = 250 } },
})
EC.LIGHT_GROUP_LEAVE({ GROUP_ID = driverGroup })
T.eq("group driver leave removes membership", adapter.light.groups:drivers()[tostring(driverGroup)], nil)

providers[appBinding] = group - 1
setup:bindingsChanged(appBinding)
prior = #requests
EC.LIGHT_GROUP_COMMAND({ GROUP_ID = group - 1, KIND = "level", LEVEL = 41, RATE = 0 })
proxy:send("GROUP_SET_LEVEL", { GROUP_ID = group - 1, LEVEL = 41 })
T.eq("a group never receives a member command echoed back through its own target link", #requests, prior)
providers[appBinding] = replacement
setup:bindingsChanged(appBinding)
providers[ids.targetLinks.bottom] = originalPeer
setup:bindingsChanged(ids.targetLinks.bottom)
T.truthy("a held paddle is active before teardown", adapter:gesture(heldButton))
failedReleases = 10
setup:destroy()
adapter:destroy()
attempts = #paddles
clock.run(1000)
T.eq("destruction cancels pending release retries", #paddles, attempts)
T.eq("destruction unregisters active native watchers", OWVC[replacement], nil)
local report = metrics:report()
T.eq("opt-in timing samples the native app and feedback boundaries", {
  report.operations["connected.on"].count > 0,
  report.operations["connected.level"].count > 0,
  report.operations["connected.feedback"].count > 0,
  report.operations["connected.paddle"].count > 0,
}, { true, true, true, true })
T.eq("no swallowed callback error", #clock.errors, 0)
T.finish()
