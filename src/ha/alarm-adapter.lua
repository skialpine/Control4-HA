-- One Home Assistant alarm entity drives one native security partition.
local bit = require("bit")
local contract = require("ha.contract")
local Endpoint = require("ha.endpoint-adapter")
local values = require("lib.values")

local PANEL, PARTITION = 5001, 5002
local states = {
  disarmed = { "Disarmed", "DISARMED_READY" },
  arming = { "Arming", "EXIT_DELAY" },
  pending = { "Entry delay", "ENTRY_DELAY" },
  disarming = { "Disarming", "ARMED" },
  triggered = { "Alarm triggered", "ALARM" },
}
local modes = {
  { "Home", "home", 1 },
  { "Away", "away", 2 },
  { "Night", "night", 4 },
  { "Vacation", "vacation", 32 },
  { "Custom Bypass", "custom_bypass", 16 },
}
local modeByLabel = {}
for _, mode in ipairs(modes) do
  local label, name = mode[1], mode[2]
  modeByLabel[label] = mode
  states["armed_" .. name] = { "Armed " .. label:lower(), "ARMED", label }
end

local function decode(state, attributes)
  local native = states[state]
  if not native then
    return nil
  end
  local features = attributes.supported_features
  if not contract.integer(features) then
    features = 0
  end
  local supported = {}
  for _, mode in ipairs(modes) do
    if bit.band(features, mode[3]) ~= 0 then
      supported[#supported + 1] = mode[1]
    end
  end
  local codeFormat = attributes.code_format
  local disarmCode = codeFormat == "number" or codeFormat == "text"
  return {
    label = native[1],
    native = native[2],
    nativeType = native[3] or "",
    state = state,
    features = features,
    modes = table.concat(supported, ", "),
    armCode = attributes.code_arm_required == true,
    disarmCode = disarmCode,
    numericCode = codeFormat == "number",
  }
end

local function same(current, previous)
  return current.state == previous.state
    and current.features == previous.features
    and current.armCode == previous.armCode
    and current.disarmCode == previous.disarmCode
    and current.numericCode == previous.numericCode
end

local function publish(current, previous, kind)
  values:update("Supported arm modes", current and current.modes or "", "STRING")
  if not previous or not current or current.armCode ~= previous.armCode then
    C4:SendToProxy(
      PARTITION,
      "CODE_REQUIRED",
      { CODE_REQUIRED_TO_ARM = current and current.armCode or false },
      "NOTIFY"
    )
  end
  if not current or not previous or current.state ~= previous.state or current.disarmCode ~= previous.disarmCode then
    local command = kind == "state" and previous and "PARTITION_STATE" or "PARTITION_STATE_INIT"
    local state = current and current.native or "OFFLINE"
    local detail = current and current.nativeType or ""
    C4:SendToProxy(PARTITION, command, {
      STATE = state,
      TYPE = detail,
      CODE_REQUIRED_TO_CLEAR = current and current.disarmCode or false,
    }, "NOTIFY")
    C4:SendToProxy(PANEL, "PANEL_PARTITION_STATE", { PARTITION_ID = 1, STATE = state, TYPE = detail }, "NOTIFY")
  end
end

local function alarmCommand(owner, disarm, params)
  local state = owner:confirmed()
  if not state then
    return false
  end
  local action = "alarm_disarm"
  if not disarm then
    local mode = modeByLabel[params.ArmType]
    if not mode or bit.band(state.features, mode[3]) == 0 then
      values:update("Last Command Result", "Choose an arm mode supported by this alarm in Home Assistant.", "STRING")
      return false
    end
    action = "alarm_arm_" .. mode[2]
  end
  local id = params.InterfaceID
  local origin = type(id) == "string" and #id <= 128 and not id:find("[%c]") and id or nil
  local function failed(needsCode)
    if disarm then
      C4:SendToProxy(PARTITION, "DISARM_FAILED", { INTERFACE_ID = origin }, "NOTIFY")
    else
      C4:SendToProxy(PARTITION, "ARM_FAILED", {
        INTERFACE_ID = origin,
        ACTION = needsCode and "keypad" or nil,
      }, "NOTIFY")
    end
  end
  local code = params.UserCode
  local requiresCode = (disarm and state.disarmCode) or (not disarm and state.armCode)
  local hasCode = type(code) == "string"
    and #code > 0
    and #code <= 64
    and not code:find("%c")
    and (not state.numericCode or code:match("^%d+$") ~= nil)
  if (requiresCode or (code ~= nil and code ~= "")) and not hasCode then
    values:update("Last Command Result", "Enter the alarm code in Control4 and try again.", "STRING")
    failed(true)
    return false
  end
  return owner:command(action, { code = hasCode and code or nil }, function(status, latest)
    if latest and status ~= "accepted" then
      failed(false)
    end
  end)
end

local function install(owner)
  -- The native handler traces parameters before checking where a message belongs.
  for _, binding in ipairs({ PANEL, PARTITION }) do
    RFP.suppressDebug[binding] = RFP.suppressDebug[binding] or {}
    for _, command in ipairs({
      "PARTITION_ARM",
      "PARTITION_DISARM",
      "SET_DEFAULT_USER_CODE",
      "KEY_PRESS",
      "ADDITIONAL_INFO",
    }) do
      RFP.suppressDebug[binding][command] = true
    end
  end
  owner:handle(RFP, PARTITION, function(_, command, params)
    if command == "PARTITION_ARM" or command == "PARTITION_DISARM" then
      return alarmCommand(owner, command == "PARTITION_DISARM", params)
    end
  end)
  C4:SendToProxy(PARTITION, "PARTITION_ENABLED", { ENABLED = "true" }, "NOTIFY")
  C4:SendToProxy(PANEL, "PANEL_INITIALIZED", {}, "NOTIFY")
end

return {
  new = function()
    return Endpoint.new({
      family = "alarm_control_panel",
      supports = function(entity)
        return contract.endpointDomain(entity) == "alarm_control_panel"
      end,
      decode = decode,
      same = same,
      publish = publish,
      install = install,
    })
  end,
}
