-- Actual shared modules, template promises/timers/persistence and wire codec.
-- Only Director calls and the authenticated HA boundary are faked.
local T = require("testlib")
local clock = require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local ids = require("ha.identities")
local deferred = require("deferred")
local Hub = require("ha.hub")
local Consumer = require("ha.consumer")
local contract = require("ha.contract")
local device, providers, peers = 10, {}, {}
local inputIds, inputPeers, installed, legacyDeclarations, missingSuite = {}, {}, {}, {}, {}
local bindingReads = {}
function C4:GetDeviceID()
  return device
end
function C4:GetBoundProviderDevice(consumer, binding)
  return binding == (inputIds[consumer] or ids.coordinatorBinding) and providers[consumer] or 0
end
function C4:GetDevices(_)
  return installed
end
function C4:GetDeviceData(id, tag)
  return installed[id] and installed[id][tag]
end
function GetDeviceBindings(id, _, role, _, class)
  bindingReads[id] = (bindingReads[id] or 0) + 1
  if
    (class == ids.coordinatorClass and missingSuite[id])
    or (class == ids.legacyCoordinatorClass and not legacyDeclarations[id])
  then
    return {}
  end
  local classes = { { class = ids.coordinatorClass } }
  if legacyDeclarations[id] then
    classes[#classes + 1] = { class = ids.legacyCoordinatorClass }
  end
  if role == true then
    return { [ids.coordinatorBinding] = { boundconsumers = peers[id] or {}, bindingclasses = classes } }
  end
  if inputPeers[id] then
    return {
      [inputIds[id] or ids.coordinatorBinding] = {
        boundprovider = { bound = inputPeers[id] },
        bindingclasses = classes,
      },
    }
  end
  return {}
end
local function at(id, fn)
  local before = device
  device = id
  local ok, result = pcall(fn)
  device = before
  assert(ok, result)
  return result
end
local function wire(value)
  return codec.decode(codec.encode(value))
end
local function bind(consumer, provider, class, binding)
  providers[consumer] = provider
  peers[provider] = peers[provider] or {}
  peers[provider][consumer] = {
    deviceid = consumer,
    bindingid = binding or inputIds[consumer] or 1,
    boundclasses = { class or ids.coordinatorClass },
  }
  inputPeers[consumer] = { deviceid = provider, bindingid = 1, boundclasses = { class or ids.coordinatorClass } }
end
local function state(entity, value)
  return wire({ entity_id = entity, state = value or "off", attributes = codec.object({}) })
end
local function fixture()
  providers, peers = {}, {}
  inputIds, inputPeers, installed, legacyDeclarations, missingSuite = {}, {}, {}, {}, {}
  local connection = { state = "connected", sent = {}, reads = {} }
  function connection:send(message)
    self.sent[#self.sent + 1] = wire(message)
    return not self.failSend
  end
  function connection:readState(entity)
    local promise = deferred.new()
    self.reads[#self.reads + 1] = { entity = entity, promise = promise }
    return promise
  end
  connection.catalogReads = {}
  function connection:readCatalog()
    local promise = deferred.new()
    self.catalogReads[#self.catalogReads + 1] = promise
    return promise
  end
  function connection:destroy()
    self.destroyed = true
  end
  function connection:recover()
    self.recoveries = (self.recoveries or 0) + 1
    self.onState("retrying")
    return true
  end
  local consumers, deliveries, requests = {}, {}, {}
  local hub = at(10, function()
    return Hub.new(connection, function(id, message)
      deliveries[#deliveries + 1] = { id = id, message = wire(message) }
      at(id, function()
        assert(consumers[id]:receive(wire(message)))
      end)
    end)
  end)
  -- These tests isolate transport/catalog transfer from the separately tested
  -- scoped registry boundary and family policy.
  hub.catalog.supplement = false
  hub.catalog.decorate = function(rows)
    for _, item in ipairs(rows) do
      item.families = codec.array({ "light", "switch" })
    end
    local promise = deferred.new()
    promise:resolve(rows)
    return promise
  end
  function SendSecretToDevice(provider, command, params)
    assert(command == "HA_SUITE_V1")
    requests[#requests + 1] = codec.decode(params.PAYLOAD)
    at(provider, function()
      hub:receive(codec.decode(params.PAYLOAD))
    end)
  end
  local f = { connection = connection, hub = hub, consumers = consumers, deliveries = deliveries, requests = requests }
  function f.consumer(id, options, onMessage)
    bind(id, 10)
    local c = at(id, function()
      return Consumer.new(onMessage, options)
    end)
    consumers[id] = c
    return c
  end
  function f.ack(id, success, result)
    at(10, function()
      connection.onMessage(
        wire({ type = "result", id = id, success = success ~= false, result = result or codec.null })
      )
    end)
  end
  function f.push(id, entity, value)
    at(10, function()
      connection.onMessage(wire({
        type = "event",
        id = id,
        event = { variables = { trigger = { to_state = state(entity, value) } } },
      }))
    end)
  end
  function f.close()
    for id, consumer in pairs(consumers) do
      at(id, function()
        consumer:destroy()
      end)
    end
    at(10, function()
      hub:destroy()
    end)
  end
  function f.reload(skipAnnouncement)
    local old, oldReceive = hub, connection.onMessage
    at(10, function()
      old:destroy()
    end)
    connection.destroyed, connection.sent, connection.reads = nil, {}, {}
    local emit = old.emit
    hub = at(10, function()
      return Hub.new(connection, emit)
    end)
    f.hub = hub
    if not skipAnnouncement then
      at(10, function()
        hub:announce()
      end)
    end
    return old, oldReceive
  end
  return f
end

T.section("two consumers share an exact subscription and one initial read")
do
  local f = fixture()
  local a, b = f.consumer(21), f.consumer(22)
  T.truthy(
    "first selects",
    at(21, function()
      return a:select(codec.array({ "light.lab" }))
    end)
  )
  T.truthy(
    "second selects",
    at(22, function()
      return b:select(codec.array({ "light.lab" }))
    end)
  )
  T.eq("one subscription", #f.connection.sent, 1)
  local subscription = f.connection.sent[1]
  T.eq("subscription is scoped to selected entity", subscription.trigger.entity_id, "light.lab")
  T.eq("no read before subscribe acknowledgement", #f.connection.reads, 0)
  f.ack(subscription.id)
  T.eq("one shared exact read", #f.connection.reads, 1)
  T.eq("read target", f.connection.reads[1].entity, "light.lab")
  f.connection.reads[1].promise:resolve(state("light.lab"))
  local snapshots = {}
  for _, delivery in ipairs(f.deliveries) do
    if delivery.message.kind == "snapshot" then
      snapshots[#snapshots + 1] = delivery.id
    end
  end
  table.sort(snapshots)
  T.eq("snapshot reaches both consumers", snapshots, { 21, 22 })
  at(21, function()
    a:release()
  end)
  T.eq("releasing one retains shared subscription", #f.connection.sent, 1)
  local count = #f.deliveries
  f.push(subscription.id, "light.lab", "on")
  T.eq("remaining consumer gets the push and readiness", #f.deliveries, count + 2)
  T.eq("remaining consumer owns delivery", f.deliveries[count + 1].id, 22)
  clock.run(120000)
  T.eq("healthy connection does not poll", #f.connection.reads, 1)
  at(22, function()
    b:destroy()
  end)
  T.eq("last release unsubscribes", f.connection.sent[2].type, "unsubscribe_events")
  T.eq("unsubscribe references original subscription", f.connection.sent[2].subscription, subscription.id)
  f.ack(f.connection.sent[2].id)
  T.eq("all entities released", f.hub.entities, {})
  f.close()
end

T.section("selection diffs retain endpoints and reject older registrations")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  local old = wire(f.requests[1])
  f.ack(1)
  at(21, function()
    a:select(codec.array({ "light.lab", "event.paddle" }))
  end)
  T.eq("retained endpoint is not resubscribed", #f.connection.sent, 2)
  T.eq("only the added endpoint subscribes", f.connection.sent[2].trigger.entity_id, "event.paddle")
  T.falsy(
    "old selection rejected",
    at(10, function()
      return f.hub:receive(old)
    end)
  )
  T.eq("new membership survives", f.hub.consumers[21].selection, a.selection)
  local oldSession = a.session
  at(21, function()
    a:destroy()
  end)
  local newer = f.consumer(21)
  at(21, function()
    newer:select(codec.array({ "switch.lab" }))
  end)
  T.truthy("persisted lifetime advances", newer.session > oldSession)
  T.falsy(
    "old lifetime cannot replace new lifetime",
    at(10, function()
      return f.hub:receive(old)
    end)
  )
  T.eq("new lifetime retains its entity", f.hub.consumers[21].entities, { ["switch.lab"] = true })
  local latest = wire(f.requests[#f.requests])
  at(21, function()
    newer:release()
  end)
  T.falsy(
    "released registration cannot resurrect membership",
    at(10, function()
      return f.hub:receive(latest)
    end)
  )
  T.eq("released consumer absent", f.hub.consumers[21], nil)
  f.close()
end

T.section("late subscription acknowledgements and reads cannot recreate released resources")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  at(21, function()
    a:release()
  end)
  T.eq("pending subscription has not been prematurely unsubscribed", #f.connection.sent, 1)
  f.ack(1)
  T.eq("late ack is immediately unsubscribed", f.connection.sent[2].subscription, 1)
  T.eq("late ack does not start a read", #f.connection.reads, 0)
  f.ack(2)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(3)
  local read, count = f.connection.reads[1], #f.deliveries
  at(21, function()
    a:release()
  end)
  read.promise:resolve(state("light.lab", "on"))
  T.eq("released read has no deliveries", #f.deliveries, count)
  T.eq("released read creates no resource", f.hub.entities, {})
  f.close()
end

T.section("pushed feedback wins over an older coalesced read")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  f.push(1, "light.lab", "on")
  local count = #f.deliveries
  f.connection.reads[1].promise:resolve(state("light.lab", "off"))
  T.eq("old snapshot is not published", #f.deliveries, count)
  T.eq("pushed evidence retained", f.hub.entities["light.lab"].state.state, "on")
  f.close()
end

T.section("binding ownership and strict wire shapes gate registrations and delivery")
do
  local f = fixture()
  local a = f.consumer(21)
  local good = wire({
    version = 1,
    op = "select",
    consumer = 21,
    session = a.session,
    selection = 1,
    entities = codec.array({ "light.lab" }),
  })
  for _, entities in ipairs({
    codec.object({}),
    codec.null,
    codec.array({ "light.lab", "light.lab" }),
    codec.array({ "sensor.private" }),
    codec.array({ "light.lab?token=secret" }),
  }) do
    local bad = wire(good)
    bad.entities = entities
    T.falsy(
      "malformed selection refused",
      at(10, function()
        return f.hub:receive(bad)
      end)
    )
  end
  bind(21, 10, "FOREIGN_CLASS")
  T.falsy(
    "wrong binding class refused",
    at(10, function()
      return f.hub:receive(good)
    end)
  )
  bind(21, 10, ids.coordinatorClass, 99)
  T.falsy(
    "wrong consumer binding refused",
    at(10, function()
      return f.hub:receive(good)
    end)
  )
  bind(21, 11)
  T.falsy(
    "different Coordinator refused",
    at(10, function()
      return f.hub:receive(good)
    end)
  )
  bind(21, 10)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  local delivery = wire({
    version = 1,
    coordinator = 10,
    boot = f.hub.boot,
    epoch = f.hub.epoch,
    session = a.session,
    selection = a.selection,
    kind = "state",
    data = state("light.lab", "on"),
  })
  T.truthy(
    "owned evidence accepted",
    at(21, function()
      return a:receive(delivery)
    end)
  )
  for key, value in pairs({ coordinator = 11, session = a.session + 1, selection = a.selection + 1, version = 99 }) do
    local bad = wire(delivery)
    bad[key] = value
    T.falsy(
      "foreign correlation refused: " .. key,
      at(21, function()
        return a:receive(bad)
      end)
    )
  end
  delivery.data = state("switch.foreign")
  T.falsy(
    "foreign payload entity refused",
    at(21, function()
      return a:receive(delivery)
    end)
  )
  bind(21, 11)
  T.falsy(
    "changed binding immediately refuses old provider",
    at(21, function()
      return a:receive(wire(f.deliveries[1].message))
    end)
  )
  at(10, function()
    f.hub:prune()
  end)
  T.eq("unbound consumer pruned", f.hub.consumers[21], nil)
  T.eq("unbound resources released", f.hub.entities, {})
  f.close()
end

T.section("transport loss invalidates read callbacks; synchronous send failure is contained")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  at(10, function()
    f.connection.onState("retrying")
  end)
  local count = #f.deliveries
  f.connection.reads[1].promise:resolve(state("light.lab", "on"))
  T.eq("old transport read ignored", #f.deliveries, count)
  at(10, function()
    f.connection.onState("connected")
  end)
  T.eq("reconnect reacquires only selected endpoint", f.connection.sent[2].trigger.entity_id, "light.lab")
  f.ack(2)
  T.eq("one fresh recovery read", #f.connection.reads, 2)
  f.close()
  local after = #f.deliveries
  f.connection.reads[2].promise:resolve(state("light.lab"))
  f.push(2, "light.lab", "on")
  T.eq("destroyed hub cannot publish", #f.deliveries, after)

  f = fixture()
  a = f.consumer(21)
  f.connection.failSend = true
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  T.eq("send failure settles pending operation", f.hub.pending, {})
  local function countFailures()
    local failures = 0
    for _, delivery in ipairs(f.deliveries) do
      if delivery.message.kind == "failure" then
        failures = failures + 1
      end
    end
    return failures
  end
  T.eq("first send failure settles once", countFailures(), 1)
  clock.run(11000)
  T.eq("bounded recovery reports one failure per attempt", countFailures(), 3)
  T.eq("bounded recovery stopped after three attempts", #f.connection.sent, 3)
  T.eq("failed attempts leave no response timers pending", f.hub.pending, {})
  f.close()
end

local function operation(f, consumer, kind, entity, arguments)
  local result = {}
  at(consumer.device, function()
    consumer:request(kind, entity, wire(arguments)):next(function(value)
      result.value = value
    end, function(failure)
      result.failure = failure
    end)
  end)
  return result
end
T.section("A one-shot load read is scoped, correlated and superseded by newer pushes")
do
  local f = fixture()
  local a, b = f.consumer(21), f.consumer(22)
  for _, c in ipairs({ a, b }) do
    at(c.device, function()
      c:select(codec.array({ "light.lab" }))
    end)
  end
  f.ack(1)
  at(10, function()
    f.connection.reads[1].promise:resolve(state("light.lab", "off"))
  end)
  local foreign = operation(f, a, "read_load", "light.other", {})
  local invalid = operation(f, a, "read_load", "light.lab", { extend = true })
  T.eq("foreign targets and expanded arguments are rejected before reading", {
    foreign.failure.kind,
    invalid.failure.kind,
    #f.connection.reads,
  }, { "unbound", "invalid_request", 1 })

  local own = operation(f, a, "read_load", "light.lab", codec.object({}))
  T.eq("verified subscription permits one authenticated read", {
    #f.connection.reads,
    f.connection.reads[2].entity,
  }, { 2, "light.lab" })
  f.push(1, "light.lab", "on")
  local before = #f.deliveries
  at(10, function()
    f.connection.reads[2].promise:resolve(state("light.lab", "off"))
  end)
  T.eq("only the requester receives the new evidence from the correlated result", {
    own.value.state,
    #f.deliveries - before,
    f.deliveries[#f.deliveries].id,
  }, { "on", 1, 21 })

  local retired = operation(f, a, "read_load", "light.lab", codec.object({}))
  at(21, function()
    a:select(codec.array({}))
  end)
  before = #f.deliveries
  at(10, function()
    f.connection.reads[3].promise:resolve(state("light.lab", "off"))
  end)
  T.eq("selection change retires the old result and leaves the other consumer alone", {
    retired.failure.kind,
    retired.value,
    #f.deliveries,
  }, { "retired", nil, before })
  local stalled = operation(f, b, "read_load", "light.lab", codec.object({}))
  clock.run(12000)
  T.eq("the exact read times out once", { stalled.failure.kind, #f.connection.reads }, { "timeout", 4 })
  before = #f.deliveries
  at(10, function()
    f.connection.reads[4].promise:resolve(state("light.lab", "off"))
  end)
  T.eq("a reply after the one-shot deadline cannot publish", #f.deliveries, before)
  f.close()
end

T.section("concurrent selection deadlines are owned by their requesting device")
do
  local f = fixture()
  local a, b = f.consumer(21), f.consumer(22)
  for _, c in ipairs({ a, b }) do
    at(c.device, function()
      c:select(codec.array({}))
    end)
  end
  f.hub.catalog.refresh = function()
    error("resolving a cached choice must not refresh HA")
  end
  local revision = string.rep("f", 64)
  local device, registry = string.rep("d", 32), string.rep("e", 32)
  local choice = "device:" .. device .. ":" .. registry
  local query = { choice_id = choice, revision = revision, family = "light", prepare = true }
  f.hub.catalog.choice = function(_, key, family, expected)
    assert(key == choice and family == "light" and expected == revision)
    return {
      entity_id = key,
      name = "Wall load",
      attributes = {
        device_choice = { device_id = device, source_load = { entity_id = "light.lab", registry_id = registry } },
      },
    }
  end
  local replies = {}
  f.hub._request = function(_, _, reply)
    replies[#replies + 1] = reply
    return true
  end
  local first = operation(f, a, "resolve", nil, query)
  clock.run(5000)
  local second = operation(f, b, "resolve", nil, query)
  clock.run(35000)
  T.eq("first Coordinator deadline fires at 40 seconds", first.failure, { kind = "timeout" })
  T.eq("other device with the same sequence number retains its deadline", second.failure, nil)
  at(b.device, function()
    b:release()
  end)
  T.eq("only the current request is retired", second.failure, { kind = "retired" })
  at(10, function()
    replies[1](true, codec.object({}))
    replies[2](true, codec.object({}))
  end)
  T.eq("late preparation cannot acquire scope after timeout or release", #f.connection.sent, 0)
  f.close()
end

T.section("confirmed commissioning transfers only to the approving current child")
for _, scenario in ipairs({
  "apply",
  "prepared switch",
  "upgrade direct switch",
  "late registration",
  "decline",
  "changed during resolve",
  "changed at apply",
  "timeout",
}) do
  local f = fixture()
  local revision = string.rep("c", 64)
  local upgrade = scenario == "upgrade direct switch"
  local preparing = scenario == "prepared switch"
  local waiting = scenario == "changed during resolve" or scenario == "timeout"
  local prepareDevice = string.rep("d", 32)
  local registry = string.rep("e", 32)
  local load = { entity_id = "light.lab", registry_id = registry, domain = "light" }
  local query = {
    choice_id = upgrade and "switch.lab"
      or preparing and "device:" .. prepareDevice .. ":" .. registry
      or waiting and "device:" .. prepareDevice .. ":none"
      or "light.lab",
    revision = revision,
    family = (upgrade or preparing) and "switch" or "light",
    prepare = true,
  }
  f.hub.catalog.refresh = function()
    error("a revisioned transfer must resolve its choice from the already-loaded catalog")
  end
  f.hub.catalog.choice = function(_, key, family)
    assert(key == query.choice_id and family == query.family)
    return {
      entity_id = key,
      name = "Test light",
      attributes = {
        device_choice = preparing and { device_id = prepareDevice, source_load = wire(load) } or waiting and {
          device_id = prepareDevice,
        } or nil,
      },
      domain = "light",
    }
  end
  local child, applies, claims = nil, 0, 0
  child = f.consumer(21, {
    mayCommission = function(family, key)
      claims = claims + 1
      return family == query.family
        and key == query.choice_id
        and scenario ~= "decline"
        and (scenario ~= "changed at apply" or claims == 1)
    end,
    applyCommission = function(config)
      applies = applies + 1
      assert(config.controlled_load.entity_id == (preparing and load.entity_id or query.choice_id))
      -- Setup.activate publishes the selected variable and registers the new
      -- subscription before the child sends the final acknowledgement.
      child:select(codec.array({ config.controlled_load.entity_id }))
      return true
    end,
  })
  local function selectEmpty()
    at(21, function()
      child:select(codec.array({}))
    end)
  end
  if scenario ~= "late registration" then
    selectEmpty()
  end
  local outcome
  at(10, function()
    local transfer = upgrade and f.hub.transfer:directSwitch(21, query.choice_id, "Test switch")
      or f.hub.transfer:start(21, query)
    transfer:next(function(ok)
      outcome = ok
    end, function(err)
      outcome = err.kind
    end)
  end)
  if scenario == "late registration" then
    T.eq("no implicit setup before the child registers", claims, 0)
    selectEmpty()
  elseif scenario == "changed during resolve" then
    selectEmpty()
  elseif scenario == "timeout" then
    clock.run(45000)
  end
  if preparing then
    local preparation = f.connection.sent[1]
    T.eq(
      "commissioning scopes preparation to the selected registry entry",
      preparation.service_data.source_registry_id,
      registry
    )
    f.ack(preparation.id, true, {
      response = {
        version = 1,
        device_id = prepareDevice,
        input_ready = true,
        source_load = load,
        controlled_load = load,
        controlled_load_origin = "selected_endpoint",
        gesture_entity_id = "event.wall_paddle",
      },
    })
  elseif waiting then
    local preparation = f.connection.sent[1]
    if scenario == "changed during resolve" then
      f.ack(preparation.id, true, { response = { version = 1, device_id = prepareDevice, input_ready = false } })
    end
  end
  local expected = ({
    ["decline"] = "target_changed",
    ["changed during resolve"] = "retired",
    ["changed at apply"] = "configuration_unconfirmed",
    ["timeout"] = "timeout",
  })[scenario] or true
  T.eq("transfer result for " .. scenario, outcome, expected)
  T.eq("exactly the approved setup count for " .. scenario, applies, expected == true and 1 or 0)
  T.eq("completed transfer releases ownership", f.hub.transfer.job, nil)
  f.close()
end

local function service(f, consumer, action, parameters)
  return operation(
    f,
    consumer,
    "service",
    "light.lab",
    { action = action or "turn_on", parameters = codec.object(parameters or {}) }
  )
end

T.section("service acceptance reaches only its caller and never fabricates state")
do
  local f = fixture()
  local a, b = f.consumer(21), f.consumer(22)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  at(22, function()
    b:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  local result = service(f, a, "turn_on", { brightness = 73 })
  local rpc = f.connection.sent[#f.connection.sent]
  T.eq("service scopes its exact target", rpc.target, { entity_id = "light.lab" })
  T.eq("service fields preserved", { rpc.domain, rpc.service, rpc.service_data.brightness }, { "light", "turn_on", 73 })
  local before = #f.deliveries
  f.ack(rpc.id)
  T.eq("caller sees acceptance only", result.value, { status = "accepted" })
  T.eq("one targeted result", #f.deliveries, before + 1)
  T.eq("result belongs to initiating consumer", f.deliveries[#f.deliveries].id, a.device)
  T.eq("acceptance does not invent confirmed state", f.hub.entities["light.lab"].state, nil)
  local sent = #f.connection.sent
  T.falsy(
    "replayed operation refused",
    at(10, function()
      return f.hub:receive(wire(f.requests[#f.requests]))
    end)
  )
  T.eq("duplicate cannot command load twice", #f.connection.sent, sent)
  f.close()
end

T.section("service rejection, timeout and transport failure remain distinct")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  local rejected = service(f, a)
  f.ack(2, false, { error = "private-server-payload" })
  T.eq("rejected result is bounded", rejected.failure, { kind = "rejected" })
  local timedOut = service(f, a)
  clock.run(10000)
  T.eq("Coordinator deadline reports timeout", timedOut.failure, { kind = "timeout" })
  local after = #f.deliveries
  f.ack(3)
  T.eq("late success cannot replace timeout", #f.deliveries, after)
  local disconnected = service(f, a)
  at(10, function()
    f.connection.onState("retrying")
  end)
  T.eq("transport loss is not a timeout", disconnected.failure, { kind = "disconnected" })
  T.eq("failed operations fabricate no state", f.hub.entities["light.lab"].state, nil)
  f.close()
end

T.section("selection and lifetime changes retire outstanding service and preparation replies")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  local result = service(f, a)
  local old = f.connection.sent[#f.connection.sent].id
  at(21, function()
    a:select(codec.array({ "switch.lab" }))
  end)
  T.eq("old selection request retired locally", result.failure, { kind = "retired" })
  local count = #f.deliveries
  f.ack(old)
  T.eq("old selection result cannot publish", #f.deliveries, count)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  local pending = operation(f, a, "prepare", "light.lab", { device_id = string.rep("a", 32) })
  old = f.connection.sent[#f.connection.sent].id
  at(21, function()
    a:destroy()
  end)
  T.eq("old lifetime preparation retired locally", pending.failure, { kind = "retired" })
  local newer = f.consumer(21)
  at(21, function()
    newer:select(codec.array({ "light.lab" }))
  end)
  count = #f.deliveries
  f.ack(old, true, { response = { version = 1, device_id = string.rep("a", 32), input_ready = true } })
  T.eq("old lifetime preparation cannot publish", #f.deliveries, count)
  f.close()
end

T.section("preparation validates response identity and has a separate longer deadline")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  local args = { device_id = string.rep("a", 32), source_registry_id = string.rep("b", 32) }
  local prepared = operation(f, a, "prepare", "light.lab", args)
  T.eq(
    "only the companion preparation service is used",
    { f.connection.sent[2].domain, f.connection.sent[2].service, f.connection.sent[2].return_response },
    { "ha_gesture_bridge", "prepare_device", true }
  )
  clock.run(20000)
  T.eq("preparation is not prematurely timed out", prepared.failure, nil)
  local response = {
    version = 1,
    device_id = args.device_id,
    input_ready = false,
    source_load = { entity_id = "light.lab", registry_id = args.source_registry_id },
    gesture_entity_id = "event.paddle",
  }
  f.ack(2, true, { response = response })
  T.eq("prepared reply delivered", prepared.value.status, "prepared")
  T.eq("input readiness remains honest", prepared.value.prepared.input_ready, false)
  T.eq("preparation is not confirmed load state", f.hub.entities["light.lab"].state, nil)
  for _, change in ipairs({
    { device_id = string.rep("c", 32) },
    { version = 99 },
    { source_load = { entity_id = "light.foreign", registry_id = args.source_registry_id } },
    { gesture_entity_id = "switch.foreign" },
  }) do
    local invalid = operation(f, a, "prepare", "light.lab", args)
    local foreign = wire(response)
    for key, value in pairs(change) do
      foreign[key] = value
    end
    f.ack(f.connection.sent[#f.connection.sent].id, true, { response = foreign })
    T.eq(
      "foreign or malformed preparation rejected",
      invalid.failure,
      { kind = change.version and "unsupported_preparation_version" or "invalid_response" }
    )
  end
  local timeout = operation(f, a, "prepare", "light.lab", args)
  clock.run(30000)
  T.eq("preparation deadline is bounded", timeout.failure, { kind = "timeout" })
  f.close()
end

T.section("invalid or unselected operations stop before HA; missing Coordinator results time out")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  local count = #f.connection.sent
  for _, arguments in ipairs({
    { action = "turn_on", parameters = { entity_id = "light.foreign" } },
    { action = "turn_on", parameters = { brightness = 999 } },
    { action = "turn_off", parameters = { brightness = 1 } },
    { action = "delete", parameters = {} },
  }) do
    local invalid = operation(f, a, "service", "light.lab", arguments)
    T.eq("invalid operation refused locally", invalid.failure, { kind = "invalid_request" })
  end
  local foreign = operation(f, a, "service", "switch.foreign", { action = "toggle", parameters = {} })
  T.eq("unselected entity cannot be commanded", foreign.failure, { kind = "unbound" })
  T.eq("invalid operations send no HA calls", #f.connection.sent, count)
  f.ack(1)
  SendSecretToDevice = function() end
  local timeout = service(f, a)
  clock.run(15000)
  T.eq("C4 delivery/result silence also has a deadline", timeout.failure, { kind = "timeout" })
  f.close()
end

T.section("readiness separates preparation failure from healthy transport and entity evidence")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  local view = a.readiness:view("light.lab")
  T.truthy("bound Coordinator is a separate fact", view.binding)
  T.eq(
    "transport can be healthy before subscription",
    { view.transport, view.subscription, view.snapshot },
    { true, false, false }
  )
  f.ack(1)
  T.eq("subscription may be ready without snapshot", a.readiness:view("light.lab").snapshot, false)
  f.connection.reads[1].promise:resolve(state("light.lab", "on"))
  T.truthy("fresh selected evidence becomes ready", a.readiness:view("light.lab").evidence_ready)
  local result = operation(f, a, "prepare", "light.lab", { device_id = string.rep("a", 32) })
  T.eq("preparation is independently pending", a.readiness:view("light.lab").preparation, "pending")
  at(10, function()
    f.connection.onMessage(wire({
      type = "result",
      id = 2,
      success = false,
      error = { code = "not_allowed", message = "private-denied-details" },
    }))
  end)
  T.eq("permission failure is distinct", result.failure, { kind = "permission_denied" })
  view = a.readiness:view("light.lab")
  T.eq("preparation failure named", { view.preparation, view.preparation_error }, { "failed", "permission_denied" })
  T.truthy("preparation failure does not mark HA disconnected", view.transport)
  T.truthy("ordinary selected state remains available", view.evidence_ready)
  f.close()
end

T.section("scoped subscription rejection retries twice and then requires explicit recovery")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1, false)
  clock.run(999)
  T.eq("failure does not immediately loop", #f.connection.sent, 1)
  clock.run(1)
  f.ack(2, false)
  clock.run(2000)
  f.ack(3, false)
  clock.run(120000)
  T.eq("three attempts bound scoped recovery", #f.connection.sent, 3)
  T.eq("failed subscription never fetches state", #f.connection.reads, 0)
  T.truthy("scoped failure preserves transport readiness", a.readiness:view("light.lab").transport)
  at(10, function()
    f.hub:retry()
  end)
  T.eq("explicit retry can recover scope", #f.connection.sent, 4)
  f.ack(4)
  T.eq("successful retry reads exactly selected state", f.connection.reads[1].entity, "light.lab")
  f.close()
end

T.section("permission refusal is visible without automatic retry or broad fetch")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "event.paddle" }))
  end)
  at(10, function()
    f.connection.onMessage(wire({ type = "result", id = 1, success = false, error = { code = "unauthorized" } }))
  end)
  clock.run(120000)
  T.eq("permission failure is not retried", #f.connection.sent, 1)
  T.eq("permission failure performs no state query", #f.connection.reads, 0)
  T.eq("no broad subscribe fallback", f.connection.sent[1].trigger.entity_id, "event.paddle")
  f.close()
end

T.section("ambiguous subscription timeouts retire the socket with a bounded recovery budget")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  for attempt = 1, 3 do
    clock.run(10000)
    T.eq("timed-out socket retired", f.connection.recoveries, attempt)
    at(10, function()
      f.connection.onState("connected")
    end)
  end
  clock.run(120000)
  T.eq("ambiguous scope cannot cause infinite reconnects", f.connection.recoveries, 3)
  T.eq("no fourth subscription after budget", #f.connection.sent, 3)
  T.eq("unknown old subscriptions cannot publish", f.hub.entities["light.lab"].state, nil)
  f.ack(1)
  T.eq("old transport ack cannot start a read", #f.connection.reads, 0)
  f.close()
end

T.section("selected-state read retries are bounded and valid push stops recovery")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  for attempt = 1, 3 do
    f.connection.reads[attempt].promise:reject({ kind = "timeout" })
    clock.run(attempt * 1000)
  end
  clock.run(120000)
  T.eq("read budget ends after three exact reads", #f.connection.reads, 3)
  for _, read in ipairs(f.connection.reads) do
    T.eq("every retry retains the exact entity", read.entity, "light.lab")
  end
  f.push(1, "light.lab", "on")
  T.truthy("pushed evidence recovers entity without polling", a.readiness:view("light.lab").evidence_ready)
  clock.run(120000)
  T.eq("healthy state never polls", #f.connection.reads, 3)
  f.close()
end

T.section("reconnect and removed entities initialize snapshots without historical occurrences")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "event.paddle" }))
  end)
  f.ack(1)
  f.push(1, "event.paddle", "old-timestamp")
  T.eq("first pushed evidence is baseline snapshot", f.deliveries[#f.deliveries - 1].message.kind, "snapshot")
  f.push(1, "event.paddle", "new-timestamp")
  T.eq("subsequent evidence is live state", f.deliveries[#f.deliveries - 1].message.kind, "state")
  at(10, function()
    f.connection.onState("retrying")
    f.connection.onState("connected")
  end)
  f.ack(2)
  f.push(2, "event.paddle", "last-stored-timestamp")
  T.eq("first reconnect evidence does not replay occurrence", f.deliveries[#f.deliveries - 1].message.kind, "snapshot")
  at(10, function()
    f.connection.onMessage(
      wire({ type = "event", id = 2, event = { variables = { trigger = { to_state = codec.null } } } })
    )
  end)
  T.eq("removed entity invalidates old snapshot", a.readiness:view("event.paddle").snapshot, false)
  T.truthy("removed entity does not mark HA disconnected", a.readiness:view("event.paddle").transport)
  f.connection.reads[2].promise:resolve(state("event.paddle", "stale-read"))
  T.eq("read predating removal cannot restore stale state", f.hub.entities["event.paddle"].state, nil)
  f.push(2, "event.paddle", "reappeared")
  T.eq("reappeared entity starts a new baseline", f.deliveries[#f.deliveries - 1].message.kind, "snapshot")
  f.close()
end

T.section("Coordinator connection retries one lost startup handshake")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  local forward = SendSecretToDevice
  SendSecretToDevice = function() end
  f.reload()
  T.eq("missing startup response leaves no selected lifetime", a.boot, nil)
  SendSecretToDevice = forward
  at(10, function()
    f.hub:announce(true)
  end)
  T.eq("second announcement recovers selection", a.boot, f.hub.boot)
  T.eq("recovers only the requested target", f.connection.sent[1].trigger.entity_id, "light.lab")
  local selection = a.selection
  at(10, function()
    f.hub:announce(true)
  end)
  T.eq("registered consumer stays on its active selection", a.selection, selection)
  f.close()
end

T.section("Bounded rejoin recovers without a Coordinator startup announcement")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  f.connection.reads[1].promise:resolve(state("light.lab", "on"))
  local selection = a.selection
  local old = f.reload(true)
  T.eq("old lifetime loses readiness", a.readiness:view("light.lab").transport, false)
  at(21, function()
    clock.run(1999)
  end)
  T.eq("replacement has no subscriptions until rejoin", #f.connection.sent, 0)
  at(21, function()
    clock.run(1)
  end)
  T.eq("rejoin retains the saved selection generation", a.selection, selection)
  T.truthy("rejoin accepts the replacement lifetime", a.boot > old.boot)
  T.eq("rejoin creates one exact subscription", f.connection.sent[1].trigger.entity_id, "light.lab")
  f.ack(f.connection.sent[1].id)
  T.eq("replacement issues one exact state read", #f.connection.reads, 1)
  if f.connection.reads[1] then
    f.connection.reads[1].promise:resolve(state("light.lab", "off"))
  end
  local requests = #f.requests
  at(21, function()
    clock.run(20000)
  end)
  T.eq("healthy rejoin does not poll", #f.requests, requests)
  f.close()
end

T.section("A retry reply does not create new HA traffic or forward to peers")
do
  local f = fixture()
  local a = f.consumer(21)
  local b = f.consumer(22)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  at(22, function()
    b:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  f.connection.reads[1].promise:resolve(state("light.lab", "on"))
  local sent, delivered = #f.connection.sent, #f.deliveries
  at(21, function()
    a:_send("select")
  end)
  T.eq(
    "exact retry requests no new HA reads or subscriptions",
    { #f.connection.sent, #f.connection.reads },
    { sent, 1 }
  )
  local recipients = {}
  for index = delivered + 1, #f.deliveries do
    recipients[#recipients + 1] = f.deliveries[index].id
  end
  T.eq("only original sender receives cached evidence", recipients, { 21, 21, 21 })
  f.close()
end

T.section("Coordinator reload re-registers selections and rejects old lifetime/transport deliveries")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  f.connection.reads[1].promise:resolve(state("light.lab", "on"))
  local oldMessage = wire(f.deliveries[#f.deliveries - 1].message)
  local oldBoot, oldSelection = f.hub.boot, a.selection
  local retired = {}
  f.hub.switchUpgrade = {
    destroy = function()
      retired.upgrade = true
    end,
  }
  f.hub.commissioning = {
    destroy = function()
      retired.commissioning = true
    end,
  }
  local oldHub, oldReceive = f.reload()
  T.eq(
    "the old Coordinator retires its setup and migration lifetimes",
    retired,
    { upgrade = true, commissioning = true }
  )
  T.truthy("replacement has a later persisted lifetime", f.hub.boot > oldBoot)
  T.truthy("announcement advances consumer selection", a.selection > oldSelection)
  T.eq("replacement recovers exact endpoint", f.connection.sent[1].trigger.entity_id, "light.lab")
  T.eq("consumer accepts replacement lifetime", a.boot, f.hub.boot)
  T.falsy(
    "old lifetime state cannot reach adapter",
    at(21, function()
      return a:receive(oldMessage)
    end)
  )
  T.falsy(
    "old reset cannot loop registration",
    at(21, function()
      return a:receive(wire({ version = 1, coordinator = 10, boot = oldBoot, kind = "reset" }))
    end)
  )
  local count = #f.connection.sent
  at(10, function()
    oldReceive(wire({ type = "result", id = 1, success = true, result = codec.null }))
    oldHub:retry()
    oldHub:announce()
  end)
  T.eq("obsolete Coordinator callbacks send nothing", #f.connection.sent, count)
  f.ack(1)
  f.connection.reads[1].promise:resolve(state("light.lab", "off"))
  oldMessage = wire(f.deliveries[#f.deliveries - 1].message)
  at(10, function()
    f.connection.onState("retrying")
    f.connection.onState("connected")
  end)
  T.falsy(
    "prior transport evidence is rejected",
    at(21, function()
      return a:receive(oldMessage)
    end)
  )
  oldMessage.kind, oldMessage.data = "selected", codec.object({})
  T.falsy(
    "old selection acknowledgement cannot roll back transport epoch",
    at(21, function()
      return a:receive(oldMessage)
    end)
  )
  f.close()
end

T.section("pending property and binding changes retire holds before any routing rejection")
do
  local f = fixture()
  local current, held = true, false
  local a = f.consumer(21, {
    isCurrent = function()
      return current
    end,
    cleanup = {
      function()
        held = false
      end,
    },
  })
  at(21, function()
    a:select(codec.array({ "event.paddle" }))
  end)
  held, current = true, false
  T.falsy(
    "unrelated payload cannot preserve old authority",
    at(21, function()
      return a:receive(codec.object({ version = 99 }))
    end)
  )
  T.eq("hold released before routing rejection", held, false)
  T.eq("old Coordinator membership released", f.hub.consumers[21], nil)
  current = true
  at(21, function()
    a:select(codec.array({ "event.other" }))
  end)
  held = true
  bind(21, 11)
  at(21, function()
    a:receive(codec.object({}))
  end)
  T.eq("changed binding releases held output", held, false)
  T.eq("changed binding clears readiness", a.readiness.binding, false)
  f.close()
end

T.section("fault-injected cleanup releases actual template Light work and prevents resurrection")
do
  local P = require("light_proxy_fake")
  local Light = require("lib.light")
  local proxy = P.install(clock)
  local commands = {}
  local light = Light.new({
    send = function(_, command)
      commands[#commands + 1] = command
    end,
    refresh = function() end,
    show = function() end,
  }, { api = 1, dims = true, fades = true, defaultOn = false, links = { top = 300, toggle = 301, bottom = 302 } })
  light:declare({ dims = true, color = false, fade = { kind = "walk", stepMs = 50 }, feedback = { refresh = false } })
  light:start()
  local f = fixture()
  local a
  local resurrected = false
  a = f.consumer(21, {
    cleanup = {
      function()
        error("private-cleanup-detail")
      end,
      function(reason)
        if reason == "destroyed" then
          light:destroy()
        else
          light:lost()
        end
      end,
      function()
        if a then
          resurrected = a:select(codec.array({ "light.foreign" }))
        end
      end,
    },
  })
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  f.ack(1)
  f.connection.reads[1].promise:resolve(state("light.lab", "on"))
  light:report({ kind = "push", on = true, level = 0.2 })
  proxy:send("RAMP_TO_LEVEL", { LEVEL = "80", TIME = "5000" })
  clock.run(100)
  local count = #commands
  local ok, _, output = T.capture(function()
    at(21, function()
      a:release()
    end)
  end)
  T.truthy("cleanup failure remains contained", ok)
  T.excludes("cleanup error body stays private", output, "private-cleanup-detail")
  clock.run(10000)
  T.eq("later cleanup stopped template-owned walked commands", #commands, count)
  T.eq("cleanup callback cannot recreate selection", resurrected, false)
  T.eq("released consumer holds no selection", a.wanted, nil)
  at(21, function()
    a:destroy()
  end)
  T.truthy("destruction retires the actual Light engine", light.destroyed)
  light:command({ kind = "on", source = "proxy" })
  clock.run(10000)
  T.eq("old engine cannot send after destruction", #commands, count)
  f.close()
  proxy:restore()
end

T.section("timer cancellation failure does not retain requests or memberships")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "switch.lab" }))
  end)
  f.ack(1)
  local outcomes = {}
  at(21, function()
    for i = 1, 2 do
      a:request("service", "switch.lab", wire({ action = "turn_on", parameters = codec.object({}) }))
        :next(nil, function(failure)
          outcomes[#outcomes + 1] = failure.kind
        end)
    end
  end)
  local cancel = CancelTimer
  CancelTimer = function()
    error("private-timer-cleanup-error")
  end
  local ok = pcall(function()
    at(21, function()
      a:destroy()
    end)
    f.close()
  end)
  CancelTimer = cancel
  T.truthy("all destruction stages ran despite failed cancellation", ok)
  T.eq("both consumer requests retired", outcomes, { "retired", "retired" })
  T.eq("Coordinator memberships retired", f.hub.consumers, {})
  T.eq("Coordinator entities retired", f.hub.entities, {})
  T.truthy("transport destruction still ran", f.connection.destroyed)
  local sent, delivered = #f.connection.sent, #f.deliveries
  clock.run(40000)
  T.eq("uncancelled obsolete timers cannot send", #f.connection.sent, sent)
  T.eq("uncancelled obsolete timers cannot publish", #f.deliveries, delivered)
end

local function catalogRow(entity, name)
  return wire({
    entity_id = entity,
    domain = entity:match("^([^%.]+)"),
    name = name or entity,
    attributes = codec.object({}),
  })
end
local function catalogReply(rows, rev, page, pages, total)
  return {
    response = {
      version = 1,
      revision = string.rep(rev or "a", 64),
      page = page or 1,
      pages = pages or 1,
      total = total or #rows,
      unchanged = false,
      entities = codec.array(rows),
    },
  }
end
local function browse(c, id, arguments)
  local outcome = {}
  at(id, function()
    c:request("catalog", nil, wire(arguments or codec.object({}))):next(function(data)
      outcome.data = data
    end, function(failure)
      outcome.failure = failure.kind
    end)
  end)
  return outcome
end

T.section("Quick Setup shows device types and rooms before any deployment")
do
  local f = fixture()
  f.hub.commissioning = {
    rooms = function()
      return { { id = 41, name = "Office" } }
    end,
    existingChoices = function()
      return { ["switch.outlet"] = true }, { ["light.bulb"] = { family = "light", room_id = 41, name = "Side lamp" } }
    end,
    destroy = function() end,
  }
  local api = require("ha.commission-page")
  local page = require("lib.ui.page")
  local original, answer = page.send, nil
  page.send = function(_, data)
    answer = data
  end
  api.install(function()
    return f.hub
  end)
  local function tab(command, params)
    params.request = "quick"
    answer = nil
    at(10, function()
      UIR[command]({ DATA = C4:Base64Encode(JSON:encode(params)) })
    end)
    return answer
  end
  local status = tab("HA_ADD_GET", {})
  T.eq("room assignment comes from the project", status.rooms[1].name, "Office")
  T.eq(
    "supported setup filters",
    { status.setups[1].id, status.setups[2].id, status.setups[3].id },
    { "lighting", "light", "switch" }
  )
  tab("HA_ADD_BROWSE", { setup = "lighting" })
  f.ack(1, true, catalogReply({ catalogRow("switch.outlet"), catalogRow("light.bulb") }))
  T.eq("single combined list with no duplicate binary devices", answer.total, 2)
  T.eq(
    "defaults reflect the actual endpoint type",
    { answer.choices[1].family, answer.choices[2].family },
    { "light", "switch" }
  )
  T.eq("Quick Setup reports which rows already have a driver", answer.choices[2].existing, true)
  T.eq("Quick Setup supplies the saved fields to finish an earlier add", answer.choices[1].resume, {
    family = "light",
    room_id = 41,
    name = "Side lamp",
  })
  local revision = answer.revision
  for _, family in ipairs({ "light", "switch" }) do
    local filtered = tab("HA_ADD_BROWSE", { setup = family, revision = revision })
    T.eq(
      family .. " filter includes the correct physical type once",
      { filtered.total, filtered.choices[1].family },
      { 1, family }
    )
    T.eq("eligible presentation options survive filtering", filtered.choices[1].families, { "light", "switch" })
  end
  T.truthy("unsupported device type is rejected", tab("HA_ADD_BROWSE", { setup = "other" }).error)
  T.eq("tab switching and room discovery need no other HA operation", #f.connection.sent, 1)
  page.send = original
  f.close()
end

T.section("two unconfigured consumers reuse one Coordinator catalog and revision check")
do
  local f = fixture()
  local a, b = f.consumer(21), f.consumer(22)
  at(21, function()
    a:select(codec.array({}))
  end)
  at(22, function()
    b:select(codec.array({}))
  end)
  T.eq("opening instances does not discover", #f.connection.sent, 0)
  local one, two = browse(a, 21), browse(b, 22)
  T.eq("concurrent picker openings coalesce", #f.connection.sent, 1)
  T.eq("read-only companion service", f.connection.sent[1].service, "get_devices")
  f.ack(1, true, catalogReply({ catalogRow("light.b"), catalogRow("switch.a") }))
  T.eq("first browser gets two rows", #one.data.entities, 2)
  T.eq("second browser reuses same dataset", two.data.revision, one.data.revision)
  T.eq("browsers add no selected state subscription", f.hub.entities, {})
  local firstSnapshot = f.hub.catalog.snapshot
  local check = browse(b, 22)
  T.eq("later opening supplies known revision", f.connection.sent[2].service_data.revision, string.rep("a", 64))
  f.ack(
    2,
    true,
    { response = { version = 1, revision = string.rep("a", 64), page = 1, pages = 1, total = 2, unchanged = true } }
  )
  T.truthy("unchanged revision retains sole dataset", f.hub.catalog.snapshot == firstSnapshot)
  T.eq("unchanged result still serves requested page", #check.data.entities, 2)
  local changed = browse(a, 21)
  f.ack(3, true, catalogReply({ catalogRow("light.new") }, "b"))
  T.eq("changed revision replaces data atomically", changed.data.entities[1].entity_id, "light.new")
  local stale = browse(b, 22, { cursor = 2, revision = string.rep("a", 64) })
  T.eq("old page cannot read a replacement snapshot", stale.failure, "revision_changed")
  T.eq("page rejection makes no HA request", #f.connection.sent, 3)
  f.close()
end

T.section("paged companion transfer publishes only a complete consistent catalog")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({}))
  end)
  local result = browse(a, 21)
  f.ack(1, true, catalogReply({ catalogRow("light.a") }, "a", 1, 2, 2))
  T.eq("partial transfer is not published", f.hub.catalog.snapshot, nil)
  T.eq("next page retains known revision", f.connection.sent[2].service_data.revision, string.rep("a", 64))
  f.ack(2, true, catalogReply({ catalogRow("switch.b") }, "b", 2, 2, 2))
  T.eq("mid-transfer revision changes reject entire transfer", result.failure, "invalid_catalog")
  T.eq("invalid catalog never falls back to native", #f.connection.catalogReads, 0)
  T.eq("invalid transfer did not publish", f.hub.catalog.snapshot, nil)
  f.close()
end

T.section("only confirmed companion absence uses filtered native discovery")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({}))
  end)
  local denied = browse(a, 21)
  at(10, function()
    f.connection.onMessage(wire({ type = "result", id = 1, success = false, error = { code = "unauthorized" } }))
  end)
  T.eq("permission error stays distinct", denied.failure, "permission_denied")
  T.eq("permission denial has no native fallback", #f.connection.catalogReads, 0)
  local result = browse(a, 21)
  at(10, function()
    f.connection.onMessage(wire({ type = "result", id = 2, success = false, error = { code = "not_found" } }))
  end)
  T.eq("absent companion starts one native read", #f.connection.catalogReads, 1)
  f.connection.catalogReads[1]:resolve(codec.array({ catalogRow("switch.native") }))
  T.eq("native endpoint remains selectable", result.data.entities[1].entity_id, "switch.native")
  T.eq("native source reported", result.data.source, "native")
  T.eq("repeat browse reuses native data", browse(a, 21).data.revision, result.data.revision)
  T.eq("no extra HA requests until explicit refresh", { #f.connection.sent, #f.connection.catalogReads }, { 2, 1 })
  local failure = browse(a, 21, { refresh = true })
  at(10, function()
    f.connection.onMessage(wire({ type = "result", id = 3, success = false, error = { code = "not_found" } }))
  end)
  f.connection.catalogReads[2]:reject({ kind = "permission_denied" })
  T.eq("filtered read failure is actionable", failure.failure, "permission_denied")
  T.eq("failure retains last complete dataset", f.hub.catalog.snapshot.rows[1].entity_id, "switch.native")
  T.eq("failed scoped read never broadens its request", #f.connection.catalogReads, 2)
  f.close()
end

T.section("released callers and prior Coordinator transport cannot publish catalog work")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({}))
  end)
  local result = browse(a, 21)
  at(21, function()
    a:release()
  end)
  local before = #f.deliveries
  f.ack(1, true, catalogReply({ catalogRow("light.lab") }))
  T.eq("retired caller gets no catalog result", #f.deliveries, before)
  T.eq("retired caller promise rejected", result.failure, "retired")
  at(21, function()
    a:select(codec.array({}))
  end)
  local stale = browse(a, 21)
  at(10, function()
    f.connection.onState("retrying")
  end)
  f.ack(2, true, catalogReply({ catalogRow("light.foreign") }, "b"))
  T.eq("old catalog result cannot replace saved dataset", f.hub.catalog.snapshot.rows[1].entity_id, "light.lab")
  T.eq("old transport catalog becomes unverified", f.hub.catalog.verified, nil)
  T.eq("request retired on transport change", stale.failure, "disconnected")
  f.close()
end

T.section("catalog cursor pages remain bounded and do not rediscover")
do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({}))
  end)
  local rows = {}
  for i = 1, 75 do
    rows[i] = catalogRow(string.format("light.endpoint_%03d", i))
  end
  local first = browse(a, 21)
  f.ack(1, true, catalogReply(rows))
  T.eq("first IPC page contains at most fifty choices", #first.data.entities, 50)
  T.eq("next cursor records exact following offset", first.data.next_cursor, 51)
  local nextPage = browse(a, 21, { cursor = 51, revision = first.data.revision })
  T.eq("second page completes the dataset", #nextPage.data.entities, 25)
  T.eq("last page has explicit null cursor", nextPage.data.next_cursor, codec.null)
  T.eq("cursor page requires no new HA request", #f.connection.sent, 1)
  f.close()
end

T.section("catalog invalid/version/timeout errors never widen discovery")
for _, mode in ipairs({ "version", "duplicate", "timeout" }) do
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({}))
  end)
  local result = browse(a, 21)
  if mode == "timeout" then
    clock.run(10000)
  else
    local response = catalogReply({ catalogRow("light.a"), catalogRow("light.a") })
    if mode == "version" then
      response.response.version = 2
    end
    f.ack(1, true, response)
  end
  T.eq(
    mode .. " remains a distinct failure",
    result.failure,
    mode == "version" and "unsupported_catalog_version" or mode == "timeout" and "timeout" or "invalid_catalog"
  )
  T.eq(mode .. " has no native fallback", #f.connection.catalogReads, 0)
  T.eq(mode .. " makes no broad request", #f.connection.sent, 1)
  f.close()
end

T.section("passive runtime profiling measures accepted and retired work without changing control")
do
  local metrics = require("ha.performance").shared
  metrics:reset()
  metrics:setEnabled(true)
  local f = fixture()
  local a = f.consumer(21)
  at(21, function()
    a:select(codec.array({ "light.lab" }))
  end)
  clock.run(5)
  f.ack(1)
  f.connection.reads[1].promise:resolve(state("light.lab", "off"))
  local accepted
  at(21, function()
    a:request("service", "light.lab", wire({ action = "turn_on", parameters = codec.object({}) })):next(function(value)
      accepted = value.status
    end)
  end)
  clock.run(7)
  f.ack(2)
  T.eq("profiling preserves service result", accepted, "accepted")
  T.eq("acceptance does not fabricate confirmed state", f.hub.entities["light.lab"].state.state, "off")
  local measurement = metrics:report().operations["request.light.on"]
  T.eq("actual correlated request recorded", measurement.count, 1)
  T.eq("request interval uses driver clock", measurement.max_ms, 7)
  at(21, function()
    a:request("service", "light.lab", wire({ action = "turn_off", parameters = codec.object({}) }))
    a:release()
  end)
  T.eq(
    "retired work has its own measured outcome",
    metrics:report().operations["request.light.off"].outcomes.retired,
    1
  )
  T.eq("profiling does not preserve released authority", f.hub.consumers[21], nil)
  f.close()
  metrics:setEnabled(false)
  metrics:reset()
end

T.section("diagnostics never strengthen opaque HA result handling")
for _, enabled in ipairs({ false, true }) do
  local metrics = require("ha.performance").shared
  metrics:reset()
  metrics:setEnabled(enabled)
  for _, result in ipairs({ true, 42 }) do
    local f = fixture()
    local called = false
    at(10, function()
      f.hub:_request(
        { type = "subscribe_trigger", trigger = { platform = "state", entity_id = "light.lab" } },
        function(ok, value)
          called = ok and value == result
        end
      )
    end)
    local ok = pcall(f.ack, 1, true, result)
    T.truthy("opaque result remains safely observable with diagnostics " .. tostring(enabled), ok and called)
    T.eq("diagnostics cannot trigger transport recovery", f.connection.recoveries, nil)
    f.close()
  end
  metrics:setEnabled(false)
  metrics:reset()
end

T.section("gesture acknowledgment is optional and independent of control requests")
do
  local metrics = require("ha.performance").shared
  local f, entity = fixture(), "event.owned"
  local c = f.consumer(21)
  at(21, function()
    c:select(codec.array({ entity, "switch.other" }))
  end)
  f.ack(1)
  f.ack(2)
  local event = state(entity, "2026-11-17T12:00:00Z")
  event.attributes = codec.object({
    bridge_acknowledgment_version = 2,
    bridge_session_id = "event-session",
    gesture_session_id = "event-session",
    gesture_sequence = 5,
  })
  for _, read in ipairs(f.connection.reads) do
    read.promise:resolve(read.entity == entity and event or state(read.entity))
  end
  local argument = {
    entity_id = entity,
    bridge_session_id = "event-session",
    gesture_sequence = 5,
    receiver_received_epoch_ms = 100,
    receiver_processed_epoch_ms = 102,
    receiver_processing_ms = 2,
    receiver = "untrusted-supplied-receiver",
  }
  local function acknowledge(override)
    local data = {}
    for key, value in pairs(argument) do
      data[key] = value
    end
    for key, value in pairs(override or {}) do
      data[key] = value
    end
    return at(21, function()
      return c:acknowledge(data)
    end)
  end
  local before = #f.connection.sent
  metrics:setEnabled(false)
  T.eq("diagnostics disabled locally", acknowledge(), false)
  T.eq("disabled performs no HA operation", #f.connection.sent, before)
  metrics:setEnabled(true)
  T.eq("foreign entity never reaches the Hub", acknowledge({ entity_id = "event.foreign" }), false)
  T.eq("wrong session and future sequence never send", #f.connection.sent, before)
  acknowledge({ bridge_session_id = "stale" })
  acknowledge({ gesture_sequence = 6 })
  T.eq("unmatched evidence does not go to HA", #f.connection.sent, before)
  T.truthy("versioned diagnostic accepted by transport", acknowledge())
  local rpc = f.connection.sent[#f.connection.sent]
  T.eq("diagnostic backend fixed", { rpc.domain, rpc.service, rpc.service_data.receiver }, {
    "ha_gesture_bridge",
    "acknowledge",
    "control4:21",
  })
  T.eq("only supported diagnostic payload travels", rpc.service_data, {
    entity_id = entity,
    bridge_session_id = "event-session",
    gesture_sequence = 5,
    receiver = "control4:21",
    receiver_received_epoch_ms = 100,
    receiver_processed_epoch_ms = 102,
    receiver_processing_ms = 2,
  })
  T.eq("diagnostic shares no control request state", { next(c.pending), next(f.hub.pending) }, {})
  acknowledge()
  T.eq("duplicate acknowledged sequence blocked", #f.connection.sent, before + 1)
  at(21, function()
    c:request("service", "switch.other", codec.object({ action = "turn_on", parameters = codec.object({}) }))
  end)
  T.eq("normal control independently reaches HA", f.connection.sent[#f.connection.sent].service, "turn_on")
  f.ack(f.connection.sent[#f.connection.sent].id)
  f.close()
  metrics:setEnabled(false)
  metrics:reset()
end

T.section("Coordinator validates indicator changes independently against latest selected metadata")
do
  local f, entity = fixture(), "event.selected_indicator"
  local owner = f.consumer(21)
  at(21, function()
    owner:select(codec.array({ entity }))
  end)
  local args =
    { device = "device", control = "control", session = "bridge", id = "top", field = "color", value = "FF0000" }
  local function change(field, value)
    local settings = wire(args)
    if field then
      settings[field] = value
    end
    return operation(f, owner, "indicator", entity, settings)
  end
  T.eq("no service without a confirmed subscription", change().failure.kind, "indicator_unavailable")
  f.ack(1)
  local snapshot = wire({
    entity_id = entity,
    state = "unknown",
    attributes = {
      bridge_contract_version = "1.0",
      bridge_led_command_version = 2,
      bridge_led_version = 1,
      bridge_source_device_id = args.device,
      bridge_control_id = args.control,
      bridge_session_id = args.session,
      bridge_leds = codec.array({
        {
          id = args.id,
          available = true,
          label = "Test indicator",
          color_supported = true,
          colors = codec.array({ "FF0000" }),
          behaviors = codec.array({ "always_on" }),
        },
      }),
    },
  })
  f.connection.reads[1].promise:resolve(snapshot)
  T.eq("foreign source selection rejected", change("device", "other").failure.kind, "indicator_unavailable")
  T.eq("foreign control rejected", change("control", "other").failure.kind, "indicator_unavailable")
  T.eq("stale helper session rejected", change("session", "old").failure.kind, "indicator_unavailable")
  T.eq("stale palette value rejected", change("value", "00FF00").failure.kind, "indicator_unavailable")
  T.eq("all rejected changes produce no HA service", #f.connection.sent, 1)
  local good = change()
  T.eq(
    "only confirmed selected command is forwarded",
    f.connection.sent[2].service_data,
    { entity_id = entity, led_id = "top", color = "FF0000" }
  )
  f.ack(2)
  T.eq("only acceptance returned", good.value, { status = "accepted" })
  f.push(1, entity, "unavailable")
  T.eq("unavailable stops new updates", change().failure.kind, "indicator_unavailable")
  T.eq("no later service after unavailability", #f.connection.sent, 2)
  f.close()
end

T.section("Suite traffic validates mixed input IDs and retained legacy edges")
do
  local f = fixture()
  local light, other = f.consumer(21), f.consumer(22)
  inputIds[21], inputIds[23] = ids.lightCoordinatorBinding, ids.lightCoordinatorBinding
  installed[21] = { driverFileName = "HA.Light.c4z", model = "HA Light" }
  installed[10] = { driverFileName = "HA.Coordinator.c4z", model = "HA Coordinator" }
  legacyDeclarations[21], legacyDeclarations[10] = true, true
  bind(21, 10)
  T.eq("new canonical suite edge at 999 is accepted alongside the 1 edge", {
    contract.provider(21),
    contract.provider(22),
  }, { 10, 10 })
  bind(21, 10, ids.legacyCoordinatorClass)
  bindingReads = {}
  T.eq("canonical upgraded pair can retain the existing legacy wire", contract.provider(21), 10)
  T.eq("retained edge uses one fresh binding read per endpoint", bindingReads, { [21] = 1, [10] = 1 })
  at(21, function()
    light:select(codec.array({ "light.lab" }))
  end)
  at(22, function()
    other:select(codec.array({ "switch.lab" }))
  end)
  T.eq("both mixed consumers establish live suite registrations", {
    f.hub.consumers[21] ~= nil,
    f.hub.consumers[22] ~= nil,
  }, { true, true })
  bind(23, 10, ids.legacyCoordinatorClass)
  installed[23], legacyDeclarations[23], missingSuite[23] = installed[21], true, true
  T.eq("an original Light with the same filename and model cannot enter the suite", contract.provider(23), nil)
  installed[10].model = "Different model"
  T.eq("legacy class edge requires canonical provider proof", contract.provider(21), nil)
  installed[10].model = "HA Coordinator"
  missingSuite[10] = true
  T.eq("unupgraded Coordinator cannot enter the suite", contract.provider(21), nil)
  missingSuite[10] = nil
  legacyDeclarations[21] = nil
  T.eq("retained wire requires the Light to declare its legacy class", contract.provider(21), nil)
  legacyDeclarations[21] = true
  legacyDeclarations[10] = nil
  T.eq("retained wire requires the Coordinator to declare its legacy class", contract.provider(21), nil)
  legacyDeclarations[10] = true
  inputPeers[21].boundclasses = { ids.coordinatorClass }
  T.eq("both ends must agree on a bound class", contract.provider(21), nil)
  inputPeers[21].boundclasses = { ids.legacyCoordinatorClass }
  inputPeers[21].bindingid = 999
  T.eq("wrong provider binding cannot enter the suite", contract.provider(21), nil)
  inputPeers[21].bindingid = 1
  peers[10][21].bindingid = 1
  T.eq("wrong reciprocal consumer binding cannot enter the suite", contract.provider(21), nil)
  peers[10][21].bindingid = 999
  inputPeers[21].deviceid = 11
  T.eq("wrong reciprocal provider device cannot enter the suite", contract.provider(21), nil)
  f.close()
end

T.eq("no swallowed callback failures", clock.errors, {})
clock.restore()
T.section("manual event recovery verifies exact registry rows and pins with one narrow request")
do
  local f = fixture()
  local c = f.consumer(21)
  at(21, function()
    c:select(codec.array({}))
  end)
  local event, load = "event.fixture", "light.fixture"
  local eventId, loadId = string.rep("e", 32), string.rep("a", 32)
  local function verify(args, change)
    local result = operation(f, c, "verify_target", event, args)
    if result.failure then
      return result
    end
    local pending = f.connection.sent[#f.connection.sent]
    T.eq(
      "registry request names exactly the requested rows",
      pending.entity_ids,
      args.load_entity and { event, load } or { event }
    )
    local rows = {
      [event] = {
        entity_id = event,
        unique_id = "paddle",
        id = eventId,
        platform = "ha_gesture_bridge",
        disabled_by = codec.null,
      },
    }
    if args.load_entity then
      rows[load] = { entity_id = load, id = loadId, platform = "mqtt", disabled_by = codec.null }
    end
    if change then
      change(rows)
    end
    f.ack(pending.id, true, rows)
    return result
  end
  T.eq(
    "event-only proof has no synthetic source or load",
    verify({ event_control = "paddle" }).value,
    { status = "verified", event_registry_id = eventId }
  )
  local both = { event_control = "paddle", event_registry_id = eventId, load_entity = load, load_registry_id = loadId }
  T.eq(
    "pinned event and explicit independent load are returned",
    verify(both).value,
    { status = "verified", event_registry_id = eventId, load_registry_id = loadId }
  )
  for _, change in ipairs({
    function(rows)
      rows[event].platform = "mqtt"
    end,
    function(rows)
      rows[event].unique_id = "other"
    end,
    function(rows)
      rows[event].disabled_by = "user"
    end,
    function(rows)
      rows[event].id = string.rep("f", 32)
    end,
    function(rows)
      rows[load].id = eventId
    end,
    function(rows)
      rows[load].entity_id = "light.wrong"
    end,
    function(rows)
      rows[load].platform = "control4"
    end,
    function(rows)
      rows[load] = nil
    end,
  }) do
    T.eq("foreign, missing or recycled identity fails closed", verify(both, change).failure.kind, "unavailable")
  end
  T.eq(
    "a load registry pin needs an exact named load",
    verify({ event_control = "paddle", load_registry_id = loadId }).failure.kind,
    "invalid_request"
  )
  f.close()
end
T.finish()
