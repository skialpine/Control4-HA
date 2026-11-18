-- Transfers a selection only inside a confirmed commissioning plan. The child
-- first agrees it can take the choice. The Hub then resolves against that
-- exact registration and the child confirms after applying the result.
local codec = require("ha.codec")
local contract = require("ha.contract")
local Selection = require("ha.selection")
local deferred = require("deferred")
local Transfer = {}
Transfer.__index = Transfer

function Transfer.new(hub)
  return setmetatable({ hub = hub, serial = 0 }, Transfer)
end

function Transfer:finish(job, failure)
  if self.job ~= job then
    return
  end
  self.job = nil
  pcall(CancelTimer, self.hub.prefix .. "commission")
  if failure then
    job.promise:reject({ kind = failure })
  else
    job.promise:resolve(true)
  end
end

function Transfer:offer(consumer)
  local job = self.job
  if not job or not consumer or job.device ~= consumer.device or job.phase ~= "waiting" then
    return
  end
  job.owner, job.phase = consumer, "offered"
  self.hub:_emit(
    consumer,
    "commission_offer",
    { ticket = job.ticket, key = job.query.choice_id, family = job.query.family }
  )
end

function Transfer:start(device, query)
  local promise = deferred.new()
  query = codec.object(query)
  if
    self.job
    or not contract.integer(device)
    or not Selection.query(query)
    or not query.prepare
    or not self.hub.online
    or not self.hub:_owns(device)
  then
    promise:reject({ kind = "configuration_unconfirmed" })
    return promise
  end
  self.serial = self.serial + 1
  local job = { ticket = self.serial, device = device, query = query, promise = promise, phase = "waiting" }
  self.job = job
  SetTimer(self.hub.prefix .. "commission", 45000, function()
    self:finish(job, "timeout")
  end)
  self:offer(self.hub.consumers[device])
  return promise
end

function Transfer:receive(consumer, message)
  local job = self.job
  if
    not job
    or not job.owner
    or not consumer
    or job.device ~= consumer.device
    or job.owner.session ~= consumer.session
    or message.request_id ~= job.ticket
  then
    return false
  end
  if message.op == "commission_ack" and job.phase == "applying" then
    local ok = codec.isObject(message.arguments) and message.arguments.applied == true
    self:finish(job, not ok and "configuration_unconfirmed" or nil)
    return true
  end
  if message.op ~= "commission_claim" or job.phase ~= "offered" or job.owner ~= consumer then
    return false
  end
  if not codec.isObject(message.arguments) or message.arguments.accept ~= true then
    self:finish(job, "target_changed")
    return true
  end
  job.phase = "resolving"
  local function active()
    return self.job == job
      and self.hub.online
      and self.hub.consumers[job.device] == consumer
      and self.hub:_owns(job.device)
  end
  Selection.resolve(self.hub.catalog, function(...)
    return self.hub:_request(...)
  end, job.query, active):next(function(config)
    if active() then
      job.phase = "applying"
      self.hub:_emit(consumer, "commission_apply", { ticket = job.ticket, config = config })
    else
      self:finish(job, "retired")
    end
  end, function(failure)
    self:finish(job, failure.kind)
  end)
  return true
end

function Transfer:cancel()
  if self.job then
    self:finish(self.job, "retired")
  end
end
return Transfer
