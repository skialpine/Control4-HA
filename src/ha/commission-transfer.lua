-- Transfers a selection only inside a confirmed commissioning plan. The child
-- first agrees it can take the choice. The Hub then resolves against that
-- exact registration and the child confirms after applying the result.
local codec = require("ha.codec")
local contract = require("ha.contract")
local Selection = require("ha.selection")
local deferred = require("deferred")
local Transfer = {}
Transfer.__index = Transfer
local OFFER_RETRY_DELAYS = { 250, 750, 1500, 3000 }

function Transfer.new(hub)
  return setmetatable({ hub = hub, serial = 0 }, Transfer)
end

function Transfer:finish(job, failure)
  if self.job ~= job then
    return
  end
  self.job = nil
  pcall(CancelTimer, self.hub.prefix .. "commission")
  pcall(CancelTimer, self.hub.prefix .. "commission.offer")
  pcall(CancelTimer, self.hub.prefix .. "commission.readback")
  if failure then
    job.promise:reject({ kind = failure, step = job.phase })
  else
    job.promise:resolve(true)
  end
end

function Transfer:offer(consumer, retry)
  local job = self.job
  if
    not job
    or not consumer
    or job.device ~= consumer.device
    or (job.phase ~= "waiting" and (job.phase ~= "offered" or (job.owner == consumer and not retry)))
  then
    return
  end
  job.owner, job.phase = consumer, "offered"
  self.hub:_emit(
    consumer,
    "commission_offer",
    { ticket = job.ticket, key = job.query.choice_id, family = job.query.family, stage_settings = job.stageSettings }
  )
end

function Transfer:retryOffer(job, attempt)
  local delay = OFFER_RETRY_DELAYS[attempt]
  if self.job ~= job or not delay or (job.phase ~= "waiting" and job.phase ~= "offered") then
    return
  end
  SetTimer(self.hub.prefix .. "commission.offer", delay, function()
    if self.job ~= job or (job.phase ~= "waiting" and job.phase ~= "offered") then
      return
    end
    local consumer = self.hub.consumers[job.device]
    if consumer then
      -- Restore the selection reply before retrying the offer. A blank child
      -- has no load subscriptions to prompt its ordinary rejoin timer.
      self.hub:_emit(consumer, "selected", codec.object({}))
      self:offer(consumer, true)
    else
      self.hub:resetConsumer(job.device)
    end
    self:retryOffer(job, attempt + 1)
  end)
end

function Transfer:_start(device, query, verified, lightSettings, stageSettings, migration)
  local promise = deferred.new()
  query = codec.object(query)
  local blocked
  if self.job then
    blocked = "busy"
  elseif not contract.integer(device) or (not verified and (not Selection.query(query) or not query.prepare)) then
    blocked = "invalid_request"
  elseif not self.hub.online then
    blocked = "offline"
  elseif not self.hub:_owns(device) then
    blocked = "unverified_binding"
  end
  if blocked then
    promise:reject({ kind = "configuration_unconfirmed", step = blocked })
    return promise
  end
  self.serial = self.serial + 1
  local job = {
    ticket = self.serial,
    device = device,
    query = query,
    verified = verified,
    promise = promise,
    phase = "waiting",
    lightSettings = lightSettings,
    stageSettings = stageSettings,
    migration = migration,
  }
  self.job = job
  SetTimer(self.hub.prefix .. "commission", 45000, function()
    self:finish(job, "timeout")
  end)
  self:offer(self.hub.consumers[device])
  self:retryOffer(job, 1)
  return promise
end

function Transfer:start(device, query)
  return self:_start(device, query)
end

-- The upgrade operation reads this exact load from HA before releasing the
-- source. Use the existing session-scoped child offer and acknowledgment.
function Transfer:directLoad(device, family, entity, name, lightSettings, migration)
  local query = { choice_id = entity, family = family }
  local config = Selection.directLoad(family, entity, name)
  assert(Selection.valid(config, query), "Invalid direct load selection")
  return self:_start(device, query, config, lightSettings, nil, migration)
end

function Transfer:stageLightSettings(device, entity, settings)
  assert(contract.loadDomain(entity) == "light" and codec.isObject(settings), "Invalid Light settings transfer")
  return self:_start(device, { choice_id = entity, family = "light" }, true, settings, true)
end

function Transfer:directSwitch(device, entity, name)
  return self:directLoad(device, "switch", entity, name)
end

function Transfer:preparedSwitch(device, config)
  local arguments = { choice_id = config.key, family = "switch" }
  assert(Selection.valid(config, arguments), "Invalid prepared Switch selection")
  return self:_start(device, arguments, config)
end

function Transfer:checkApplied(job, remaining)
  if self.job ~= job or not job.migration or not job.migration.applied then
    return
  end
  SetTimer(self.hub.prefix .. "commission.readback", 1000, function()
    if self.job == job and self.hub.online and self.hub:_owns(job.device) then
      local ok, applied = pcall(job.migration.applied)
      if ok and applied then
        self:finish(job)
      elseif remaining > 1 then
        self:checkApplied(job, remaining - 1)
      else
        self:finish(job, "configuration_unconfirmed")
      end
    end
  end)
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
  pcall(CancelTimer, self.hub.prefix .. "commission.offer")
  local function active()
    return self.job == job
      and self.hub.online
      and self.hub.consumers[job.device] == consumer
      and self.hub:_owns(job.device)
  end
  if job.verified then
    local function apply(ready)
      if not ready or not active() then
        return self:finish(job, "configuration_unconfirmed")
      end
      job.phase = "applying"
      -- Settings-only jobs never send a selection to the child.
      self.hub:_emit(consumer, "commission_apply", {
        ticket = job.ticket,
        config = not job.stageSettings and job.verified or nil,
        light_settings = job.lightSettings,
      })
      self:checkApplied(job, 4)
    end
    if job.migration then
      job.phase = "releasing"
      local ok, ready = pcall(job.migration.beforeApply, active)
      if ok and type(ready) == "table" and type(ready.next) == "function" then
        ready:next(apply, function()
          apply(false)
        end)
      else
        apply(ok and ready == true)
      end
    else
      apply(true)
    end
    return true
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
