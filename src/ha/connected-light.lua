-- A connected Control4 light owns its own level, presets, scenes and ramps.
local Color = require("lib.light.color")
local Settings = require("lib.light.settings")
local contract = require("ha.contract")
local ids = require("ha.identities")
local metrics = require("ha.performance").shared
require("lib.utils")

local Target = {}
Target.__index = Target
local CLASS = "BUTTON_LINK"
local POWER, LEVEL, COLOR, CAPS = 1000, 1001, 1200, 6661
local VARIABLES = { POWER, LEVEL, COLOR, CAPS }
local ROLES = { "app", "top", "toggle", "bottom" }
local RETRY_TIMER = "HA.Connected.Target"
local RELEASE_RETRIES = 3
local TRACE_LIMIT = 25
local POWER_COMMANDS = { ON = "ON", DYNAMIC_ON = "ON", OFF = "OFF", DYNAMIC_OFF = "OFF", TOGGLE = "TOGGLE" }
local LEVEL_COMMANDS = { SET_LEVEL = true, RAMP_TO_LEVEL = true, SET_BRIGHTNESS_TARGET = true }
local STOP_COMMANDS = { SET_BRIGHTNESS_STOP = "brightnessStop", SET_COLOR_STOP = "colorStop" }

local function number(value, low, high)
  value = tonumber(value)
  return value and value >= low and value <= high and value or nil
end

local function boolean(value)
  if type(value) == "string" then
    value = value:lower()
  end
  if value == true or value == 1 or value == "true" or value == "1" then
    return true
  elseif value == false or value == 0 or value == "false" or value == "0" then
    return false
  end
end

local function own()
  return tonumber(C4:GetDeviceID())
end

local function peers(ownIds)
  local me = own()
  local bindings = GetDeviceBindings(me, nil, false, nil, CLASS)
  local result = {}
  for _, role in ipairs(ROLES) do
    local id = ids.targetLinks[role]
    local binding = bindings[id]
    local peer = binding and binding.boundprovider and binding.boundprovider.bound
    local device = peer and tonumber(peer.deviceid)
    local targetBinding = peer and tonumber(peer.bindingid)
    if
      contract.integer(device)
      and device ~= me
      and not (ownIds and ownIds[device])
      and contract.integer(targetBinding)
    then
      result[role] = { role = role, binding = id, device = device, targetBinding = targetBinding }
    end
  end
  return result
end

local function samePeer(a, b)
  return a and b and a.binding == b.binding and a.device == b.device and a.targetBinding == b.targetBinding
end

-- A failed lookup leaves ownership unknown. A successful lookup can rule out
-- the old peer and retire its cleanup without sending a release.
local function currentPeer(link, ownIds)
  local ok, live = pcall(peers, ownIds)
  if ok then
    return samePeer(link, live[link.role]) == true
  end
end

local function sameLinks(left, right)
  for _, role in ipairs(ROLES) do
    if (left[role] or right[role]) and not samePeer(left[role], right[role]) then
      return false
    end
  end
  return true
end

local function stillBound(link)
  return tonumber(C4:GetBoundProviderDevice(own(), link.binding)) == link.device
end

local function read(device, variable)
  local ok, value = pcall(C4.GetDeviceVariable, C4, device, variable)
  if ok then
    return value, true
  end
  return nil, false
end

local function ownProxySet()
  local result = { [own()] = true }
  for _, id in ipairs({ C4:GetProxyDevicesById(own()) }) do
    result[tonumber(id) or id] = true
  end
  return result
end

local function backedBySuite(device)
  local found = C4:GetDevices({ DeviceIds = tostring(device) }) or {}
  local item = found[device] or found[tostring(device)]
  local protocol = item and type(item.protocol) == "table" and next(item.protocol)
  local root = tonumber(protocol) or device
  local model = C4:GetDeviceData(root, "model")
  return model == ids.packages.interimLight.model
    or (
      model == ids.packages.light.model
      and GetDeviceBindings(root, nil, false, nil, ids.coordinatorClass)[ids.lightCoordinatorBinding] ~= nil
    )
end

local function resolve(link, ownIds)
  local device = link.device
  local valid, seen = {}, {}
  local function consider(candidate)
    candidate = tonumber(candidate)
    if contract.integer(candidate) and not ownIds[candidate] and not seen[candidate] then
      seen[candidate] = true
      if boolean(read(candidate, POWER)) ~= nil and not backedBySuite(candidate) then
        valid[#valid + 1] = candidate
      end
    end
  end
  for _, id in ipairs({ C4:GetProxyDevicesById(device) }) do
    consider(id)
  end
  if #valid == 0 then
    consider(device)
  end
  return #valid == 1 and valid[1] or nil, #valid > 1
end

local function capabilities(xml, device)
  local caps = {}
  if type(xml) == "string" and #xml <= 65536 and xml:find("<DynamicCapabilities", 1, true) then
    local ok, parsed = pcall(ParseXml, xml)
    if ok and type(parsed) == "table" and type(parsed.DynamicCapabilities) == "table" then
      caps = parsed.DynamicCapabilities
    end
  end
  if boolean(caps.dimmer) == true and caps.ramp_level == nil then
    -- Director's dynamic capabilities variable omits this deprecated field.
    -- Its native setup response still reports whether the target supports ramps.
    local ok, setup = pcall(function()
      local response = SendUIRequest(device, "GET_SETUP", {})
      if type(response) == "string" and #response <= 65536 then
        return Select(ParseXml(response), "setup")
      end
    end)
    if ok and type(setup) == "table" then
      caps.ramp_level = boolean(setup.ramp_level)
      caps.brightness_rate_max = number(setup.brightness_rate_max, 1, 999999) or caps.brightness_rate_max
    end
  end
  return caps
end

local function reportColor(raw, color, cct)
  if type(raw) ~= "string" or #raw > 128 then
    return nil
  end
  local x, y, mode = raw:match("^%s*([^,]+),([^,]+),([^,]+)%s*$")
  x, y, mode = number(x, 0, 1), number(y, 0.000001, 1), number(mode, 0, 1)
  if not x or not y or x + y > 1.000001 then
    return nil
  end
  if color and mode == 0 then
    return { x = x, y = y, mode = Color.FULL }
  elseif cct and mode == 1 then
    return { x = x, y = y, mode = Color.CCT }
  end
end

function Target.new(changed, releaseFailed)
  return setmetatable({ changed = changed, releaseFailed = releaseFailed, links = {}, held = {} }, Target)
end

function Target:linked()
  return next(self.links) ~= nil
end

function Target:setTrace(enabled)
  if enabled ~= (self.traceLines ~= nil) then
    self.traceLines = enabled and 0 or nil
  end
end

function Target:_tracing()
  return self.traceLines ~= nil and self.traceLines < TRACE_LIMIT
end

function Target:_trace(message)
  self.traceLines = self.traceLines + 1
  local suffix = self.traceLines == TRACE_LIMIT and " | Limit reached. Select Off, then Trace to start again." or ""
  print("Linked light trace | " .. message .. suffix)
end

function Target:_unwatch()
  local previous = self.target
  self.target = nil
  if not previous then
    return
  end
  local debugFlags = OWVC.suppressDebug[previous.device]
  for variable in pairs(previous.watch) do
    pcall(UnregisterVariableListener, previous.device, variable)
    if debugFlags then
      debugFlags[variable] = nil
    end
  end
  if debugFlags and not next(debugFlags) then
    OWVC.suppressDebug[previous.device] = nil
  end
end

function Target:_publish()
  local state = self:state()
  local previous = self.current
  self.current = state
  if self:_tracing() and previous and previous.id == state.id then
    local report, before = state.report, previous.report
    if report and (not before or before.on ~= report.on or before.level ~= report.level) then
      local level = report.level and (" at %g%%"):format(report.level * 100) or ""
      self:_trace("Linked light reported " .. (report.on and "On" or "Off") .. level)
    end
  end
  self.changed(state)
end

function Target:_seed(target)
  target.loading = true
  for _, variable in ipairs(VARIABLES) do
    if self.target ~= target then
      return
    end
    local value, readable = read(target.device, variable)
    target.values[variable] = value
    if (value ~= nil or not readable) and not target.watch[variable] then
      local flags = OWVC.suppressDebug[target.device] or {}
      OWVC.suppressDebug[target.device] = flags
      flags[variable] = true
      target.watch[variable] = true
      local ok = pcall(RegisterVariableListener, target.device, variable, function(_, _, current)
        if self.target ~= target or not stillBound(target.link) then
          return
        end
        local timing = metrics:start("connected.feedback")
        target.values[variable] = current
        if not target.loading then
          if variable == CAPS then
            self:_seed(target)
          else
            self:_publish()
          end
        end
        metrics:finish(timing, "ok")
      end)
      if not ok then
        pcall(UnregisterVariableListener, target.device, variable)
        target.watch[variable] = nil
        flags[variable] = nil
      end
    end
  end
  target.loading = false
  self:_publish()
end

function Target:readLinks()
  self.ownIds = ownProxySet()
  local current = peers(self.ownIds)
  if not sameLinks(current, self.links) then
    CancelTimer(RETRY_TIMER)
    self.retries = 0
  end
  self.links = current
  return self:linked()
end

function Target:setEnabled(value)
  if value and self.destroyed then
    return
  end
  local previous = self.enabled
  self.enabled = value
  if not value then
    CancelTimer(RETRY_TIMER)
    self:_unwatch()
    self.reason, self.name, self.current, self.retries = nil, nil, nil, 0
    self:release()
  elseif not previous then
    self:refresh(true)
  end
end

function Target:refresh(resolveLinks)
  if not self.enabled then
    return
  end
  if resolveLinks then
    local ownIds, target, ambiguous = self.ownIds or ownProxySet(), nil, false
    local chosen = self.links.app or self.links[self.preferredAppRole]
    if chosen then
      target, ambiguous = resolve(chosen, ownIds)
    elseif not self.preferredAppRole then
      local byDevice = {}
      for _, role in ipairs(ROLES) do
        local link = self.links[role]
        if link and not byDevice[link.device] then
          byDevice[link.device] = true
          local candidate, multiple = resolve(link, ownIds)
          if multiple or (chosen and (not candidate or candidate ~= target)) then
            ambiguous = true
          elseif not chosen then
            target, chosen = candidate, link
          end
        end
      end
    end
    if ambiguous then
      self.reason, target = "choose_link", nil
    elseif chosen then
      self.reason = "waiting_target"
    else
      self.reason = self.preferredAppRole and "choose_paddle" or "choose_link"
    end
    self.name = chosen and not ambiguous and C4:GetDeviceDisplayName(chosen.device) or nil
    if target then
      CancelTimer(RETRY_TIMER)
      self.retries = 0
    elseif self.reason == "waiting_target" and (self.retries or 0) < 3 then
      self.retries = (self.retries or 0) + 1
      SetTimer(RETRY_TIMER, 500 * self.retries, function()
        self:readLinks()
        self:refresh(true)
      end)
    end
    if not self.target or self.target.device ~= target or not samePeer(self.target.link, chosen) then
      self:_unwatch()
      if target then
        self.target = {
          device = target,
          link = chosen,
          name = C4:GetDeviceDisplayName(target),
          values = {},
          watch = {},
        }
      end
    else
      return
    end
  end
  if self.target then
    self:_seed(self.target)
  else
    self:_publish()
  end
end

function Target:state()
  local target = self.target
  if not target then
    return { reason = self.reason, name = self.name }
  end
  if not target.caps or target.capsSource ~= target.values[CAPS] then
    target.capsSource = target.values[CAPS]
    target.caps = capabilities(target.capsSource, target.device)
  end
  local caps = target.caps
  local on, level = boolean(target.values[POWER]), number(target.values[LEVEL], 0, 100)
  local dims = boolean(caps.dimmer)
  if dims == nil then
    dims = level ~= nil
  end
  local ready = on ~= nil and (not on or not dims or (level ~= nil and level > 0))
  local color = boolean(caps.supports_color) == true
  local min, max =
    number(caps.color_correlated_temperature_min, 1, 99999), number(caps.color_correlated_temperature_max, 1, 99999)
  local cct = boolean(caps.supports_color_correlated_temperature)
      and min
      and max
      and min <= max
      and { minK = min, maxK = max }
    or nil
  local reportedColor = reportColor(target.values[COLOR], color, cct)
  local ramps = dims and boolean(caps.ramp_level) == true
  local maxMs = number(caps.brightness_rate_max, 1, 999999) or 65535
  local controls = {
    ramp = ramps,
    brightnessStop = dims and boolean(caps.supports_brightness_stop) == true,
    colorStop = reportedColor ~= nil and boolean(caps.supports_color_stop) == true,
    colorRateBehavior = number(caps.color_rate_behavior, 0, 2) or 0,
    colorRateMax = number(caps.color_rate_max, 0, 999999) or 0,
    colorRateMin = number(caps.color_rate_min, 0, 999999) or 0,
  }
  return {
    id = target.device,
    name = target.name,
    reason = not ready and self.reason or nil,
    ready = ready,
    reachable = on ~= nil,
    controls = controls,
    device = {
      dims = dims,
      color = color and reportedColor ~= nil,
      cct = reportedColor and cct or nil,
      levelSteps = 100,
      fade = ramps and { kind = "device", maxMs = maxMs }
        or { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } },
      feedback = { shows = "position", refresh = false },
      targetControls = controls,
    },
    report = ready
        and { kind = "push", on = on, level = dims and (on and level / 100 or 0) or nil, color = reportedColor }
      or nil,
  }
end

function Target:_send(operation, command, parameters)
  local target = self.target
  if self.sending then
    return false, "another linked command is being sent"
  end
  if not target or not samePeer(target.link, self.links[target.link.role]) then
    return false, "the selected connection changed"
  end
  local readOK, live = pcall(peers, self.ownIds)
  if not readOK then
    return false, "the connections could not be verified"
  end
  if not sameLinks(self.links, live) then
    return false, "the connections changed"
  end
  local span = metrics:start(operation)
  self.sending = true
  local ok, result = pcall(SendToDevice, target.device, command, parameters or {})
  self.sending = false
  local sent = ok and result ~= false
  metrics:finish(span, sent and "accepted" or "failed")
  return sent, not sent and "Director did not accept the command" or nil
end

local function colorIntent(state, params)
  local x, y = number(params.LIGHT_COLOR_TARGET_X, 0, 1), number(params.LIGHT_COLOR_TARGET_Y, 0.000001, 1)
  local kelvin = number(params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE, 1, 99999)
  local mode = kelvin and 1 or number(params.LIGHT_COLOR_TARGET_MODE or 0, 0, 1)
  local rate = params.LIGHT_COLOR_TARGET_RATE or params.LIGHT_COLOR_TARGET_COLOR_RATE or params.RATE
  local data = {}
  if kelvin then
    local range = state.device.cct
    if not range or not number(kelvin, range.minK, range.maxK) then
      return nil
    end
    data.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = kelvin
  elseif (mode == 0 and state.device.color or mode == 1 and state.device.cct) and x and y and x + y <= 1.000001 then
    data.LIGHT_COLOR_TARGET_X, data.LIGHT_COLOR_TARGET_Y = x, y
  else
    return nil
  end
  if rate ~= nil then
    rate = number(rate, state.controls.colorRateMin, state.controls.colorRateMax)
    if not rate then
      return nil
    end
    data.LIGHT_COLOR_TARGET_RATE, data.LIGHT_COLOR_TARGET_COLOR_RATE, data.RATE = rate, rate, rate
  end
  data.LIGHT_COLOR_TARGET_MODE = mode
  return data
end

function Target:canSetColor(params)
  return self.current and colorIntent(self.current, params) ~= nil
end

function Target.handlesCommand(command)
  return POWER_COMMANDS[command] ~= nil
    or LEVEL_COMMANDS[command] == true
    or STOP_COMMANDS[command] ~= nil
    or command == "SET_COLOR_TARGET"
end

function Target:isAppTarget(device)
  local target = self.target
  return target ~= nil and (target.device == device or target.link.device == device)
end

local function route(state, command, params, onPreset)
  if not state or not state.reachable then
    return nil, "the linked light has no current state"
  end
  local power = POWER_COMMANDS[command]
  if power then
    return "connected." .. power:lower(), power
  elseif LEVEL_COMMANDS[command] then
    local level = number(params.LEVEL or params.LIGHT_BRIGHTNESS_TARGET, 0, 100)
    if level == nil then
      return nil, "the requested brightness is missing or invalid"
    end
    local preset, origin =
      tonumber(params.LIGHT_BRIGHTNESS_TARGET_PRESET_ID), tonumber(params.LIGHT_BRIGHTNESS_TARGET_PRESET_ORIGIN)
    local nativePreset = command == "SET_BRIGHTNESS_TARGET"
      and (origin == nil or origin == Settings.PRESET_ORIGIN_DEVICE)
    if nativePreset and level == 0 and preset == Settings.OFF_PRESET_ID then
      -- Director can translate Navigator Off into a preset with the source's ramp rate.
      -- The linked light owns its Off transition, just as it owns the On preset.
      return "connected.off", "OFF"
    end
    local requestedRate = params.TIME or params.RATE
    local rate = requestedRate ~= nil and number(requestedRate, 0, state.device.fade.maxMs or 65535) or nil
    if requestedRate ~= nil and rate == nil then
      return nil, "the requested transition time is out of range"
    end
    if
      nativePreset
      and level > 0
      and (preset == (onPreset or Settings.DEFAULT_ON_PRESET_ID) or preset == Settings.PREVIOUS_ON_PRESET_ID)
    then
      return "connected.on", "ON", nil, preset
    end
    if not state.device.dims then
      if rate and rate > 0 then
        return nil, "the linked light supports only on and off"
      end
      return level > 0 and "connected.on" or "connected.off", level > 0 and "ON" or "OFF"
    elseif rate and rate > 0 then
      if not state.controls.ramp then
        return nil, "the linked light does not support timed brightness changes"
      end
      return "connected.ramp", "RAMP_TO_LEVEL", { LEVEL = level, TIME = rate }
    end
    return "connected.level", "SET_LEVEL", { LEVEL = level }
  elseif command == "SET_COLOR_TARGET" then
    local data = colorIntent(state, params)
    if data then
      return "connected.color", command, data
    end
    return nil, "the color request is invalid or unsupported by the linked light"
  elseif STOP_COMMANDS[command] then
    if state.controls[STOP_COMMANDS[command]] then
      return "connected.stop", command
    end
    return nil, "the linked light does not support stopping that transition"
  end
  return nil, "unsupported command"
end

local function brightnessDetails(params)
  local level = number(params.LEVEL or params.LIGHT_BRIGHTNESS_TARGET, 0, 100)
  local rate = number(params.TIME or params.RATE, 0, 999999)
  return (level and (" %g%%"):format(level) or "") .. (rate and (" over %g ms"):format(rate) or "")
end

function Target:command(command, params, onPreset)
  local operation, forwarded, data, preset = route(self.current, command, params, onPreset)
  local sent, reason = false, forwarded
  if operation then
    sent, reason = self:_send(operation, forwarded, data)
  end
  if self:_tracing() and Target.handlesCommand(command) then
    local request = command .. (LEVEL_COMMANDS[command] and brightnessDetails(params) or "")
    if sent then
      self:_trace(request .. " forwarded as " .. forwarded .. (data and brightnessDetails(data) or ""))
    else
      self:_trace(request .. " not forwarded: " .. reason)
    end
  end
  return sent, preset
end

function Target:traceOnColorSkipped()
  if self:_tracing() then
    self:_trace("SET_COLOR_TARGET not forwarded: the linked light applies its own On preset")
  end
end

function Target:_paddle(link, command)
  local span = metrics:start("connected.paddle")
  local ok, result = pcall(SendToProxy, link.binding, command, {}, "COMMAND")
  local sent = ok and result ~= false
  metrics:finish(span, sent and "accepted" or "failed")
  if self:_tracing() then
    self:_trace(link.role .. " button " .. command .. (sent and " forwarded" or " failed"))
  end
  return sent
end

-- Leaving connected mode blocks new presses but does not retire cleanup for
-- a press already sent. Each retry checks the actual original binding.
function Target:_release(role, hold, peerUnknown)
  if self.held[role] ~= hold then
    return
  end
  local timer = "HA.Connected.Release." .. role
  CancelTimer(timer)
  self.held[role] = nil
  local matches
  if not peerUnknown then
    matches = currentPeer(hold.link, self.ownIds)
  end
  if matches == false then
    return
  end
  local sent = matches and self:_paddle(hold.link, "DO_RELEASE")
  if sent or self.held[role] or self.destroyed or not samePeer(hold.link, self.links[role]) then
    return
  end
  self.held[role] = hold
  hold.retries = (hold.retries or 0) + 1
  if hold.retries <= RELEASE_RETRIES then
    SetTimer(timer, 100 * hold.retries, function()
      self:_release(role, hold)
    end)
  elseif hold.retries == RELEASE_RETRIES + 1 and self.releaseFailed then
    self.releaseFailed()
  end
end

function Target:release(buttonId)
  for role, hold in pairs(self.held) do
    if not buttonId or hold.buttonId == buttonId then
      self:_release(role, hold)
    end
  end
end

-- Feedback uses the selected paddle, which may control a different light than the app.
function Target:feedbackLink(role)
  local link = self.links[role]
  return self.enabled and role ~= "app" and link and currentPeer(link, self.ownIds) and link or nil
end

function Target:button(role, action, buttonId)
  local link = self.links[role]
  if not self.enabled or not link or role == "app" then
    return false
  end
  local held = self.held[role]
  local matches = currentPeer(link, self.ownIds)
  if not matches then
    if matches == nil and action == "release" and held and held.buttonId == buttonId then
      self:_release(role, held, true)
    end
    return false
  end
  if held and not samePeer(held.link, link) then
    self:_release(role, held)
    held = nil
  end
  if held and held.retries and action ~= "release" then
    self:_release(role, held)
    return false
  end
  if (action == "press" or action == "click") and not held then
    held = { link = link, buttonId = buttonId }
    self.held[role] = held
    local sent = self:_paddle(link, "DO_PUSH")
    if self.held[role] ~= held or not self.enabled or not samePeer(link, self.links[role]) then
      return false
    end
    if not sent then
      self:release(buttonId)
      return false
    end
    if action == "press" then
      return true
    end
    -- DO_PUSH may run programming before returning. Complete a tap only
    -- after making sure its original peer is still on the binding.
    if not currentPeer(link, self.ownIds) then
      self:_release(role, held)
      return false
    end
  end
  if held and held.buttonId == buttonId and (action == "click" or action == "release") then
    self.held[role] = nil
    local sent = self:_paddle(link, action == "click" and "DO_CLICK" or "DO_RELEASE")
    if not sent and not self.held[role] and not self.destroyed and samePeer(link, self.links[role]) then
      self.held[role] = held
      self:release(buttonId)
    end
    return sent
  end
  return false
end

function Target:destroy()
  self.destroyed = true
  self.releaseFailed = nil
  self:setEnabled(false)
  self.changed = function() end
end

return Target
