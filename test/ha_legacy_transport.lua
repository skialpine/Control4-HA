local codec = require("ha.codec")
local deferred = require("deferred")
return function()
  local conn = { state = "connected", generation = 1, sent = {}, reads = 0, reading = {}, subscriptions = {} }
  function conn:send(message)
    self.sent[#self.sent + 1] = message
    if message.type == "subscribe_trigger" then
      self.subscriptions[message.trigger.entity_id] = message.id
    end
    self.onMessage(codec.object({ type = "result", id = message.id, success = true }))
    return true
  end
  function conn:readState(entity)
    self.reads = self.reads + 1
    self.entity = entity
    self.pending = deferred.new()
    self.reading[entity] = self.pending
    return self.pending
  end
  function conn:configure() end
  function conn:destroy() end
  return conn
end
