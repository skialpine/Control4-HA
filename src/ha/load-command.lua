-- The family adapter owns native command semantics. The Coordinator owns HA
-- acceptance; only a separate selected-entity report can confirm load state.
local codec = require("ha.codec")
local metrics = require("ha.performance").shared
local M = {}

local uncertain = { timeout = true, disconnected = true, rejected = true, invalid_response = true, not_found = true }

function M.uncertain(status)
  return uncertain[status] == true
end

function M.read(consumer, entity)
  return consumer:request("read_load", entity, codec.object({}))
end

function M.send(consumer, entity, action, parameters, onResult, isCurrent, metric)
  if not consumer or not entity or not consumer.readiness:view(entity).evidence_ready then
    return false
  end
  local span = metrics:start(metric)
  local result =
    consumer:request("service", entity, codec.object({ action = action, parameters = codec.object(parameters) }))
  metrics:finish(span, "ok")
  if onResult then
    local function publish(status)
      if isCurrent() then
        onResult(status)
      end
    end
    result:next(function()
      publish("accepted")
    end, function(failure)
      publish(failure.kind)
    end)
  end
  return true
end
return M
