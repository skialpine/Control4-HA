-- Family-neutral selection and routing over the template binding helpers.
local codec = require("ha.codec")
local contract = require("ha.contract")
local ids = require("ha.identities")
local deferred = require("deferred")
local operations = require("ha.operations")
local Readiness = require("ha.readiness")
local lifetime = require("ha.lifetime")
local log = require("lib.logging")
local metrics = require("ha.performance").shared
local Selection = require("ha.selection")
require("lib.utils")
local Consumer = {}
Consumer.__index = Consumer
local SESSION_KEY = "HA.Consumer.Session"
local REJOIN_DELAYS = { 2000, 5000, 10000 }

function Consumer.new(onMessage, options)
  local session = lifetime.next(SESSION_KEY)
  return setmetatable({
    device = C4:GetDeviceID(),
    session = session,
    selection = 0,
    entities = {},
    pending = {},
    requestSerial = 0,
    prefix = "HA.Consumer." .. C4:GetDeviceID() .. "." .. session .. ".",
    onMessage = onMessage,
    readiness = Readiness.new(),
    options = options or {},
    bootFloor = 0,
  }, Consumer)
end

function Consumer:_provider()
  return contract.provider(self.device)
end

function Consumer:_send(op, request)
  if not self.provider or self.destroyed then
    return false
  end
  local message = {
    version = ids.api,
    op = op,
    consumer = self.device,
    session = self.session,
    selection = self.selection,
  }
  if op == "select" then
    message.entities = codec.array(self.entities)
  end
  if request then
    for _, key in ipairs({ "request_id", "operation", "entity_id", "arguments" }) do
      message[key] = request[key]
    end
  end
  local ok = pcall(SendSecretToDevice, self.provider, "HA_SUITE_V1", { PAYLOAD = codec.encode(message) })
  return ok
end

function Consumer:_cancelRejoin()
  if self.rejoin then
    self.rejoin = nil
    pcall(CancelTimer, self.prefix .. "rejoin")
  end
end

function Consumer:_scheduleRejoin()
  if self.rejoin or not self.provider or not self.wanted or next(self.wanted) == nil then
    return
  end
  local recovery = {}
  self.rejoin = recovery
  local function schedule(attempt)
    local delay = REJOIN_DELAYS[attempt]
    if delay then
      SetTimer(self.prefix .. "rejoin", delay, function()
        if self.rejoin ~= recovery or not self:_current() then
          return
        end
        -- Use the exact existing registration. A live Coordinator can respond
        -- from its cache, while a replacement can rebuild the scoped selection.
        self:_send("select")
        if self.rejoin == recovery then
          schedule(attempt + 1)
        end
      end)
    end
  end
  schedule(1)
end

function Consumer:_invalidate(reason, entity)
  local retiring = self.retiring
  self.retiring = true
  for _, cleanup in ipairs(self.options.cleanup or {}) do
    if not pcall(cleanup, reason, entity) then
      log:warn("HA consumer cleanup failed; other resources were retired")
    end
  end
  self.retiring = retiring
end

function Consumer:_current()
  if self.destroyed or self.retiring then
    return false
  end
  local ok, current = true, true
  if self.options.isCurrent then
    ok, current = pcall(self.options.isCurrent)
  end
  local bindingOk, provider = pcall(self._provider, self)
  if not ok or not current or not bindingOk or (self.provider and provider ~= self.provider) then
    -- Retire before inspecting a routing payload: a delayed property callback
    -- must not let unrelated/foreign messages preserve the old held outputs.
    self:release("selection_or_binding")
    return false
  end
  return true
end

function Consumer:release(reason)
  if self.destroyed or self.retiring then
    return
  end
  self.commissionOffer = nil
  self:_cancelRejoin()
  self.retiring = true
  self:_invalidate(reason or "release")
  self:_retireRequests()
  if self.selection > 0 then
    self:_send("release")
  end
  self.provider, self.entities, self.wanted = nil, {}, nil
  self.readiness:select(nil, false)
  self.boot, self.epoch = nil, nil
  self.retiring = false
end

function Consumer:select(entities)
  if self.destroyed or self.retiring then
    return false
  end
  local wanted = contract.entities(entities)
  if not wanted then
    return false
  end
  self.commissionOffer = nil
  self:_cancelRejoin()
  self.retiring = true
  self:_retireRequests()
  self:_invalidate("selection")
  self.retiring = false
  local bindingOk, provider = pcall(self._provider, self)
  if not bindingOk then
    provider = nil
  end
  if self.provider ~= provider then
    self:release()
    self.bootFloor, self.bootRetried = 0, false
  end
  self.selection = self.selection + 1
  self.entities = {}
  for i, entity in ipairs(entities) do
    self.entities[i] = entity
  end
  self.wanted = wanted
  self.provider = provider
  self.boot, self.epoch = nil, nil
  self.readiness:select(wanted, provider ~= nil)
  self:_scheduleRejoin()
  return self:_send("select")
end

function Consumer:_retireRequests(reason)
  local pending = self.pending
  self.pending = {}
  for id, request in pairs(pending) do
    pcall(CancelTimer, self.prefix .. id)
    if request.operation == "prepare" then
      self.readiness:prepare(request.entity, "failed", reason or "retired")
    end
    request.promise:reject({ kind = reason or "retired" })
  end
end

function Consumer:request(operation, entity, arguments)
  local promise = deferred.new()
  local browsing = operation == "catalog"
  local resolving = operation == "resolve"
  local verifying = operation == "verify_target"
  local reading = operation == "read_load"
  local setup = browsing or resolving or verifying
  if not self:_current() or not self.wanted or (not setup and not self.wanted[entity]) or not self.provider then
    promise:reject({ kind = "unbound" })
    return promise
  end
  if
    (browsing and not contract.catalogQuery(arguments))
    or (resolving and not Selection.query(arguments))
    or (verifying and not operations.verifyTarget(entity, arguments))
    or (reading and not operations.readLoad(entity, arguments))
    or (not setup and not reading and not operations.build(operation, entity, arguments))
  then
    promise:reject({ kind = "invalid_request" })
    return promise
  end
  self.requestSerial = self.requestSerial + 1
  local id = self.requestSerial
  local request = {
    promise = promise,
    operation = operation,
    entity = entity,
    arguments = {
      device_id = arguments.device_id,
      source_registry_id = arguments.source_registry_id,
      family = arguments.family,
      choice_id = arguments.choice_id,
      event_control = arguments.event_control,
      event_registry_id = arguments.event_registry_id,
      load_entity = arguments.load_entity,
      load_registry_id = arguments.load_registry_id,
    },
  }
  self.pending[id] = request
  if operation == "prepare" then
    self.readiness:prepare(entity, "pending")
  end
  SetTimer(self.prefix .. id, operation == "resolve" and 45000 or operation == "prepare" and 35000 or 15000, function()
    if self.pending[id] == request then
      self.pending[id] = nil
      if operation == "prepare" then
        self.readiness:prepare(entity, "failed", "timeout")
      end
      promise:reject({ kind = "timeout" })
    end
  end)
  if
    not self:_send("request", { request_id = id, operation = operation, entity_id = entity, arguments = arguments })
    and self.pending[id] == request
  then
    self.pending[id] = nil
    pcall(CancelTimer, self.prefix .. id)
    if operation == "prepare" then
      self.readiness:prepare(entity, "failed", "disconnected")
    end
    promise:reject({ kind = "disconnected" })
  end
  return promise
end

-- Refresh only the current subscription set when the user requests fresh device states.
function Consumer:refreshSelected()
  return self:_current() and self.wanted and next(self.wanted) ~= nil and self:_send("refresh_selected")
end

function Consumer:acknowledge(data)
  if not metrics.enabled or not self.provider or not self.wanted or not self.wanted[data.entity_id] then
    return false
  end
  local proof = self.readiness:view(data.entity_id)
  local arguments = operations.acknowledgment(codec.object(data))
  if not arguments or not (proof.transport and proof.subscription and proof.snapshot) or not self:_current() then
    return false
  end
  return self:_send("acknowledge", { arguments = arguments })
end

-- Direct calls use decoded test/transport data. The driver passes its wire string
-- so binding and pending property changes are checked once, before decoding.
function Consumer:receive(message)
  if not self:_current() then
    return false
  end
  if type(message) == "string" then
    local span = metrics:start("consumer.decode")
    local ok, decoded = pcall(codec.decode, message)
    metrics:finish(span, ok and "ok" or "rejected")
    if not ok then
      return false
    end
    message = decoded
  end
  if
    not codec.isObject(message)
    or message.version ~= ids.api
    or not self.provider
    or message.coordinator ~= self.provider
    or not contract.integer(message.boot)
  then
    return false
  end
  if message.kind == "reset" then
    if
      not self.wanted
      or message.boot < self.bootFloor
      or (message.boot == self.bootFloor and (self.boot ~= nil or self.bootRetried))
    then
      return false
    end
    self.bootRetried = message.boot == self.bootFloor
    self.bootFloor = message.boot
    return self:select(codec.array(self.entities))
  end
  if
    self.destroyed
    or not self.wanted
    or not codec.isObject(message)
    or message.session ~= self.session
    or message.selection ~= self.selection
    or not codec.isObject(message.data)
  then
    return false
  end
  if message.kind == "selected" then
    if
      message.boot < self.bootFloor
      or not contract.integer(message.epoch)
      or (message.boot == self.boot and message.epoch < self.epoch)
    then
      return false
    end
    if self.boot and message.boot > self.boot then
      self:_invalidate("transport")
      self:_retireRequests("disconnected")
      self.readiness:select(self.wanted, true)
    end
    self.boot, self.bootFloor, self.epoch = message.boot, message.boot, message.epoch
    return true
  end
  if message.boot ~= self.boot or not contract.integer(message.epoch) or message.epoch < self.epoch then
    return false
  end
  if message.epoch > self.epoch then
    self:_invalidate("transport")
    self:_retireRequests("disconnected")
    self.readiness:select(self.wanted, true)
    self.epoch = message.epoch
  end
  if message.kind == "commission_offer" or message.kind == "commission_apply" then
    local data = message.data
    if not contract.integer(data.ticket) or not self.options.mayCommission then
      return false
    end
    if message.kind == "commission_offer" then
      local accept = self.options.mayCommission(data.family, data.key)
      self.commissionOffer = accept and { ticket = data.ticket, choice_id = data.key, family = data.family } or nil
      return self:_send("commission_claim", { request_id = data.ticket, arguments = { accept = accept } })
    end
    local offer = self.commissionOffer
    self.commissionOffer = nil
    if not offer or offer.ticket ~= data.ticket or not Selection.valid(data.config, offer) then
      return false
    end
    local applied = self.options.mayCommission(offer.family, offer.choice_id)
      and self.options.applyCommission(data.config)
    return self:_send("commission_ack", { request_id = data.ticket, arguments = { applied = applied == true } })
  end
  local operation = message.data.operation
  local setup = operation == "catalog" or operation == "resolve" or operation == "verify_target"
  if not self.wanted[message.data.entity_id] and not (message.kind == "result" and setup) then
    return false
  end
  local kind, data = message.kind, message.data
  if kind == "result" then
    local request = self.pending[data.request_id]
    if
      not contract.integer(data.request_id)
      or (not setup and operation ~= "service" and operation ~= "indicator" and operation ~= "prepare" and operation ~= "read_load")
      or type(data.status) ~= "string"
    then
      return false
    end
    if not request then
      return true
    end -- valid receipt for already-retired work
    if request.entity ~= data.entity_id or request.operation ~= data.operation then
      return false
    end
    self.pending[data.request_id] = nil
    pcall(CancelTimer, self.prefix .. data.request_id)
    if
      data.status == "resolved"
      and data.operation == "resolve"
      and Selection.valid(data.resolved, request.arguments)
    then
      request.promise:resolve(data.resolved)
    elseif
      data.status == "catalog"
      and data.operation == "catalog"
      and contract.catalogPage(data.catalog)
      and data.catalog.family == request.arguments.family
    then
      request.promise:resolve(data.catalog)
    elseif data.status == "accepted" and (data.operation == "service" or data.operation == "indicator") then
      request.promise:resolve({ status = "accepted" })
    elseif
      data.status == "load_state"
      and data.operation == "read_load"
      and contract.state(data.load_state, request.entity)
    then
      request.promise:resolve(data.load_state)
    elseif data.status == "verified" and data.operation == "verify_target" then
      if request.arguments.event_control then
        if operations.eventReceiptMatches(data.resolved, request.entity, request.arguments) then
          request.promise:resolve({
            status = "verified",
            event_registry_id = data.resolved.event_registry_id,
            load_registry_id = data.resolved.load_registry_id,
          })
        else
          request.promise:reject({ kind = "invalid_response" })
        end
      else
        request.promise:resolve({ status = "verified" })
      end
    elseif
      data.status == "prepared"
      and data.operation == "prepare"
      and operations.prepared(codec.object({ response = data.prepared }), request.entity, request.arguments)
    then
      self.readiness:prepare(data.entity_id, "prepared", nil, data.prepared.input_ready)
      request.promise:resolve({ status = "prepared", prepared = data.prepared })
    else
      local allowed = {
        rejected = true,
        timeout = true,
        disconnected = true,
        busy = true,
        invalid_response = true,
        permission_denied = true,
        not_found = true,
        unavailable = true,
        invalid_catalog = true,
        unsupported_catalog_version = true,
        invalid_revision_confirmation = true,
        incomplete_catalog = true,
        invalid_filtered_catalog = true,
        filtered_read_failed = true,
        read_failed = true,
        redirect_refused = true,
        request_failed = true,
        catalog_unverified = true,
        revision_changed = true,
        invalid_cursor = true,
        invalid_family = true,
        invalid_endpoint_metadata = true,
        filtered_registry_failed = true,
        unsupported_endpoint = true,
        indicator_unavailable = true,
        unsupported_preparation_version = true,
      }
      if data.operation == "prepare" then
        self.readiness:prepare(data.entity_id, "failed", allowed[data.status] and data.status or "invalid_response")
      end
      request.promise:reject({ kind = allowed[data.status] and data.status or "invalid_response" })
    end
    return true
  elseif kind == "state" or kind == "snapshot" then
    if not contract.state(data, data.entity_id) then
      self:_invalidate("malformed", data.entity_id)
      return false
    end
    if not self.readiness:view(data.entity_id).snapshot then
      kind = "snapshot"
    end
    self.readiness:state(data)
    if data.state == "unknown" or data.state == "unavailable" then
      self:_invalidate("entity", data.entity_id)
    end
  elseif kind == "readiness" then
    for _, key in ipairs({ "transport", "subscription", "snapshot", "available" }) do
      if type(data[key]) ~= "boolean" then
        return false
      end
    end
    self.readiness:update(data)
    if data.transport then
      self:_cancelRejoin()
    else
      self:_scheduleRejoin()
    end
    if not data.transport or not data.subscription or not data.snapshot or not data.available then
      self:_invalidate("readiness", data.entity_id)
    end
  elseif kind == "failure" then
    if type(data.boundary) ~= "string" or type(data.kind) ~= "string" then
      return false
    end
    self:_invalidate("source_failure", data.entity_id)
  else
    return false
  end
  if self.onMessage then
    local span = metrics:start("consumer.handler")
    local handled = pcall(self.onMessage, kind, data)
    metrics:finish(span, handled and "ok" or "failed")
    if not handled then
      self:_invalidate("handler", data.entity_id)
      return false
    end
  end
  return true
end

function Consumer:destroy()
  if self.destroyed or self.retiring then
    return
  end
  self:release("destroyed")
  self.destroyed = true
end

return Consumer
