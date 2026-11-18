--- Advanced Lighting Scenes: the scenes the proxy pushes, kept under the `scenes` key, and the one run
--- of their steps. Each step becomes one intent for Motion. The step timer is timed from each step's own
--- delay and rate, never from the device's fade.

local log = require("lib.logging")
local persist = require("lib.persist")
local Timer = require("lib.light.timer")
local Fade = require("lib.light.fade")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

-- The key every release stored the scenes under, in the shape below.
local P_SCENES = "scenes"

-- The proxy's color mode for a color temperature.
local COLOR_MODE_CCT = 1

--- One step of a scene, as stored.
--- @class LightSceneStep
--- @field delay integer Ms to wait before the step.
--- @field brightnessRate integer
--- @field colorRate integer
--- @field level number|nil C4 level 0-100.
--- @field levelEnabled boolean
--- @field colorEnabled boolean
--- @field colorX number|nil
--- @field colorY number|nil
--- @field colorMode integer|nil The proxy's color mode: 0 full color, 1 a color temperature.

--- One scene, as stored.
--- @class LightScene
--- @field elements LightSceneStep[]
--- @field flash boolean
--- @field ignoreRamp boolean
--- @field fromGroup boolean
--- @field state integer

--- What the timer does when it fires: take the step it waited for, or move to the next one.
--- @alias LightSceneDue "apply"|"advance"|"walk"

--- The one scene running.
--- @class LightSceneRun
--- @field id integer
--- @field idx integer The step taken or waited for, 0 before the first.
--- @field scene LightScene|nil The saved activation. An interactive software ramp has no scene steps.
--- @field walk LightSceneWalk|nil
--- @field due LightSceneDue

--- @class LightSceneWalk
--- @field from number
--- @field to number
--- @field elapsed integer
--- @field duration integer
--- @field wait integer Remaining dwell after a timed scene step.

--- @class LightScenes
--- @field light Light
--- @field profile LightProfile
--- @field run LightSceneRun|nil
--- @field generation integer Bumped by every stop, so a timer from an earlier run takes nothing.
--- @field ramping integer|nil The ID of the interactive scene ramp Stop Scene Ramp can stop.
local Scenes = {}
Scenes.__index = Scenes

--- @param light Light
--- @param profile LightProfile
--- @return LightScenes
function Scenes.new(light, profile)
  return setmetatable({ light = light, profile = profile, run = nil, generation = 0, ramping = nil }, Scenes)
end

--- @return table<string, LightScene>
local function stored()
  return persist:get(P_SCENES, {})
end

--- @param scenes table<string, LightScene>
local function store(scenes)
  persist:set(P_SCENES, scenes)
end

--- @param id integer
--- @return string
local function timerName(id)
  return "Light.Scene." .. tostring(id)
end

--- @param tParams table<string, string>|nil
--- @return integer|nil
local function sceneId(tParams)
  local id = tofinite(Select(tParams, "SCENE_ID"))
  if id and id >= 1 and id <= 2147483647 and id == math.floor(id) then
    return id
  end
end

local MAX_SCENES = 128
local MAX_ELEMENTS = 128
local MAX_XML_BYTES = 32768
local MAX_RATE_MS = 86400000
local MIN_FLASH_MS = 250
local WALK_STEP_MS = 250

local function bounded(value, max, whole)
  local n = tofinite(value)
  if n and n >= 0 and n <= max and (not whole or n == math.floor(n)) then
    return n
  end
end

--- Read the flat leaf fields used by Light V2. The outer ELEMENTS tag is
--- optional. A malformed replacement must leave the previous scene intact.
local function parseElements(xml)
  if type(xml) ~= "string" or #xml > MAX_XML_BYTES then
    return nil
  end
  local wrapper, content = xml:match("^%s*<(%a+)%s*>(.-)</%1%s*>%s*$")
  if wrapper and wrapper:lower() == "elements" then
    xml = content
  end
  local steps, valid = {}, true
  local rest = xml:gsub("<element%s*>(.-)</element%s*>", function(body)
    if not valid or #steps >= MAX_ELEMENTS then
      valid = false
      return ""
    end
    local fields = {}
    local tail = body:gsub("<([%w_]+)%s*>([^<>]*)</%1%s*>", function(key, value)
      if fields[key] ~= nil then
        valid = false
      end
      fields[key] = value:match("^%s*(.-)%s*$")
      return ""
    end)
    local rawLevel = fields.brightness or fields.level
    local levelEnabled = toboolean(fields.brightnessEnabled)
      or (fields.brightnessEnabled == nil and fields.colorEnabled == nil and rawLevel ~= nil)
    local step = {
      delay = bounded(fields.delay or 0, MAX_RATE_MS, true),
      brightnessRate = bounded(fields.brightnessRate or fields.rate or 0, MAX_RATE_MS, true),
      colorRate = bounded(fields.colorRate or fields.brightnessRate or fields.rate or 0, MAX_RATE_MS, true),
      level = bounded(rawLevel, 100),
      levelEnabled = levelEnabled,
      colorEnabled = toboolean(fields.colorEnabled),
      colorX = bounded(fields.colorX, 1),
      colorY = bounded(fields.colorY, 1),
      colorMode = bounded(fields.colorMode or 0, 1, true),
    }
    local x, y = step.colorX, step.colorY
    if
      tail:find("%S")
      or not step.delay
      or not step.brightnessRate
      or not step.colorRate
      or (step.levelEnabled and step.level == nil)
      or (step.colorEnabled and (not x or not y or x + y <= 0 or x + y > 1 or not step.colorMode))
    then
      valid = false
    end
    steps[#steps + 1] = step
    return ""
  end)
  if valid and not rest:find("%S") then
    return steps
  end
end

--- How long a step takes: the longer of its two rates.
--- @param step LightSceneStep
--- @return integer
local function stepMs(step)
  return math.max(0, step.brightnessRate or 0, step.colorRate or 0)
end

--- The intent a step asks for: its level, its color, or both in one command. Nil for a step that only waits.
--- @param step LightSceneStep
--- @return LightIntent|nil
local function stepIntent(step)
  local level = step.levelEnabled and step.level or nil
  --- @type LightColor|nil
  local color = nil
  if step.colorEnabled and step.colorX and step.colorY then
    color = { x = step.colorX, y = step.colorY, mode = step.colorMode == COLOR_MODE_CCT and "cct" or "xy" }
  end
  if level == nil and color == nil then
    return nil
  end
  return {
    kind = level ~= nil and "level" or "color",
    level = level and math.max(0, math.min(100, level)) or nil,
    color = color,
    rateMs = stepMs(step),
    sceneLevelRate = step.brightnessRate,
    sceneColorRate = step.colorRate,
    source = "scene",
  }
end

--- Arm the run's timer. Its function takes nothing once a stop has bumped the generation.
--- @private
--- @param ms integer
function Scenes:_arm(ms)
  local id, generation, light = self.run.id, self.generation, self.light
  Timer.arm(timerName(id), ms, function()
    if generation == self.generation then
      light:_sceneStep(id)
    end
  end, false)
end

--- Look up a saved scene, with a read-only fallback for earlier driver formats.
function Scenes:_saved(id)
  local key = tostring(id)
  local scene = stored()[key]
  if type(scene) == "table" and type(scene.elements) == "table" then
    return scene
  end
  local legacy = self.light.adapter.legacyScene
  local old = legacy and legacy(self.light.adapter, key)
  if type(old) == "table" and type(old.xml) == "string" then
    local steps = parseElements(old.xml)
    if steps then
      return { elements = steps, flash = old.flash == true, ignoreRamp = old.ignore == true }
    end
  end
end

local function validFlash(scene)
  local cycle = 0
  for _, step in ipairs(scene.elements) do
    cycle = cycle + (step.delay or 0) + stepMs(step)
    if cycle >= MIN_FLASH_MS then
      return true
    end
  end
  return false
end

--- Move to the next step. A validated flash scene repeats with a minimum dwell on each step.
--- @private
--- @return LightIntent|nil
function Scenes:_advance()
  local run = self.run
  local scene = run and run.scene
  if not scene then
    self:stopSteps()
    return nil
  end
  local idx = run.idx + 1
  if idx > #scene.elements then
    if scene.flash and self.profile.flash then
      idx = 1
    else
      self:stopSteps()
      return nil
    end
  end
  run.idx = idx
  local delay = math.max(0, scene.elements[idx].delay or 0)
  if delay > 0 then
    run.due = "apply"
    self:_arm(delay)
    return nil
  end
  return self:_apply()
end

--- Use the shared fade curve for a scene on a load without a native fade.
--- All increments use the scene timer so overrides and target changes retire them.
function Scenes:_walk(from, to, duration, dwell)
  if duration <= 0 then
    return false
  end
  self.run.due = "walk"
  self.run.walk = { from = from, to = to, elapsed = 0, duration = duration, wait = math.max(1, dwell - duration) }
  self:_arm(math.min(WALK_STEP_MS, duration))
  return true
end

function Scenes:_walkLevel()
  local run = self.run
  local walk = run.walk
  walk.elapsed = math.min(walk.elapsed + WALK_STEP_MS, walk.duration)
  local level = Fade.between(walk.from, walk.to, walk.elapsed / walk.duration)
  if walk.elapsed < walk.duration then
    self:_arm(math.min(WALK_STEP_MS, walk.duration - walk.elapsed))
  elseif run.scene then
    run.walk, run.due = nil, "advance"
    self:_arm(walk.wait)
  else
    self:stopSteps()
  end
  return { kind = "level", level = level, rateMs = 0, source = "scene" }
end

local function softwareLevel(self, interactive)
  local read = self.light.adapter.softwareSceneLevel
  return read and read(self.light.adapter, interactive) or nil
end

--- Take the run's step, and time the move to the next from the step's own rate.
--- @private
--- @return LightIntent|nil
function Scenes:_apply()
  local run = self.run
  local scene = run and run.scene
  if not scene or not scene.elements[run.idx] then
    self:stopSteps()
    return nil
  end
  local step = scene.elements[run.idx]
  local ms = stepMs(step)
  local dwell = scene.flash and self.profile.flash and math.max(MIN_FLASH_MS, ms) or ms
  local intent = stepIntent(step)
  self.ramping = nil
  if intent and intent.level ~= nil and step.brightnessRate > 0 then
    local level = softwareLevel(self, false)
    if level ~= nil and self:_walk(level, intent.level, step.brightnessRate, dwell) then
      if intent.color then
        return {
          kind = "color",
          color = intent.color,
          rateMs = step.colorRate,
          sceneColorRate = step.colorRate,
          source = "scene",
        }
      end
      return nil
    end
  end
  run.due = "advance"
  self:_arm(dwell)
  return intent
end

--- End the run: no later step moves the light. A step's ramp in flight is Motion's and runs on.
function Scenes:stopSteps()
  self.generation = self.generation + 1
  if self.run then
    CancelTimer(timerName(self.run.id))
    self.run = nil
  end
end

--- Another hand moved the light. A level or an on from elsewhere ends the run; a color does not.
--- @param aspects LightAspect[]
function Scenes:foreign(aspects)
  for _, aspect in ipairs(aspects) do
    if aspect == "level" or aspect == "on" then
      self:stopSteps()
      self.ramping = nil
      return
    end
  end
end

--- The run is replaced: the light was lost or reset.
function Scenes:reset()
  self:stopSteps()
  self.ramping = nil
end

--- The run's timer fired for scene `id`.
--- @param id integer
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:step(id, _now)
  local run = self.run
  if not run or run.id ~= id then
    return nil
  end
  if run.due == "apply" then
    return self:_apply()
  elseif run.due == "walk" then
    return self:_walkLevel()
  end
  return self:_advance()
end

--- PUSH_SCENE: store a scene's steps.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:push(tParams, _now)
  local id = sceneId(tParams)
  if id == nil then
    return nil
  end
  local elements = parseElements(Select(tParams, "ELEMENTS"))
  if not elements then
    return nil
  end
  local scene = {
    elements = elements,
    flash = toboolean(Select(tParams, "FLASH")),
    ignoreRamp = toboolean(Select(tParams, "IGNORE_RAMP")),
    fromGroup = toboolean(Select(tParams, "FROM_GROUP")),
    state = 0,
  }
  if scene.flash and not validFlash(scene) then
    return nil
  end
  local scenes = stored()
  local count = 0
  for _ in pairs(scenes) do
    count = count + 1
  end
  local key = tostring(id)
  if scenes[key] == nil and count >= MAX_SCENES then
    return nil
  end
  local stop = self:stopRamp(tParams)
  scenes[key] = scene
  store(scenes)
  log:debug("Stored scene %s with %d step(s)", id, #elements)
  return stop
end

--- REMOVE_SCENE.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:remove(tParams, _now)
  local id = sceneId(tParams)
  if id == nil then
    return nil
  end
  local stop = self:stopRamp(tParams)
  local scenes = stored()
  scenes[tostring(id)] = nil
  store(scenes)
  local forget = self.light.adapter.forgetLegacyScene
  if forget then
    forget(self.light.adapter, tostring(id))
  end
  return stop
end

--- CLEAR_ALL_SCENES.
--- @param _tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:clear(_tParams, _now)
  local ramp = self.ramping
  self:reset()
  store({})
  local forget = self.light.adapter.forgetLegacyScene
  if forget then
    forget(self.light.adapter)
  end
  if ramp then
    return { kind = "stop", source = "scene" }
  end
end

--- ACTIVATE_SCENE: run a scene from its first step, ending any other.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:activate(tParams, _now)
  local id = sceneId(tParams)
  if id == nil then
    return nil
  end
  local scene = self:_saved(id)
  if not scene then
    log:warn("ACTIVATE_SCENE: unknown scene id %s", id)
    return nil
  end
  if #scene.elements == 0 or (scene.flash and not validFlash(scene)) then
    return nil
  end
  local validate = self.light.adapter.validateScene
  if validate then
    for _, step in ipairs(scene.elements) do
      local intent = stepIntent(step)
      if intent and not validate(self.light.adapter, intent) then
        return nil
      end
    end
  end
  local ramp = self.ramping
  self:reset()
  self.run = { id = id, scene = scene, idx = 0, due = "advance" }
  local intent = self:_advance()
  if not intent and ramp then
    return { kind = "stop", source = "scene" }
  end
  return intent
end

--- DEACTIVATE_SCENE stops any pending steps and interactive ramp for the named scene.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:deactivate(tParams, _now)
  return self:stopRamp(tParams, _now)
end

--- RAMP_SCENE_UP or RAMP_SCENE_DOWN, unless the scene ignores ramps: the steps stop, and the light ramps to
--- full or off over the asked time, in the color of the scene's last element.
--- @private
--- @param tParams table<string, string>
--- @param up boolean
--- @return LightIntent|nil
function Scenes:_ramp(tParams, up)
  local id = sceneId(tParams)
  local scene = id and self:_saved(id)
  if not scene or scene.ignoreRamp or not (self.light.device and self.light.device.dims) then
    return nil
  end
  local rawRate = Select(tParams, "RATE")
  local rate = bounded(rawRate or 5000, MAX_RATE_MS, true)
  if rate == nil then
    return nil
  end
  self:stopSteps()
  local target = up and 100 or 0
  local level = softwareLevel(self, true)
  if level ~= nil and rate > 0 and target ~= level then
    local wasRamping = self.ramping
    self.ramping = nil
    self.run = { id = id, idx = 0 }
    self:_walk(level, target, math.max(1, math.ceil(rate * math.abs(target - level) / 100)), 0)
    if wasRamping then
      return { kind = "stop", source = "scene" }
    end
    return nil
  end
  local last = scene.elements[#scene.elements]
  local step = last and stepIntent(last)
  self.ramping = id
  return {
    kind = "level",
    level = target,
    color = step and step.color or nil,
    rateMs = rate,
    source = "scene",
    ramp = true,
  }
end

--- RAMP_SCENE_UP.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:rampUp(tParams, _now)
  return self:_ramp(tParams, true)
end

--- RAMP_SCENE_DOWN.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:rampDown(tParams, _now)
  return self:_ramp(tParams, false)
end

--- Both native stop spellings stop the named scene and any interactive ramp it owns.
--- A step's own fade runs to its end.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:stopRamp(tParams, _now)
  local id = sceneId(tParams)
  if self.run and self.run.id == id then
    self:stopSteps()
  end
  if not id or self.ramping ~= id then
    return nil
  end
  self.ramping = nil
  return { kind = "stop", source = "scene" }
end

--- TOGGLE_SCENE: the light keeps no scene's active state, so it activates; the agent tracks the toggle.
--- @param tParams table<string, string>
--- @param now LightNow
--- @return LightIntent|nil
function Scenes:toggle(tParams, now)
  return self:activate(tParams, now)
end

return Scenes
