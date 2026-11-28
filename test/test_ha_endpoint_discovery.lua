local T = require("testlib")
local clock = require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local deferred = require("deferred")
local Catalog = require("ha.catalog")
local Choices = require("ha.choices")
local Contract = require("ha.contract")
local Native = require("ha.native-catalog")
local Selection = require("ha.selection")
local Operations = require("ha.operations")
local State = require("ha.endpoint-state")

local function row(id, domain, class)
  return codec.object({
    entity_id = id,
    domain = domain,
    name = id,
    available = true,
    attributes = codec.object({ device_class = class }),
  })
end

T.section("Native domain filters use independent standard API projections")
T.truthy("fan index selects only fans", Native.template(nil, 0, "fan"):find("ids = states.fan", 1, true))
T.truthy("garage doors are scoped by class", Native.template(nil, 0, "garage"):find("== 'garage'", 1, true))
T.truthy("blinds exclude garage class", Native.template(nil, 0, "blinds"):find("!= 'garage'", 1, true))
T.falsy("fan page cannot send arbitrary entity IDs", pcall(Native.template, { "lock.side_door" }, 0, "fan"))

local fan = row("fan.lab", "fan")
local registry = ("a"):rep(32)
local reads, bridge = 0, 0
local scope = Catalog.new(function()
  bridge = bridge + 1
end, function()
  reads = reads + 1
  return deferred.new():resolve(codec.array({ fan }))
end, function(rows)
  return deferred.new():resolve(Choices.apply(rows, {
    ["fan.lab"] = codec.object({
      id = registry,
      entity_id = "fan.lab",
      disabled_by = codec.null,
      hidden_by = codec.null,
      entity_category = codec.null,
      platform = "demo",
    }),
  }, true))
end, false, "fan")

local function await(result)
  local value, failure
  result:next(function(resolved)
    value = resolved
  end, function(error)
    failure = error.kind
  end)
  clock.run(100)
  return value, failure
end
local first = assert(await(scope:refresh()))
local page = assert(scope:read(first.revision, nil, "fan"))
T.truthy("fan page type checks", Contract.catalogPage(codec.object(page)))
T.eq("fan scope contains only its family", page.entities[1].families, { "fan" })
T.eq("ambient HA state changes do not start new catalog work", assert(await(scope:refresh())).revision, first.revision)
T.eq("warm path projected only once", reads, 1)
T.eq("new scopes never ask the Bridge", bridge, 0)

local selected = assert(await(Selection.resolve(
  scope,
  function()
    error("unexpected prepare")
  end,
  codec.object({
    family = "fan",
    choice_id = "fan.lab",
    revision = first.revision,
    prepare = true,
  }),
  function()
    return true
  end
)))
T.eq("selection pins the exact registered endpoint", selected.controlled_load.registry_id, registry)
T.falsy("manual sensor cannot select a fan", Selection.directLoad("sensor", "fan.lab"))
registry = ("b"):rep(32)
local nextRevision = assert(await(scope:refresh(true))).revision
T.truthy("a replaced registry identity changes the revision", nextRevision ~= first.revision)
scope:invalidate()
T.falsy("a disconnected scope cannot serve stale selections", scope:hasVerifiedSnapshot(nextRevision))

T.section("A shared HA device keeps distinct cover and climate endpoints")
local shade = row("cover.lab_shade", "cover", "shade")
local thermostat = row("climate.lab_thermostat", "climate")
shade.device_id, thermostat.device_id = ("c"):rep(32), ("c"):rep(32)
local registryEntries = {}
for index, endpoint in ipairs({ shade, thermostat }) do
  registryEntries[endpoint.entity_id] = codec.object({
    id = tostring(index):rep(32),
    entity_id = endpoint.entity_id,
    device_id = endpoint.device_id,
    disabled_by = codec.null,
    hidden_by = codec.null,
    entity_category = codec.null,
    platform = "demo",
  })
end
local shared = assert(Choices.apply(codec.array({ shade, thermostat }), registryEntries, true))
T.eq(
  "a shared physical device retains both independently controlled entities",
  { { shared[1].entity_id, shared[1].families[1] }, { shared[2].entity_id, shared[2].families[1] } },
  { { "cover.lab_shade", "blinds" }, { "climate.lab_thermostat", "climate" } }
)
T.truthy(
  "the explicit primary climate target can be verified",
  Operations.verifyTarget("climate.lab_thermostat", codec.object({ family = "climate" }))
)
T.falsy(
  "a select found elsewhere in HA cannot act as the primary thermostat",
  Operations.verifyTarget("select.ambiguous_mode", codec.object({ family = "climate" }))
)

T.section("Only validated family actions or public feedback cross the wire")
local function action(entity, name, parameters)
  return Operations.build(
    "service",
    entity,
    codec.object({
      action = name,
      parameters = codec.object(parameters),
    })
  )
end
T.falsy("sensor cannot send arbitrary commands", action("sensor.lab", "turn_on", {}))
T.falsy("fan speed rejects a fraction", action("fan.lab", "set_percentage", { percentage = 21.5 }))
T.eq(
  "fan service owns the exact target",
  action("fan.lab", "oscillate", { oscillating = false }).target.entity_id,
  "fan.lab"
)
T.falsy(
  "climate range rejects reversed setpoints",
  action("climate.lab", "set_temperature", { target_temp_low = 25, target_temp_high = 20 })
)
T.falsy(
  "photo URL is not an allowed media command",
  action("media_player.lab", "play_media", { media_content_id = "https://example.test" })
)
local media = State.project(
  codec.object({
    entity_id = "media_player.lab",
    state = "playing",
    attributes = codec.object({
      friendly_name = "Media room",
      entity_picture = "https://example.test?private=example",
      media_title = "Demo track",
      media_artist = "https://example.test?private=example",
      source_list = codec.array({ "Playlist", "https://example.test?private=example" }),
    }),
  }),
  "media_player"
)
T.eq(
  "public titles and source names survive",
  { media.attributes.media_title, media.attributes.source_list[1] },
  { "Demo track", "Playlist" }
)
T.falsy("media feedback omits signed locations", codec.encode(media):find("private=", 1, true))
local question = State.project(
  codec.object({
    entity_id = "media_player.lab",
    state = "playing",
    attributes = codec.object({ media_title = "Where is my track?", media_artist = "cover.png?token=private" }),
  }),
  "media_player"
)
T.eq(
  "ordinary question marks survive and credential query strings stay hidden",
  { question.attributes.media_title, question.attributes.media_artist },
  { "Where is my track?" }
)
T.finish()
