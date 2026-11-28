-- Shared exact-entity resources. HA protocol is carried by template transports.
local codec = require("ha.codec")
local ids = require("ha.identities")
local contract = require("ha.contract")
local operations = require("ha.operations")
local indicators = require("ha.indicators")
local lifetime = require("ha.lifetime")
local log = require("lib.logging")
local Catalog = require("ha.catalog")
local catalogNames = require("ha.catalog-names")
local Choices = require("ha.choices")
local metrics = require("ha.performance").shared
local Selection = require("ha.selection")
local Transfer = require("ha.commission-transfer")
local Installation = require("ha.installation-scope")
local SnapshotQueue = require("ha.snapshot-queue")
local endpointState = require("ha.endpoint-state")
require("lib.utils")
local programmedService = require("ha.programmed-service")
local Hub = {}
Hub.__index = Hub
local serial = 0
local integer = contract.integer
local MAX_FAILURES = 3
local SWITCH_WAIT_LIMIT, SWITCH_WAIT_MS = 4, 4000

function Hub.new(connection, emit)
  serial = serial + 1
  local self = setmetatable({
    connection = connection,
    emit = emit,
    consumers = {},
    leases = {},
    entities = {},
    pending = {},
    snapshotQueue = SnapshotQueue.new(),
    scopedCatalogs = {},
    switchServices = {},
    serial = 0,
    epoch = 0,
    prefix = "HA.Hub." .. serial .. ".",
    online = false,
    boot = lifetime.next("HA.Hub.Session"),
  }, Hub)
  self.transfer = Transfer.new(self)
  self.installation = Installation.new(self)
  local function catalogRequest(message, callback)
    return self:_request(message, callback)
  end
  self.catalog = Catalog.new(catalogRequest, function()
    return connection:readCatalog()
  end, function(rows, active, native)
    return Choices.enrich(rows, catalogRequest, active, native)
  end, true)
  local prior = connection.onState
  connection.onState = function(state, detail)
    if prior then
      prior(state, detail)
    end
    self:_transport(state == "connected")
    if state == "connecting" then
      self:retry()
    end
  end
  connection.onMessage = function(message)
    self:_message(message)
  end
  self:_transport(connection.state == "connected")
  return self
end

function Hub:catalogFor(family)
  if not contract.endpointFamily(family) then
    return self.catalog
  end
  if not self.scopedCatalogs[family] then
    local function request(message, callback)
      return self:_request(message, callback)
    end
    self.scopedCatalogs[family] = Catalog.new(request, function()
      return self.connection:readCatalog(family)
    end, function(rows, active, native)
      return Choices.enrich(rows, request, active, native)
    end, false, family)
  end
  return self.scopedCatalogs[family]
end

function Hub:_owns(device, outputs)
  local ok, provider = pcall(contract.provider, device, outputs)
  return ok and provider == C4:GetDeviceID()
end

function Hub:_consumerState(state)
  local domain = contract.endpointDomain(state.entity_id)
  if domain == "climate" then
    return self.connection:addClimateScale(state)
  end
  return endpointState.project(state, domain)
end

function Hub:_emit(consumer, kind, data)
  if not self.destroyed and self.consumers[consumer.device] == consumer and self:_owns(consumer.device) then
    if kind == "snapshot" or kind == "state" then
      data = self:_consumerState(data)
    elseif kind == "result" and data.load_state then
      data.load_state = self:_consumerState(data.load_state)
    end
    local span = metrics:start("consumer.dispatch")
    local sent = pcall(self.emit, consumer.device, {
      version = ids.api,
      coordinator = C4:GetDeviceID(),
      boot = self.boot,
      epoch = self.epoch,
      session = consumer.session,
      selection = consumer.selection,
      kind = kind,
      data = data,
    })
    metrics:finish(span, sent and "ok" or "failed")
  end
end

function Hub:_members(entry, kind, data, legacyStamp)
  if legacyStamp and legacyStamp == entry.legacy and self.legacy then
    local delivery = entry.legacyInitialized and kind or "snapshot"
    local ok, sent = pcall(self.legacy.deliver, self.legacy, delivery, data, legacyStamp)
    if entry.legacy == legacyStamp then
      entry.legacyInitialized = ok and sent == true
    end
  end
  for device in pairs(entry.members) do
    local consumer = self.consumers[device]
    if consumer then
      self:_emit(consumer, kind, data)
    end
  end
end

local function available(state)
  return state ~= nil and state.state ~= "unavailable" and state.state ~= "unknown"
end

function Hub:_readiness(entry, consumer)
  local data = {
    entity_id = entry.entity,
    transport = self.online,
    subscription = entry.ready == true,
    snapshot = entry.state ~= nil,
    available = available(entry.state),
  }
  if consumer then
    self:_emit(consumer, "readiness", data)
  else
    self:_members(entry, "readiness", data)
  end
end

function Hub:_request(message, callback, register, timeout, timingName)
  self.serial = self.serial + 1
  local id = self.serial
  local operation = timingName
    or message.type == "subscribe_trigger" and "subscription.confirm"
    or message.type == "unsubscribe_events" and "subscription.release"
    or message.type == "config/entity_registry/get_entries" and "catalog.registry"
    or message.service == "prepare_device" and "preparation.round_trip"
    or message.service == "get_devices" and "catalog.page"
    or "service.round_trip"
  local span = metrics:start(operation)
  local tracing = log:isEnabled() and log:getLogLevel() >= log.LogLevel.TRACE
  if tracing then
    pcall(log.trace, log, "HA request %d started: %s", id, operation)
  end
  if span then
    self.pendingTimings = self.pendingTimings or {}
    self.pendingTimings[id] = span
  end
  if span or tracing then
    local done = callback
    callback = function(ok, result)
      local kind = type(result) == "table" and result.kind
      local outcome = (kind == "timeout" or kind == "disconnected" or kind == "retired") and kind or "rejected"
      outcome = ok and "accepted" or outcome
      if span then
        self.pendingTimings[id] = nil
        metrics:finish(span, outcome)
      end
      if tracing then
        pcall(log.trace, log, "HA request %d completed: %s", id, outcome)
      end
      return done(ok, result)
    end
  end
  message.id = id
  if register then
    register(id)
  end
  self.pending[id] = callback
  SetTimer(self.prefix .. id, timeout or 10000, function()
    if self.pending[id] == callback then
      self.pending[id] = nil
      callback(false, { kind = "timeout" })
    end
  end)
  local sent, accepted = pcall(self.connection.send, self.connection, message)
  if (not sent or not accepted) and self.pending[id] == callback then
    pcall(CancelTimer, self.prefix .. id)
    self.pending[id] = nil
    callback(false, { kind = "disconnected" })
  end
  return id
end

-- The saved Composer command belongs to this Coordinator. Child-driver
-- operations continue to use their own selection and binding checks.
function Hub:programmedService(params, done)
  if self.destroyed or not self.online then
    return done(false, "Connect to Home Assistant, then run the saved action again.")
  end
  local request, problem = programmedService.request(params)
  if not request then
    return done(false, problem)
  end
  local function complete(status)
    if status == "accepted" then
      done(true)
    elseif status == "disconnected" or status == "timeout" then
      done(false, "Home Assistant did not confirm the saved action. Check the device before running it again.")
    else
      done(false, "Home Assistant declined the saved action. Check Service, Entity ID, Data and account permissions.")
    end
  end
  local entity = request.target and request.target.entity_id
  if
    request.domain == "switch"
    and contract.loadDomain(entity) == "switch"
    and (request.service == "turn_on" or request.service == "turn_off" or request.service == "toggle")
  then
    self:_switchService(request, complete)
  else
    self:_request(request, function(ok, result)
      complete(ok and "accepted" or result.kind)
    end)
  end
end

-- BP service packets have no request ID or response callback. Use the same
-- sequencer and bounded acceptance measurement as the saved Composer action.
function Hub:legacyService(request)
  if self.online and not self.destroyed then
    self:_request(request, function() end)
  end
end

function Hub:_read(entry)
  if entry.reading or not entry.ready or (entry.readFailures or 0) >= MAX_FAILURES then
    return
  end
  entry.reading = true
  local epoch, queuedRevision = self.epoch, entry.revision
  local queued, ready = metrics:start("snapshot.queue"), metrics:start("snapshot.ready")
  local function current()
    return not self.destroyed and self.epoch == epoch and self.entities[entry.entity] == entry
  end
  local function discard(outcome)
    metrics:finish(queued, outcome)
    metrics:finish(ready, outcome)
    if current() then
      entry.reading = false
      if outcome == "failed" and not entry.state then
        self:_readFailed(entry, "read_failed")
      end
    end
  end
  self.snapshotQueue:push(function(release)
    if not current() then
      discard("retired")
      return release()
    end
    if entry.revision ~= queuedRevision and entry.state and (not entry.legacy or entry.legacyInitialized) then
      discard("accepted")
      return release()
    end
    metrics:finish(queued, "ok")
    local revision, stamp = entry.revision, entry.legacy
    self.connection
      :readState(entry.entity)
      :next(function(state)
        if not current() then
          return metrics:finish(ready, "retired")
        end
        entry.reading = false
        if entry.revision ~= revision then
          return metrics:finish(ready, "retired")
        end
        if not contract.state(state, entry.entity) then
          metrics:finish(ready, "rejected")
          return self:_readFailed(entry, "invalid_state")
        end
        local publish = metrics:start("snapshot.publish")
        entry.state = state
        entry.readFailures = 0
        self:_members(entry, "snapshot", state, stamp)
        self:_readiness(entry)
        metrics:finish(publish, "ok")
        metrics:finish(ready, "ok")
        if entry.legacy and entry.legacy ~= stamp and self.entities[entry.entity] == entry then
          self:_read(entry)
        end
      end, function(failure)
        if not current() then
          return metrics:finish(ready, "retired")
        end
        entry.reading = false
        metrics:finish(ready, failure.kind)
        if not entry.state then
          self:_readFailed(entry, failure.kind)
        end
      end)
      :next(release, release)
  end, discard)
end

function Hub:_retryTimer(entry, boundary, work, failures)
  local epoch = self.epoch
  SetTimer(self.prefix .. boundary .. "." .. entry.entity, 1000 * failures, function()
    if not self.destroyed and self.online and self.epoch == epoch and self.entities[entry.entity] == entry then
      if boundary == "read" and entry.state then
        return
      end
      work(self, entry)
    end
  end)
end

function Hub:_readFailed(entry, kind)
  entry.readFailures = (entry.readFailures or 0) + 1
  self:_members(entry, "failure", { entity_id = entry.entity, boundary = "snapshot", kind = kind })
  self:_readiness(entry)
  if
    entry.readFailures < MAX_FAILURES
    and kind ~= "permission_denied"
    and kind ~= "not_found"
    and kind ~= "redirect_refused"
  then
    self:_retryTimer(entry, "read", self._read, entry.readFailures)
  end
end

function Hub:_start(entry)
  if not self.online or entry.subscription or (entry.subFailures or 0) >= MAX_FAILURES then
    return
  end
  local epoch = self.epoch
  if contract.endpointDomain(entry.entity) == "climate" and entry.climateEpoch ~= epoch then
    if entry.climatePending ~= epoch then
      entry.climatePending = epoch
      self.connection:climateScale():next(function()
        if self.epoch == epoch and self.entities[entry.entity] == entry then
          entry.climateEpoch = epoch
          self:_start(entry)
        end
      end)
    end
    return
  end
  self:_request({
    type = "subscribe_trigger",
    trigger = { platform = "state", entity_id = entry.entity },
  }, function(ok, result)
    if self.destroyed or self.epoch ~= epoch then
      return
    end
    if self.entities[entry.entity] ~= entry then
      -- A pending subscribe may finish after the last owner released it. Wait
      -- for its success before unsubscribing, so a late ack cannot leak it.
      if ok then
        self:_unsubscribe(entry.subscription)
      elseif result.kind == "timeout" then
        self.connection:recover()
      end
      return
    end
    if ok then
      entry.ready = true
      entry.subFailures = 0
      self:_readiness(entry)
      self:_read(entry)
    else
      entry.ready = false
      entry.subscription = nil
      entry.subFailures = (entry.subFailures or 0) + 1
      self:_members(
        entry,
        "failure",
        { entity_id = entry.entity, boundary = "subscription", kind = result.kind or "rejected" }
      )
      self:_readiness(entry)
      if result.kind == "timeout" then
        self.connection:recover()
      elseif entry.subFailures < MAX_FAILURES and result.kind ~= "permission_denied" then
        self:_retryTimer(entry, "subscribe", self._start, entry.subFailures)
      end
    end
  end, function(id)
    entry.subscription = id
  end)
end

function Hub:_unsubscribe(subscription)
  if self.online then
    self:_request({ type = "unsubscribe_events", subscription = subscription }, function(ok)
      if not ok and not self.destroyed then
        self.connection:recover()
      end
    end)
  end
end

function Hub:_stop(entry)
  self.entities[entry.entity] = nil
  pcall(CancelTimer, self.prefix .. "read." .. entry.entity)
  pcall(CancelTimer, self.prefix .. "subscribe." .. entry.entity)
  if entry.subscription then
    if entry.ready then
      self:_unsubscribe(entry.subscription)
    end
  end
end

function Hub:watchLegacy(stamps, requested, retireOnly)
  if self.destroyed then
    return
  end
  -- A new plan can reuse subscriptions that still have owners. A rejected
  -- request may revoke a stale plan but cannot authorize its replacement.
  for entity, entry in pairs(self.entities) do
    if entry.legacy and (not stamps[entity] or (retireOnly and entry.legacy ~= stamps[entity])) then
      entry.legacy, entry.legacyInitialized = nil, nil
      if not next(entry.members) then
        self:_stop(entry)
      end
    end
  end
  if retireOnly then
    return
  end
  for entity, stamp in pairs(stamps) do
    local entry = self.entities[entity]
    if not entry then
      entry = { entity = entity, members = {}, revision = 0 }
      self.entities[entity] = entry
    end
    local changed = entry.legacy ~= stamp
    entry.legacy = stamp
    if changed or entity == requested then
      if changed then
        entry.legacyInitialized = false
      end
      entry.readFailures, entry.subFailures = 0, 0
      if entry.ready then
        self:_read(entry)
      else
        self:_start(entry)
      end
    end
  end
end

function Hub:_release(consumer)
  self:_retireRequests(consumer)
  self.consumers[consumer.device] = nil
  for entity in pairs(consumer.entities) do
    local entry = self.entities[entity]
    if entry then
      entry.members[consumer.device] = nil
      if next(entry.members) == nil and not entry.legacy then
        self:_stop(entry)
      end
    end
  end
end

function Hub:_retireRequests(consumer)
  for id in pairs(consumer.requests or {}) do
    if self.pendingTimings then
      metrics:finish(self.pendingTimings[id], "retired")
      self.pendingTimings[id] = nil
    end
    self.pending[id] = nil
    pcall(CancelTimer, self.prefix .. id)
  end
  consumer.requests = {}
end

function Hub:_readLoad(entity, active, finish)
  local entry = self.entities[entity]
  if not entry or not entry.ready then
    return finish("unavailable")
  end
  local revision = entry.revision
  local function done(state, status)
    if not active() then
      return
    end
    if self.entities[entity] ~= entry then
      return finish("unavailable")
    end
    -- Pushed evidence takes precedence over the reply to an in-flight read.
    if entry.revision ~= revision then
      state, status = entry.state, "unavailable"
    end
    if contract.state(state, entity) then
      finish("load_state", nil, state)
    else
      finish(status)
    end
  end
  self.connection:readState(entity):next(function(state)
    done(state, "invalid_response")
  end, function(failure)
    done(nil, failure.kind)
  end)
end

local function finishWaitingSwitches(lane, status)
  local waiting = lane.waiting
  lane.waiting = {}
  for _, job in ipairs(waiting) do
    job.finish(status)
  end
end

function Hub:_advanceSwitch(entity, lane)
  if self.switchServices[entity] ~= lane then
    return
  end
  while not lane.active and #lane.waiting > 0 do
    table.remove(lane.waiting, 1).start()
  end
  if not lane.active and self.switchServices[entity] == lane then
    self.switchServices[entity] = nil
  end
end

function Hub:_switchService(rpc, reply, consumer, requestId)
  local entity = rpc.target.entity_id
  local lane = self.switchServices[entity]
  if not lane then
    lane = { waiting = {} }
    self.switchServices[entity] = lane
  end
  if #lane.waiting >= SWITCH_WAIT_LIMIT then
    return reply("busy")
  end
  local job = {}
  local key = "switch." .. (consumer and (consumer.device .. "." .. requestId) or tostring(job))
  local timer = self.prefix .. key
  local waiting = lane.active and metrics:start("service.switch_queue") or nil
  local queued = lane.active
  if consumer then
    consumer.requests[key] = true
  end
  function job.finish(status)
    metrics:finish(waiting, status == "timeout" and "timeout" or "retired")
    pcall(CancelTimer, timer)
    if consumer then
      if not consumer.requests[key] then
        return
      end
      consumer.requests[key] = nil
    end
    reply(status)
  end
  function job.start()
    if
      consumer
      and (
        not consumer.requests[key]
        or self.consumers[consumer.device] ~= consumer
        or (queued and not self:_owns(consumer.device))
      )
    then
      job.finish("retired")
      return
    end
    if consumer and queued then
      local entry = self.entities[entity]
      if not entry or not entry.ready or not available(entry.state) then
        return job.finish("unavailable")
      end
    end
    pcall(CancelTimer, timer)
    metrics:finish(waiting, "ok")
    lane.active = true
    -- Keep the lane reserved until the HA result even if the initiating
    -- consumer reselects. Its expired lease cannot receive a reply.
    self:_request(rpc, function(ok, result)
      local status = ok and "accepted" or result.kind or "rejected"
      if status == "timeout" or status == "disconnected" then
        finishWaitingSwitches(lane, status)
      end
      job.finish(status)
      lane.active = false
      self:_advanceSwitch(entity, lane)
    end, nil, nil, operations.timingName(rpc))
  end
  if
    lane.active
    and not SetTimer(timer, SWITCH_WAIT_MS, function()
      for index, queued in ipairs(lane.waiting) do
        if queued == job then
          table.remove(lane.waiting, index)
          job.finish("timeout")
          break
        end
      end
    end)
  then
    return job.finish("busy")
  end
  lane.waiting[#lane.waiting + 1] = job
  self:_advanceSwitch(entity, lane)
end

function Hub:_operation(consumer, message)
  local browsing = message.operation == "catalog"
  local resolving = message.operation == "resolve"
  local verifying = message.operation == "verify_target"
  local reading = message.operation == "read_load"
  local setup = browsing or resolving or verifying
  if
    not integer(message.request_id)
    or message.request_id <= (consumer.lastRequest or 0)
    or (not setup and not consumer.entities[message.entity_id])
  then
    return false
  end
  local rpc = not setup and not reading and operations.build(message.operation, message.entity_id, message.arguments)
  if browsing and not contract.catalogQuery(message.arguments) then
    return false
  end
  if resolving and not Selection.query(message.arguments) then
    return false
  end
  if verifying and not operations.verifyTarget(message.entity_id, message.arguments) then
    return false
  end
  if reading and not operations.readLoad(message.entity_id, message.arguments) then
    return false
  end
  if not setup and not reading and not rpc then
    return false
  end
  consumer.lastRequest = message.request_id
  local active = 0
  for _ in pairs(consumer.requests) do
    active = active + 1
  end
  local function reply(status, prepared, catalog, resolved, loadState)
    self:_emit(consumer, "result", {
      entity_id = message.entity_id,
      request_id = message.request_id,
      operation = message.operation,
      status = status,
      prepared = prepared,
      catalog = catalog,
      resolved = resolved,
      load_state = loadState,
    })
  end
  if active >= 32 then
    reply("busy")
    return true
  end
  if not self.online then
    reply("disconnected")
    return true
  end
  if resolving or verifying or reading then
    local key, epoch = message.operation .. "." .. consumer.device .. "." .. message.request_id, self.epoch
    consumer.requests[key] = true
    local timing = not reading and metrics:start(resolving and "selection.commit" or "selection.verify")
    if timing then
      self.pendingTimings = self.pendingTimings or {}
      self.pendingTimings[key] = timing
    end
    local function active()
      return not self.destroyed
        and self.online
        and self.epoch == epoch
        and consumer.requests[key]
        and self.consumers[consumer.device] == consumer
        and self:_owns(consumer.device)
    end
    local function finish(status, resolved, loadState)
      if not consumer.requests[key] then
        return
      end
      consumer.requests[key] = nil
      if self.pendingTimings then
        self.pendingTimings[key] = nil
      end
      pcall(CancelTimer, self.prefix .. key)
      local success = status == "resolved" or status == "verified" or status == "load_state"
      metrics:finish(timing, success and "ok" or status == "timeout" and "timeout" or "failed")
      reply(status, nil, nil, resolved, loadState)
    end
    SetTimer(self.prefix .. key, resolving and 40000 or 12000, function()
      finish("timeout")
    end)
    if resolving then
      Selection.resolve(self:catalogFor(message.arguments.family), function(...)
        return self:_request(...)
      end, message.arguments, active):next(function(resolved)
        finish("resolved", resolved)
      end, function(failure)
        finish(failure.kind)
      end)
    elseif reading then
      if contract.endpointDomain(message.entity_id) == "climate" then
        self.connection:climateScale():next(function()
          if active() then
            self:_readLoad(message.entity_id, active, finish)
          end
        end)
      else
        self:_readLoad(message.entity_id, active, finish)
      end
    elseif message.arguments.registry_id or message.arguments.event_control then
      local args, entity = message.arguments, message.entity_id
      local entityIds = args.event_control and operations.eventRegistryTargets(entity, args)
        or operations.registryTargets(entity, args)
      self:_request({ type = "config/entity_registry/get_entries", entity_ids = entityIds }, function(ok, response)
        if active() then
          if args.event_control then
            local receipt = ok and operations.eventRegistryReceipt(response, entity, args)
            finish(receipt and "verified" or "unavailable", receipt or nil)
          else
            finish(ok and operations.registryMatches(response, entity, args) and "verified" or "unavailable")
          end
        end
      end)
    else
      self.connection:readState(message.entity_id):next(function(state)
        if active() then
          local ready, reason = operations.targetAvailable(message.entity_id, state, message.arguments)
          finish(ready and "verified" or reason or "unavailable")
        end
      end, function(failure)
        if active() then
          finish(failure.kind)
        end
      end)
    end
    return true
  end
  if browsing then
    local key = "catalog." .. message.request_id
    local catalog = self:catalogFor(message.arguments.family)
    consumer.requests[key] = true
    local function page(rev)
      if not consumer.requests[key] then
        return
      end
      local args = message.arguments
      local values, failure = catalog:read(rev, args.cursor, args.family)
      if not values then
        consumer.requests[key] = nil
        reply(failure)
        return
      end
      local function finish(names, unavailable)
        if not consumer.requests[key] then
          return
        end
        consumer.requests[key] = nil
        local verified = catalog:hasVerifiedSnapshot(rev)
        if not verified then
          reply("revision_changed")
          return
        end
        if names then
          catalogNames.apply(values, names)
        end
        if unavailable then
          values.names_unavailable = true
        end
        if values.next_cursor == codec.null then
          consumer.catalogNames = nil
        end
        reply("catalog", nil, values)
      end
      local sensor = args.names_sensor
      if not sensor or sensor == "" or (sensor == catalogNames.default and values.source == "companion") then
        return finish()
      end
      local previous = consumer.catalogNames
      if args.cursor and previous and previous.sensor == sensor and previous.rev == rev then
        return finish(previous.names, previous.unavailable)
      end
      local function remember(names, unavailable)
        if not consumer.requests[key] then
          return
        end
        consumer.catalogNames = { sensor = sensor, rev = rev, names = names, unavailable = unavailable }
        finish(names, unavailable)
      end
      self.connection:readCatalogNames(sensor):next(function(names)
        remember(names)
      end, function(err)
        remember(nil, sensor ~= catalogNames.default or err.kind ~= "not_found")
      end)
    end
    if message.arguments.cursor then
      page(message.arguments.revision)
    else
      catalog:refresh(message.arguments.refresh):next(function(metadata)
        page(metadata.revision)
      end, function(failure)
        consumer.requests[key] = nil
        reply(failure.kind)
      end)
    end
    return true
  end
  if message.operation == "indicator" then
    local entity, args = message.entity_id, message.arguments
    local entry = self.entities[entity]
    local meta = entry and entry.ready and indicators.metadata(entry.state, entity, args.device, args.control)
    if
      not meta
      or meta.bridge_session_id ~= args.session
      or not indicators.allowed(meta, args.id, args.field, args.value)
    then
      reply("indicator_unavailable")
      return true
    end
  end
  if message.operation == "service" and rpc.domain == "switch" then
    self:_switchService(rpc, reply, consumer, message.request_id)
    return true
  end
  local id
  self:_request(rpc, function(ok, result)
    consumer.requests[id] = nil
    if self.consumers[consumer.device] ~= consumer then
      return
    end
    if not ok then
      reply(result.kind or "rejected")
    elseif message.operation == "prepare" then
      local prepared, invalid = operations.prepared(result, message.entity_id, message.arguments)
      reply(prepared and "prepared" or invalid or "invalid_response", prepared)
    else
      -- HA acceptance is progress. Only pushed/read state can confirm a load.
      reply("accepted")
    end
  end, function(request)
    id = request
    consumer.requests[id] = true
  end, message.operation == "prepare" and 30000 or 10000, operations.timingName(rpc))
  return true
end

function Hub:_acknowledge(consumer, arguments)
  local data = operations.acknowledgment(arguments)
  if not self.online or not data or not consumer.entities[data.entity_id] then
    return false
  end
  local entry = self.entities[data.entity_id]
  local attrs = entry and entry.ready and entry.state and entry.state.attributes
  if
    not attrs
    or attrs.bridge_acknowledgment_version ~= 2
    or attrs.bridge_session_id ~= data.bridge_session_id
    or attrs.gesture_session_id ~= data.bridge_session_id
    or type(attrs.gesture_sequence) ~= "number"
    or attrs.gesture_sequence < data.gesture_sequence
  then
    return false
  end
  consumer.acknowledged = consumer.acknowledged or {}
  local prior = consumer.acknowledged[data.entity_id]
  if prior and prior.session == data.bridge_session_id and data.gesture_sequence <= prior.sequence then
    return false
  end
  consumer.acknowledged[data.entity_id] = { session = data.bridge_session_id, sequence = data.gesture_sequence }
  data.receiver = "control4:" .. consumer.device
  self.serial = self.serial + 1
  local ok, sent = pcall(self.connection.send, self.connection, {
    id = self.serial,
    type = "call_service",
    domain = "ha_gesture_bridge",
    service = "acknowledge",
    service_data = data,
  })
  return ok and sent == true
end

function Hub:receive(message)
  if
    self.destroyed
    or not codec.isObject(message)
    or message.version ~= ids.api
    or not self:_owns(message.consumer)
  then
    return false
  end
  if not integer(message.session) or not integer(message.selection) then
    return false
  end
  local existing = self.consumers[message.consumer]
  if message.op == "release" then
    if existing and existing.session == message.session and existing.selection == message.selection then
      self:_release(existing)
    end
    return true
  end
  if message.op == "commission_claim" or message.op == "commission_ack" then
    if not existing or existing.session ~= message.session or existing.selection ~= message.selection then
      return false
    end
    return self.transfer:receive(existing, message)
  end
  if message.op == "refresh_selected" then
    if
      not self.online
      or not existing
      or existing.session ~= message.session
      or existing.selection ~= message.selection
    then
      return false
    end
    for entity in pairs(existing.entities) do
      local entry = self.entities[entity]
      if entry and entry.members[existing.device] then
        entry.readFailures = 0
        if entry.ready then
          self:_read(entry)
        elseif not entry.subscription then
          entry.subFailures = 0
          self:_start(entry)
        end
      end
    end
    return true
  end
  if message.op == "acknowledge" then
    if not existing or existing.session ~= message.session or existing.selection ~= message.selection then
      return false
    end
    return self:_acknowledge(existing, message.arguments)
  end
  if message.op == "request" then
    if not existing or existing.session ~= message.session or existing.selection ~= message.selection then
      return false
    end
    return self:_operation(existing, message)
  end
  if message.op ~= "select" then
    return false
  end
  local wanted = contract.entities(message.entities)
  if not wanted then
    return false
  end
  if existing and existing.session == message.session and existing.selection == message.selection then
    -- The consumer can retry a lost reply. Keep leases, pending requests
    -- and subscriptions intact, and send current evidence only to that peer.
    for entity in pairs(wanted) do
      if not existing.entities[entity] then
        return false
      end
    end
    for entity in pairs(existing.entities) do
      if not wanted[entity] then
        return false
      end
    end
    self:_emit(existing, "selected", codec.object({}))
    for entity in pairs(existing.entities) do
      local entry = self.entities[entity]
      if entry then
        if entry.state then
          self:_emit(existing, "snapshot", entry.state)
        end
        self:_readiness(entry, existing)
      end
    end
    return true
  end
  local lease = self.leases[message.consumer]
  if
    lease
    and (message.session < lease.session or (message.session == lease.session and message.selection <= lease.selection))
  then
    -- Retain the watermark after release as well. An older lifetime or delayed
    -- registration cannot resurrect retired ownership.
    return false
  end
  -- Diff memberships before releasing the prior generation, retaining shared
  -- resources for endpoints which stay selected on this consumer.
  if existing then
    self:_retireRequests(existing)
  end
  local consumer = {
    device = message.consumer,
    session = message.session,
    selection = message.selection,
    entities = wanted,
    requests = {},
  }
  self.leases[consumer.device] = { session = consumer.session, selection = consumer.selection }
  self.consumers[consumer.device] = consumer
  self:_emit(consumer, "selected", codec.object({}))
  for entity in pairs(wanted) do
    local entry = self.entities[entity]
    if not entry then
      entry = { entity = entity, members = {}, revision = 0 }
      self.entities[entity] = entry
    end
    -- A committed selection is an explicit recovery action; ordinary healthy
    -- reports never restart reads or refresh these budgets.
    if not entry.ready and not entry.subscription then
      entry.subFailures, entry.readFailures = 0, 0
    end
    entry.members[consumer.device] = true
    self:_start(entry)
    if entry.ready and not entry.state and not entry.reading then
      entry.readFailures = 0
      self:_read(entry)
    end
    if entry.state then
      self:_emit(consumer, "snapshot", entry.state)
    end
    self:_readiness(entry)
  end
  if existing then
    for entity in pairs(existing.entities) do
      if not wanted[entity] then
        local entry = self.entities[entity]
        entry.members[consumer.device] = nil
        if next(entry.members) == nil and not entry.legacy then
          self:_stop(entry)
        end
      end
    end
  end
  self.transfer:offer(consumer)
  return true
end

function Hub:_message(message)
  if self.destroyed or not self.online or not codec.isObject(message) then
    return
  end
  if message.type == "result" then
    local callback = self.pending[message.id]
    if callback then
      self.pending[message.id] = nil
      pcall(CancelTimer, self.prefix .. message.id)
      local code = codec.isObject(message.error) and message.error.code
      local kind = (code == "unauthorized" or code == "not_allowed") and "permission_denied"
        or code == "not_found" and "not_found"
        or "rejected"
      callback(message.success == true, message.success == true and message.result or { kind = kind })
    end
  elseif message.type == "event" then
    for _, entry in pairs(self.entities) do
      if entry.subscription == message.id and entry.ready then
        local state = type(message.event) == "table"
          and type(message.event.variables) == "table"
          and type(message.event.variables.trigger) == "table"
          and message.event.variables.trigger.to_state
        if contract.state(state, entry.entity) then
          local previous = entry.state
          local kind = previous and "state" or "snapshot"
          entry.revision = entry.revision + 1
          entry.state = state
          entry.readFailures = 0
          pcall(CancelTimer, self.prefix .. "read." .. entry.entity)
          self:_members(entry, kind, state, entry.legacy)
          if not previous or available(previous) ~= available(state) then
            self:_readiness(entry)
          end
          if not available(state) and self.switchServices[entry.entity] then
            finishWaitingSwitches(self.switchServices[entry.entity], "unavailable")
          end
        elseif state == codec.null then
          entry.revision, entry.state = entry.revision + 1, nil
          pcall(CancelTimer, self.prefix .. "read." .. entry.entity)
          self:_members(entry, "failure", { entity_id = entry.entity, boundary = "entity", kind = "removed" })
          self:_readiness(entry)
          if self.switchServices[entry.entity] then
            finishWaitingSwitches(self.switchServices[entry.entity], "unavailable")
          end
        end
        break
      end
    end
  end
end

function Hub:_transport(online)
  if not online then
    self.transfer:cancel()
  end
  if self.destroyed or self.online == online then
    return
  end
  self.online = online
  self.epoch = self.epoch + 1
  self.snapshotQueue:clear()
  self.snapshotQueue = SnapshotQueue.new()
  local switches = self.switchServices
  self.switchServices = {}
  for _, lane in pairs(switches) do
    finishWaitingSwitches(lane, "disconnected")
  end
  self.catalog:invalidate()
  for _, catalog in pairs(self.scopedCatalogs) do
    catalog:invalidate()
  end
  local pending = self.pending
  self.pending = {}
  for id, callback in pairs(pending) do
    pcall(CancelTimer, self.prefix .. id)
    callback(false, { kind = "disconnected" })
  end
  for _, entry in pairs(self.entities) do
    pcall(CancelTimer, self.prefix .. "read." .. entry.entity)
    pcall(CancelTimer, self.prefix .. "subscribe." .. entry.entity)
    entry.subscription, entry.ready, entry.reading, entry.state = nil, false, false, nil
    if online then
      self:_start(entry)
    end
    self:_readiness(entry)
  end
end

-- The explicit Composer action lists selected entity IDs. Normal connection
-- diagnostics below carry counts only and never query other devices.
function Hub:linkedEntityIds(linked)
  for entity, entry in pairs(self.entities) do
    for device in pairs(entry.members) do
      if self:_owns(device) then
        linked[entity] = true
        break
      end
    end
  end
  local names = {}
  for name in pairs(linked) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function Hub:diagnostics()
  local snapshot = self.catalog.snapshot
  local subscriptions, states, failedReads, failedSubscriptions = 0, 0, 0, 0
  for _, entry in pairs(self.entities) do
    subscriptions = subscriptions + (entry.subscription and 1 or 0)
    states = states + (entry.state and 1 or 0)
    failedReads = failedReads + (entry.readFailures or 0)
    failedSubscriptions = failedSubscriptions + (entry.subFailures or 0)
  end
  return {
    connection = self.connection.state,
    linked_drivers = GetTableSize(self.consumers),
    selected_entities = GetTableSize(self.entities),
    pending_requests = GetTableSize(self.pending),
    active_subscriptions = subscriptions,
    available_snapshots = states,
    current_read_failures = failedReads,
    current_subscription_failures = failedSubscriptions,
    cached_devices = snapshot and #snapshot.rows or 0,
    catalog_refresh_pending = self.catalog.pending ~= nil,
  }
end

function Hub:retry()
  if self.destroyed then
    return
  end
  for _, entry in pairs(self.entities) do
    entry.subFailures, entry.readFailures = 0, 0
    if self.online then
      self:_start(entry)
      if entry.ready and (not entry.state or (entry.legacy and not entry.legacyInitialized)) then
        self:_read(entry)
      end
    end
  end
end

function Hub:prune(outputs)
  outputs = outputs or {}
  for _, consumer in pairs(self.consumers) do
    if not self:_owns(consumer.device, outputs) then
      self:_release(consumer)
      -- Releasing a subscription can call into the transport.
      for provider in pairs(outputs) do
        outputs[provider] = nil
      end
    end
  end
end

function Hub:resetConsumer(device, outputs)
  if not self.destroyed and self:_owns(device, outputs) then
    pcall(self.emit, device, {
      version = ids.api,
      coordinator = C4:GetDeviceID(),
      boot = self.boot,
      epoch = self.epoch,
      kind = "reset",
    })
  end
end

function Hub:announce(missingOnly, outputs)
  if self.destroyed then
    return
  end
  outputs = outputs or {}
  local binding = contract.coordinatorOutput(C4:GetDeviceID(), outputs)
  for _, peer in pairs(binding and binding.boundconsumers or {}) do
    local device = tonumber(peer.deviceid)
    if not missingOnly or not self.consumers[device] then
      self:resetConsumer(device, outputs)
    end
  end
end

function Hub:reconcileBindings()
  local outputs = {}
  self:prune(outputs)
  self:announce(false, outputs)
end

function Hub:destroy()
  if self.destroyed then
    return
  end
  if self.switchUpgrade then
    self.switchUpgrade:destroy()
  end
  if self.commissioning then
    self.commissioning:destroy()
  end
  self:_transport(false)
  self.destroyed = true
  for _, entry in pairs(self.entities) do
    pcall(CancelTimer, self.prefix .. "read." .. entry.entity)
    pcall(CancelTimer, self.prefix .. "subscribe." .. entry.entity)
  end
  for id in pairs(self.pending) do
    pcall(CancelTimer, self.prefix .. id)
  end
  self.pending, self.entities, self.consumers, self.leases = {}, {}, {}, {}
  self.connection:destroy()
end

return Hub
