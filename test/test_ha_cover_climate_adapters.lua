local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
local operations = require("ha.operations")
require("drivers-common-public.global.handlers")

local notes, events, requests, results
function C4:SendToProxy(binding, command, params)
  notes[#notes + 1] = { binding, command, params }
end
function C4:FireEventByID(id)
  events[#events + 1] = id
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

local function adapter(family, entity)
  notes, events, requests, results = {}, {}, {}, {}
  local owner = require("ha." .. family .. "-adapter").new()
  local consumer = { readiness = {} }
  function consumer.readiness:view(target)
    return { evidence_ready = target == entity }
  end
  function consumer:_current()
    return true
  end
  function consumer:request(operation, target, arguments)
    local result = deferred.new()
    requests[#requests + 1] = { rpc = assert(operations.build(operation, target, arguments)), result = result }
    return result
  end
  owner:start()
  owner:bind(consumer, entity, function(status)
    results[#results + 1] = status
  end)
  return owner,
    function(kind, state, attributes, target)
      owner:message(
        kind,
        codec.object({
          entity_id = target or entity,
          state = state,
          attributes = codec.object(attributes or {}),
        })
      )
    end,
    consumer
end

local function lastRequest()
  return requests[#requests].rpc
end

local function lastNote(command)
  for index = #notes, 1, -1 do
    if notes[index][2] == command then
      return notes[index][3]
    end
  end
end

T.section("Blind keypad, simple cover, and independent tilt")
local blind, sendBlind = adapter("blinds", "cover.study_shade")
sendBlind("snapshot", "closed", { supported_features = 3 })
T.falsy(
  "Unsupported mid-level request sends nothing",
  ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 40 })
)
T.falsy("Unsupported stop sends nothing", ReceivedFromProxy(5001, "STOP", {}))
T.eq("No writes yet", #requests, 0)
T.truthy("Open button runs the open service", ReceivedFromProxy(200, "DO_CLICK", {}))
T.eq("Open targets the selected cover", lastRequest().target.entity_id, "cover.study_shade")
T.eq("Open uses the native cover operation", lastRequest().service, "open_cover")
T.truthy(
  "Full open works in the discrete native editor",
  ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 100 })
)
sendBlind("state", "open", { supported_features = 255, current_position = 39, current_tilt_position = 27 })
T.eq("Current lift recorded independently", Variables.Position, "39")
T.eq("Current tilt recorded independently", Variables["Tilt Position"], "27")
T.truthy("Set tilt via Programming", ExecuteCommand("Set Tilt", { Percent = "65" }))
T.eq("Only tilt is commanded", lastRequest().service_data, { tilt_position = 65 })
requests[#requests].result:resolve({})
T.eq("HA acceptance reaches diagnostics", results, { "accepted" })
T.eq("Accepting a tilt request retains old tilt until HA confirms", Variables["Tilt Position"], "27")
sendBlind("state", "open", { supported_features = 255, current_position = 39, current_tilt_position = 65 })
T.eq("Tilt updates with HA feedback", Variables["Tilt Position"], "65")
T.eq("Tilt feedback leaves lift unchanged", Variables.Position, "39")
T.truthy(
  "Set independent lift through the native editor",
  ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = "80" })
)
T.eq("Only lift is commanded", lastRequest().service_data, { position = 80 })
blind:destroy()
T.eq("Destroy releases native route", RFP[5001], nil)

T.section("Blind movement and supported Programming controls")
blind, sendBlind = adapter("blinds", "cover.study_shade")
sendBlind("snapshot", "closed", { supported_features = 255, current_position = 0, current_tilt_position = 10 })
T.eq("Native discrete position and stop are enabled", {
  lastNote("SET_HAS_LEVEL").LEVEL_DISCRETE_CONTROL,
  lastNote("SET_CAN_STOP").CAN_STOP,
}, { true, true })
local blindActions = {
  { "Open", "open_cover" },
  { "Close", "close_cover" },
  { "Stop", "stop_cover" },
  { "Open Tilt", "open_cover_tilt" },
  { "Close Tilt", "close_cover_tilt" },
  { "Stop Tilt", "stop_cover_tilt" },
}
for _, action in ipairs(blindActions) do
  T.truthy(action[1] .. " sends a request", ExecuteCommand(action[1], {}))
  T.eq(
    action[1] .. " sends its own service without extra data",
    { lastRequest().service, lastRequest().service_data },
    {
      action[2],
      {},
    }
  )
end
T.truthy("Programming can set the lift position", ExecuteCommand("Set Position", { Percent = "35" }))
T.eq("Only the requested lift is sent", lastRequest().service_data, { position = 35 })
T.truthy("Close keypad link sends close", ReceivedFromProxy(201, "DO_CLICK", {}))
T.eq("Close link uses the selected cover", lastRequest().service, "close_cover")
T.truthy("Toggle keypad link opens a confirmed closed shade", ReceivedFromProxy(202, "DO_CLICK", {}))
T.eq("Toggle selects open from the confirmed state", lastRequest().service, "open_cover")
T.truthy("The native stop controls the shade", ReceivedFromProxy(5001, "STOP", {}))
T.eq("Native stop uses the supported service", lastRequest().service, "stop_cover")
local blindRequests = #requests
T.falsy(
  "A keypad press without a click does not move the shade",
  ReceivedFromProxy(202, "BUTTON_ACTION", { ACTION = 1 })
)
T.falsy("Fractional position is rejected", ExecuteCommand("Set Position", { Percent = "40.5" }))
T.falsy("Out-of-range tilt is rejected", ExecuteCommand("Set Tilt", { Percent = "101" }))
T.eq("The invalid inputs send nothing", #requests, blindRequests)
sendBlind("state", "opening", { supported_features = 255, current_position = 16, current_tilt_position = 10 })
T.eq("The native proxy receives confirmed movement", lastNote("MOVING").LEVEL, 16)
local nativeNotices = #notes
sendBlind("state", "opening", { supported_features = 255, current_position = 16, current_tilt_position = 10 })
T.eq("An identical report does not repeat native notifications", #notes, nativeNotices)
sendBlind("state", "open", { supported_features = 255, current_position = 35, current_tilt_position = 10 })
T.eq("A settled shade reports the confirmed intermediate position", lastNote("STOPPED").LEVEL, 35)
sendBlind("state", "unavailable")
T.eq("Signal loss clears the reported positions", { Variables.Position, Variables["Tilt Position"] }, { "-1", "-1" })
T.falsy("Movement is disabled until a fresh report", ExecuteCommand("Close", {}))
sendBlind("snapshot", "closed", { supported_features = 3 })
T.eq("Recovered simple shade refreshes the closed position", Variables.Position, "0")
T.falsy("Recovered simple shade does not expose discrete position", lastNote("SET_HAS_LEVEL").LEVEL_DISCRETE_CONTROL)
T.falsy("Recovered simple shade does not expose unsupported stop", lastNote("SET_CAN_STOP").CAN_STOP)
blind:destroy()

T.section("Legacy cover mode and native axis settings")
Properties["Position control"], Properties["Control method"] = "Automatic", "Automatic"
blind, sendBlind = adapter("blinds", "cover.study_shade")
sendBlind("snapshot", "open", { supported_features = 255, current_position = 30, current_tilt_position = 70 })
local function selectCoverProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end
T.truthy("A positional shade offers the position override", blind.definition.offersProperty(blind, "Position control"))
T.truthy("A shade with slats offers the native method", blind.definition.offersProperty(blind, "Control method"))
local priorStopNotice = lastNote("STOPPED")
selectCoverProperty("Position control", "Open and close")
T.falsy("Open and close removes intermediate movement", lastNote("SET_HAS_LEVEL").LEVEL_DISCRETE_CONTROL)
T.truthy("Stop remains available in the open and close mode", lastNote("SET_CAN_STOP").CAN_STOP)
T.eq("Position-mode edits do not repeat a native stop notification", lastNote("STOPPED"), priorStopNotice)
T.falsy("Intermediate target is refused", ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 50 }))
T.truthy("Full open still works", ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 100 }))
T.eq("Full open uses the open service", lastRequest().service, "open_cover")
blind:destroy()
blind, sendBlind = adapter("blinds", "cover.study_shade")
sendBlind("snapshot", "open", { supported_features = 255, current_position = 30, current_tilt_position = 70 })
T.falsy("The saved position mode applies after reload", lastNote("SET_HAS_LEVEL").LEVEL_DISCRETE_CONTROL)
selectCoverProperty("Position control", "Positional")
selectCoverProperty("Control method", "Tilt")
T.eq("Selecting tilt presents the confirmed slat level", lastNote("STOPPED").LEVEL, 70)
T.truthy("Native level sets the selected tilt axis", ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 82 }))
T.eq("Native level writes tilt", lastRequest().service_data, { tilt_position = 82 })
local priorMovingNotice = lastNote("MOVING")
sendBlind("state", "opening", { supported_features = 255, current_position = 46, current_tilt_position = 70 })
T.eq("Lift motion does not masquerade as tilt motion", lastNote("MOVING"), priorMovingNotice)
T.falsy("Partial tilt without direction does not guess a step", ReceivedFromProxy(203, "DO_CLICK"))
T.truthy("Explicit lift Programming still controls lift", ExecuteCommand("Set Position", { Percent = "40" }))
T.eq("Native axis choice leaves explicit lift Programming intact", lastRequest().service_data, { position = 40 })
selectCoverProperty("Control method", "Automatic")
sendBlind("state", "open", { supported_features = 3, current_position = 40 })
T.truthy("Positional shows a read-only HA level", lastNote("SET_HAS_LEVEL").HAS_LEVEL)
T.falsy("Read-only feedback does not enable intermediate requests", lastNote("SET_HAS_LEVEL").LEVEL_DISCRETE_CONTROL)
T.falsy("Positional preserves HA capability checks", ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 50 }))
T.truthy("Native LEVEL_TOGGLE routes control", ReceivedFromProxy(5001, "LEVEL_TOGGLE"))
T.eq("Native toggle requests close from open", lastRequest().service, "close_cover")
blind:destroy()
Properties["Position control"], Properties["Control method"] = nil, nil

T.section("Garage Door motion, loss, and reconnect")
Properties["Door status"] = "Unavailable"
local garage, sendGarage = adapter("garage", "cover.test_garage")
local garageAttrs = { device_class = "garage", supported_features = 3 }
sendGarage("snapshot", "closed", garageAttrs)
T.truthy("Closed limit is confirmed", TestCondition("IS_CLOSED"))
T.eq("No transitions on initial read", events, {})
OnBindingChanged(2, "CONTACT_SENSOR", true, 25, 1)
T.eq("A newly bound limit initializes without creating a transition", notes[#notes], { 2, "STATE_CLOSED", {} })
T.truthy("Relay Open is explicit", ReceivedFromProxy(4, "OPEN"))
T.eq("Uses HA Open", lastRequest().service, "open_cover")
sendGarage("state", "opening", garageAttrs)
T.falsy("Opening is not confirmed open", TestCondition("IS_OPEN"))
T.falsy("Opening is not confirmed closed", TestCondition("IS_CLOSED"))
T.eq("Door distinguishes opening", Properties["Door status"], "Opening")
T.falsy("Relay toggle does not guess a direction during movement", ReceivedFromProxy(4, "TOGGLE"))
T.eq("Toggle during movement sends no request", #requests, 1)
sendGarage("state", "unavailable", garageAttrs)
T.eq("Lost feedback displayed", Properties["Door status"], "Unavailable")
T.eq("Movement and loss are separate events", events, { 1002, 1004 })
T.eq("Neither limit asserts on loss", { Variables["Open limit"], Variables["Closed limit"] }, { "0", "0" })
requests[1].result:resolve({})
T.eq("A service response from before signal loss is retired", results, {})
sendGarage("snapshot", "open", garageAttrs)
T.eq("Opening without position still reports the door state", Properties["Door status"], "Open")
T.falsy("Missing position does not imply the fully open limit", TestCondition("IS_OPEN"))
T.truthy(
  "Native Toggle uses the confirmed door state even without position",
  ReceivedFromProxy(5001, "LEVEL_TOGGLE", {})
)
T.eq("Native Toggle closes the open door", lastRequest().service, "close_cover")
sendGarage("snapshot", "open", { device_class = "garage", supported_features = 3, current_position = 40 })
T.eq("Partly open is distinct from open limit", Properties["Door status"], "Partly open")
T.falsy("Partly open does not assert open limit", TestCondition("IS_OPEN"))
T.eq("Reconnect emits no phantom endpoint event", events, { 1002, 1004 })
sendGarage("state", "open", { device_class = "garage", supported_features = 3, current_position = 100 })
T.truthy("Confirmed limit is now fully open", TestCondition("IS_OPEN"))
T.eq("Open limit emits once", events, { 1002, 1004, 1000 })
T.truthy("Programming Toggle requests close from the confirmed open limit", ExecuteCommand("Toggle", {}))
T.eq("Toggle sends close to the selected door", { lastRequest().target.entity_id, lastRequest().service }, {
  "cover.test_garage",
  "close_cover",
})
sendGarage("state", "open", garageAttrs)
T.truthy("The native Closed button requests close", ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 0 }))
T.eq("Close uses the HA close action", lastRequest().service, "close_cover")
sendGarage("state", "closing", garageAttrs)
T.eq("Both limit contacts release while the door closes", { Variables["Open limit"], Variables["Closed limit"] }, {
  "0",
  "0",
})
sendGarage("state", "closed", garageAttrs)
sendGarage("state", "closed", garageAttrs)
T.eq("Closing and closed each emit once", events, { 1002, 1004, 1000, 1003, 1001 })
T.eq("Open and closed contacts are mutually exclusive", { Variables["Open limit"], Variables["Closed limit"] }, {
  "0",
  "1",
})
T.truthy("The relay trigger opens a confirmed closed door", ReceivedFromProxy(4, "TRIGGER"))
T.eq("Trigger uses the HA open service", lastRequest().service, "open_cover")
local beforeRelays = #requests
T.falsy("Releasing the open relay sends no command", ReceivedFromProxy(5, "OPEN"))
T.falsy("The stop relay is inactive without the HA Stop feature", ReceivedFromProxy(7, "PULSE"))
T.falsy("Unsupported position control sends no command", ExecuteCommand("Set Position", { Percent = "50" }))
T.eq("No writes for release or unsupported controls", #requests, beforeRelays)
T.truthy("The open relay closure requests Open", ReceivedFromProxy(5, "CLOSE"))
T.eq("The open relay sends only the open service", lastRequest().service, "open_cover")
T.truthy("The close relay pulse requests Close", ReceivedFromProxy(6, "PULSE"))
T.eq("The close relay sends only the close service", lastRequest().service, "close_cover")
sendGarage("state", "opening", { device_class = "garage", supported_features = 15 })
T.truthy("The stop relay pulse can stop a supported door", ReceivedFromProxy(7, "PULSE"))
T.eq("The stop relay sends only the stop service", lastRequest().service, "stop_cover")
T.truthy("Programming exposes Stop for the same selected door", ExecuteCommand("Stop", {}))
T.truthy("Programming accepts a supported intermediate position", ExecuteCommand("Set Position", { Percent = "50" }))
T.eq("The exact percentage goes to Home Assistant", lastRequest().service_data, { position = 50 })
T.falsy("Programming rejects a position outside the range", ExecuteCommand("Set Position", { Percent = "101" }))
sendGarage("state", "open", { device_class = "shade", supported_features = 3, current_position = 100 })
T.falsy("A shade report cannot assert either garage limit", TestCondition("IS_AVAILABLE"))
T.falsy("Garage Programming cannot command a non-garage report", ExecuteCommand("Open", {}))
garage:destroy()
T.eq(
  "Destroy releases relay, condition and button handlers",
  { RFP[4], RFP[5], RFP[6], RFP[7], TC.IS_OPEN, RFP[203] },
  {}
)

T.section("Garage door native position and step-by-step keypad")
garage, sendGarage = adapter("garage", "cover.test_garage")
local function doorReport(kind, state, position, flags)
  sendGarage(kind, state, { device_class = "garage", supported_features = flags or 15, current_position = position })
end
doorReport("snapshot", "closed", 0)
T.truthy("The first step opens a closed door", ReceivedFromProxy(203, "DO_CLICK"))
T.eq("Closed step requests open", lastRequest().service, "open_cover")
doorReport("state", "opening", 30)
T.truthy("The next step stops opening", ReceivedFromProxy(203, "BUTTON_ACTION", { ACTION = 2 }))
T.eq("Opening step requests stop", lastRequest().service, "stop_cover")
doorReport("state", "open", 30)
T.truthy("A stopped door can reverse the confirmed direction", ReceivedFromProxy(203, "DO_CLICK"))
T.eq("Reversing after opening requests close", lastRequest().service, "close_cover")
doorReport("state", "closing", 20)
T.truthy("The next step stops closing", ReceivedFromProxy(203, "DO_CLICK"))
T.eq("Closing step requests stop", lastRequest().service, "stop_cover")
doorReport("state", "open", 20)
T.truthy("A stopped closing door can go up again", ReceivedFromProxy(203, "DO_CLICK"))
T.eq("Reversing after closing requests open", lastRequest().service, "open_cover")
doorReport("state", "opening", 45, 7)
T.falsy("A step does not reverse motion without an available Stop", ReceivedFromProxy(203, "DO_CLICK"))
doorReport("state", "unavailable")
doorReport("snapshot", "open", 45)
T.falsy("A fresh partial position does not reuse a lost direction", ReceivedFromProxy(203, "DO_CLICK"))
T.truthy(
  "Garage accepts a native intermediate target",
  ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 55 })
)
T.eq("The requested target stays scoped to the door", { lastRequest().target.entity_id, lastRequest().service_data }, {
  "cover.test_garage",
  { position = 55 },
})
T.eq("The UI still reports the confirmed percentage", lastNote("STOPPED").LEVEL, 45)
selectCoverProperty("Position control", "Open and close")
T.falsy("The mode does not manufacture an open limit", TestCondition("IS_OPEN"))
T.falsy("The mode blocks intermediate Programming", ExecuteCommand("Set Position", { Percent = "55" }))
doorReport("state", "open", 100)
T.truthy("The open limit still requires confirmed 100%", TestCondition("IS_OPEN"))
garage:destroy()
Properties["Position control"] = nil

T.section("Thermostat native state, alternate units, and feedback")
local climate, sendClimate = adapter("climate", "climate.test_thermostat")
local attrs = {
  temperature_unit = "°C",
  supported_features = 15 + 16,
  hvac_modes = codec.array({ "off", "heat_cool", "heat", "cool", "auto" }),
  hvac_action = "heating",
  fan_mode = "auto",
  fan_modes = codec.array({ "auto", "high" }),
  preset_mode = "home",
  preset_modes = codec.array({ "home", "eco" }),
  current_temperature = 20,
  min_temp = 10,
  max_temp = 30,
  target_temp_step = 0.5,
  target_temp_low = 18,
  target_temp_high = 25,
  current_humidity = 40,
  min_humidity = 25,
  max_humidity = 70,
  humidity = 50,
}
sendClimate("snapshot", "heat_cool", attrs)
T.eq("Native controls initialize to the confirmed Celsius scale", lastNote("SCALE_CHANGED"), { SCALE = "C" })
T.eq("HVAC action readback", Variables["Current HVAC action"], "Heating")
T.eq("Humidity target readback", Variables["Target humidity"], "50")
T.truthy(
  "Fahrenheit input changes only the heating bound",
  ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { FAHRENHEIT = 68 })
)
T.eq("HA receives converted range", lastRequest().service_data, { target_temp_low = 20, target_temp_high = 25 })
T.falsy("Inverted range is rejected", ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = 16 }))
T.eq("Inverted range sends no write", #requests, 1)
requests[#requests].result:resolve({})
local before = #notes
attrs.target_temp_low = 20
sendClimate("state", "heat_cool", attrs)
T.eq("One range notification follows confirmed feedback", #notes, before + 1)
T.eq("Confirmation publishes the reported heating bound", notes[#notes], {
  5001,
  "HEAT_SETPOINT_CHANGED",
  { SETPOINT = 20, SCALE = "C" },
})
T.truthy("Auto remains distinct from Heat/Cool", ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Auto" }))
T.eq("Auto resolves to exact HA mode", lastRequest().service_data, { hvac_mode = "auto" })
T.truthy("Reported fan mode is selectable", ReceivedFromProxy(5001, "SET_MODE_FAN", { MODE = "high" }))
T.falsy("Unreported fan mode is rejected", ReceivedFromProxy(5001, "SET_MODE_FAN", { MODE = "low" }))
T.truthy("A reported HA preset is available to Programming", ExecuteCommand("Set Comfort Setting", { Mode = "eco" }))
T.eq("Preset is sent as an HA preset", lastRequest().service_data, { preset_mode = "eco" })
T.falsy("Humidity must fit the device limits", ExecuteCommand("Set Target Humidity", { Percent = "80" }))
T.truthy("Valid humidity request is sent", ExecuteCommand("Set Target Humidity", { Percent = "55" }))
T.eq("Humidity request uses HA's action", lastRequest().service_data, { humidity = 55 })
attrs.temperature_unit, attrs.temperature = nil, 21
attrs.target_temp_low, attrs.target_temp_high = nil, nil
sendClimate("state", "heat", attrs)
T.falsy(
  "Native setpoint is unavailable without authoritative units",
  ReceivedFromProxy(5001, "SET_SETPOINT_SINGLE", { CELSIUS = 22 })
)
T.truthy(
  "Missing temperature scale leaves HVAC mode control available",
  ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Off" })
)
attrs.temperature_unit = "°C"
sendClimate("state", "heat", attrs)
T.truthy("Single setpoint uses scalar field", ReceivedFromProxy(5001, "SET_SETPOINT_SINGLE", { CELSIUS = 22.25 }))
T.eq("Setpoint rounds to the reported step", lastRequest().service_data, { temperature = 22.5 })
sendClimate("state", "unavailable")
T.falsy(
  "Device unavailable means native control cannot send",
  ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Off" })
)
T.eq("The native thermostat is marked offline", lastNote("CONNECTION"), { CONNECTED = "false" })
T.eq("Unavailable thermostat exposes no stale comfort choices", GetCommandParamList("Set Comfort Setting", "Mode"), {})
attrs.temperature_unit, attrs.temperature = "°F", 68
attrs.current_temperature, attrs.min_temp, attrs.max_temp, attrs.target_temp_step = 69, 50, 86, 1
sendClimate("snapshot", "heat", attrs)
T.eq("Recovery marks the native thermostat online", lastNote("CONNECTION"), { CONNECTED = "true" })
T.eq("Native controls recover with the reported Fahrenheit scale", lastNote("SCALE_CHANGED"), { SCALE = "F" })
T.eq("The native proxy publishes the supported single setpoint", lastNote("SINGLE_SETPOINT_CHANGED"), {
  SETPOINT = 68,
  SCALE = "F",
})
T.eq("Recovered comfort settings use HA's reported options", GetCommandParamList("Set Comfort Setting", "Mode"), {
  "home",
  "eco",
})
T.truthy(
  "A Celsius command converts into the current Fahrenheit scale",
  ReceivedFromProxy(5001, "SET_SETPOINT_SINGLE", { CELSIUS = 21 })
)
T.eq("The Fahrenheit value is rounded to the reported step", lastRequest().service_data, { temperature = 70 })
local noticeCount = #notes
sendClimate("state", "heat", attrs)
T.eq("Identical Fahrenheit feedback does not repeat notifications", #notes, noticeCount)
attrs.temperature_unit, attrs.temperature = "°C", 20
attrs.current_temperature, attrs.min_temp, attrs.max_temp, attrs.target_temp_step = 21, 10, 30, 0.5
sendClimate("state", "heat", attrs)
T.eq("A live scale change updates the native controls", lastNote("SCALE_CHANGED"), { SCALE = "C" })
T.eq("Scale change refreshes the confirmed temperature", lastNote("TEMPERATURE_CHANGED"), {
  TEMPERATURE = 21,
  SCALE = "C",
})
climate:destroy()

T.section("Thermostat serializes full range writes before confirmed feedback")
attrs.temperature, attrs.target_temp_low, attrs.target_temp_high = nil, 18, 25
local function reportedRange(low, high)
  local report = {}
  for key, value in pairs(attrs) do
    report[key] = value
  end
  report.target_temp_low, report.target_temp_high = low, high
  return report
end
for _, first in ipairs({ "HEAT", "COOL" }) do
  local second = first == "HEAT" and "COOL" or "HEAT"
  local edits = { HEAT = 20, COOL = 24 }
  climate, sendClimate = adapter("climate", "climate.test_thermostat")
  sendClimate("snapshot", "heat_cool", attrs)
  T.truthy(
    first .. " can be edited first",
    ReceivedFromProxy(5001, "SET_SETPOINT_" .. first, { CELSIUS = edits[first] })
  )
  T.eq(first .. " initially keeps the confirmed opposite bound", lastRequest().service_data, {
    target_temp_low = first == "HEAT" and 20 or 18,
    target_temp_high = first == "COOL" and 24 or 25,
  })
  T.truthy(
    second .. " can be edited before either result",
    ReceivedFromProxy(5001, "SET_SETPOINT_" .. second, { CELSIUS = edits[second] })
  )
  T.eq("Only one range write is in flight", #requests, 1)
  requests[1].result:resolve({})
  T.eq("The next service merges both changes into the same pair", lastRequest().service_data, {
    target_temp_low = 20,
    target_temp_high = 24,
  })
  T.eq("The edits have not been published as confirmed", {
    lastNote("HEAT_SETPOINT_CHANGED").SETPOINT,
    lastNote("COOL_SETPOINT_CHANGED").SETPOINT,
  }, { 18, 25 })
  requests[2].result:resolve({})
  sendClimate("state", "heat_cool", reportedRange(20, 24))
  T.eq("Confirmed feedback updates both native bounds", {
    lastNote("HEAT_SETPOINT_CHANGED").SETPOINT,
    lastNote("COOL_SETPOINT_CHANGED").SETPOINT,
  }, { 20, 24 })
  climate:destroy()
end

T.section("Thermostat acceptance, failure and selection changes preserve the authoritative range")
local consumer
climate, sendClimate, consumer = adapter("climate", "climate.test_thermostat")
sendClimate("snapshot", "heat_cool", attrs)
T.truthy(
  "The first heat edit can be accepted before feedback",
  ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = 20 })
)
requests[1].result:resolve({})
T.truthy("A cool edit before feedback is available", ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = 24 }))
T.eq("The accepted heat edit remains in the pending pair", lastRequest().service_data, {
  target_temp_low = 20,
  target_temp_high = 24,
})
requests[2].result:resolve({})
sendClimate("state", "heat_cool", reportedRange(20, 25))
T.truthy(
  "A delayed first acknowledgement allows another edit",
  ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = 21 })
)
T.eq("The delayed first feedback cannot undo the accepted cool edit", lastRequest().service_data, {
  target_temp_low = 21,
  target_temp_high = 24,
})
T.truthy(
  "Another cool edit waits behind the active request",
  ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = 23 })
)
requests[3].result:reject({ kind = "rejected" })
T.eq("A rejected write discards its dependent follow-up", #requests, 3)
T.eq("The original rejection still reaches command feedback", results[#results], "rejected")
T.truthy(
  "A subsequent cool edit can start from confirmed state",
  ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = 24 })
)
T.eq("A rejected heat edit cannot change the opposite bound on retry", lastRequest().service_data, {
  target_temp_low = 20,
  target_temp_high = 24,
})
T.truthy("A heat edit queues before replacement", ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = 21 }))
local replacement = "climate.replacement"
function consumer.readiness:view(target)
  return { evidence_ready = target == replacement }
end
climate:bind(consumer, replacement)
requests[4].result:resolve({})
T.eq("Retired command acceptance cannot dispatch a queued edit to the replacement", #requests, 4)
sendClimate("snapshot", "heat_cool", reportedRange(16, 27), replacement)
T.truthy("The new thermostat uses its own range", ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = 25 }))
T.eq("The retired pair cannot contaminate the new thermostat's range", lastRequest().service_data, {
  target_temp_low = 16,
  target_temp_high = 25,
})
T.eq("The new command belongs to the replacement thermostat", lastRequest().target.entity_id, replacement)
requests[5].result:resolve({})
sendClimate("state", "heat_cool", reportedRange(17, 26), replacement)
T.truthy(
  "The replacement can be controlled after an external range change",
  ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = 18 })
)
T.eq("Authoritative external feedback overrides earlier accepted values", lastRequest().service_data, {
  target_temp_low = 18,
  target_temp_high = 26,
})
requests[6].result:resolve({})
sendClimate("state", "heat_cool", reportedRange(18, 26), replacement)
sendClimate("state", "heat_cool", reportedRange(17, 26), replacement)
T.truthy(
  "a cool edit starts after confirmation and a later external return to the earlier range",
  ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = 25 })
)
T.eq("a confirmed old intent cannot overwrite the externally changed heat bound", lastRequest().service_data, {
  target_temp_low = 17,
  target_temp_high = 25,
})
climate:destroy()

T.finish()
