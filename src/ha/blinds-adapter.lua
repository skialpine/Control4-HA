-- Maps one Home Assistant cover to Control4's blind and Programming controls.
local endpoint = require("ha.endpoint-adapter")
local cover = require("ha.cover-controls")
local values = require("lib.values")
local unknown = -1

local programming = {
  Open = "open_cover",
  Close = "close_cover",
  Stop = "stop_cover",
  Set_Position = "set_cover_position",
  Open_Tilt = "open_cover_tilt",
  Close_Tilt = "close_cover_tilt",
  Stop_Tilt = "stop_cover_tilt",
  Set_Tilt = "set_cover_tilt_position",
}

local function install(adapter)
  local function program(action)
    return function(parameters)
      return cover.command(adapter, action, parameters.Percent)
    end
  end
  for name, action in pairs(programming) do
    adapter:handle(EC, name, program(action))
  end
  cover.installNative(adapter, true)
  cover.keypad(
    adapter,
    { [200] = "open_cover", [201] = "close_cover", [202] = "toggle" },
    { [0] = "open_cover", [1] = "close_cover", [2] = "toggle" }
  )
end

local function publish(state, previous, _, adapter)
  values:update("Position", cover.publishNative(adapter, state, previous, true), "NUMBER")
  values:update("Tilt Position", state and state.tilt or unknown, "NUMBER")
end

local definition = {
  family = "blinds",
  supports = cover.supports,
  decode = function(state, attributes)
    if attributes.device_class ~= "garage" then
      return cover.decode(state, attributes)
    end
  end,
  install = install,
  offersProperty = function(adapter, name)
    return cover.offersProperty(adapter, name, true)
  end,
  publish = publish,
  same = function(state, previous)
    return state.status == previous.status
      and state.flags == previous.flags
      and state.position == previous.position
      and state.tilt == previous.tilt
  end,
}

return {
  new = function()
    return endpoint.new(definition)
  end,
}
