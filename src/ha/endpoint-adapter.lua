-- Shared feedback and handler lifecycle for native Home Assistant endpoints.
local contract = require("ha.contract")
local loadCommand = require("ha.load-command")
local metrics = require("ha.performance").shared
local values = require("lib.values")

local Adapter = {}
Adapter.__index = Adapter

function Adapter.installHandler(owner, handlers, key, handler)
  handlers[key] = handler
  owner.owned[#owner.owned + 1] = { handlers, key, handler }
end

function Adapter.removeHandlers(owner)
  for _, entry in ipairs(owner.owned or {}) do
    local handlers, key, handler = unpack(entry)
    if handlers[key] == handler then
      handlers[key] = nil
    end
  end
  owner.owned = nil
end

-- A family supplies domain validation, state decoding and native publication.
-- Only an authenticated selected endpoint report can change published state.
function Adapter.new(definition)
  return setmetatable({ definition = definition, generation = 0 }, Adapter)
end

function Adapter:handle(handlers, key, handler)
  Adapter.installHandler(self, handlers, key, handler)
end

function Adapter:start()
  if self.destroyed or self.owned then
    return
  end
  self.owned = {}
  self.definition.install(self)
  self:publish(nil, nil, "initial")
end

function Adapter:publish(state, previous, kind)
  local span = metrics:start(self.definition.family .. ".feedback")
  values:update("Available", state ~= nil, "BOOL")
  values:update("State", state and state.label or "Unavailable", "STRING")
  self.definition.publish(state, previous, kind, self)
  metrics:finish(span, state and "ok" or "unavailable")
end

function Adapter:lost(entity)
  if self.destroyed or (entity and entity ~= self.entity) then
    return
  end
  self.generation = self.generation + 1
  local previous = self.state
  if previous then
    self.state = nil
    self:publish(nil, previous, entity and "lost" or "reset")
  end
end

function Adapter:bind(consumer, entity, onResult, _, feedbackChanged)
  if self.destroyed then
    return
  end
  self:lost()
  self.consumer, self.onResult, self.feedbackChanged = consumer, onResult, feedbackChanged
  self.feedbackUnavailable = nil
  self.entity = self.definition.supports(entity) and entity or nil
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
  if self.definition.destroy then
    self.definition.destroy(self)
  end
  Adapter.removeHandlers(self)
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

function Adapter:command(action, parameters, onResult)
  if not self:confirmed() then
    return false
  end
  local generation = self.generation
  self.commandSequence = (self.commandSequence or 0) + 1
  local sequence = self.commandSequence
  return loadCommand.send(self.consumer, self.entity, action, parameters, function(result)
    local latest = self.commandSequence == sequence
    if self.onResult and latest then
      self.onResult(result)
    end
    if onResult then
      onResult(result, latest)
    end
  end, function()
    return not self.destroyed and self.generation == generation and self.consumer:_current()
  end, self.definition.family .. ".dispatch")
end

function Adapter:message(kind, data)
  local entity = self.entity
  if self.destroyed or not entity or data.entity_id ~= entity then
    return
  end
  if
    kind == "failure"
    or (kind == "readiness" and not (data.transport and data.subscription and data.snapshot and data.available))
  then
    self:lost(entity)
    return
  end
  if (kind ~= "snapshot" and kind ~= "state") or not contract.state(data, entity) then
    return
  end
  if self.definition.observe then
    self.definition.observe(data)
  end
  local current
  if data.state ~= "unavailable" and data.state ~= "unknown" then
    current = self.definition.decode(data.state, data.attributes)
  end
  self.feedbackUnavailable = current == nil
  if not current then
    self:lost(entity)
    return
  end
  local previous = self.state
  self.state = current
  if not previous or not self.definition.same(current, previous) then
    self:publish(current, previous, kind)
  end
end

return Adapter
