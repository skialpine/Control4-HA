-- Native fan control based on the capabilities and speed reported by Home Assistant.
require("lib.utils")
local bit = require("bit")
local codec = require("ha.codec")
local Adapter = require("ha.endpoint-adapter")
local values = require("lib.values")

local proxy = 5001
local power = { ON = "turn_on", OFF = "turn_off", TOGGLE = "toggle" }
local buttons = { [200] = "turn_on", [201] = "turn_off", [202] = "toggle" }
local definition = { family = "fan" }
local setSpeedFeature, oscillateFeature, presetFeature = 1, 2, 8
local oscillationOn, oscillationOff, presetPrefix = "Oscillation on", "Oscillation off", "Preset · "

function definition.supports(entity)
  return type(entity) == "string" and entity:match("^fan%.[a-z0-9_]+$") ~= nil
end

local function percent(value)
  if type(value) == "number" and value >= 0 and value <= 100 and value == math.floor(value) then
    return value
  end
end

local function reportedFeatures(features)
  if type(features) ~= "number" or features < 0 or features > 2147483647 or features ~= math.floor(features) then
    return 0
  end
  return features
end

local function levels(features, step)
  if bit.band(features, setSpeedFeature) == 0 then
    return 1
  end
  if type(step) == "number" and step >= 1 and step <= 100 then
    local count = 100 / step
    local rounded = math.floor(count + 0.5)
    if rounded <= 9 and math.abs(count - rounded) < 0.01 then
      return rounded
    end
  end
  -- Zero is the fan proxy capability for a percentage scale.
  return 0
end

local function presetModes(features, raw)
  if bit.band(features, presetFeature) == 0 or not codec.isArray(raw) or #raw > 64 then
    return {}
  end
  local names, seen = {}, {}
  for _, name in ipairs(raw) do
    if type(name) == "string" and #name > 0 and #name <= 120 and not name:find("%c") and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names, seen
end

function definition.decode(raw, attributes)
  if raw ~= "on" and raw ~= "off" then
    return nil
  end
  local features = reportedFeatures(attributes.supported_features)
  local count = levels(features, attributes.percentage_step)
  local on = raw == "on"
  local percentage, speed
  if not on then
    percentage, speed = 0, 0
  elseif count == 1 then
    speed = 1
  else
    local reported = percent(attributes.percentage)
    if reported and reported > 0 then
      percentage = reported
      speed = count == 0 and percentage or math.max(1, math.floor(percentage * count / 100 + 0.5))
    end
  end
  local label = not on and "Off" or percentage and ("On · " .. percentage .. "%") or "On"
  local canOscillate = bit.band(features, oscillateFeature) ~= 0
  local oscillating
  if canOscillate and type(attributes.oscillating) == "boolean" then
    oscillating = attributes.oscillating
  end
  local presets, known = presetModes(features, attributes.preset_modes)
  return {
    on = on,
    percentage = percentage,
    speed = speed,
    levels = count,
    label = label,
    canOscillate = canOscillate,
    oscillating = oscillating,
    presets = presets,
    preset = known and known[attributes.preset_mode] and attributes.preset_mode or nil,
  }
end

function definition.same(current, previous)
  return current.on == previous.on
    and current.percentage == previous.percentage
    and current.speed == previous.speed
    and current.levels == previous.levels
    and current.canOscillate == previous.canOscillate
    and current.oscillating == previous.oscillating
    and current.preset == previous.preset
    and table.concat(current.presets, "\n") == table.concat(previous.presets, "\n")
end

local function options(state)
  local list = {}
  if state then
    if state.canOscillate then
      list[#list + 1] = oscillationOn
      list[#list + 1] = oscillationOff
    end
    for _, name in ipairs(state.presets) do
      list[#list + 1] = presetPrefix .. name
    end
  end
  return list
end

local function setOption(adapter, option)
  local state = adapter:confirmed()
  if not state or type(option) ~= "string" then
    return false
  end
  if state.canOscillate and (option == oscillationOn or option == oscillationOff) then
    return adapter:command("oscillate", { oscillating = option == oscillationOn })
  end
  for _, name in ipairs(state.presets) do
    if option == presetPrefix .. name then
      return adapter:command("set_preset_mode", { preset_mode = name })
    end
  end
  return false
end

local function setSpeed(adapter, state, speed)
  local max = state.levels == 0 and 100 or state.levels
  if not speed or speed < 0 or speed > max or speed ~= math.floor(speed) then
    return false
  end
  if speed == 0 then
    return adapter:command("turn_off", {})
  elseif state.levels == 1 then
    return adapter:command("turn_on", {})
  end
  -- Home Assistant maps each ordered speed to its integer percentage boundary.
  local percentage = state.levels == 0 and speed or math.floor(speed * 100 / state.levels)
  return adapter:command("set_percentage", { percentage = percentage })
end

local function publishProxy(state, previous)
  if not state or not previous then
    C4:SendToProxy(proxy, "ONLINE_CHANGED", { STATE = state ~= nil }, "NOTIFY")
  end
  if not state then
    return
  end
  if not previous or state.levels ~= previous.levels then
    C4:SendToProxy(proxy, "DYNAMIC_CAPABILITIES_CHANGED", { DISCRETE_LEVELS = state.levels }, "NOTIFY")
  end
  if state.speed ~= nil and (not previous or state.speed ~= previous.speed or state.levels ~= previous.levels) then
    C4:SendToProxy(proxy, "CURRENT_SPEED", { SPEED = state.speed }, "NOTIFY")
  end
end

function definition.install(adapter)
  local commands = { Turn_On = power.ON, Turn_Off = power.OFF, Toggle = power.TOGGLE }
  for name, action in pairs(commands) do
    adapter:handle(EC, name, function()
      return adapter:command(action, {})
    end)
  end
  adapter:handle(GCPL, "Set_Fan_Option", function(parameter)
    return parameter == "Option" and options(adapter:confirmed()) or {}
  end)
  adapter:handle(EC, "Set_Fan_Option", function(params)
    return setOption(adapter, params.Option)
  end)
  for binding, action in pairs(buttons) do
    adapter:handle(RFP, binding, function(_, command, params)
      if command == "DO_CLICK" or (command == "BUTTON_ACTION" and tonumber(params.ACTION) == 2) then
        return adapter:command(action, {})
      end
    end)
  end
  adapter:handle(TC, "IS_AVAILABLE", function()
    return adapter:confirmed() ~= nil
  end)
  adapter:handle(RFP, proxy, function(_, command, params)
    if power[command] then
      return adapter:command(power[command], {})
    end
    local state = adapter:confirmed()
    if command == "GET_CURRENT_STATE" then
      publishProxy(state)
    elseif command == "GET_SETUP" then
      local count = state and state.levels or 1
      return (
        "<fan_setup><speeds_count>%d</speeds_count><can_reverse>false</can_reverse>"
        .. "<can_set_preset>false</can_set_preset></fan_setup>"
      ):format(count)
    elseif command == "GET_STATE" then
      if state and state.speed then
        return ("<fan_state><current_speed>%d</current_speed></fan_state>"):format(state.speed)
      end
    elseif state and command == "SET_SPEED" then
      return setSpeed(adapter, state, tonumber(params.SPEED))
    elseif state and state.speed and state.levels > 1 then
      if command == "CYCLE_SPEED_UP" and state.speed < state.levels then
        return setSpeed(adapter, state, state.speed + 1)
      elseif command == "CYCLE_SPEED_DOWN" and state.speed > 0 then
        return setSpeed(adapter, state, state.speed - 1)
      end
    end
  end)
end

function definition.publish(state, previous, kind)
  values:update("Speed Reported", state ~= nil and state.percentage ~= nil, "BOOL")
  if state and state.percentage ~= nil then
    values:update("Speed Percent", state.percentage, "NUMBER")
  end
  if
    (state and state.canOscillate)
    or (previous and previous.canOscillate)
    or (kind == "initial" and values:getValue("Oscillation state"))
  then
    local oscillating = state and state.oscillating
    local status = oscillating == true and "On" or oscillating == false and "Off" or "Unavailable"
    values:update("Oscillation state", status, "STRING")
  end
  if
    (state and #state.presets > 0)
    or (previous and #previous.presets > 0)
    or (kind == "initial" and values:getValue("Fan preset"))
  then
    values:update("Fan preset", state and state.preset or "", "STRING")
  end
  publishProxy(state, previous)
  if kind == "lost" then
    C4:FireEventByID(1002)
  end
end

return {
  new = function()
    return Adapter.new(definition)
  end,
}
