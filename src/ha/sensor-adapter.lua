-- Typed readings and native temperature and humidity outputs.
require("lib.utils")
require("drivers-common-public.global.timer")
local Adapter = require("ha.endpoint-adapter")
local codec = require("ha.codec")
local values = require("lib.values")

local temperature, humidity = 500, 600
local types = { Temperature = "temperature", Humidity = "humidity" }
local fallbackUnits = { Celsius = "°C", Fahrenheit = "°F" }
local temperatureScales = { ["°C"] = "CELSIUS", ["°F"] = "FAHRENHEIT", K = "KELVIN" }
local definition = { family = "sensor" }
local pollTimer = "HA.GenericSensor.LegacyPoll"
local legacyVariables = {
  { "SENSOR_STATE", "STRING" },
  { "SENSOR_STATE_INT", "INT" },
  { "SENSOR_STATE_FLOAT", "FLOAT" },
  { "SENSOR_LAST_UPDATED", "STRING" },
}

function definition.restoreVariables()
  for _, entry in ipairs(legacyVariables) do
    local name, kind = unpack(entry)
    if not values:getValue(name) then
      values:update(name, Variables[name] or "", kind, true)
    end
  end
end

function definition.supports(entity)
  return type(entity) == "string" and entity:match("^sensor%.[a-z0-9_]+$") ~= nil
end

local function plainText(value, limit)
  if type(value) == "string" and #value <= limit and not value:find("%c") then
    return value:match("^%s*(.-)%s*$")
  end
end

local function project(raw, unit, deviceClass)
  local numeric = tonumber(raw)
  local number = tofinite(numeric)
  if numeric ~= nil and number == nil then
    return nil
  end
  local configuredType = Properties["Sensor Type"]
  local role = types[configuredType] or (configuredType ~= "Generic" and deviceClass or nil)
  local displayedUnit = unit
  local binding, scale
  local fallback = role == "temperature" and unit == ""
  if role == "temperature" then
    if fallback then
      displayedUnit = fallbackUnits[Properties["Unit Fallback"]] or ""
    end
    local reportedScale = temperatureScales[displayedUnit]
    if number ~= nil and ToCelsius(number, reportedScale) ~= nil then
      binding, scale = temperature, reportedScale
    end
  elseif role == "humidity" and number and number >= 0 and number <= 100 and (unit == "%" or unit == "") then
    binding, scale, displayedUnit = humidity, "PERCENT", "%"
  end
  return {
    raw = raw,
    reportedUnit = unit,
    deviceClass = deviceClass,
    label = displayedUnit ~= "" and (raw .. " " .. displayedUnit) or raw,
    number = number,
    binding = binding,
    scale = scale,
    unit = displayedUnit,
    canUseFallback = fallback,
  }
end

function definition.decode(raw, attributes)
  local reading = plainText(raw, 255)
  if reading and reading ~= "" then
    return project(reading, plainText(attributes.unit_of_measurement, 40) or "", attributes.device_class)
  end
end

function definition.same(current, previous)
  return current.raw == previous.raw
    and current.reportedUnit == previous.reportedUnit
    and current.deviceClass == previous.deviceClass
    and current.binding == previous.binding
    and current.unit == previous.unit
    and current.canUseFallback == previous.canUseFallback
end

local function sendReading(state, initialize)
  local params = SensorValueParams(state.number, state.scale)
  if initialize then
    C4:SendToProxy(state.binding, "VALUE_INITIALIZED", { STATUS = "active", TIMESTAMP = params.TIMESTAMP }, "NOTIFY")
  end
  C4:SendToProxy(state.binding, "VALUE_CHANGED", params, "NOTIFY")
end

function definition.offersProperty(adapter, name)
  local state = adapter.state
  if name == "Poll Timer" then
    return adapter.legacyPolling and Properties["Poll Timer"] == "On"
  end
  return state ~= nil and (name == "Sensor Type" or name == "Unit Fallback" and state.canUseFallback)
end

function definition.observe(data)
  local timestamp = data.last_updated
  if type(timestamp) == "string" and #timestamp <= 64 then
    local ok, _, seconds = pcall(C4.ParseIso8601DateTime, C4, timestamp, true)
    if ok and tofinite(seconds) then
      local formatted = os.date("%Y-%m-%d %H:%M:%S", seconds)
      values:update("SENSOR_LAST_UPDATED", formatted, "STRING")
      UpdateProperty("Last Updated", formatted)
    end
  end
  if data.state == "unavailable" or data.state == "unknown" then
    values:update("SENSOR_STATE", data.state, "STRING")
    if data.state == "unknown" then
      UpdateProperty("Value", data.state)
    end
  end
end

function definition.install(adapter)
  local function refresh()
    return adapter.consumer ~= nil and adapter.entity ~= nil and adapter.consumer:refreshSelected()
  end
  -- Resume a previously saved opt-in. The property is hidden on fresh installations.
  adapter.legacyPolling = Properties["Poll Timer"] == "On"
  local function pollChanged()
    if adapter.legacyPolling and Properties["Poll Timer"] == "On" then
      SetTimer(pollTimer, 30000, refresh, true)
    else
      CancelTimer(pollTimer)
    end
  end
  pollChanged()
  local function settingChanged()
    local state = adapter:confirmed()
    if state then
      adapter:message(
        "snapshot",
        codec.object({
          entity_id = adapter.entity,
          state = state.raw,
          attributes = codec.object({
            unit_of_measurement = state.reportedUnit,
            device_class = state.deviceClass,
          }),
        })
      )
    end
  end
  adapter:handle(OPC, "Sensor_Type", settingChanged)
  adapter:handle(OPC, "Unit_Fallback", settingChanged)
  adapter:handle(OPC, "Poll_Timer", pollChanged)
  adapter:handle(EC, "REFRESH", refresh)
  adapter:handle(TC, "IS_AVAILABLE", function()
    return adapter:confirmed() ~= nil
  end)
  adapter:handle(TC, "HAS_NUMERIC_READING", function()
    local state = adapter:confirmed()
    return state ~= nil and state.number ~= nil
  end)
  local function readback(binding)
    local state = adapter:confirmed()
    if state and state.binding == binding then
      sendReading(state, true)
    end
  end
  for _, binding in ipairs({ temperature, humidity }) do
    adapter:handle(RFP, binding, function(id, command)
      if command == "GET_SENSOR_VALUE" then
        readback(id)
      end
    end)
    adapter:handle(OBC, binding, function(id, _, isBound)
      if isBound then
        readback(id)
      end
    end)
  end
end

function definition.destroy()
  CancelTimer(pollTimer)
end

function definition.publish(state, previous, kind)
  values:update("Reading", state and state.label or "Unavailable", "STRING")
  values:update("Reading Unit", state and state.unit or "", "STRING")
  values:update("Reading Is Numeric", state ~= nil and state.number ~= nil, "BOOL")
  if state then
    values:update("SENSOR_STATE", state.raw, "STRING")
    UpdateProperty("Value", state.raw)
  end
  if state and state.number ~= nil then
    values:update("Numeric Reading", state.number, "NUMBER")
    -- The legacy integer alias rounded toward +infinity at an exact half step.
    values:update("SENSOR_STATE_INT", math.floor(state.number + 0.5), "INT")
    values:update("SENSOR_STATE_FLOAT", state.number, "FLOAT")
  end
  if previous and previous.binding and (not state or state.binding ~= previous.binding) then
    C4:SendToProxy(previous.binding, "VALUE_UNAVAILABLE", { STATUS = "offline" }, "NOTIFY")
  end
  if state and state.binding then
    sendReading(state, not previous or state.binding ~= previous.binding)
  end
  if kind == "lost" then
    C4:FireEventByID(1002)
  elseif kind == "state" and previous and (state.raw ~= previous.raw or state.unit ~= previous.unit) then
    C4:FireEventByID(1000)
  end
end

return {
  new = function()
    return Adapter.new(definition)
  end,
}
