local T = require("testlib")
local clock = require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local deferred = require("deferred")
local values = require("lib.values")
local metrics = require("ha.performance").shared

local adapter, entity, notices, events, requests, results, refreshes
local consumer = { readiness = {} }
function consumer:_current()
  return true
end
function consumer.readiness:view(target)
  return { evidence_ready = target == entity }
end
function consumer:request(operation, target, arguments)
  local promise = deferred.new()
  requests[#requests + 1] = { operation = operation, target = target, arguments = arguments, promise = promise }
  return promise
end
function consumer:refreshSelected()
  refreshes = refreshes + 1
  return true
end
function C4:SendToProxy(binding, command, params, direction)
  notices[#notices + 1] = { binding = binding, command = command, params = params, direction = direction }
end
function C4:FireEventByID(event)
  events[#events + 1] = event
end

local function begin(module, target)
  if adapter then
    adapter:destroy()
  end
  notices, events, requests, results, refreshes = {}, {}, {}, {}, 0
  entity, adapter = target, require(module).new()
  adapter:start()
  adapter:bind(consumer, entity, function(result)
    results[#results + 1] = result
  end)
end

local function report(kind, state, attributes, target, updated)
  adapter:message(
    kind,
    codec.object({
      entity_id = target or entity,
      state = state,
      attributes = codec.object(attributes or {}),
      last_updated = updated,
    })
  )
end

local function value(name)
  local entry = values:getValue(name)
  return entry and entry.value
end

T.section("Binary contact initializes without replay and keeps loss separate from a closed contact")
begin("ha.binary-sensor-adapter", "binary_sensor.entry")
T.eq("no contact feedback before a snapshot", #notices, 0)
report("snapshot", "on", { device_class = "door" }, "binary_sensor.alternate")
T.eq("a foreign contact cannot publish", #notices, 0)
report("snapshot", "off", { device_class = "door" })
T.eq("the existing contact polarity initializes closed", notices[1], {
  binding = 1,
  command = "STATE_CLOSED",
  params = {},
  direction = "NOTIFY",
})
T.eq("a door reports a closed signal", value("State"), "Closed")
T.eq("startup leaves programming events untouched", events, {})
report("state", "on", { device_class = "door" })
T.eq("transition command reaches the linked contact", notices[2].command, "OPENED")
T.eq("one transition event", events, { 1000 })
T.eq("active condition tests confirmed state", TestCondition("IS_ACTIVE"), true)
report("state", "on", { device_class = "occupancy" })
T.eq("an occupancy state is described by class", value("State"), "Occupied")
T.eq("class update repeats neither contact nor event", { #notices, #events }, { 2, 1 })
report("state", "unavailable")
T.eq("loss emits its own event without closing the contact", { #notices, events }, { 2, { 1000, 1002 } })
T.eq(
  "loss satisfies neither signal condition",
  { TestCondition("IS_ACTIVE"), TestCondition("IS_INACTIVE") },
  { false, false }
)
report("snapshot", "off", { device_class = "occupancy" })
T.eq(
  "reconnect sends state without replaying an edge",
  { notices[3].command, #events, value("State") },
  { "STATE_CLOSED", 2, "Unoccupied" }
)
OnBindingChanged(1, "CONTACT_SENSOR", true)
T.eq("a linked contact can receive current feedback on bind", notices[4].command, "STATE_CLOSED")

T.section("Generic sensor infers its native connection and retains explicitly saved unit fallback")
Properties["Sensor Type"], Properties["Unit Fallback"], Properties["Reading"] = "Automatic", "None", ""
Properties["Value"], Properties["Last Updated"], Properties["Poll Timer"] = "", "", "Off"
local seconds, stamp = 1730000000, "2024-10-27T03:33:20.000+00:00"
function C4:ParseIso8601DateTime(raw, strict)
  if raw == stamp and strict then
    return {}, seconds, 0
  end
end
begin("ha.sensor-adapter", "sensor.indoor")
report("snapshot", "0", { device_class = "temperature", unit_of_measurement = "°C" }, nil, stamp)
T.eq(
  "numeric zero stays a typed value",
  { value("Numeric Reading"), value("Reading"), value("Reading Unit") },
  { 0, "0 °C", "°C" }
)
T.eq("native sensor initialization", { notices[1].binding, notices[1].command }, { 500, "VALUE_INITIALIZED" })
T.eq("native temperature units", { notices[2].params.CELSIUS, notices[2].params.FAHRENHEIT }, { 0, 32 })
T.eq(
  "legacy numeric and text variables remain typed",
  { value("SENSOR_STATE"), value("SENSOR_STATE_INT"), value("SENSOR_STATE_FLOAT") },
  { "0", 0, 0 }
)
T.eq(
  "legacy timestamp uses the reported measurement time",
  value("SENSOR_LAST_UPDATED"),
  os.date("%Y-%m-%d %H:%M:%S", seconds)
)
ReceivedFromProxy(500, "GET_SENSOR_VALUE")
T.eq("native readback resends the measured value", { notices[4].binding, notices[4].params.CELSIUS }, { 500, 0 })
report("state", "unknown")
T.eq(
  "unknown keeps last numeric value and clears availability",
  { value("Numeric Reading"), value("Available"), value("Reading"), value("Reading Is Numeric") },
  { 0, false, "Unavailable", false }
)
T.eq("temperature consumer sees an unavailable reading", notices[5].command, "VALUE_UNAVAILABLE")
T.eq(
  "legacy text goes unknown while the previous numeric reading is retained",
  { value("SENSOR_STATE"), value("SENSOR_STATE_INT"), value("SENSOR_STATE_FLOAT") },
  { "unknown", 0, 0 }
)
T.eq("native unknown is a distinct event", events, { 1002 })
report("snapshot", "68", { device_class = "temperature" })
T.eq("no guessed temperature unit", { #notices, value("Reading") }, { 5, "68" })
T.eq(
  "unit fallback is offered for a confirmed temperature without units",
  adapter.definition.offersProperty(adapter, "Unit Fallback"),
  true
)
Properties["Unit Fallback"] = "Fahrenheit"
OnPropertyChanged("Unit Fallback")
T.eq(
  "setting fallback reprojects latest confirmed reading",
  { value("Reading"), notices[7].params.CELSIUS },
  { "68 °F", 20 }
)
report("state", "20", { device_class = "temperature", unit_of_measurement = "°C" })
T.eq("reported unit wins over configured fallback", { value("Reading"), notices[8].params.CELSIUS }, { "20 °C", 20 })
T.eq("a reported unit hides the fallback", adapter.definition.offersProperty(adapter, "Unit Fallback"), false)
T.eq("changed value or unit signals programming", events, { 1002, 1000 })
report("state", "42", { device_class = "humidity", unit_of_measurement = "%" })
T.eq(
  "role change retires the old native reading",
  { notices[9].binding, notices[9].command },
  { 500, "VALUE_UNAVAILABLE" }
)
T.eq("humidity publication has percentage value", { notices[11].binding, notices[11].params.VALUE }, { 600, 42 })
report("state", "Comfortable")
T.eq("text readings stay strings", { value("Reading"), value("Reading Is Numeric") }, { "Comfortable", false })
T.eq("legacy Refresh Sensor requests only selected feedback", { EC.REFRESH(), refreshes }, { true, 1 })
clock.run(31000)
T.eq("a fresh sensor does not poll", refreshes, 1)
adapter:unbind()
T.eq("refresh without an endpoint is inert", { EC.REFRESH(), refreshes }, { false, 1 })

T.section("Generic Sensor resumes polling only with a saved opt-in")
Properties["Poll Timer"] = "On"
begin("ha.sensor-adapter", "sensor.indoor")
clock.run(29999)
T.eq("legacy poll waits a full interval", refreshes, 0)
clock.run(1)
T.eq("old opt-in refreshes the selected sensor", refreshes, 1)
Properties["Poll Timer"] = "Off"
OnPropertyChanged("Poll Timer")
clock.run(30000)
T.eq("turning the legacy setting off cancels the recurring refresh", refreshes, 1)
Properties["Poll Timer"] = "On"
begin("ha.sensor-adapter", "sensor.indoor")
adapter:destroy()
clock.run(30000)
T.eq("retiring the driver disposes of the legacy timer", refreshes, 0)

T.section("Fan power and nine discrete speeds use native commands and confirmed feedback")
begin("ha.fan-adapter", "fan.workshop")
metrics:setEnabled(true)
T.eq("fan has no control authority before the snapshot", ReceivedFromProxy(5001, "ON"), false)
report("snapshot", "on", { supported_features = 48 })
T.eq(
  "one speed presents native power without a percentage",
  { notices[4].params.SPEED, value("Speed Reported") },
  { 1, false }
)
T.check(
  "native fan setup reports one speed",
  ReceivedFromProxy(5001, "GET_SETUP"):find("<speeds_count>1</speeds_count>", 1, true)
)
ReceivedFromProxy(200, "DO_CLICK")
ReceivedFromProxy(201, "BUTTON_ACTION", { ACTION = "2" })
ReceivedFromProxy(202, "DO_RELEASE")
ReceivedFromProxy(202, "DO_CLICK")
T.eq("binary keypad routes one request per click", #requests, 3)
T.eq(
  "buttons map to the supported power actions",
  { requests[1].arguments.action, requests[2].arguments.action, requests[3].arguments.action },
  { "turn_on", "turn_off", "toggle" }
)
requests[3].promise:resolve({})
requests[2].promise:reject({ kind = "timeout" })
T.eq("an older completion cannot replace the latest request result", results, { "accepted" })
results = {}
local attributes = { supported_features = 49, percentage_step = 100 / 9, percentage = 22 }
report("state", "on", attributes)
T.check(
  "native fan setup reports nine speeds",
  ReceivedFromProxy(5001, "GET_SETUP"):find("<speeds_count>9</speeds_count>", 1, true)
)
T.eq(
  "native feedback maps percentage to reported level",
  { notices[#notices].params.SPEED, value("Speed Percent") },
  { 2, 22 }
)
local noteCount = #notices
ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "8" })
T.eq("native speed uses the HA percentage step boundary", requests[4].arguments.parameters.percentage, 88)
T.eq("exact target", requests[4].target, entity)
requests[4].promise:resolve({})
T.eq(
  "acceptance has no immediate effect on feedback",
  { #notices, value("Speed Percent"), results },
  { noteCount, 22, { "accepted" } }
)
attributes.percentage = 66
report("state", "on", attributes)
T.eq(
  "device reports a different speed from the command",
  { notices[#notices].params.SPEED, value("Speed Percent") },
  { 6, 66 }
)
ReceivedFromProxy(5001, "CYCLE_SPEED_DOWN")
T.eq("cycle uses last confirmed speed", requests[5].arguments.parameters.percentage, 55)
T.eq("optional direction is unavailable", ReceivedFromProxy(5001, "SET_DIRECTION"), nil)
T.eq("out-of-range speed is rejected locally", ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "10" }), false)
report("state", "unavailable")
requests[5].promise:resolve({})
T.eq("late acceptance cannot survive endpoint loss", results, { "accepted" })
T.eq("loss does not report an off speed", { value("Available"), notices[#notices].params.STATE }, { false, false })
T.eq("dispatch and feedback timing are distinct", {
  metrics:report().operations["fan.dispatch"].count,
  metrics:report().operations["fan.feedback"].count,
}, { 5, 4 })
adapter:destroy()
T.eq("destroy removes native handler", RFP[5001], nil)

T.section("Fan Programming options require relevant confirmed device capabilities")
metrics:setEnabled(false)
begin("ha.fan-adapter", "fan.workshop")
local function fanOptions()
  return GetCommandParamList("Set Fan Option", "Option")
end
local function chooseOption(option)
  return ExecuteCommand("Set Fan Option", { Option = option })
end
local reported = {
  supported_features = 48,
  oscillating = false,
  preset_modes = codec.array({ "sleep", "breeze", "sleep", false }),
  preset_mode = "sleep",
}
report("snapshot", "on", reported)
T.eq("a power-only fan offers no optional choices", fanOptions(), {})
T.eq("a stale program cannot enable an unsupported option", chooseOption("Oscillation on"), false)
reported.supported_features = 58
report("state", "on", reported)
T.eq(
  "optional settings are enumerated from verified state",
  fanOptions(),
  { "Oscillation on", "Oscillation off", "Preset · breeze", "Preset · sleep" }
)
T.eq(
  "confirmed optional state is available to Programming",
  { value("Oscillation state"), value("Fan preset") },
  { "Off", "sleep" }
)
T.eq("a preset outside the current list is rejected", chooseOption("Preset · unknown"), false)
chooseOption("Oscillation on")
chooseOption("Preset · breeze")
T.eq(
  "exact HA oscillation request",
  { requests[1].target, requests[1].arguments.action, requests[1].arguments.parameters },
  { entity, "oscillate", { oscillating = true } }
)
T.eq(
  "exact HA preset request",
  { requests[2].target, requests[2].arguments.action, requests[2].arguments.parameters },
  { entity, "set_preset_mode", { preset_mode = "breeze" } }
)
requests[2].promise:resolve({})
T.eq("acceptance leaves the confirmed preset alone", value("Fan preset"), "sleep")
reported.oscillating, reported.preset_mode = true, "breeze"
report("state", "on", reported)
T.eq(
  "new feedback publishes the actual settings",
  { value("Oscillation state"), value("Fan preset") },
  { "On", "breeze" }
)
report("state", "unavailable")
T.eq("an unavailable fan offers no optional choices", fanOptions(), {})
T.eq(
  "loss retires cached optional feedback",
  { value("Oscillation state"), value("Fan preset") },
  { "Unavailable", "" }
)
adapter:destroy()

T.section("Binary Sensor preserves contact polarity and both transitions through loss and reselection")
begin("ha.binary-sensor-adapter", "binary_sensor.window")
report("snapshot", "on", { device_class = "window" })
T.eq("initial active feedback is state only", { notices[1].command, value("State"), #events }, {
  "STATE_OPENED",
  "Open",
  0,
})
report("state", "off", { device_class = "window" })
report("state", "off", { device_class = "window" })
T.eq("duplicate inactive feedback cannot repeat an edge", { #notices, notices[2].command, events }, {
  2,
  "CLOSED",
  { 1001 },
})
T.eq("closed contact is confirmed and inactive", { TestCondition("IS_AVAILABLE"), TestCondition("IS_INACTIVE") }, {
  true,
  true,
})
adapter:message("readiness", { entity_id = entity, transport = true, subscription = false })
adapter:message("failure", { entity_id = entity })
T.eq("loss is reported once without changing the contact", { TestCondition("IS_AVAILABLE"), #notices, events }, {
  false,
  2,
  { 1001, 1002 },
})
report("snapshot", "on", { device_class = "window" })
T.eq("reconnection initializes even if the contact moved offline", { notices[3].command, #events }, {
  "STATE_OPENED",
  2,
})
local retiredContact = entity
entity = "binary_sensor.leak"
adapter:bind(consumer, entity)
report("state", "off", { device_class = "window" }, retiredContact)
T.eq("feedback from the previous selection cannot publish", { value("Available"), #notices, #events }, { false, 3, 2 })
report("snapshot", "off", { device_class = "moisture" })
T.eq("new selection initializes its class and contact", { value("State"), notices[4].command }, {
  "Dry",
  "STATE_CLOSED",
})
report("state", "on", { device_class = "moisture" })
T.eq("the selected contact publishes the active edge once", { value("State"), notices[5].command, events }, {
  "Wet",
  "OPENED",
  { 1001, 1002, 1000 },
})
adapter:destroy()
T.falsy("teardown removes the contact binding callback", OBC[1])

T.section("Generic Sensor overrides, native humidity readback and malformed measurements")
Properties["Sensor Type"], Properties["Unit Fallback"], Properties["Poll Timer"] = "Humidity", "None", "Off"
begin("ha.sensor-adapter", "sensor.reading")
report("snapshot", "0", {})
T.eq("explicit humidity makes an untyped zero routable", {
  value("Reading"),
  notices[2].binding,
  notices[2].params.SCALE,
  notices[2].params.VALUE,
}, {
  "0 %",
  600,
  "PERCENT",
  0,
})
ReceivedFromProxy(500, "GET_SENSOR_VALUE")
T.eq("an incompatible temperature readback produces no feedback", #notices, 2)
ReceivedFromProxy(600, "GET_SENSOR_VALUE")
T.eq("the humidity consumer can request the current reading", { notices[3].command, notices[4].params.VALUE }, {
  "VALUE_INITIALIZED",
  0,
})
OnBindingChanged(600, "HUMIDITY", true)
T.eq("a new humidity binding receives the current value", { notices[5].binding, notices[6].params.VALUE }, { 600, 0 })
report("state", "101", { unit_of_measurement = "%" })
T.eq("out-of-range humidity retires the native reading but preserves the typed state", {
  notices[7].command,
  value("Numeric Reading"),
  TestCondition("HAS_NUMERIC_READING"),
}, { "VALUE_UNAVAILABLE", 101, true })
report("state", "90", { unit_of_measurement = "ppm" })
T.eq("an incompatible unit remains a generic reading", { #notices, value("Reading") }, { 7, "90 ppm" })
Properties["Sensor Type"] = "Generic"
OnPropertyChanged("Sensor Type")
report("state", "50", { device_class = "humidity", unit_of_measurement = "%" })
T.eq("an explicit Generic choice suppresses inferred humidity", { #notices, value("Reading") }, { 7, "50 %" })
Properties["Sensor Type"] = "Temperature"
OnPropertyChanged("Sensor Type")
report("state", "273.15", { unit_of_measurement = "K" })
T.eq("Kelvin conversion preserves the source scale while publishing native temperature", {
  notices[9].binding,
  notices[9].params.CELSIUS,
  notices[9].params.FAHRENHEIT,
  notices[9].params.SCALE,
  notices[9].params.VALUE,
}, { 500, 0, 32, "KELVIN", 273.15 })
report("state", "1e999", { unit_of_measurement = "K" })
T.eq("a non-finite measurement cannot become native feedback", {
  notices[10].command,
  value("Numeric Reading"),
  TestCondition("IS_AVAILABLE"),
  TestCondition("HAS_NUMERIC_READING"),
}, { "VALUE_UNAVAILABLE", 273.15, false, false })
report("state", "broken\nreading")
T.eq("a malformed report cannot repeat a loss event", { #notices, events[#events] }, { 10, 1002 })
report("snapshot", "18", { unit_of_measurement = "°C" })
T.eq("a fresh reading recovers the selected sensor", { notices[11].command, notices[12].params.CELSIUS }, {
  "VALUE_INITIALIZED",
  18,
})

T.section("Fan percentage control rejects invalid requests and restores authority after reselection")
begin("ha.fan-adapter", "fan.workshop")
local speedFeature = { supported_features = 49, percentage_step = 1, percentage = 42 }
report("snapshot", "on", speedFeature)
T.check(
  "a continuous fan advertises percentage capability",
  ReceivedFromProxy(5001, "GET_SETUP"):find("<speeds_count>0</speeds_count>", 1, true)
)
T.eq(
  "the native query reports the current percentage",
  ReceivedFromProxy(5001, "GET_STATE"),
  "<fan_state><current_speed>42</current_speed></fan_state>"
)
T.eq("fractional and excessive speed are refused without dispatch", {
  ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "42.5" }),
  ReceivedFromProxy(5001, "SET_SPEED", { SPEED = 101 }),
  #requests,
}, { false, false, 0 })
T.truthy("a valid native percentage is accepted for dispatch", ReceivedFromProxy(5001, "SET_SPEED", { SPEED = 37 }))
T.eq("the native percentage passes through as an exact HA service parameter", requests[1].arguments.parameters, {
  percentage = 37,
})
requests[1].promise:reject({ kind = "rejected" })
T.eq("a rejected command leaves confirmed feedback intact", { results, value("Speed Percent") }, {
  { "rejected" },
  42,
})
ExecuteCommand("Toggle")
requests[2].promise:reject({ kind = "timeout" })
T.eq("Programming toggle reports timeout without moving speed", { requests[2].arguments.action, results }, {
  "toggle",
  { "rejected", "timeout" },
})
ReceivedFromProxy(5001, "SET_SPEED", { SPEED = 0 })
T.eq("speed zero maps to off", requests[3].arguments.action, "turn_off")
local retiredFan = entity
entity = "fan.replacement"
adapter:bind(consumer, entity, function(result)
  results[#results + 1] = result
end)
requests[3].promise:resolve({})
report("state", "on", speedFeature, retiredFan)
T.eq("changing the selection invalidates pending results and feedback", {
  results,
  value("Available"),
  ExecuteCommand("Turn On"),
}, { { "rejected", "timeout" }, false, false })
report("snapshot", "off", { supported_features = 48 })
T.truthy("power-only fan is ready for the first command", TestCondition("IS_AVAILABLE"))
ReceivedFromProxy(5001, "SET_SPEED", { SPEED = 1 })
T.eq("one native position controls only power on the replacement target", {
  requests[4].target,
  requests[4].arguments.action,
  requests[4].arguments.parameters,
}, { entity, "turn_on", {} })
requests[4].promise:resolve({})
T.eq("fresh acceptance stays separate from the replacement's confirmed off state", {
  results[#results],
  value("State"),
}, { "accepted", "Off" })
adapter:destroy()
T.finish()
