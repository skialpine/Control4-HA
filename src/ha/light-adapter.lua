-- Adapt confirmed HA state and bounded HA commands to the template Light engine.
local Light = require("lib.light")
local LightHandlers = require("lib.light.handlers")
local Color = require("lib.light.color")
local Range = require("lib.light.range")
local bit = require("bit")
local capabilities = require("ha.light-capabilities")
local compatibility = require("ha.light-compatibility")
local codec = require("ha.codec")
local contract = require("ha.contract")
local ids = require("ha.identities")
local commandSender = require("ha.load-command")
local metrics = require("ha.performance").shared
local Connected = require("ha.connected-light")
local Buttons = require("lib.light.buttons")
local Picks = require("lib.light.picks")
local Effects = require("ha.light-effects")
local OnColor = require("lib.light.oncolor")
local persist = require("lib.persist")

local Adapter = {}
Adapter.__index = Adapter
Adapter.stageMigrationSettings = compatibility.stageMigration
Adapter.verifyMigrationSettings = compatibility.sameStoredMigration

local STEPS, TRANSITION = 255, 32
local BP_SCENE_RETIREMENTS = "HA.Light.BPSceneRetirements"
local buttonRoles = { [Buttons.TOP] = "top", [Buttons.BOTTOM] = "bottom", [Buttons.TOGGLE] = "toggle" }
local appLinkRoles = { Top = "top", Bottom = "bottom", Toggle = "toggle" }
local linkActions = { DO_PUSH = "press", DO_CLICK = "click", DO_RELEASE = "release" }
local proxyActions =
  { [Buttons.PRESS] = "press", [Buttons.RELEASE_CLICK] = "click", [Buttons.RELEASE_HOLD] = "release" }

local function inRange(value, low, high)
  return type(value) == "number" and value >= low and value <= high
end

local function deviceFacts(entity, attrs, overrides)
  local modes = entity:match("^light%.") and attrs.supported_color_modes or nil
  local dims, color, cct = capabilities.fromModes(modes)
  local kind = compatibility.kind(overrides)
  if kind then
    dims, color, cct = kind.dims == true, kind.color == true, kind.temperature == true
  end
  local flags = attrs.supported_features
  local transition = dims
    and inRange(flags, 0, 2147483647)
    and flags == math.floor(flags)
    and bit.band(flags, TRANSITION) ~= 0
  local rgb = false
  for _, mode in ipairs(codec.isArray(modes) and modes or {}) do
    if mode == "xy" then
      rgb = false
      break
    elseif mode == "rgb" or mode == "rgbw" or mode == "rgbww" then
      rgb = true
    end
  end
  return {
    dims = dims,
    color = color,
    cct = cct and (compatibility.range(overrides.range) or compatibility.nativeRange(attrs)) or nil,
    colorWhileOff = "hold",
    fade = transition and { kind = "device", retimes = true } or {
      kind = "own",
      own = { onMs = 0, offMs = 0, changeMs = 0 },
    },
    feedback = { shows = "position", refresh = "deadline" },
    levelSteps = STEPS,
  },
    color and (overrides.format or (rgb and "RGB" or "XY")) or nil,
    transition,
    cct
end

local function xy(x, y)
  return inRange(x, 0, 1) and inRange(y, 0.000001, 1) and x + y <= 1.000001
end

local function reportedColor(device, attrs)
  local mode = attrs.color_mode
  if mode == "color_temp" and device.cct then
    local k = attrs.color_temp_kelvin
    if k == nil and inRange(attrs.color_temp, 10, 1000000) then
      k = Color.miredsToKelvin(attrs.color_temp)
    end
    -- Overrides limit outgoing commands. Feedback still follows the HA load.
    local nativeRange = compatibility.nativeRange(attrs)
    if inRange(k, 1, 99999) and (not nativeRange or inRange(k, nativeRange.minK, nativeRange.maxK)) then
      local x, y = Color.kelvinToXY(k)
      if xy(x, y) then
        return { x = x, y = y, mode = Color.CCT, kelvin = k }
      end
    end
    return
  end
  if not device.color then
    return
  end
  local xyColor, rgbColor, hsColor = attrs.xy_color, attrs.rgb_color, attrs.hs_color
  local x, y
  if codec.isArray(xyColor) and #xyColor == 2 and xy(xyColor[1], xyColor[2]) then
    x, y = xyColor[1], xyColor[2]
  elseif
    codec.isArray(rgbColor)
    and #rgbColor == 3
    and inRange(rgbColor[1], 0, STEPS)
    and inRange(rgbColor[2], 0, STEPS)
    and inRange(rgbColor[3], 0, STEPS)
  then
    x, y = Color.rgbToXY(rgbColor[1] / STEPS, rgbColor[2] / STEPS, rgbColor[3] / STEPS)
  elseif codec.isArray(hsColor) and #hsColor == 2 and inRange(hsColor[1], 0, 360) and inRange(hsColor[2], 0, 100) then
    local r, g, b = Color.hsvToRGB(hsColor[1], hsColor[2], 100)
    x, y = Color.rgbToXY(r, g, b)
  end
  if xy(x, y) then
    return { x = x, y = y, mode = Color.FULL }
  end
end

function Adapter.new()
  local self = setmetatable({ generation = 0, connectedPicks = Picks.new() }, Adapter)
  self.connected = Connected.new(function(state)
    local changedTarget = self.targetId ~= state.id
    self.targetId = state.id
    if state.report then
      state.device.extras = false
      if changedTarget and self.light.online then
        self.light:lost()
      end
      self.light:declare(state.device)
      self.light:report(state.report)
    elseif self.light.online and (changedTarget or not state.reachable) then
      self.light:lost()
    end
    if self.feedbackChanged then
      self.feedbackChanged()
    end
  end, function()
    if self.onResult then
      self.onResult("connected_release_failed")
    end
  end)
  self.light = Light.new(self, {
    api = Light.API,
    proxy = ids.proxy,
    links = ids.lightLinks,
    dims = true,
    color = true,
    cct = true,
    fades = true,
    defaultOn = true,
    onModes = true,
    scenes = true,
    flash = true,
    extras = true,
    loadGroups = true,
  })
  return self
end

function Adapter:start()
  if self.destroyed then
    return
  end
  -- The original device-level programming commands use the same dispatch as
  -- Navigator, including target selection, scene cancellation and On presets.
  local handlers = self.light.ownedHandlers
  local proxyCommand = handlers.rfp[ids.proxy]
  for savedName, command in pairs({ Turn_On = "ON", Turn_Off = "OFF", Toggle = "TOGGLE" }) do
    local function run()
      proxyCommand(ids.proxy, command, {})
    end
    handlers.ec[savedName] = run
    EC[savedName] = run
  end
  self.light:start()
end

function Adapter:_clearEffects()
  Effects.publish(ids.proxy, nil, self.effects)
  self.effects = nil
end

local notSent = { permission_denied = true, busy = true, invalid_request = true }

local function settle(light, report)
  light:report({ kind = "final", on = report.on, level = report.level, color = report.color })
end

function Adapter:_currentCommand(command)
  return not self.destroyed and self.latestCommand == command and self.generation == command.generation
end

function Adapter:_recoverLoad(command)
  if command.reading or command.finished then
    return
  end
  command.reading = true
  local before = command.requestedReport or self.reported
  local function complete(state)
    if not self:_currentCommand(command) then
      return
    end
    command.finished = true
    if self.reported and self.reported ~= before then
      settle(self.light, self.reported)
    elseif not state or not self:message("snapshot", state, "final") then
      self.feedbackUnavailable = true
      self:lost()
      if self.feedbackUnavailable and self.feedbackChanged then
        self.feedbackChanged()
      end
    end
  end
  if self.reported and self.reported ~= before then
    -- A push arrived while the deadline waited on the service acceptance.
    complete()
    return
  end
  commandSender.read(self.consumer, self.entity):next(complete, function()
    complete(nil)
  end)
end

function Adapter:_sendService(action, parameters, operation)
  local command = { generation = self.generation }
  self.latestCommand = command
  local function latest()
    return self:_currentCommand(command)
  end
  commandSender.send(self.consumer, self.entity, action, parameters, function(status)
    if self.onResult then
      self.onResult(status)
    end
    if not latest() then
      return
    end
    if notSent[status] and self.reported then
      -- A command that never reached the load can settle the library's
      -- prediction with the last confirmed report for this selection.
      command.finished = true
      settle(self.light, self.reported)
    elseif commandSender.uncertain(status) then
      self:_recoverLoad(command)
    elseif status == "accepted" then
      command.accepted = true
      if command.requestedReport then
        self:_recoverLoad(command)
      end
    end
  end, latest, operation)
end

function Adapter:lost(entity)
  if self.destroyed or self.connected.enabled or (entity and entity ~= self.entity) then
    return
  end
  self:_clearEffects()
  self.generation = self.generation + 1
  self.device, self.colorFormat, self.transition, self.reported = nil, nil, nil, nil
  self.compatibilityState, self.hasTemperature = nil, nil
  if self.light.online then
    self.light:lost()
  end
end

function Adapter:bind(consumer, entity, onResult, connectedMode, feedbackChanged)
  if entity ~= self.entity or connectedMode then
    self.confirmedAvailable = nil
  end
  self.feedbackUnavailable = nil
  self.feedbackChanged = feedbackChanged
  if self.connected.enabled or connectedMode then
    if self.connected.enabled ~= connectedMode then
      self:_clearEffects()
      self.connectedPicks:reset()
      self.generation = self.generation + 1
      self.device, self.colorFormat, self.transition, self.reported = nil, nil, nil, nil
      self.compatibilityState, self.hasTemperature = nil, nil
      if self.light.online then
        self.light:lost()
      end
    end
    self.connected:setEnabled(connectedMode == true)
    if connectedMode then
      self.consumer, self.entity, self.onResult = nil, nil, onResult
      return
    end
  end
  self:lost()
  self.consumer, self.entity, self.onResult = consumer, contract.loadDomain(entity) and entity or nil, onResult
  self.overrides = self.entity and self.entity:match("^light%.") and compatibility.read(self.entity) or {}
end

function Adapter:compatibilityProperties()
  if self.entity and self.entity:match("^light%.") then
    return compatibility.properties(self.overrides, self.device, self.hasTemperature)
  end
  return {}
end

function Adapter:loadDevice()
  return self.device
end

function Adapter:setCompatibility(name, value)
  local field = compatibility.field(name)
  if not field then
    return false
  end
  if not self.entity or not self.entity:match("^light%.") then
    return true, "Choose a Home Assistant light first."
  end
  local failure, saved = compatibility.save(self.entity, self.overrides, field, value, self.device, self.hasTemperature)
  if saved then
    self.overrides = saved
    if self.compatibilityState then
      self:message("snapshot", self.compatibilityState)
    end
  end
  return true, failure
end

function Adapter:unbind()
  self:bind(nil)
end

function Adapter:destroy()
  self.destroyed = true
  self.connected:destroy()
  self.consumer, self.entity, self.onResult, self.reported = nil, nil, nil, nil
  self.light:destroy()
end

function Adapter:message(kind, data, reportKind)
  if self.destroyed or not self.light.started or not self.entity or data.entity_id ~= self.entity then
    return
  end
  if kind == "failure" or (kind == "readiness" and not data.available) then
    self:lost()
    return
  end
  if kind ~= "snapshot" and kind ~= "state" then
    return
  end
  local becameUnavailable = data.state == "unavailable" and self.confirmedAvailable == true
  if becameUnavailable then
    self.confirmedAvailable = false
  end
  if data.state ~= "on" and data.state ~= "off" then
    if reportKind ~= "final" then
      self:lost()
    end
    if becameUnavailable then
      C4:FireEventByID(ids.lightUnavailableEvent)
    end
    return
  end
  self.confirmedAvailable = true
  local device, format, transition, temperature = deviceFacts(self.entity, data.attributes, self.overrides)
  local brightness = data.attributes.brightness
  local level = device.dims and inRange(brightness, 1, STEPS) and brightness / STEPS or nil
  -- A lit dimmer without evidence of its level must never acquire a guessed level.
  if device.dims and data.state == "on" and not level then
    if reportKind ~= "final" then
      self:lost()
      self.feedbackUnavailable = true
      self.compatibilityState = data
      self.hasTemperature = temperature
    end
    return
  end
  self.feedbackUnavailable = nil
  self.device, self.colorFormat, self.transition = device, format, transition
  self.compatibilityState, self.hasTemperature = data, temperature
  local previous = self.effects
  self.effects = self.entity:match("^light%.") and Effects.read(data.attributes) or nil
  device.extras = self.effects ~= nil
  self.light:declare(device)
  self.reported = {
    kind = "push",
    on = data.state == "on",
    level = level,
    color = reportedColor(device, data.attributes),
  }
  if reportKind == "final" then
    settle(self.light, self.reported)
  else
    self.light:report(self.reported)
  end
  Effects.publish(ids.proxy, self.effects, previous)
  return true
end

-- The template owns each transition's deadline. A whole-state read can answer
-- several aspect windows, and may have to wait for the current service reply.
function Adapter:refresh(cachedOnly)
  if self.connected.enabled then
    if not self.connected.target then
      self.connected:readLinks()
      self.connected:refresh(true)
    else
      self.connected:refresh()
    end
  elseif self.reported and self.consumer and self.consumer.readiness:view(self.entity).evidence_ready then
    local command = self.latestCommand
    if not cachedOnly and command and self:_currentCommand(command) and not command.finished then
      command.requestedReport = command.requestedReport or self.reported
      if command.accepted then
        self:_recoverLoad(command)
      end
      return
    end
    self.light:report(self.reported)
    Effects.publish(ids.proxy, self.effects)
  end
end
function Adapter:show() end

function Adapter:readLinks()
  self.connectedPicks:reset()
  self.connected.preferredAppRole = appLinkRoles[Properties["App Control Link"]]
  local found = self.connected:readLinks()
  self.connected:refresh(true)
  return found
end

function Adapter:appLinkChoices()
  local links = self.connected.links
  if links.app then
    return
  end
  local selected = Properties["App Control Link"]
  local selectedRole = appLinkRoles[selected]
  local selectedLink = links[selectedRole]
  local choices, devices, seen = { "Automatic" }, {}, {}
  for _, label in ipairs({ "Top", "Bottom", "Toggle" }) do
    local link = links[appLinkRoles[label]]
    if link and not seen[link.device] then
      seen[link.device] = true
      local value = selectedLink and selectedLink.device == link.device and selected or label
      choices[#choices + 1], devices[value] = value, link.device
    end
  end
  local needsRecovery = selectedRole ~= nil and selectedLink == nil
  if #choices > 2 or (#choices == 2 and needsRecovery) then
    if needsRecovery then
      choices[#choices + 1] = selected
    end
    return choices, devices
  end
end

function Adapter:targetState()
  return self.connected.current
end

function Adapter:bottomRampTarget()
  local target = self.connected.current
  local bottom = self.connected.links.bottom
  if bottom and target and target.controls and target.controls.ramp and self.connected:isAppTarget(bottom.device) then
    return target.name
  end
end

function Adapter:_button(role, action, identity)
  if role and action and self.connected.enabled then
    if action ~= "release" then
      self.light.scenes:reset()
    end
    return self.connected:button(role, action, identity)
  end
  return false
end

-- Native proxy ACTION values 2, 3 and 4 are completed single, double and triple taps.
function Adapter.nativeAction(occurrence)
  if not occurrence.role or Buttons[occurrence.role:upper()] == nil then
    return
  end
  if occurrence.kind == "press" and occurrence.press_count >= 1 and occurrence.press_count <= 3 then
    return occurrence.press_count + 1
  elseif occurrence.kind == "hold_start" then
    return Buttons.PRESS
  elseif occurrence.kind == "release" then
    return Buttons.RELEASE_HOLD
  end
end

function Adapter:publishNative(occurrence)
  local action = Adapter.nativeAction(occurrence)
  if self.destroyed or self.publishingButton or not action then
    return
  end
  self.publishingButton = true
  local ok, err = pcall(C4.SendToProxy, C4, ids.proxy, "BUTTON_ACTION", {
    BUTTON_ID = Buttons[occurrence.role:upper()],
    ACTION = action,
  }, "NOTIFY")
  self.publishingButton = false
  if not ok then
    error(err)
  end
end

function Adapter:gesture(occurrence)
  local role = occurrence.role
  if occurrence.kind == "press" and occurrence.press_count == 1 then
    return self:_button(role, "click", occurrence.button_id)
  elseif occurrence.kind == "hold_start" then
    return self:_button(role, "press", occurrence.button_id)
  elseif occurrence.kind == "release" then
    return self:_button(role, "release", occurrence.button_id)
  end
  return false
end

function Adapter:releaseGesture(buttonId)
  if self.connected.enabled then
    self.connected:release(buttonId)
  end
end

local function bpSceneLevel(key)
  -- BP 106 stored the parsed ELEMENTS node and used its first level or brightness.
  local nodes = Select(C4:PersistGetValue("ALS:" .. key, false), "ChildNodes")
  if type(nodes) ~= "table" then
    return nil
  end
  for _, node in ipairs(nodes) do
    local name = Select(node, "Name")
    if name == "level" or name == "brightness" then
      local level = tonumber(node.Value)
      return inRange(level, 0, 100) and level or nil
    end
  end
end

local function bpSceneRetirements()
  local retired = persist:get(BP_SCENE_RETIREMENTS, {})
  return type(retired) == "table" and retired or {}
end

function Adapter:legacyScene(key)
  local scenes = type(PersistData) == "table" and PersistData.LightScenes
  if type(scenes) == "table" and scenes[key] ~= nil then
    return scenes[key]
  end
  local retired = bpSceneRetirements()
  if retired.all or retired[key] then
    return nil
  end
  local level = bpSceneLevel(key)
  if level ~= nil then
    return { xml = "<element><level>" .. tostring(level) .. "</level></element>" }
  end
end

function Adapter:forgetLegacyScene(key)
  local scenes = type(PersistData) == "table" and PersistData.LightScenes
  if type(scenes) == "table" then
    if key then
      scenes[key] = nil
    else
      PersistData.LightScenes = nil
    end
  end
  -- Retire only on scene removal. Keep the original rows available for rollback.
  if not key then
    persist:set(BP_SCENE_RETIREMENTS, { all = true })
  elseif bpSceneLevel(key) ~= nil then
    local retired = bpSceneRetirements()
    if not retired.all and not retired[key] then
      retired[key] = true
      persist:set(BP_SCENE_RETIREMENTS, retired)
    end
  end
end

local function sceneColorParams(intent)
  return {
    LIGHT_COLOR_TARGET_X = intent.color.x,
    LIGHT_COLOR_TARGET_Y = intent.color.y,
    LIGHT_COLOR_TARGET_MODE = intent.color.mode == Color.CCT and 1 or 0,
    LIGHT_COLOR_TARGET_RATE = intent.sceneColorRate,
  }
end

function Adapter:validateScene(intent)
  if self.connected.enabled then
    return self.connected:state().ready and (not intent.color or self.connected:canSetColor(sceneColorParams(intent)))
  end
  local device = self.device
  return device ~= nil and (not intent.color or device.color or (intent.color.mode == Color.CCT and device.cct ~= nil))
end

function Adapter:softwareSceneLevel(interactive)
  if self.connected.enabled then
    local state = self.connected:state()
    if
      state.ready
      and state.device.dims
      and (not state.controls.ramp or interactive and not state.controls.brightnessStop)
    then
      return state.report.on and state.report.level * 100 or 0
    end
  elseif self.device and self.device.dims and self.reported and not self.transition then
    return self.reported.on and self.reported.level * 100 or 0
  end
end

function Adapter:delegateScene(intent)
  if not self.connected.enabled then
    return false
  end
  local state = self.connected:state()
  if not state.ready then
    self.light.scenes:reset()
    return true
  end
  if intent.kind == "stop" then
    self.connected:command("SET_BRIGHTNESS_STOP", {})
    return true
  end
  local generation = self.light.scenes.generation
  local sent = true
  local colorParams = intent.color and sceneColorParams(intent)
  if colorParams and (not intent.ramp or self.connected:canSetColor(colorParams)) then
    sent = self.connected:command("SET_COLOR_TARGET", colorParams)
  end
  if generation ~= self.light.scenes.generation then
    return true
  end
  if sent and intent.level ~= nil then
    local rate = state.controls.ramp and math.min(intent.sceneLevelRate or intent.rateMs, state.device.fade.maxMs) or 0
    sent = self.connected:command("SET_LEVEL", { LEVEL = intent.level, TIME = rate })
  end
  if not sent and generation == self.light.scenes.generation then
    self.light.scenes:reset()
  end
  return true
end

function Adapter:isButtonEcho(command)
  return self.publishingButton and (command == "BUTTON_ACTION" or linkActions[command] ~= nil)
end

-- The library resolves group membership and parses group intent. The app
-- target owns motion, including its brightness range and supported rates.
function Adapter:delegateGroup(intent, groupId)
  if not self.connected.enabled then
    return false
  end
  if self.connected:isAppTarget(groupId) then
    return true
  end
  local state = self.connected:state()
  if not state.ready then
    return true
  end
  self.light.scenes:reset()
  self.connectedPicks:reset()
  local target = self.connected.target
  if intent.color then
    local params = sceneColorParams(intent)
    params.LIGHT_COLOR_TARGET_RATE = intent.rateMs
        and math.max(state.controls.colorRateMin, math.min(intent.rateMs, state.controls.colorRateMax))
      or nil
    self.connected:command("SET_COLOR_TARGET", params)
  end
  if self.connected.target ~= target then
    return true
  end
  if intent.kind == "off" then
    self.connected:command("OFF", {})
  elseif intent.kind == "stopLevel" then
    self.connected:command("SET_BRIGHTNESS_STOP", {})
  elseif intent.kind == "level" then
    local rate = state.controls.ramp and math.min(intent.rateMs or 0, state.device.fade.maxMs) or 0
    self.connected:command("SET_LEVEL", { LEVEL = intent.level, TIME = rate })
  end
  return true
end

-- Native settings, group membership and queries have already been dispatched
-- by the library. Only intercept commands with a known connected route.
function Adapter:delegate(binding, command, params)
  if binding == ids.proxy and command == "SELECT_LIGHT_EFFECT" then
    local name = params.value
    if self.effects and self.effects.allowed[name] then
      self:_sendService("turn_on", { effect = name }, "light.effect")
    end
    return true
  end
  if not self.connected.enabled then
    if binding == ids.proxy and (command == "SET_COLOR_TARGET" or command == "SET_COLOR_STOP") then
      -- A manual color override stops a suite scene's later steps.
      self.light.scenes:reset()
    end
    return false
  end
  if binding ~= ids.proxy then
    for role, id in pairs(ids.lightLinks) do
      if id == binding then
        self:_button(role, linkActions[command], "link:" .. role)
        return true
      end
    end
    return false
  end
  if command == "SYNCHRONIZE" then
    self.light.proxy:resay({ "level", "color" }, true)
    self:refresh()
    self.light:ask("GET_CONNECTED_STATE", {}, binding)
    return true
  elseif command == "BUTTON_ACTION" then
    local role = buttonRoles[tonumber(params.BUTTON_ID)]
    local action = proxyActions[tonumber(params.ACTION)]
    if role then
      self:_button(role, action, "app-button:" .. role)
    end
    return true
  end
  if not Connected.handlesCommand(command) then
    return false
  end
  self.light.scenes:reset()
  if command == "SET_BRIGHTNESS_TARGET" then
    self.connectedPicks:reset()
    local sent, preset = self.connected:command(command, params, self.light.settings:brightnessPresetId())
    if sent and preset then
      self.connectedPicks:noted({ kind = "on", presetId = preset }, { on = false })
    end
  else
    local colorPreset = command == "SET_COLOR_TARGET" and tonumber(params.LIGHT_COLOR_TARGET_PRESET_ID) or nil
    local colorPresetOrigin = command == "SET_COLOR_TARGET" and tonumber(params.LIGHT_COLOR_TARGET_PRESET_ORIGIN) or nil
    local follow = command == "SET_COLOR_TARGET"
      and OnColor.followUp({
        kind = "color",
        color = true,
        presetId = colorPreset,
        presetOrigin = colorPresetOrigin,
      }, self.connectedPicks:forOn(), self.light.settings:forOn())
    self.connectedPicks:reset()
    if not follow then
      if colorPreset then
        local color, fromPreset = LightHandlers.targetColor(self.light, params, colorPreset, colorPresetOrigin)
        if fromPreset and color then
          params = sceneColorParams({
            color = color,
            sceneColorRate = params.LIGHT_COLOR_TARGET_RATE or params.LIGHT_COLOR_TARGET_COLOR_RATE or params.RATE,
          })
        end
      end
      self.connected:command(command, params)
    else
      self.connected:traceOnColorSkipped()
    end
  end
  return true
end

local proxyOperations = {
  TOGGLE = "light.toggle",
  SET_PRESET_LEVEL = "light.preset",
  SET_BRIGHTNESS_ON_MODE = "light.preset",
  UPDATE_BRIGHTNESS_ON_MODE = "light.preset",
  UPDATE_BRIGHTNESS_PRESET = "light.preset",
  UPDATE_COLOR_ON_MODE = "light.preset",
  UPDATE_COLOR_PRESET = "light.preset",
  JOIN_GROUP = "light.group",
  LEAVE_GROUP = "light.group",
  GROUP_SET_LEVEL = "light.group",
  GROUP_START_RAMP = "light.group",
  GROUP_STOP_RAMP = "light.group",
  LIGHT_GROUP_JOIN = "light.group",
  LIGHT_GROUP_LEAVE = "light.group",
  LIGHT_GROUP_COMMAND = "light.group",
}

local function observe(metric)
  local span = metric and metrics:start(metric)
  if span then
    return function()
      metrics:finish(span, "ok")
    end
  end
end

function Adapter:observeProxy(command)
  return observe(LightHandlers.isSceneCommand(command) and "light.scene" or proxyOperations[command])
end

function Adapter:observeSceneStep()
  return observe("light.scene_step")
end

local function colorParameters(device, format, color, parameters)
  if type(color) ~= "table" or not xy(color.x, color.y) then
    return nil
  end
  if color.mode == Color.CCT and device.cct then
    local k = color.kelvin or Color.kelvin(color.x, color.y)
    if not inRange(k, 1, 99999) then
      return nil
    end
    parameters.color_temp_kelvin = math.floor(math.max(device.cct.minK, math.min(device.cct.maxK, k)) + 0.5)
    return "light.cct"
  elseif device.color then
    if format == "RGB" then
      local r, g, b = Color.xyToRGB(color.x, color.y)
      if not (inRange(r, 0, 1) and inRange(g, 0, 1) and inRange(b, 0, 1)) then
        return nil
      end
      parameters.rgb_color = codec.array({ Range.step(r, STEPS), Range.step(g, STEPS), Range.step(b, STEPS) })
    elseif format == "HS" then
      local hue, saturation = C4:ColorXYtoHSV(color.x, color.y)
      if not (inRange(hue, 0, 360) and inRange(saturation, 0, 100)) then
        return nil
      end
      parameters.hs_color = codec.array({ hue, saturation })
    else
      parameters.xy_color = codec.array({ color.x, color.y })
    end
    return "light.color"
  end
end

function Adapter:send(command)
  local consumer, entity, device = self.consumer, self.entity, self.device
  if self.destroyed or not consumer or not entity or not device or (not command.on and not command.setsLevel) then
    return
  end
  local parameters = codec.object({})
  local action = command.on and "turn_on" or "turn_off"
  local operation = command.on and "light.on" or "light.off"
  -- Use the library's On level when the proxy supplied a mode or Default On Brightness.
  if
    command.on
    and command.setsLevel
    and device.dims
    and (command.intent ~= "on" or self.light.settings:hasConfiguredOnLevel())
  then
    if not inRange(command.level, 0, 1) then
      return
    end
    parameters.brightness = math.max(1, Range.step(command.level, STEPS))
    operation = "light.level"
  end
  if command.on and command.setsColor then
    operation = colorParameters(device, self.colorFormat, command.color, parameters) or operation
  end
  if command.kind == "stop" and not self.transition then
    return
  end
  if self.transition and (command.transitionMs > 0 or command.kind == "stop") then
    parameters.transition = command.transitionMs / 1000
    operation = command.kind == "stop" and "light.stop" or "light.ramp"
  end
  if
    not command.setsLevel
    and not (parameters.rgb_color or parameters.xy_color or parameters.hs_color or parameters.color_temp_kelvin)
  then
    return
  end

  self:_sendService(action, parameters, operation)
end

return Adapter
