-- Standard Home Assistant covering features shared by the two native surfaces.
local M = {}

local features = {
  open_cover = 1,
  close_cover = 2,
  set_cover_position = 4,
  stop_cover = 8,
  open_cover_tilt = 16,
  close_cover_tilt = 32,
  stop_cover_tilt = 64,
  set_cover_tilt_position = 128,
}

local states = { open = "Open", closed = "Closed", opening = "Opening", closing = "Closing" }
local proxy, unknown = 5001, -1
local lift =
  { open = "open_cover", close = "close_cover", stop = "stop_cover", set = "set_cover_position", level = "position" }
local slats = {
  open = "open_cover_tilt",
  close = "close_cover_tilt",
  stop = "stop_cover_tilt",
  set = "set_cover_tilt_position",
  level = "tilt",
}

function M.supports(entity)
  return type(entity) == "string" and entity:match("^cover%.[a-z0-9_]+$") ~= nil
end

function M.percent(value)
  local number = tonumber(value)
  if number and number >= 0 and number <= 100 and number == math.floor(number) then
    return number
  end
end

function M.decode(state, attributes)
  if not states[state] then
    return nil
  end
  local flags = attributes.supported_features
  if type(flags) ~= "number" or flags < 0 or flags >= 2147483648 or flags ~= math.floor(flags) then
    flags = 0
  end
  return {
    status = state,
    label = states[state],
    flags = flags,
    position = M.percent(attributes.current_position),
    tilt = M.percent(attributes.current_tilt_position),
  }
end

function M.has(state, action)
  local flag = features[action]
  return flag ~= nil and state ~= nil and bit.band(state.flags, flag) ~= 0
end

local function hasLift(state)
  return M.has(state, lift.open) or M.has(state, lift.close) or M.has(state, lift.set)
end

local function nativeAxis(state, allowTilt)
  local mode = Properties["Control method"]
  if
    allowTilt
    and (
      mode == "Tilt"
      or mode ~= "Lift"
        and not hasLift(state)
        and (M.has(state, slats.open) or M.has(state, slats.close) or M.has(state, slats.set))
    )
  then
    return slats
  end
  return lift
end

local function positional(state, axis)
  local mode = Properties["Position control"]
  return state ~= nil
    and mode ~= "Open and close"
    and (M.has(state, axis.set) or mode == "Positional" and state[axis.level] ~= nil)
end

local function canSetPosition(state, axis)
  return Properties["Position control"] ~= "Open and close" and M.has(state, axis.set)
end

function M.offersProperty(adapter, name, allowTilt)
  if name ~= "Position control" and (name ~= "Control method" or not allowTilt) then
    return false
  end
  local state, mode = adapter:confirmed(), Properties[name]
  if name == "Position control" then
    return mode ~= nil and mode ~= "Automatic"
      or state ~= nil
        and (state.position ~= nil or M.has(state, lift.set) or allowTilt and (state.tilt ~= nil or M.has(
          state,
          slats.set
        )))
  end
  return mode ~= nil and mode ~= "Automatic"
    or state ~= nil
      and (state.tilt ~= nil or M.has(state, slats.open) or M.has(state, slats.close) or M.has(state, slats.set))
end

function M.command(adapter, action, value)
  local state = adapter:confirmed()
  if action == "toggle" and state then
    if state.status == "open" then
      action = "close_cover"
    elseif state.status == "closed" then
      action = "open_cover"
    else
      return false
    end
  end
  if action == lift.set or action == slats.set then
    local axis = action == slats.set and slats or lift
    local percent = M.percent(value)
    if not percent or not canSetPosition(state, axis) then
      return false
    end
    local key = axis == slats and "tilt_position" or "position"
    return adapter:command(action, { [key] = percent })
  end
  return M.has(state, action) and adapter:command(action, {})
end

local function movement(state, axis)
  if state and (axis == lift or not hasLift(state)) and (state.status == "opening" or state.status == "closing") then
    return state.status
  end
end

local function step(adapter, axis)
  local state = adapter:confirmed()
  if not state then
    return false
  elseif movement(state, axis) then
    return M.command(adapter, axis.stop)
  end
  local position = state[axis.level]
  if position == 0 or axis == lift and state.status == "closed" then
    return M.command(adapter, axis.open)
  elseif position == 100 or axis == lift and state.status == "open" and position == nil then
    return M.command(adapter, axis.close)
  elseif position and adapter.coverDirection then
    return M.command(adapter, adapter.coverDirection == "opening" and axis.close or axis.open)
  end
  return false
end

local function publishCapabilities(state, axis)
  C4:SendToProxy(proxy, "SET_CAN_STOP", { CAN_STOP = M.has(state, axis.stop) }, "NOTIFY")
  C4:SendToProxy(proxy, "SET_HAS_LEVEL", {
    HAS_LEVEL = positional(state, axis),
    LEVEL_OPEN = 100,
    LEVEL_CLOSED = 0,
    LEVEL_UNKNOWN = unknown,
    LEVEL_DISCRETE_CONTROL = canSetPosition(state, axis),
  }, "NOTIFY")
end

function M.installNative(adapter, allowTilt)
  adapter:handle(RFP, proxy, function(_, command, parameters)
    local state = adapter:confirmed()
    local axis = nativeAxis(state, allowTilt)
    if command == "SET_LEVEL_TARGET" then
      local target = M.percent(parameters.LEVEL_TARGET)
      if target and canSetPosition(state, axis) then
        return M.command(adapter, axis.set, target)
      elseif target == 0 or target == 100 then
        return M.command(adapter, target == 0 and axis.close or axis.open)
      end
      return false
    elseif command == "LEVEL_TOGGLE" or command == "TOGGLE" then
      if axis == lift then
        return M.command(adapter, "toggle")
      end
      return step(adapter, axis)
    end
    return M.command(adapter, ({ UP = axis.open, DOWN = axis.close, STOP = axis.stop })[command])
  end)
  adapter:handle(OPC, "Position_control", function()
    local state = adapter:confirmed()
    publishCapabilities(state, nativeAxis(state, allowTilt))
  end)
  if allowTilt then
    adapter:handle(OPC, "Control_method", function()
      local state = adapter:confirmed()
      if state and nativeAxis(state, allowTilt) ~= adapter.coverAxis then
        M.publishNative(adapter, state, nil, allowTilt)
      end
    end)
  end
  M.keypad(adapter, { [203] = "step" }, {}, allowTilt)
end

local function levelFor(state, axis, allowBlindEndpoints)
  if not state then
    return unknown
  end
  local level = state[axis.level]
  if level ~= nil then
    return level
  elseif axis == lift and state.status == "closed" then
    return 0
  elseif axis == lift and allowBlindEndpoints and state.status == "open" and not positional(state, axis) then
    return 100
  end
  return unknown
end

function M.publishNative(adapter, state, previous, allowTilt)
  local axis = nativeAxis(state, allowTilt)
  local oldAxis = nativeAxis(previous, allowTilt)
  local direction, oldDirection = movement(state, axis), movement(previous, oldAxis)
  if not state or adapter.coverAxis ~= axis then
    adapter.coverDirection = nil
  end
  if direction then
    adapter.coverDirection = direction
  end
  adapter.coverAxis = axis
  local hasPosition = positional(state, axis)
  if
    not previous
    or not state
    or previous.flags ~= state.flags
    or axis ~= oldAxis
    or hasPosition ~= positional(previous, oldAxis)
  then
    publishCapabilities(state, axis)
  end
  local level, oldLevel = levelFor(state, axis, allowTilt), levelFor(previous, oldAxis, allowTilt)
  if direction then
    if direction ~= oldDirection or axis ~= oldAxis then
      C4:SendToProxy(proxy, "MOVING", {
        LEVEL_TARGET = direction == "opening" and 100 or 0,
        LEVEL = level ~= unknown and level or nil,
        RAMP_RATE = 0,
      }, "NOTIFY")
    end
  elseif not previous or not state or oldLevel ~= level or oldDirection or axis ~= oldAxis then
    C4:SendToProxy(proxy, "STOPPED", { LEVEL = level }, "NOTIFY")
  end
  return levelFor(state, lift, allowTilt)
end

function M.keypad(adapter, bindings, buttonActions, allowTilt)
  local function receive(binding, command, parameters)
    local action
    if command == "DO_CLICK" then
      action = bindings[binding]
    elseif command == "BUTTON_ACTION" and tonumber(parameters.ACTION) == 2 then
      action = buttonActions[tonumber(parameters.BUTTON_ID)] or bindings[binding]
    end
    if action == "step" then
      return step(adapter, nativeAxis(adapter:confirmed(), allowTilt))
    end
    return action ~= nil and M.command(adapter, action)
  end
  for binding in pairs(bindings) do
    adapter:handle(RFP, binding, receive)
  end
end

return M
