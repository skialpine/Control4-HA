local T = require("testlib")
local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local Adapter = require("ha.light-adapter")
local codec = require("ha.codec")
local operations = require("ha.operations")
local color = require("lib.light.color")
local deferred = require("deferred")

local function fixture(entity, proxyOptions)
  local clock = F.virtualClock()
  local proxy = P.install(clock, proxyOptions)
  local adapter = Adapter.new()
  local calls, results = {}, {}
  local ready = true
  local consumer = {
    readiness = {
      view = function()
        return { evidence_ready = ready }
      end,
    },
    request = function(_, operation, target, args)
      local rpc = assert(
        operations.build(operation, target, args)
          or (operation == "read_load" and operations.readLoad(target, args) and { entity_id = target })
      )
      local completion = deferred.new()
      calls[#calls + 1] = { operation = operation, rpc = rpc, completion = completion }
      return completion
    end,
  }
  adapter:start()
  adapter:bind(consumer, entity, function(result)
    results[#results + 1] = result
  end)
  return {
    adapter = adapter,
    consumer = consumer,
    clock = clock,
    proxy = proxy,
    calls = calls,
    results = results,
    ready = function(value)
      ready = value
    end,
    state = function(value, attrs, target)
      adapter:message("snapshot", {
        entity_id = target or entity,
        state = value,
        attributes = codec.object(attrs or {}),
      })
    end,
    rpc = function()
      return assert(calls[#calls]).rpc
    end,
    done = function()
      adapter:destroy()
      proxy:restore()
      clock.restore()
    end,
  }
end

T.section("A binary light keeps its optional Control4 keypad links without claiming physical HA indicators")
do
  local f = fixture("switch.lamp")
  f.proxy.links = require("ha.identities").lightLinks
  local declared = {}
  for _, row in ipairs(require("lib.light.caps").static(f.adapter.light.profile)) do
    declared[row.key] = row.value
  end
  T.eq("Composer exposes the standard light_v2 settings", declared.hide_proxy_properties, "False")
  T.eq("both static proxy features remain available to saved keypad programming", {
    declared.has_leds,
    declared.has_button_events,
  }, { "True", "True" })
  f.state("off")
  local dynamic = f.proxy:last("DYNAMIC_CAPABILITIES_CHANGED")
  T.eq("the binary device declares no dimming and never overrides the static keypad features", {
    dynamic.dimmer,
    dynamic.has_leds,
    dynamic.has_button_events,
  }, { false })
  f.proxy:mark()
  f.state("on")
  for role, binding in pairs(require("ha.identities").lightLinks) do
    T.eq(
      role .. " keypad can track binary on/off feedback",
      f.proxy:toldLink(binding, "MATCH_LED_STATE"),
      { { STATE = true } }
    )
  end
  f.proxy:mark()
  f.proxy:send("SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "c0ffee" })
  T.eq(
    "the native light editor publishes the known color without inventing its opposite",
    f.proxy:toldLink(f.proxy.links.top, "BUTTON_COLORS"),
    { { ON_COLOR = "c0ffee" } }
  )
  T.eq("keypad feedback causes no HA LED or light requests", #f.calls, 0)
  f.done()
end

T.section("native Light programming receives distinct paddle actions")
do
  local f = fixture("light.paddle")
  f.state("off")
  for _, role in ipairs({ "top", "bottom", "toggle" }) do
    for _, event in ipairs({
      { "press", 1, 2 },
      { "press", 2, 3 },
      { "press", 3, 4 },
      { "hold_start", false, 1 },
      { "release", false, 0 },
    }) do
      f.adapter:publishNative({ role = role, kind = event[1], press_count = event[2] })
      T.eq(role .. " " .. event[1] .. " native action " .. event[3], f.proxy:last("BUTTON_ACTION"), {
        BUTTON_ID = ({ top = 0, bottom = 1, toggle = 2 })[role],
        ACTION = event[3],
      })
    end
  end
  f.proxy:mark()
  f.adapter:publishNative({ role = "bottom", kind = "press", press_count = 4 })
  f.adapter:publishNative({ button_id = "additional", kind = "press", press_count = 1 })
  T.eq("higher counts and auxiliary buttons stay custom", f.proxy:count("BUTTON_ACTION"), 0)
  T.eq("publishing native gestures does not send a load command", #f.calls, 0)
  f.done()
end

T.section("Navigator effects come from the current Home Assistant light")
do
  local f = fixture("light.effects")
  local name = 'Fire & "Ice"'
  local attrs = { effect_list = codec.array({ name, "Pulse" }), effect = name }
  f.state("off", attrs)
  local setup = f.proxy:last("EXTRAS_SETUP_CHANGED").XML
  T.eq(
    "effect names are escaped for XML display and selection",
    setup:find("Fire &amp; &quot;Ice&quot;", 1, true) ~= nil,
    true
  )
  T.eq(
    "Navigator receives current effect",
    f.proxy:last("EXTRAS_STATE_CHANGED").XML:find("&quot;Ice&quot;", 1, true) ~= nil,
    true
  )
  f.proxy:send("SELECT_LIGHT_EFFECT", { value = "Pulse" })
  T.eq(
    "saved command turns on selected effect",
    { f.rpc().target.entity_id, f.rpc().service, f.rpc().service_data.effect },
    { "light.effects", "turn_on", "Pulse" }
  )
  f.proxy:send("SELECT_LIGHT_EFFECT", { value = "Unknown" })
  T.eq("unknown effect ignored", #f.calls, 1)
  f.proxy:mark()
  f.state("off", attrs)
  T.eq("unchanged list produces no new setup", f.proxy:count("EXTRAS_SETUP_CHANGED"), 0)
  attrs.effect = "Pulse"
  f.state("on", attrs)
  T.eq("effect feedback only after HA confirms", f.proxy:count("EXTRAS_STATE_CHANGED"), 1)
  f.state("on", {})
  T.eq("capability removal clears the old menu", f.proxy:last("EXTRAS_SETUP_CHANGED").XML, "<extras_setup/>")
  f.proxy:send("SELECT_LIGHT_EFFECT", { value = "Pulse" })
  T.eq("removed effect no longer callable", #f.calls, 1)
  f.done()
end

T.section("binary switching always sends exact power commands")
do
  local f = fixture("switch.lamp")
  f.proxy:send("ON")
  T.eq("no command before confirmed state", #f.calls, 0)
  f.state("off")
  T.eq("does not advertise dimming", f.adapter.light.device.dims, false)
  f.proxy:send("ON")
  T.eq("selected switch receives bare power service", f.rpc(), {
    type = "call_service",
    domain = "switch",
    target = { entity_id = "switch.lamp" },
    service = "turn_on",
    service_data = codec.object({}),
  })
  f.state("on")
  f.proxy:send("OFF")
  T.eq("Off service has no brightness, color or transition", { f.rpc().service, f.rpc().service_data }, {
    "turn_off",
    codec.object({}),
  })
  f.done()
end

T.section("existing Composer power programs share the Light command path")
do
  local f = fixture("switch.lamp")
  f.state("off")
  ExecuteCommand("Turn On", {})
  T.eq("saved Turn On controls selected load", f.rpc().service, "turn_on")
  f.state("on")
  ExecuteCommand("Turn Off", {})
  T.eq("saved Turn Off controls selected load", f.rpc().service, "turn_off")
  f.state("off")
  ExecuteCommand("Toggle", {})
  T.eq("saved Toggle acts exactly once", #f.calls, 3)
  local old = EC.Toggle
  f.done()
  old()
  T.eq("retired handler has no load authority", { EC.Toggle, #f.calls }, { nil, 3 })
end

T.section("logical On keeps HA semantics and explicit numeric levels use the template's line")
do
  local f = fixture("light.lamp")
  local attrs = { supported_color_modes = codec.array({ "brightness" }) }
  f.state("on", { supported_color_modes = attrs.supported_color_modes, brightness = 91 })
  f.state("off", attrs)
  f.proxy:send("ON")
  T.eq("logical On leaves HA in charge of remembered brightness", f.rpc().service_data, codec.object({}))
  f.calls[1].completion:resolve({})
  T.eq("acceptance does not become confirmed feedback", f.results, { "accepted" })
  attrs.brightness = 180
  f.state("on", attrs)
  f.clock.run(1500)
  f.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("explicit 100 uses an exact brightness byte", f.rpc().service_data, codec.object({ brightness = 255 }))
  f.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  f.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("template applies Max On", f.rpc().service_data.brightness, 204)
  f.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 100 })

  f.state("unknown")
  local count = #f.calls
  f.proxy:send("ON")
  T.eq("unknown state retires commands", #f.calls, count)
  f.calls[2].completion:reject({ kind = "permission_denied" })
  T.eq("late acceptance or failure retired when state lost", f.results, { "accepted" })
  attrs.brightness = nil
  f.state("on", attrs)
  T.falsy("an on without native brightness never comes online", f.adapter.light.online)
  f.state("on", { brightness = 32, supported_color_modes = attrs.supported_color_modes }, "light.other")
  T.falsy("unselected entity does not become evidence", f.adapter.light.online)
  attrs.brightness = 64
  f.state("on", attrs)
  T.truthy("fresh exact brightness restores authority", f.adapter.light.online)
  f.ready(false)
  f.proxy:send("ON")
  T.eq("adapter checks live Consumer evidence before sending", #f.calls, count)
  f.done()
end

T.section("Permission rejection reconciles only the current command")
do
  local f = fixture("switch.lamp")
  f.state("off")
  f.proxy:send("ON")
  T.eq("light predicts On while awaiting HA", f.proxy:percent(), 100)
  f.proxy:send("OFF")
  f.proxy:send("ON")
  f.calls[1].completion:reject({ kind = "permission_denied" })
  T.eq("failure on an earlier command cannot roll back a newer On", f.proxy:percent(), 100)
  f.calls[3].completion:reject({ kind = "permission_denied" })
  T.eq("the latest denial settles on confirmed Off", f.proxy:percent(), 0)
  T.eq("the last command result retains the useful error", f.results[#f.results], "permission_denied")
  T.eq("reconciliation sends no second request", #f.calls, 3)
  f.done()
end

T.section("An uncertain direct command checks only the selected load and settles from confirmed evidence")
do
  local f = fixture("light.lamp")
  local attrs = { supported_color_modes = codec.array({ "brightness" }) }
  f.state("off", attrs)
  f.proxy:send("SET_LEVEL", { LEVEL = 100 })
  f.calls[1].completion:reject({ kind = "timeout" })
  T.eq("one read of the exact load is sent", { #f.calls, f.calls[2].operation, f.rpc().entity_id }, {
    2,
    "read_load",
    "light.lamp",
  })
  attrs.brightness = 102
  f.calls[2].completion:resolve(
    codec.object({ entity_id = "light.lamp", state = "on", attributes = codec.object(attrs) })
  )
  T.eq("the template settles an unacknowledged On at the actual brightness", f.proxy:percent(), 40)
  T.eq("the timeout remains the command result", f.results, { "timeout" })
  f.clock.run(16000)
  T.eq("the completed recovery never retries the command or polls", #f.calls, 2)
  f.done()
end

T.section("Accepted direct commands recover missing feedback once at the template deadline")
for _, acceptance in ipairs({ "early", "late", "late with a push" }) do
  local f = fixture("light.lamp")
  local attrs = { supported_color_modes = codec.array({ "brightness" }) }
  f.state("off", attrs)
  f.proxy:send("ON")
  if acceptance == "early" then
    f.calls[1].completion:resolve({})
  end
  f.clock.run(999)
  T.eq(acceptance .. " receipt leaves the full normal feedback window", #f.calls, 1)
  f.clock.run(1)
  attrs.brightness = 102
  if acceptance ~= "early" then
    T.eq(acceptance .. " receipt waits for the service result", #f.calls, 1)
    if acceptance == "late with a push" then
      f.state("on", attrs)
    end
    f.calls[1].completion:resolve({})
  end
  if acceptance == "late with a push" then
    T.eq("a push while waiting for acceptance supplies current evidence", #f.calls, 1)
  else
    T.eq(acceptance .. " receipt uses one exact read for power and brightness", {
      #f.calls,
      f.calls[2] and f.calls[2].operation,
      f.calls[2] and f.calls[2].rpc.entity_id,
    }, { 2, "read_load", "light.lamp" })
    f.calls[2].completion:resolve(
      codec.object({ entity_id = "light.lamp", state = "on", attributes = codec.object(attrs) })
    )
  end
  T.eq(acceptance .. " receipt displays the confirmed level", f.proxy:percent(), 40)
  local requests = #f.calls
  f.clock.run(16000)
  T.eq(acceptance .. " receipt never retries the command or polls", #f.calls, requests)
  f.done()
end

T.section("A power-only Light needs no brightness confirmation")
for _, withPush in ipairs({ false, true }) do
  local f = fixture("switch.lamp")
  f.state("off")
  f.proxy:send("ON")
  f.calls[1].completion:resolve({})
  if withPush then
    f.state("on")
  end
  f.clock.run(1000)
  T.eq("a binary device reads only for missing power evidence", #f.calls, withPush and 1 or 2)
  if not withPush then
    f.calls[2].completion:resolve(
      codec.object({ entity_id = "switch.lamp", state = "off", attributes = codec.object({}) })
    )
    T.eq("a power-only Light settles using the retrieved power state", f.proxy:percent(), 0)
  end
  f.done()
end

T.section("A native fade uses normal push and only checks a silent device after landing")
for _, withPush in ipairs({ false, true }) do
  local f = fixture("light.fade")
  local attrs = { supported_color_modes = codec.array({ "brightness" }), supported_features = 32 }
  f.state("off", attrs)
  f.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 2500 })
  T.eq("the requested fade is sent as a 2.5 second transition", f.rpc().service_data.transition, 2.5)
  f.calls[1].completion:resolve({})
  f.clock.run(500)
  f.state("off", attrs)
  f.clock.run(2000)
  T.eq("a stale push during a fade causes no early read", #f.calls, 1)
  if withPush then
    attrs.brightness = 179
    f.state("on", attrs)
  end
  f.clock.run(1000)
  if withPush then
    T.eq("a normally completed fade adds no network read", { #f.calls, f.proxy:percent() }, { 1, 70 })
  else
    T.eq("only a fade without final feedback gets one read", { #f.calls, f.calls[2] and f.calls[2].operation }, {
      2,
      "read_load",
    })
    f.calls[2].completion:resolve(
      codec.object({ entity_id = "light.fade", state = "off", attributes = codec.object(attrs) })
    )
    T.eq("an acknowledged fade can finish at the confirmed Off state", f.proxy:percent(), 0)
  end
  f.done()
end

T.section("Recovery preserves newer feedback, newer commands and a replacement selection")
do
  local f = fixture("switch.lamp")
  f.state("on")
  f.proxy:send("OFF")
  f.calls[1].completion:reject({ kind = "rejected" })
  f.state("on")
  f.calls[2].completion:resolve(codec.object({
    entity_id = "switch.lamp",
    state = "off",
    attributes = codec.object({}),
  }))
  T.eq("a concurrent push supersedes the exact read", f.proxy:percent(), 100)

  f.proxy:send("OFF")
  f.calls[3].completion:reject({ kind = "timeout" })
  f.proxy:send("ON")
  f.calls[5].completion:resolve({})
  f.calls[4].completion:reject({ kind = "timeout" })
  T.eq("a retired read cannot overwrite a newer On or its result", { f.proxy:percent(), f.results[#f.results] }, {
    100,
    "accepted",
  })

  f.proxy:send("OFF")
  f.calls[6].completion:reject({ kind = "timeout" })
  f.adapter:bind(f.consumer, "switch.other")
  f.state("on", nil, "switch.other")
  f.calls[7].completion:reject({ kind = "timeout" })
  T.eq("a retired read cannot take a replacement offline", {
    f.adapter.light.online,
    f.proxy:percent(),
    f.adapter.feedbackUnavailable,
  }, { true, 100 })
  f.done()
end

T.section("A failed exact read marks the Light unavailable until confirmed feedback returns")
do
  local f = fixture("switch.lamp")
  f.state("off")
  f.proxy:send("ON")
  f.calls[1].completion:reject({ kind = "disconnected" })
  f.calls[2].completion:reject({ kind = "read_failed" })
  T.eq("the displayed Light goes offline and setup can show unavailability", {
    f.adapter.light.online,
    f.adapter.feedbackUnavailable,
  }, { false, true })
  f.proxy:send("OFF")
  T.eq("the unavailable proxy does not send a new unconfirmed command", #f.calls, 2)
  f.state("off")
  T.eq("subscribed feedback restores genuine control", {
    f.adapter.light.online,
    f.proxy:percent(),
    f.adapter.feedbackUnavailable,
  }, { true, 0 })
  f.done()
end

T.section("supported color formats and temperature bounds map without waking a lamp")
do
  local f = fixture("light.xy")
  local attrs = {
    supported_color_modes = codec.array({ "xy", "color_temp" }),
    supported_features = 32,
    min_color_temp_kelvin = 2600,
    max_color_temp_kelvin = 5400,
    color_mode = "color_temp",
    color_temp_kelvin = 3750,
    brightness = 128,
  }
  f.state("off", attrs)
  f.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.39, LIGHT_COLOR_TARGET_Y = 0.33, RATE = 0 })
  T.eq("changing color while off creates no HA command", #f.calls, 0)
  f.proxy:send("ON")
  T.eq("held xy is sent with next On", f.rpc().service_data.xy_color, { 0.39, 0.33 })
  f.state("on", attrs)
  f.clock.run(2000)
  f.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 2500 })
  T.eq("transition mapping is milliseconds to seconds", f.rpc().service_data.transition, 2.5)

  local x, y = color.kelvinToXY(2000)
  f.adapter:send({
    kind = "change",
    setsColor = true,
    on = true,
    transitionMs = 0,
    color = { x = x, y = y, mode = "cct", kelvin = 2000 },
  })
  T.eq("warm endpoint clamps to advertised minimum", f.rpc().service_data.color_temp_kelvin, 2600)
  attrs.min_color_temp_kelvin, attrs.max_color_temp_kelvin = 6000, 2000
  f.state("on", attrs)
  T.eq("contradictory bounds do not advertise temperature", f.adapter.light.device.cct, nil)
  f.done()
end

T.section("RGB conversion uses the template color helper and no unadvertised transition")
do
  local f = fixture("light.rgb")
  f.state("on", {
    color_mode = "rgb",
    brightness = 120,
    supported_color_modes = codec.array({ "rgb" }),
    rgb_color = codec.array({ 255, 100, 0 }),
  })
  T.truthy("Color capability is advertised", f.adapter.light.device.color)
  local x, y = color.rgbToXY(1, 0, 0)
  f.adapter:send({
    kind = "change",
    setsColor = true,
    on = true,
    transitionMs = 1000,
    color = { x = x, y = y, mode = "xy" },
  })
  T.eq(
    "RGB uses bounded integer channels, without transition",
    f.rpc().service_data,
    codec.object({
      rgb_color = codec.array({ 255, 0, 0 }),
    })
  )
  local count = #f.calls
  f.adapter:send({
    kind = "change",
    setsColor = true,
    on = true,
    transitionMs = 0,
    color = { x = 0.9, y = 0.9, mode = "xy" },
  })
  T.eq("invalid color-only requests do not become power commands", #f.calls, count)
  f.adapter:send({
    kind = "change",
    setsLevel = true,
    on = true,
    transitionMs = 0,
    level = 0 / 0,
  })
  T.eq("invalid explicit levels do not become power commands", #f.calls, count)
  f.done()
end

T.section("Native color targets distinguish device presets from Color Agent presets")
do
  local f = fixture("light.color_preset")
  f.state("on", {
    color_mode = "xy",
    brightness = 120,
    supported_color_modes = codec.array({ "xy" }),
    xy_color = codec.array({ 0.32, 0.34 }),
  })
  f.proxy:send("UPDATE_COLOR_PRESET", { ID = 10, COMMAND = "ADDED", COLOR_X = 0.42, COLOR_Y = 0.38, COLOR_MODE = 0 })
  local params = { LIGHT_COLOR_TARGET_PRESET_ID = 10, LIGHT_COLOR_TARGET_PRESET_ORIGIN = 2 }
  f.proxy:send("SET_COLOR_TARGET", params)
  T.eq("an unresolved Color Agent preset sends no HA command", #f.calls, 0)
  params.LIGHT_COLOR_TARGET_X, params.LIGHT_COLOR_TARGET_Y = 0.29, 0.31
  f.proxy:send("SET_COLOR_TARGET", params)
  T.eq(
    "Color Agent coordinates take precedence over the stored device color",
    f.rpc().service_data.xy_color,
    { 0.29, 0.31 }
  )
  f.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = 10, LIGHT_COLOR_TARGET_PRESET_ORIGIN = 1 })
  T.eq("a device preset still resolves its stored color", f.rpc().service_data.xy_color, { 0.42, 0.38 })
  f.done()
end

T.section("legacy mired ranges are inverted into Kelvin")
do
  local f = fixture("light.legacy_temp")
  f.state("on", {
    color_mode = "color_temp",
    brightness = 100,
    supported_color_modes = codec.array({ "color_temp" }),
    color_temp = 250,
    min_mireds = 150,
    max_mireds = 500,
  })
  T.eq("the coolest mired maps to the highest Kelvin limit", f.adapter.light.device.cct, {
    minK = 2000,
    maxK = 6667,
  })
  T.eq("reported color uses the confirmed temperature", f.adapter.reported.color.kelvin, 4000)
  f.done()
end

T.section("Explicit On mode uses its level and survives a capability refresh")
do
  local f = fixture("light.preset")
  local attrs = { supported_color_modes = codec.array({ "brightness" }) }
  f.state("off", attrs)
  f.proxy:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 52, BRIGHTNESS_PRESET_LEVEL = 55 })
  f.proxy:send("ON")
  T.eq("explicit mode uses its level in the On service", f.rpc().service_data.brightness, 140)
  attrs.supported_features = 32
  f.state("off", attrs)
  f.proxy:send("ON")
  T.eq("capability refresh preserves the explicit mode", f.rpc().service_data.brightness, 140)
  f.proxy:send("UPDATE_BRIGHTNESS_PRESET", { ID = 52, COMMAND = "REMOVED" })
  f.proxy:send("ON")
  T.eq("removing the explicit mode restores plain HA On", f.rpc().service_data, codec.object({}))
  f.done()
end

T.section("The native Default On setting and its preset stay in sync")
do
  local f = fixture("light.preset")
  f.state("off", { supported_color_modes = codec.array({ "brightness" }) })
  f.proxy:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 1, BRIGHTNESS_PRESET_LEVEL = 75 })
  f.proxy:send("SET_PRESET_LEVEL", { LEVEL = 55 })
  f.proxy:send("ON")
  T.eq("an On command follows the edited Default On level", f.rpc().service_data.brightness, 140)
  f.proxy:appOn(55)
  T.eq("the Navigator target requests the edited preset level", f.rpc().service_data.brightness, 140)
  f.proxy:send("UPDATE_BRIGHTNESS_PRESET", { ID = 1, COMMAND = "MODIFIED", NAME = "On", LEVEL = 53 })
  T.eq("editing preset one keeps the reported Default On level in sync", f.adapter.light.settings:presetLevel(), 53)
  f.proxy:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 10, BRIGHTNESS_PRESET_LEVEL = 41 })
  f.proxy:send("SET_PRESET_LEVEL", { LEVEL = 55 })
  T.eq("editing Default On preserves another selected mode", f.adapter.light.settings:onModeLevel(), 41)
  f.proxy:send("UPDATE_BRIGHTNESS_PRESET", { ID = 10, COMMAND = "REMOVED" })
  f.proxy:send("SET_PRESET_LEVEL", { LEVEL = 100 })
  f.done()
end

T.section("An upgraded Light honors Default On without a native mode selection")
do
  local settings = require("lib.light.settings")
  local persist = require("lib.persist")
  persist:delete(settings.P_BRIGHTNESS_ON_MODE_PRESET)
  persist:delete(settings.P_ON_MODE)
  persist:delete(settings.P_PRESET_LEVEL)
  persist:delete(settings.P_BRIGHTNESS_PRESETS)
  local f = fixture("light.legacy_preset")
  f.state("off", { supported_color_modes = codec.array({ "brightness" }) })
  T.eq("the proxy has no saved brightness mode", f.adapter.light.settings:brightnessPresetId(), nil)
  f.proxy:send("SET_PRESET_LEVEL", { LEVEL = 55 })
  f.proxy:send("ON")
  T.eq(
    "plain On uses the saved level on a proxy that only exposes Default On Brightness",
    f.rpc().service_data.brightness,
    140
  )
  persist:delete(settings.P_PRESET_LEVEL)
  persist:delete(settings.P_BRIGHTNESS_PRESETS)
  f.done()

  f = fixture("light.legacy_preset", {
    setup = '<setup><brightnesses><level id="1" name="On" level="55"/></brightnesses></setup>',
  })
  f.state("off", { supported_color_modes = codec.array({ "brightness" }) })
  f.proxy:send("ON")
  T.eq("after reload the native preset is used without resaving", f.rpc().service_data.brightness, 140)
  persist:delete(settings.P_PRESET_LEVEL)
  persist:delete(settings.P_BRIGHTNESS_PRESETS)
  f.done()
end

T.section("Startup drops the On mode for a preset the native setup no longer lists")
do
  local attrs = { supported_color_modes = codec.array({ "brightness" }) }
  local f = fixture("light.removed_preset")
  f.state("off", attrs)
  f.proxy:send("SET_PRESET_LEVEL", { LEVEL = 57 })
  f.proxy:send("UPDATE_BRIGHTNESS_PRESET", { ID = 42, COMMAND = "ADDED", NAME = "Reading", LEVEL = 43 })
  f.proxy:send("SET_BRIGHTNESS_ON_MODE", { PRESET_ID = 42 })
  f.proxy:send("ON")
  T.eq("before reload the custom On level reaches HA", f.rpc().service_data.brightness, 110)
  f.done()

  f = fixture("light.removed_preset", {
    setup = "<setup><light_brightness_on_mode_preset_id>42</light_brightness_on_mode_preset_id>"
      .. '<brightnesses><level id="1" name="On" level="57"/></brightnesses></setup>',
  })
  f.state("off", attrs)
  f.proxy:send("ON")
  T.eq("after reload On uses the saved Default On level", f.rpc().service_data.brightness, 145)
  T.eq("the missing preset is no longer selected", f.adapter.light.settings:brightnessPresetId(), nil)
  f.proxy:send("UPDATE_BRIGHTNESS_PRESET", { ID = 42, COMMAND = "ADDED", NAME = "Evening", LEVEL = 80 })
  f.proxy:send("ON")
  T.eq("reusing the ID leaves Default On selected", f.rpc().service_data.brightness, 145)
  f.proxy:send("UPDATE_BRIGHTNESS_PRESET", { ID = 42, COMMAND = "REMOVED", LEVEL = 80 })
  f.proxy:send("SET_PRESET_LEVEL", { LEVEL = 100 })
  f.done()
end

T.section("Navigator shows numeric fade targets and identifies brightness presets on completion")
do
  local f = fixture("light.preset")
  local attrs = { brightness = 140, supported_color_modes = codec.array({ "brightness" }), supported_features = 32 }
  f.state("on", attrs)
  f.proxy:mark()
  f.proxy:send("SET_BRIGHTNESS_TARGET", {
    LIGHT_BRIGHTNESS_TARGET = "0",
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "2",
    RATE = "750",
  })
  T.eq("Off sends a single turn_off with the native transition", { #f.calls, f.rpc().service, f.rpc().service_data }, {
    1,
    "turn_off",
    codec.object({ transition = 0.75 }),
  })
  T.eq("the native ramp uses the explicit zero target", f.proxy:last("LIGHT_BRIGHTNESS_CHANGING"), {
    LIGHT_BRIGHTNESS_CURRENT = 55,
    LIGHT_BRIGHTNESS_TARGET = 0,
    RATE = 750,
  })
  f.state("off", { supported_color_modes = attrs.supported_color_modes, supported_features = 32 })
  f.clock.run(750)
  T.eq("the landed brightness preserves the native Off preset", f.proxy:last("LIGHT_BRIGHTNESS_CHANGED"), {
    LIGHT_BRIGHTNESS_CURRENT = 0,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 2,
  })
  f.proxy:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 1, BRIGHTNESS_PRESET_LEVEL = 55 })
  f.proxy:appOn(55)
  local onRamp = f.proxy:last("LIGHT_BRIGHTNESS_CHANGING")
  T.eq(
    "the Default On ramp shows the saved numeric target",
    { onRamp.LIGHT_BRIGHTNESS_TARGET, onRamp.LIGHT_BRIGHTNESS_TARGET_PRESET_ID },
    { 55 }
  )
  f.state("on", attrs)
  f.clock.run(750)
  T.eq("the landed brightness identifies Default On", f.proxy:last("LIGHT_BRIGHTNESS_CHANGED"), {
    LIGHT_BRIGHTNESS_CURRENT = 55,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 1,
  })
  f.proxy:send("SET_BRIGHTNESS_TARGET", {
    LIGHT_BRIGHTNESS_TARGET = "37",
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "10",
    RATE = "750",
  })
  T.eq("the Previous Level ramp shows the remembered numeric target", f.proxy:last("LIGHT_BRIGHTNESS_CHANGING"), {
    LIGHT_BRIGHTNESS_CURRENT = 55,
    LIGHT_BRIGHTNESS_TARGET = 37,
    RATE = 750,
  })
  attrs.brightness = 94
  f.state("on", attrs)
  f.clock.run(750)
  T.eq("the landed brightness identifies Previous Level", f.proxy:last("LIGHT_BRIGHTNESS_CHANGED"), {
    LIGHT_BRIGHTNESS_CURRENT = 37,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 10,
  })
  f.proxy:send("SET_BRIGHTNESS_TARGET", {
    LIGHT_BRIGHTNESS_TARGET = "64",
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "42",
    RATE = "750",
  })
  T.eq("the custom preset also sends a numeric fade target", f.proxy:last("LIGHT_BRIGHTNESS_CHANGING"), {
    LIGHT_BRIGHTNESS_CURRENT = 37,
    LIGHT_BRIGHTNESS_TARGET = 64,
    RATE = 750,
  })
  local targets = {}
  for i = 1, 3 do
    targets[i] = f.proxy.vars["1110"].value
    f.clock.run(250)
  end
  T.eq("the native target shows 64 throughout the fade", targets, { "64", "64", "64" })
  attrs.brightness = 163
  f.state("on", attrs)
  T.eq("the landed brightness identifies the custom preset", f.proxy:last("LIGHT_BRIGHTNESS_CHANGED"), {
    LIGHT_BRIGHTNESS_CURRENT = 64,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 42,
  })
  f.done()
end

local function dimmer(transition, colorMode)
  local f = fixture("light.paddle")
  f.state("on", {
    brightness = 64,
    supported_color_modes = codec.array({ colorMode or "brightness" }),
    color_mode = colorMode,
    xy_color = colorMode and codec.array({ 0.32, 0.33 }) or nil,
    supported_features = transition and 32 or 0,
  })
  return f
end

T.section("Holds stop future commands and only a supported transition is retargeted")
do
  local top = 200
  local f = dimmer(true)
  f.proxy:link(top, "DO_PUSH")
  f.clock.run(1000)
  T.truthy("held input starts a rated HA target", f.rpc().service_data.transition > 0)
  f.proxy:link(top, "DO_RELEASE")
  local stop = f.rpc().service_data
  T.eq("release replaces the target immediately", stop.transition, 0)
  T.check("estimated hold level stays inside the ramp", stop.brightness > 64 and stop.brightness < 255)
  local sent = #f.calls
  f.clock.run(8000)
  T.eq("no follow-up after release", #f.calls, sent)
  f.done()

  f = dimmer(true)
  f.proxy:link(top, "DO_PUSH")
  f.proxy:send("SET_LEVEL", { LEVEL = 35 })
  f.clock.run(8000)
  T.eq("override retires the waiting hold gate", #f.calls, 1)
  f.proxy:link(top, "DO_RELEASE")
  T.eq("release of overridden hold issues no replacement", #f.calls, 1)
  f.done()

  f = dimmer(false)
  f.proxy:link(top, "DO_PUSH")
  f.clock.run(1000)
  T.eq(
    "hold on an unrated device receives an immediate level target",
    f.rpc().service_data,
    codec.object({ brightness = 255 })
  )
  f.proxy:link(top, "DO_RELEASE")
  f.clock.run(8000)
  T.eq("a backend without transition receives no synthetic stop", #f.calls, 1)
  f.done()
end

T.section("Delayed scene steps retire on source failure, override, selection change and destruction")
for _, case in ipairs({
  {
    name = "source failure",
    retire = function(f)
      f.adapter:message("failure", { entity_id = "light.paddle" })
    end,
  },
  {
    name = "explicit override",
    retire = function(f)
      f.proxy:send("SET_LEVEL", { LEVEL = 35 })
    end,
  },
  {
    name = "explicit color override",
    colorMode = "xy",
    retire = function(f)
      f.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.40, LIGHT_COLOR_TARGET_Y = 0.35 })
      T.eq("the user's color reaches the lamp", f.rpc().service_data.xy_color, { 0.40, 0.35 })
    end,
  },
  {
    name = "an override forwarded to a quiet group",
    retire = function(f)
      f.proxy:send("JOIN_GROUP", { GROUP_ID = 9179, KEEP_SYNC = true })
      f.proxy:send("ON")
      T.eq("group forwarding does not send a direct request", #f.calls, 1)
      f.proxy:send("LEAVE_GROUP", { GROUP_ID = 9179 })
    end,
  },
  {
    name = "selection change",
    retire = function(f)
      f.adapter:bind(f.consumer, "light.replacement")
    end,
  },
  {
    name = "destruction",
    retire = function(f)
      f.adapter:destroy()
    end,
  },
}) do
  local f = dimmer(true, case.colorMode)
  f.proxy:send("PUSH_SCENE", {
    SCENE_ID = 7,
    FROM_GROUP = "True",
    ELEMENTS = "<element><brightnessEnabled>True</brightnessEnabled><brightness>35</brightness><brightnessRate>0</brightnessRate></element>"
      .. "<element><delay>2000</delay><brightnessEnabled>True</brightnessEnabled><brightness>70</brightness><brightnessRate>0</brightnessRate></element>",
  })
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("scene starts with its first target before " .. case.name, f.rpc().service_data.brightness, 89)
  case.retire(f)
  local sent = #f.calls
  f.clock.run(10000)
  T.eq("later scene step canceled on " .. case.name, #f.calls, sent)
  T.eq("timers did not raise after " .. case.name, f.clock.errors, {})
  f.done()
end

T.section("Original BP scenes play from their stored ALS record")
do
  local f = dimmer(true)
  local persist = require("lib.persist")
  local retirementKey = "HA.Light.BPSceneRetirements"
  local original = C4:ParseXml("<element><delay>500</delay><level>35.5</level><brightness>75</brightness></element>")
  local second = C4:ParseXml("<element><brightness>64</brightness></element>")
  C4:PersistSetValue("ALS:81", original, false)
  C4:PersistSetValue("ALS:82", second, false)
  C4:PersistSetValue("ALS:83", C4:ParseXml("<element><brightness>101</brightness></element>"), false)
  ShimPersistLand()

  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "83" })
  T.eq("invalid BP brightness sends no command", #f.calls, 0)
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "81" })
  T.eq("BP activation uses its first level immediately", f.rpc().service_data.brightness, 91)
  T.eq("activation leaves the original parsed scene intact", C4:PersistGetValue("ALS:81", false), original)
  T.eq("read-only activation writes no compatibility settings", C4:PersistGetValue(retirementKey, false), nil)

  f.proxy:send("REMOVE_SCENE", { SCENE_ID = "81" })
  local sent = #f.calls
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "81" })
  T.eq("a removed scene cannot reappear while the storage write is pending", #f.calls, sent)
  ShimPersistLand()
  persist._persist[retirementKey] = nil
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "81" })
  T.eq("a removed scene stays retired on a cold read", #f.calls, sent)
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "82" })
  T.eq("removal keeps unrelated BP scenes playable", f.rpc().service_data.brightness, 163)

  f.proxy:send("CLEAR_ALL_SCENES")
  sent = #f.calls
  ShimPersistLand()
  persist._persist[retirementKey] = nil
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "82" })
  T.eq("clear-all retires BP scenes after a cold read", #f.calls, sent)
  T.eq("scene removal keeps the original records for rollback", {
    C4:PersistGetValue("ALS:81", false),
    C4:PersistGetValue("ALS:82", false),
  }, { original, second })
  f.proxy:send("PUSH_SCENE", { SCENE_ID = "82", ELEMENTS = "<element><level>20</level></element>" })
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "82" })
  T.eq("Composer can save a new scene at a retired BP ID", f.rpc().service_data.brightness, 51)
  persist:set(retirementKey, nil)
  f.done()
end

T.section("Director's first Light scene survives a cold read")
do
  local persist = require("lib.persist")
  local scenesKey = "scenes"
  local sceneId = "0"
  local before = dimmer(true)
  before.proxy:send("PUSH_SCENE", {
    SCENE_ID = sceneId,
    ELEMENTS = "<element><level>40</level></element>",
  })
  before.done()
  ShimPersistLand()
  persist._persist[scenesKey] = nil

  local after = dimmer(true)
  after.proxy:send("ACTIVATE_SCENE", { SCENE_ID = sceneId })
  T.eq("the saved scene still sends its brightness without another push", after.rpc().service_data.brightness, 102)
  after.proxy:send("REMOVE_SCENE", { SCENE_ID = sceneId })
  after.done()
  ShimPersistLand()
  persist._persist[scenesKey] = nil
end

T.section("Prototype scenes play from the original persisted table and obey native stop")
do
  local f = dimmer(true)
  local oldPersist = PersistData
  local level = "<element><brightnessEnabled>True</brightnessEnabled><brightness>35.5</brightness></element>"
  local later = "<element><delay>500</delay><level>0</level></element>"
  local prototype = { xml = level .. later, flash = true, ignore = true }
  PersistData = { LightScenes = { ["86"] = prototype } }
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "86" })
  T.eq("legacy brightness retains its fractional target", f.rpc().service_data.brightness, 91)
  T.eq("read leaves the original scene intact", PersistData.LightScenes["86"], prototype)
  f.proxy:send("RAMP_SCENE_DOWN", { SCENE_ID = "86", RATE = 4000 })
  f.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = "85" })
  f.clock.run(749)
  T.eq("delay and flash dwell both elapse before the next step", #f.calls, 1)
  f.clock.run(1)
  T.eq("legacy flash switches the load off", f.rpc().service, "turn_off")
  f.clock.run(250)
  T.eq("flash repeats at the beginning", f.rpc().service_data.brightness, 91)
  f.proxy:send("STOP_RAMP_SCENE", { SCENE_ID = "86" })
  local sent = #f.calls
  f.clock.run(6000)
  T.eq("stop cancels a flashing scene", #f.calls, sent)
  f.proxy:send("PUSH_SCENE", { SCENE_ID = "86", FLASH = "True", ELEMENTS = level })
  f.proxy:send("PUSH_SCENE", { SCENE_ID = "86", ELEMENTS = "<elements>" .. level })
  f.proxy:send("PUSH_SCENE", { SCENE_ID = "86" })
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "86" })
  T.eq("unsafe replacement leaves previous saved scene playable", #f.calls, sent + 1)
  f.proxy:send("REMOVE_SCENE", { SCENE_ID = "86" })
  sent = #f.calls
  f.proxy:send("ACTIVATE_SCENE", { SCENE_ID = "86" })
  f.clock.run(6000)
  T.eq(
    "explicit removal stops pending steps and removes the old scene",
    { #f.calls, PersistData.LightScenes["86"] },
    { sent }
  )
  T.eq("no callback errors", f.clock.errors, {})
  PersistData = oldPersist
  f.done()
end

T.section("Scene fades use bounded increments on an HA dimmer without transitions")
do
  local f = dimmer(false)
  local params = { SCENE_ID = "92" }
  f.proxy:send("PUSH_SCENE", {
    SCENE_ID = params.SCENE_ID,
    ELEMENTS = "<element><level>75</level><rate>1000</rate></element>"
      .. "<element><delay>500</delay><level>35</level></element>",
  })
  f.proxy:send("ACTIVATE_SCENE", params)
  f.clock.run(249)
  T.eq("software fade waits for its first no-transition increment", #f.calls, 0)
  f.clock.run(1)
  T.eq(
    "first increment uses confirmed brightness and zero backend transition",
    f.rpc().service_data,
    { brightness = 96 }
  )
  f.clock.run(750)
  T.eq("software fade lands on the requested level", { #f.calls, f.rpc().service_data.brightness }, { 4, 191 })
  f.proxy:send("DEACTIVATE_SCENE", params)
  f.clock.run(600)
  T.eq("deactivation cancels the remaining delayed steps", #f.calls, 4)

  f.proxy:send("RAMP_SCENE_DOWN", { SCENE_ID = params.SCENE_ID, RATE = 4000 })
  f.clock.run(250)
  T.eq("interactive fade issues an increment", #f.calls, 5)
  f.proxy:send("STOP_SCENE_RAMP", params)
  f.clock.run(5000)
  T.eq("interactive stop cancels pending increments", #f.calls, 5)
  T.eq("software fade timers did not raise", f.clock.errors, {})
  f.proxy:send("REMOVE_SCENE", params)
  f.done()
end

if os.getenv("HA_SCENE_BENCHMARK") == "1" then
  local metrics = require("ha.performance").shared
  local savedClock, savedName, savedProperties = metrics.clock, metrics.clockName, Properties
  metrics.clock = function()
    return os.clock() * 1000
  end
  metrics.clockName = "Lua os.clock process CPU (ms)"
  Properties = { ["Log Mode"] = "Off", ["Log Level"] = "0 - Fatal" }
  local f = dimmer(true)
  local params = { SCENE_ID = "90" }
  metrics:reset()
  metrics:setEnabled(true)
  for _ = 1, 64 do
    f.proxy:send("PUSH_SCENE", {
      SCENE_ID = params.SCENE_ID,
      ELEMENTS = "<elements><element><level>70</level></element>"
        .. "<element><delay>500</delay><level>35</level></element></elements>",
    })
    f.proxy:send("ACTIVATE_SCENE", params)
    f.clock.run(510)
    f.proxy:send("DEACTIVATE_SCENE", params)
  end
  local report = metrics:report()
  print("Scene CPU benchmark " .. JSON:encode(report))
  T.eq("benchmark recorded proxy scene dispatch and deferred steps", {
    report.operations["light.scene"].count,
    report.operations["light.scene_step"].count,
  }, { 192, 192 })
  metrics:setEnabled(false)
  metrics:reset()
  metrics.clock, metrics.clockName, Properties = savedClock, savedName, savedProperties
  f.proxy:send("REMOVE_SCENE", params)
  f.done()
end

T.finish()
