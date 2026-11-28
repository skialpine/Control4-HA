-- ThermostatV2 presentation and standard Home Assistant climate actions.
local endpoint = require("ha.endpoint-adapter")
local codec = require("ha.codec")
local values = require("lib.values")
local proxy = 5001

local modes = {
  off = "Off",
  heat = "Heat",
  cool = "Cool",
  heat_cool = "Heat/Cool",
  auto = "Auto",
  dry = "Dry",
  fan_only = "Fan Only",
}
local actions = {
  heating = "Heating",
  cooling = "Cooling",
  idle = "Idle",
  off = "Off",
  fan = "Fan",
  drying = "Drying",
  defrosting = "Defrosting",
  preheating = "Preheating",
}
local scales = { C = "C", CELSIUS = "C", F = "F", FAHRENHEIT = "F", ["°C"] = "C", ["°F"] = "F" }

local function scale(raw)
  return type(raw) == "string" and scales[raw:upper()] or nil
end

local function number(raw, low, high)
  local value = tonumber(raw)
  return value and value >= low and value <= high and value or nil
end

local function degrees(raw)
  return number(raw, -200, 500)
end

local function convert(value, from, to)
  if from == to then
    return value
  end
  return from == "C" and value * 9 / 5 + 32 or (value - 32) * 5 / 9
end

local function keys(raw, labels)
  local list, byLabel, allowed = {}, {}, {}
  if codec.isArray(raw) then
    for index = 1, math.min(#raw, 32) do
      local item = raw[index]
      if type(item) == "string" and #item <= 64 and item:match("^[%w][%w _%-]*$") then
        local label = not labels and item or labels[item]
        if label and not allowed[item] and not byLabel[label:lower()] then
          allowed[item], byLabel[label:lower()] = true, item
          list[#list + 1] = label
        end
      end
    end
  end
  return { allowed = allowed, byLabel = byLabel, list = list, csv = table.concat(list, ",") }
end

local function decode(state, attrs)
  if not modes[state] then
    return nil
  end
  local features = number(attrs.supported_features, 0, 2147483647) or 0
  local supported = function(flag)
    return features == math.floor(features) and bit.band(features, flag) ~= 0
  end
  return {
    label = modes[state],
    mode = state,
    action = actions[attrs.hvac_action],
    hvac = keys(attrs.hvac_modes, modes),
    fans = keys(supported(8) and attrs.fan_modes),
    fan = type(attrs.fan_mode) == "string" and attrs.fan_mode or nil,
    presets = keys(supported(16) and attrs.preset_modes),
    preset = type(attrs.preset_mode) == "string" and attrs.preset_mode or nil,
    unit = scale(attrs.temperature_unit) or scale(attrs.unit_of_measurement),
    temperature = degrees(attrs.current_temperature),
    minimum = degrees(attrs.min_temp),
    maximum = degrees(attrs.max_temp),
    step = number(attrs.target_temp_step, 0.01, 20),
    single = supported(1) and degrees(attrs.temperature) or nil,
    low = supported(2) and degrees(attrs.target_temp_low) or nil,
    high = supported(2) and degrees(attrs.target_temp_high) or nil,
    humidity = number(attrs.current_humidity, 0, 100),
    targetHumidity = supported(4) and number(attrs.humidity or attrs.target_humidity, 0, 100) or nil,
    minimumHumidity = number(attrs.min_humidity, 0, 100) or 0,
    maximumHumidity = number(attrs.max_humidity, 0, 100) or 100,
    canSetHumidity = supported(4),
  }
end

local function validRange(state)
  return state.low ~= nil and state.high ~= nil and state.low <= state.high
end

local function usesRange(state)
  return state and validRange(state) and (state.mode == "heat_cool" or state.single == nil)
end

local function equalRange(left, right)
  return left and right and left.low == right.low and left.high == right.high
end

local function sameRangeScope(adapter, intent, state)
  return usesRange(state)
    and adapter.generation == intent.generation
    and state.mode == intent.mode
    and state.unit == intent.unit
end

local function sendRange(adapter, intent, state)
  local requested = intent.desired
  if not state.minimum or not state.maximum or requested.low < state.minimum or requested.high > state.maximum then
    adapter.rangeIntent = nil
    return false
  end
  intent.inFlight, intent.baseline, intent.previous = true, state, intent.accepted
  local sent = adapter:command(
    "set_temperature",
    { target_temp_low = requested.low, target_temp_high = requested.high },
    function(status)
      if adapter.rangeIntent ~= intent then
        return
      end
      local current = adapter:confirmed()
      intent.inFlight = false
      if status ~= "accepted" or not sameRangeScope(adapter, intent, current) then
        adapter.rangeIntent = nil
      else
        intent.accepted = requested
        if not equalRange(requested, intent.desired) then
          -- Home Assistant requires a full pair. Wait for the first service
          -- result before sending the latest edits, even if feedback is delayed.
          sendRange(adapter, intent, current)
        elseif equalRange(current, requested) then
          adapter.rangeIntent = nil
        end
      end
    end
  )
  if not sent then
    adapter.rangeIntent = nil
  end
  return sent
end

local function setRangePoint(adapter, state, role, value)
  if role == "single" then
    return false
  end
  local intent = adapter.rangeIntent
  if intent then
    local awaitingFeedback = not equalRange(state, intent.desired)
      and (equalRange(state, intent.baseline) or equalRange(state, intent.previous))
    if not sameRangeScope(adapter, intent, state) or not intent.inFlight and not awaitingFeedback then
      adapter.rangeIntent = nil
      intent = nil
    end
  end
  local base = intent and intent.desired or state
  local low, high = role == "heat" and value or base.low, role == "cool" and value or base.high
  if low > high then
    return false
  end
  intent = intent or { generation = adapter.generation, mode = state.mode, unit = state.unit }
  intent.desired = { low = low, high = high }
  adapter.rangeIntent = intent
  return intent.inFlight or sendRange(adapter, intent, state)
end

local function target(state, parameters)
  local unit = state.unit
  if not unit or not state.minimum or not state.maximum then
    return nil
  end
  local preferred = unit == "C" and "CELSIUS" or "FAHRENHEIT"
  local alternative = unit == "C" and "FAHRENHEIT" or "CELSIUS"
  local value = degrees(parameters[preferred])
  if not value and parameters[preferred] == nil then
    local source = scale(alternative)
    value = degrees(parameters[alternative])
    if not value then
      source = scale(parameters.SCALE)
      value = degrees(parameters.SETPOINT)
    end
    if not value or not source then
      return nil
    end
    value = convert(value, source, unit)
  end
  if not value or value < state.minimum - 0.000001 or value > state.maximum + 0.000001 then
    return nil
  end
  if state.step then
    value = state.minimum + math.floor((value - state.minimum) / state.step + 0.5) * state.step
  end
  if value >= state.minimum and value <= state.maximum then
    return value
  end
end

local function setpoint(adapter, role, parameters)
  local state = adapter:confirmed()
  local value = state and target(state, parameters)
  if value == nil then
    return false
  end
  if usesRange(state) then
    return setRangePoint(adapter, state, role, value)
  end
  if state.single == nil or (role == "heat" and state.mode ~= "heat") or (role == "cool" and state.mode ~= "cool") then
    return false
  end
  return adapter:command("set_temperature", { temperature = value })
end

local function option(adapter, category, action, key, raw)
  local state = adapter:confirmed()
  local value = state
    and type(raw) == "string"
    and (state[category].allowed[raw] and raw or state[category].byLabel[raw:lower()])
  return type(value) == "string" and adapter:command(action, { [key] = value })
end

local function humidity(adapter, raw)
  local state = adapter:confirmed()
  local value = state and number(raw, state.minimumHumidity, state.maximumHumidity)
  return value ~= nil and state.canSetHumidity and adapter:command("set_humidity", { humidity = value })
end

local function install(adapter)
  adapter:handle(RFP, proxy, function(_, command, parameters)
    if command == "SET_MODE_HVAC" then
      return option(adapter, "hvac", "set_hvac_mode", "hvac_mode", parameters.MODE)
    elseif command == "SET_MODE_FAN" then
      return option(adapter, "fans", "set_fan_mode", "fan_mode", parameters.MODE)
    elseif command == "SET_SETPOINT_HEAT" then
      return setpoint(adapter, "heat", parameters)
    elseif command == "SET_SETPOINT_COOL" then
      return setpoint(adapter, "cool", parameters)
    elseif command == "SET_SETPOINT_SINGLE" then
      return setpoint(adapter, "single", parameters)
    end
    return false
  end)
  adapter:handle(EC, "Set_Comfort_Setting", function(parameters)
    return option(adapter, "presets", "set_preset_mode", "preset_mode", parameters.Mode)
  end)
  adapter:handle(GCPL, "Set_Comfort_Setting", function()
    local state = adapter:confirmed()
    return state and state.presets.list or {}
  end)
  adapter:handle(EC, "Set_Target_Humidity", function(parameters)
    return humidity(adapter, parameters.Percent)
  end)
end

local function notify(command, parameters)
  C4:SendToProxy(proxy, command, parameters, "NOTIFY")
end

local function temperatureCapabilities(state, range)
  local hasTarget = state and state.unit and (range or state.single ~= nil) or false
  local params = {
    HAS_SINGLE_SETPOINT = hasTarget and not range,
    HAS_HUMIDITY = state and state.humidity ~= nil or false,
    HAS_TEMPERATURE = state and state.unit ~= nil and state.temperature ~= nil or false,
  }
  if hasTarget and state.minimum and state.maximum then
    local limitTypes = range and { "HEAT", "COOL" } or { "SINGLE" }
    for _, role in ipairs(limitTypes) do
      for _, unit in ipairs({ "C", "F" }) do
        local key = role .. "_SETPOINT_"
        params[key .. "MIN_" .. unit] = convert(state.minimum, state.unit, unit)
        params[key .. "MAX_" .. unit] = convert(state.maximum, state.unit, unit)
        if state.step then
          params[key .. "RESOLUTION_" .. unit] = unit == state.unit and state.step
            or state.step * (unit == "F" and 9 / 5 or 5 / 9)
        end
      end
    end
  end
  return params
end

local function publish(state, previous, _, adapter)
  local intent = adapter.rangeIntent
  if
    intent
    and not intent.inFlight
    and sameRangeScope(adapter, intent, state)
    and equalRange(state, intent.accepted)
  then
    adapter.rangeIntent = nil
  end
  if not state or not previous then
    notify("CONNECTION", { CONNECTED = tostring(state ~= nil) })
  end
  if not state then
    values:update("Current HVAC action", "Unavailable", "STRING")
    values:update("Comfort Setting", "", "STRING")
    values:update("Target humidity", -1, "NUMBER")
    return
  end
  local prior = previous or {}
  local range = usesRange(state)
  local priorRange = usesRange(previous) or false
  local changedScale = state.unit ~= prior.unit
  if state.unit and changedScale then
    notify("SCALE_CHANGED", { SCALE = state.unit })
  end
  if
    changedScale
    or state.minimum ~= prior.minimum
    or state.maximum ~= prior.maximum
    or state.step ~= prior.step
    or range ~= priorRange
    or (state.single == nil) ~= (prior.single == nil)
    or (state.temperature == nil) ~= (prior.temperature == nil)
    or (state.humidity == nil) ~= (prior.humidity == nil)
  then
    notify("DYNAMIC_CAPABILITIES_CHANGED", temperatureCapabilities(state, range))
  end
  if not prior.hvac or state.hvac.csv ~= prior.hvac.csv then
    notify("ALLOWED_HVAC_MODES_CHANGED", { MODES = state.hvac.csv })
  end
  if not prior.fans or state.fans.csv ~= prior.fans.csv then
    notify("ALLOWED_FAN_MODES_CHANGED", { MODES = state.fans.csv })
  end
  if state.mode ~= prior.mode then
    notify("HVAC_MODE_CHANGED", { MODE = state.label })
  end
  if state.action and state.action ~= prior.action then
    notify("HVAC_STATE_CHANGED", { STATE = state.action })
  end
  if state.fan and state.fans.allowed[state.fan] and state.fan ~= prior.fan then
    notify("FAN_MODE_CHANGED", { MODE = state.fan })
  end
  if state.humidity ~= nil and state.humidity ~= prior.humidity then
    notify("HUMIDITY_CHANGED", { HUMIDITY = state.humidity })
  end
  if state.unit then
    if state.temperature and (changedScale or state.temperature ~= prior.temperature) then
      notify("TEMPERATURE_CHANGED", { TEMPERATURE = state.temperature, SCALE = state.unit })
    end
    if range then
      if changedScale or not priorRange or state.low ~= prior.low then
        notify("HEAT_SETPOINT_CHANGED", { SETPOINT = state.low, SCALE = state.unit })
      end
      if changedScale or not priorRange or state.high ~= prior.high then
        notify("COOL_SETPOINT_CHANGED", { SETPOINT = state.high, SCALE = state.unit })
      end
    elseif state.single and (changedScale or priorRange or state.single ~= prior.single) then
      notify("SINGLE_SETPOINT_CHANGED", { SETPOINT = state.single, SCALE = state.unit })
    end
  end
  values:update("Current HVAC action", state.action or "Unknown", "STRING")
  values:update(
    "Comfort Setting",
    state.preset and state.presets.allowed[state.preset] and state.preset or "",
    "STRING"
  )
  values:update("Target humidity", state.targetHumidity or -1, "NUMBER")
end

local stateFields = {
  "mode",
  "action",
  "fan",
  "preset",
  "unit",
  "temperature",
  "minimum",
  "maximum",
  "step",
  "single",
  "low",
  "high",
  "humidity",
  "targetHumidity",
  "minimumHumidity",
  "maximumHumidity",
  "canSetHumidity",
}
local definition = {
  family = "climate",
  supports = function(entity)
    return type(entity) == "string" and entity:match("^climate%.[a-z0-9_]+$") ~= nil
  end,
  decode = decode,
  install = install,
  publish = publish,
  same = function(state, previous)
    for _, field in ipairs(stateFields) do
      if state[field] ~= previous[field] then
        return false
      end
    end
    return state.hvac.csv == previous.hvac.csv
      and state.fans.csv == previous.fans.csv
      and state.presets.csv == previous.presets.csv
  end,
}

return {
  new = function()
    return endpoint.new(definition)
  end,
}
