-- Two independent Lua VMs boot the same extracted Light package. Only Director's
-- persisted rows cross the boundary. No HA device or linked keypad is required.
return function(driver, phase, filename)
  local keys = {
    "preset_level",
    "brightness_presets",
    "brightness_on_mode",
    "brightness_on_mode_preset",
    "click_rate_up",
    "click_rate_down",
    "hold_rate_up",
    "hold_rate_down",
    "button_colors",
  }
  if phase == "reload" then
    local file = assert(io.open(filename))
    for _, key in ipairs(keys) do
      local kind, encoded = assert(file:read("*l"), key):match("^(%a+) (.*)$")
      local value = C4:Base64Decode(encoded)
      C4:PersistSetValue(key, kind == "number" and tonumber(value) or value)
    end
    file:close()
    ShimPersistLand()
  end
  local colors = {}
  function C4:SendToProxy(binding, command, params)
    if command == "BUTTON_COLORS" then
      colors[binding] = params
    end
  end
  local deviceCommands = 0
  function C4:SendToDevice()
    deviceCommands = deviceCommands + 1
  end
  local setupReads = 0
  if phase == "edit" then
    local proxy = require("light_proxy_fake")
    local setup = proxy.setupFile("setup-607.xml")
    local device = C4:GetDeviceID()
    ShimSetDevices({
      [device] = { proxies = { [proxy.PROXY_DEVICE] = {} } },
      [proxy.PROXY_DEVICE] = { driverFileName = "light_v2.c4i", protocol = { [device] = {} } },
    })
    ShimSetUIRequest(function(id, request)
      if tonumber(id) == proxy.PROXY_DEVICE and request == "GET_SETUP" then
        setupReads = setupReads + 1
        return setup
      end
      return ""
    end)
  end
  assert(loadfile(driver))()
  OnDriverInit()
  ShimLateInit()
  local settings = require("lib.light.settings").new({ onModes = true })
  if phase == "edit" then
    assert(setupReads > 0 and settings:previousOnLevel() == 20, "Startup did not read the native setup fixture")
    local function send(command, params)
      ReceivedFromProxy(5001, command, params)
    end
    -- Director sends Default On twice and then reports the updated preset (light_proxy_fake).
    send("SET_PRESET_LEVEL", { LEVEL = "64" })
    send("SET_PRESET_LEVEL", { LEVEL = "64" })
    send("UPDATE_BRIGHTNESS_PRESET", { ID = "1", COMMAND = "MODIFIED", NAME = "On", LEVEL = "64" })
    send("SET_BRIGHTNESS_ON_MODE", { PRESET_ID = "1" })
    assert(settings:onModeLevel() == 64, "Default On did not select its edited preset")
    send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = "10", BRIGHTNESS_PRESET_LEVEL = "42" })
    send("UPDATE_BRIGHTNESS_PRESET", { ID = "10", COMMAND = "MODIFIED", NAME = "Previous On", LEVEL = "37" })
    send("SET_CLICK_RATE_UP", { RATE = "350" })
    send("SET_CLICK_RATE_DOWN", { RATE = "825" })
    send("SET_HOLD_RATE_UP", { RATE = "6100" })
    send("SET_HOLD_RATE_DOWN", { RATE = "4550" })
    for button = 0, 2 do
      send("SET_BUTTON_COLOR", { BUTTON_ID = tostring(button), ON_COLOR = "aabb0" .. button })
      send("SET_BUTTON_COLOR", { BUTTON_ID = tostring(button), OFF_COLOR = "11330" .. button })
    end
  end
  assert(settings:presetLevel() == 64 and settings:brightnessPresetId() == 10, "Preset selection did not persist")
  assert(settings:previousOnLevel() == 37 and settings:clickLevel() == 37, "Previous On did not follow its edit")
  assert(settings:clickRate(true) == 350 and settings:clickRate(false) == 825, "Click rates did not persist")
  assert(settings:holdRate(true) == 6100 and settings:holdRate(false) == 4550, "Hold rates did not persist")
  for button = 0, 2 do
    local link = 200 + button
    colors[link] = nil
    ReceivedFromProxy(link, "REQUEST_BUTTON_COLORS", {})
    local answer = assert(colors[link], "Linked keypad did not receive button colors")
    assert(
      answer.ON_COLOR == "aabb0" .. button and answer.OFF_COLOR == "11330" .. button,
      "Linked keypad color mismatch on " .. link
    )
  end
  OnDriverDestroyed()
  assert(deviceCommands == 0, "Editing Light Properties sent an unexpected device command")
  if phase == "edit" then
    ShimPersistLand()
    local file = assert(io.open(filename, "w"))
    for _, key in ipairs(keys) do
      local value = assert(C4:PersistGetValue(key), key)
      assert(type(value) == "number" or type(value) == "string")
      file:write(type(value), " ", C4:Base64Encode(tostring(value)), "\n")
    end
    file:close()
  end
end
