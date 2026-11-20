local T = require("testlib")
local codec = require("ha.codec")
local contract = require("ha.contract")
local clock = require("c4_fixtures").virtualClock()
local newHub = require("ha_legacy_harness")

local owner = 21
local devices, replies, connection, legacy
local function child(model, entity, class)
  return { model = model, entity = entity, class = class or "HA_DEVICE", binding = 999, version = 106, provider = owner }
end
local function peer(device, binding, class)
  return { deviceid = device, bindingid = binding, boundclasses = { class } }
end
function C4:GetDeviceID()
  return owner
end
function C4:GetBindingsByDevice(id)
  if id ~= owner then
    local device = devices[id]
    return {
      bindings = {
        {
          bindingid = device.binding,
          provider = false,
          bindingclasses = { { class = device.class } },
          boundprovider = { bound = peer(device.provider, 1, device.class) },
        },
      },
    }
  end
  local consumers = {}
  for id, device in pairs(devices) do
    consumers[#consumers + 1] = peer(id, device.binding, device.class)
  end
  return {
    bindings = {
      {
        bindingid = 1,
        provider = true,
        bindingclasses = { { class = "HA_DEVICE" }, { class = "SKIALPINE_HA_SUITE_V1" } },
        boundconsumers = consumers,
      },
    },
  }
end
function C4:GetBoundProviderDevice(id, binding)
  local device = devices[id]
  return binding == device.binding and device.provider or 0
end
function C4:GetDevices(filters)
  local id = tonumber(filters.DeviceIds)
  return { [id] = { driverFileName = devices[id].file or devices[id].model:gsub(" ", ".") .. ".c4z" } }
end
function C4:GetDeviceData(id, field)
  return ({ model = devices[id].model, version = devices[id].version, manufacturer = devices[id].manufacturer or "BP" })[field]
end
function GetDeviceProperties(id)
  return { ["Entity ID"] = devices[id].entity, ["Debug Mode"] = devices[id].debug or "Off" }
end
function C4:SendToProxy(binding, command, parameters)
  replies[#replies + 1] = { binding = binding, command = command, parameters = parameters }
end

local function fixture(model, entity)
  devices = { [22] = child(model, entity) }
  replies = {}
  connection, legacy = newHub()
end
local function request(entity, binding)
  legacy:request(binding or 1, { entity = entity })
end
local function state(entity)
  return codec.object({ entity_id = entity, state = "on", attributes = codec.object({ friendly_name = "Hall" }) })
end

T.section("Original BP request and reply use exactly the configured entity")
for _, group in ipairs({ { "HA Light", "light.hall" }, { "HA Switch", "switch.hall" } }) do
  local model, entity = group[1], group[2]
  fixture(model, entity)
  request(entity, 999)
  request(entity .. "_other")
  legacy:request(1, { entity = entity, consumer_id = 22 })
  T.eq("invalid requests never start HA reads", connection.reads, 0)
  request(entity)
  request(entity)
  T.eq("verified request shares one bounded read", connection.reads, 1)
  T.eq("read uses the configured exact entity", connection.entity, entity)
  connection.pending:resolve(state(entity))
  T.eq("one reply for " .. model, #replies, 1)
  T.eq("uses the original binding and packet shape", replies[1], {
    binding = 1,
    command = "RECEIEVE_STATE",
    parameters = { response = codec.encode({ entity_id = entity, state = "on", attributes = codec.object() }) },
  })
end

T.section("A shared binding requires known recipients with valid selections")
for _, candidate in ipairs({
  child("HA Light", "light.hall", "SKIALPINE_HA_SUITE_V1"),
  child("HA Switch", "light.hall"),
  child("Unexpected HA Light", "light.hall"),
}) do
  fixture("HA Light", "light.hall")
  devices[23] = candidate
  request("light.hall")
  T.eq("no lookup for a group with any unauthorized recipient", connection.reads, 0)
end
fixture("HA Light", "light.hall")
devices[22].provider = 40
request("light.hall")
T.eq("a one-sided binding cannot establish authority", connection.reads, 0)
devices[22].provider, devices[22].version = owner, 107
request("light.hall")
T.eq("an unqualified package version cannot establish authority", connection.reads, 0)
devices[22].version = 106
devices[22].debug = "On"
request("light.hall")
T.eq("the exact private read can proceed while legacy public delivery is disabled", connection.reads, 1)
connection.pending:resolve(state("light.hall"))
T.eq("no raw packet is published while any legacy peer has debug enabled", #replies, 0)
devices[22].debug = "Off"
devices[23] = child("HA Light", "light.hall")
request("light.hall")
connection.pending:resolve(state("light.hall"))
T.eq("one reply can serve a stable group sharing the exact entity", #replies, 1)

T.section("A retired request has no remaining authority")
for _, retire in ipairs({
  function()
    devices[23] = child("HA Light", "light.hall")
  end,
  function()
    devices[22].entity = "light.changed"
  end,
  function()
    devices[22].debug = "On"
  end,
  function()
    legacy:bindingChanged()
  end,
  function()
    connection.generation = connection.generation + 1
  end,
  function()
    connection.state = "retrying"
  end,
  function()
    legacy:destroy()
  end,
}) do
  fixture("HA Light", "light.hall")
  request("light.hall")
  retire()
  connection.pending:resolve(state("light.hall"))
  T.eq("changed binding, property or connection suppresses the reply", #replies, 0)
end
fixture("HA Light", "light.hall")
request("light.hall")
connection.pending:resolve(state("light.other"))
T.eq("HA cannot reply with unrelated state", #replies, 0)
request("light.hall")
connection.pending:reject({ kind = "timeout" })
T.eq("an unsuccessful read never emits a reply", #replies, 0)
request("light.hall")
T.eq("a later valid request can try again", connection.reads, 3)
T.section("explicit entity diagnostic rereads only reciprocal legacy selections")
fixture("HA Light", "light.entry")
devices[23] = child("HA Switch", "switch.other")
devices[24] = child("HA Light", "private-untrusted-value")
devices[25] = child("HA Light", "light.retired")
devices[25].provider = 40
T.eq("fresh valid IDs only", legacy:linkedEntities(), { ["light.entry"] = true, ["switch.other"] = true })
devices[22].entity = "light.changed"
T.eq(
  "print sees revised selections and no duplicates",
  legacy:linkedEntities(),
  { ["light.changed"] = true, ["switch.other"] = true }
)
T.eq("entity diagnostic performs no HA reads", connection.reads, 0)
T.section("Original control packets require a currently selected target on a verified project")
fixture("HA Light", "light.first")
devices[23] = child("HA Light", "light.second")
local function lightPacket(target, data)
  return {
    JSON = codec.encode({
      domain = "light",
      service = "turn_on",
      target = { entity_id = target },
      service_data = data or codec.object(),
    }),
  }
end
legacy:service(1, lightPacket("light.first"))
legacy:service(1, lightPacket("light.second"))
T.eq(
  "two original selections keep their service targets",
  { connection.sent[1].target.entity_id, connection.sent[2].target.entity_id },
  { "light.first", "light.second" }
)
legacy:service(1, lightPacket("light.not_linked"))
devices[22].entity = "light.reassigned"
legacy:service(1, lightPacket("light.first"))
legacy:service(1, lightPacket("light.second", { entity_id = "light.not_linked" }))
legacy:service(999, lightPacket("light.second"))
devices[22].version = "9999"
legacy:service(1, lightPacket("light.second"))
devices[22].version = "106"
devices[22].entity = ""
legacy:service(1, lightPacket("light.second"))
T.eq("stale, unrelated, malformed and unqualified calls never send", #connection.sent, 2)
T.section("known suite Light and Switch ignore the shared wire after capability verification")
for _, suite in ipairs({ { "HA Light", "HA.Light.c4z", 999 }, { "Control4.HA.Switch", "Control4.HA.Switch.c4z", 1 } }) do
  fixture("HA Light", "light.first")
  devices[23] = child(suite[1], "", "SKIALPINE_HA_SUITE_V1")
  devices[23].file, devices[23].binding, devices[23].version = suite[2], suite[3], "20261117"
  function C4:SendUIRequest(device, command)
    if device == 23 and command == "HA_LEGACY_WIRE" then
      return "<legacy_wire>ignore-v1</legacy_wire>"
    end
  end
  request("light.first")
  T.eq("verified mixed receiver permits original snapshots", connection.reads, 1)
  connection.pending:resolve(state("light.first"))
  T.eq("original receives its projected state", #replies, 1)
  legacy:service(1, lightPacket("light.first"))
  T.eq("known suite receiver leaves original control working", connection.sent[#connection.sent].service, "turn_on")
  function C4:SendUIRequest()
    return "<result>success</result>"
  end
  local before = #connection.sent
  legacy:service(1, lightPacket("light.first"))
  T.eq("an older handler without a positive capability cannot authorize a legacy write", #connection.sent, before)
end
T.section("media projection excludes signed credentials and unrelated attributes")
local projection = require("ha.legacy-state")
local media = state("media_player.example")
media.attributes.entity_picture = "/api/media_player_proxy/example?token=private-art"
media.attributes.media_title = "Track"
media.attributes.unused = { secret = "private-extra" }
local projected = projection.project(media, { ["HA Media Player"] = true })
T.eq("keep title while withholding signed art and unused fields", projected.attributes, { media_title = "Track" })
media.attributes.entity_picture = "//external.invalid/picture.png"
T.eq(
  "off-host image is not forwarded",
  projection.project(media, { ["HA Media Player"] = true }).attributes.entity_picture,
  nil
)
media.attributes.entity_picture = "/local/cover.png"
T.eq(
  "ordinary local artwork survives",
  projection.project(media, { ["HA Media Player"] = true }).attributes.entity_picture,
  "/local/cover.png"
)

local function scopedRequest(id, entity, active)
  legacy:request(1, {
    consumer_id = tostring(id),
    entity = entity,
    active_entities = active or codec.encode(codec.array({ entity })),
  })
end
local function directPacket(entity, action, parameters)
  return {
    JSON = codec.encode({
      domain = contract.loadDomain(entity),
      service = action,
      target = { entity_id = entity },
      service_data = codec.object(parameters),
    }),
  }
end

T.section("Pinned prototype direct loads use their scoped packet on the original binding")
for _, original in ipairs({
  { "HA Light", 1, "light.prototype", "turn_on", { brightness = 163, transition = 0.75 } },
  { "HA Switch", 107, "input_boolean.prototype", "toggle", {} },
}) do
  local model, version, entity, action, parameters = unpack(original)
  fixture(model, entity)
  devices[22].version = version
  request(entity)
  legacy:service(1, directPacket(entity, action, parameters))
  T.eq("unscoped lookup and control do not grant prototype authority", { connection.reads, #connection.sent }, { 0, 0 })
  scopedRequest(22, entity)
  scopedRequest(22, entity)
  T.eq("repeat requests share one exact read", { connection.reads, connection.entity }, { 1, entity })
  local snapshot = state(entity)
  snapshot.last_updated = "2026-11-18T20:00:00+00:00"
  snapshot.attributes.supported_features = 32
  snapshot.attributes.unused = { token = "fixture-private" }
  connection.pending:resolve(snapshot)
  T.eq("prototype reads the stock snapshot envelope", replies[1].command, "RECEIEVE_STATE")
  local returned = codec.decode(replies[1].parameters.response)
  T.eq("prototype receives the state revision", returned.last_updated, snapshot.last_updated)
  T.eq("the bounded projection keeps relevant prototype fields", returned.attributes, {
    friendly_name = "Hall",
    supported_features = 32,
  })
  legacy:service(1, directPacket(entity, action, parameters))
  T.eq("prototype reaches the exact load with validated parameters", connection.sent[#connection.sent], {
    id = connection.sent[#connection.sent].id,
    type = "call_service",
    domain = contract.loadDomain(entity),
    service = action,
    service_data = parameters,
    target = { entity_id = entity },
  })
  local sent = #connection.sent
  devices[22].entity = entity .. "_new"
  legacy:service(1, directPacket(entity, action, parameters))
  legacy:service(1, directPacket(devices[22].entity, action, parameters))
  T.eq("a changed property authorizes neither the retired nor unregistered load", #connection.sent, sent)
end

T.section("A prototype request cannot select a foreign load, claim a BP device or expand the scope")
fixture("HA Light", "light.prototype")
devices[22].version = 1
devices[23] = child("HA Light", "light.original")
scopedRequest(22, "light.foreign")
scopedRequest(22, "light.prototype", '["light.prototype","light.foreign"]')
scopedRequest(22, "light.prototype", '{"1":"light.prototype"}')
scopedRequest(23, "light.original")
devices[22].manufacturer = "Other"
scopedRequest(22, "light.prototype")
devices[22].manufacturer = "BP"
devices[22].file = "Another.Light.c4z"
scopedRequest(22, "light.prototype")
T.eq("all unverified claims leave the transport untouched", #connection.sent, 0)
devices[22].file = "HA.Light.c4z"
scopedRequest(22, "light.prototype")
T.eq("known mixed peers read their configured entities", connection.reads, 2)
local pending = connection.reading["light.prototype"]
legacy:release(1, { consumer_id = "22" })
pending:resolve(state("light.prototype"))
T.eq("a released prototype cannot publish its delayed snapshot", #replies, 0)
local sent = #connection.sent
legacy:service(1, directPacket("light.prototype", "turn_on", { brightness = 163 }))
T.eq("release also removes prototype control scope", #connection.sent, sent)
local last = connection.reading["light.original"]
last:resolve(state("light.original"))
T.eq(
  "release preserves the unrelated BP subscription and its pending reply",
  codec.decode(replies[1].parameters.response).entity_id,
  "light.original"
)
T.eq("releasing another scope does not restart the BP read", connection.reads, 2)

T.section("Staggered prototype registrations do one snapshot read per entity")
fixture("HA Light", "light.prototype")
devices[22].version = 1
devices[23] = child("HA Light", "light.second_prototype")
devices[23].version = 1
scopedRequest(22, "light.prototype")
connection.reading["light.prototype"]:resolve(state("light.prototype"))
scopedRequest(23, "light.second_prototype")
connection.reading["light.second_prototype"]:resolve(state("light.second_prototype"))
T.eq("a new scope does not reread a stable load", connection.reads, 2)
T.eq("both owners receive a snapshot", #replies, 2)

T.section("A peer's debug logging pauses replies without discarding approved prototype scopes")
fixture("HA Light", "light.prototype")
devices[22].version = 1
devices[23] = child("HA Light", "light.original")
scopedRequest(22, "light.prototype")
local approved = legacy.hub.entities["light.prototype"].legacy
devices[23].debug = "On"
connection.reading["light.prototype"]:resolve(state("light.prototype"))
T.eq("no sensitive packet goes to a logging peer", #replies, 0)
T.eq(
  "previous scope can still receive state after logging stops",
  legacy.hub.entities["light.prototype"].legacy,
  approved
)
devices[23].debug = "Off"
legacy.hub:retry()
connection.reading["light.prototype"]:resolve(state("light.prototype"))
T.eq("retry publishes a fresh initial snapshot after logging stops", replies[1].command, "RECEIEVE_STATE")
devices[22].debug = "On"
local sends = #connection.sent
legacy:service(1, directPacket("light.prototype", "turn_off", {}))
T.eq("debug logging does not revoke scoped outgoing control", #connection.sent, sends + 1)
devices[23].debug = "On"
legacy:release(1, { consumer_id = "22" })
T.eq("releasing the final owner immediately drops the watch", legacy.hub.entities["light.prototype"], nil)
devices[22].debug = "Off"
devices[23].debug = "Off"
T.eq("a release during debug logging stays released", legacy:deliver("state", state("light.prototype"), approved), nil)
T.eq("no packet after release", #replies, 1)

T.section("a muted push after initialization can recover on explicit retry")
fixture("HA Light", "light.prototype")
devices[22].version = 1
scopedRequest(22, "light.prototype")
connection.reading["light.prototype"]:resolve(state("light.prototype"))
local known = legacy.hub.entities["light.prototype"]
T.truthy("the first snapshot initialized feedback", known.legacyInitialized)
devices[22].debug = "On"
local updated = state("light.prototype")
updated.state = "off"
legacy.hub:_members(known, "state", updated, known.legacy)
T.eq("the push was withheld and is eligible for a fresh snapshot", { #replies, known.legacyInitialized }, { 1, false })
devices[22].debug = "Off"
legacy.hub:retry()
connection.reading["light.prototype"]:resolve(updated)
T.eq(
  "retry returns the settled state without another live push",
  codec.decode(replies[2].parameters.response).state,
  "off"
)

T.section("Reconnect with a logging peer keeps every approved private watch")
fixture("HA Light", "light.prototype")
devices[22].version = 1
devices[23] = child("HA Light", "light.original")
scopedRequest(22, "light.prototype")
devices[23].debug = "On"
connection.state = "retrying"
legacy:bindingChanged()
connection.generation = connection.generation + 1
connection.state = "connected"
scopedRequest(22, "light.prototype")
connection.reading["light.prototype"]:resolve(state("light.prototype"))
T.eq("reconnect while logging still sends no raw packet", #replies, 0)
devices[23].debug = "Off"
legacy.hub:retry()
connection.reading["light.prototype"]:resolve(state("light.prototype"))
T.eq("a linked retry recovers after a muted reconnect", replies[1].command, "RECEIEVE_STATE")

T.section("Two prototype readers share one subscription without sharing their release")
fixture("HA Light", "light.shared")
devices[22].version = 1
devices[23] = child("HA Light", "light.shared")
devices[23].version = 1
scopedRequest(22, "light.shared")
scopedRequest(23, "light.shared")
local shared = connection.subscriptions["light.shared"]
T.eq("the second reader reuses the same HA subscription", #connection.sent, 1)
legacy:release(1, { consumer_id = "22" })
T.eq("the active reader keeps the exact subscription", #connection.sent, 1)
legacy:release(1, { consumer_id = "23" })
T.eq("only the last release unsubscribes", {
  connection.sent[#connection.sent].type,
  connection.sent[#connection.sent].subscription,
}, { "unsubscribe_events", shared })

T.section("Connection status lets a prototype retire and refresh state without claiming preparation support")
fixture("HA Light", "light.prototype")
legacy:connectionStatus(1)
T.eq("original-only installation emits no prototype status traffic", #replies, 0)
devices[22].version = 1
legacy:connectionStatus(1)
legacy:connectionStatus(1)
connection.state = "retrying"
legacy:connectionStatus(1)
legacy:connectionStatus(999, true)
T.eq("one status per transition on the retained binding", replies, {
  { binding = 1, command = "HA_CONNECTION_STATUS", parameters = { CONNECTED = "true" } },
  { binding = 1, command = "HA_CONNECTION_STATUS", parameters = { CONNECTED = "false" } },
})

T.section("An offline release stays retired at reconnect")
fixture("HA Light", "light.prototype")
devices[22].version = 1
scopedRequest(22, "light.prototype")
connection.state = "retrying"
connection.onState(connection.state)
legacy:bindingChanged()
legacy:release(1, { consumer_id = "22" })
connection.generation = connection.generation + 1
connection.state = "connected"
connection.onState(connection.state)
legacy:refresh()
T.eq("reconnect does not read the released selection again", connection.reads, 1)
clock.restore()
T.finish()
