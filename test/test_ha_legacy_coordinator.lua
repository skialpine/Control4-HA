local T = require("testlib")
local codec = require("ha.codec")
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
  return ({ model = devices[id].model, version = devices[id].version, manufacturer = "BP" })[field]
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
T.eq("legacy raw payload logging must be disabled", connection.reads, 0)
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
clock.restore()
T.finish()
