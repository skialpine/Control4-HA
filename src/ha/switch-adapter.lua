-- Binary load notifications and native command routing for the Switch family.
require("lib.utils")
local ids = require("ha.identities")
local contract = require("ha.contract")
local loadCommand = require("ha.load-command")
local metrics = require("ha.performance").shared
local values = require("lib.values")

local Adapter = {}
Adapter.__index = Adapter

local presentation = {
  on = { label = "On", relay = "CLOSED" },
  off = { label = "Off", relay = "OPENED" },
  buttons = { label = "Buttons only" },
  unavailable = { label = "Unavailable" },
}
local relayActions = { CLOSE = "on", OPEN = "off", TOGGLE = "toggle" }
local serviceActions = { on = "turn_on", off = "turn_off", toggle = "toggle" }
local buttonActions = { ["0"] = "on", ["1"] = "off" }

local function clickAction(params)
  if type(params) ~= "table" or (params.ACTION ~= 2 and params.ACTION ~= "2") then
    return nil
  end
  local button = params.BUTTON_ID
  if type(button) == "number" and (button == 0 or contract.integer(button)) then
    button = tostring(button)
  end
  if type(button) == "string" and (button == "" or button:match("^%d+$")) then
    return buttonActions[button] or "toggle"
  end
end

function Adapter.new()
  return setmetatable({ generation = 0 }, Adapter)
end

function Adapter:confirmed()
  local consumer, entity = self.consumer, self.entity
  if
    not self.destroyed
    and self.state
    and consumer
    and entity
    and consumer:_current()
    and consumer.readiness:view(entity).evidence_ready
  then
    return self.state
  end
end

function Adapter:command(action)
  if not self.state or not serviceActions[action] then
    return false
  end
  local generation = self.generation
  local sent = loadCommand.send(self.consumer, self.entity, serviceActions[action], {}, self.onResult, function()
    return not self.destroyed and generation == self.generation
  end, "switch." .. action)
  return sent and generation == self.generation
end

function Adapter:publish(state, event)
  local icon = state or (self.buttonsReady and "buttons" or "unavailable")
  local definition = presentation[icon]
  local span = metrics:start("switch.feedback")
  values:update("State", definition.label, "STRING")
  values:update("Available", state ~= nil, "BOOL")
  C4:SendToProxy(ids.proxy, "ICON_CHANGED", { icon = icon, icon_description = definition.label })
  if definition.relay then
    -- The relay protocol distinguishes initialization from a transition.
    local relay = event and definition.relay or "STATE_" .. definition.relay
    C4:SendToProxy(ids.relay, relay, {}, "NOTIFY")
  end
  if event then
    C4:FireEventByID(event)
  end
  metrics:finish(span, "ok")
end

function Adapter:setButtonsReady(ready)
  if self.destroyed or self.buttonsReady == ready then
    return
  end
  local previous = self.buttonsReady
  self.buttonsReady = ready
  if not self.state and (previous or ready) then
    self:publish(nil)
  end
end

function Adapter:start()
  if self.destroyed or self.owned then
    return
  end
  self.owned = {}
  local function install(handlers, key, fn)
    handlers[key] = fn
    self.owned[#self.owned + 1] = { handlers, key, fn }
  end
  for command, action in pairs({ TurnOn = "on", TurnOff = "off", Toggle = "toggle" }) do
    install(EC, command, function()
      return self:command(action)
    end)
  end
  install(RFP, ids.proxy, function(_, command)
    return command == "SELECT" and self:command("toggle")
  end)
  install(RFP, ids.relay, function(_, command, params)
    return self:command(command == "BUTTON_ACTION" and clickAction(params) or relayActions[command])
  end)
  local function link(id, action)
    install(RFP, id, function(_, command, params)
      if command == "BUTTON_ACTION" then
        return self:command(clickAction(params))
      end
      return command == "DO_CLICK" and self:command(action)
    end)
  end
  link(ids.links.top, "on")
  link(ids.links.bottom, "off")
  link(ids.links.toggle, "toggle")
  install(TC, "IS_ON", function()
    return self:confirmed() == "on"
  end)
  install(TC, "IS_OFF", function()
    return self:confirmed() == "off"
  end)
  install(TC, "IS_AVAILABLE", function()
    return self:confirmed() ~= nil
  end)
  self:publish(nil)
end

function Adapter:lost(entity)
  if self.destroyed or (entity and entity ~= self.entity) then
    return
  end
  self.generation = self.generation + 1
  if not entity then
    self:setButtonsReady(false)
  end
  if self.state then
    self.state = nil
    self:publish(nil, entity and ids.events.unavailable)
  end
end

function Adapter:bind(consumer, entity, onResult)
  if self.destroyed then
    return
  end
  self:lost()
  self.consumer, self.onResult = consumer, onResult
  self.entity = contract.loadDomain(entity) and entity or nil
end

function Adapter:unbind()
  self:bind(nil)
end

function Adapter:destroy()
  if self.destroyed then
    return
  end
  self:unbind()
  self.destroyed = true
  for _, owned in ipairs(self.owned or {}) do
    local handlers, key, fn = unpack(owned)
    if handlers[key] == fn then
      handlers[key] = nil
    end
  end
  self.owned = nil
end

function Adapter:message(kind, data)
  if self.destroyed or not self.entity or data.entity_id ~= self.entity then
    return
  end
  if
    kind == "failure"
    or (kind == "readiness" and not (data.transport and data.subscription and data.snapshot and data.available))
  then
    self:lost(self.entity)
    return
  end
  if kind ~= "snapshot" and kind ~= "state" then
    return
  end
  if data.state ~= "on" and data.state ~= "off" then
    self:lost(self.entity)
    return
  end
  local previous = self.state
  self.state = data.state
  if previous ~= data.state then
    local event
    if previous and kind == "state" then
      event = data.state == "on" and ids.events.stateOn or ids.events.stateOff
    end
    self:publish(data.state, event)
  end
end

return Adapter
