-- Actual catalog + eligibility pipeline. Only HA RPC responses are faked.
local T = require("testlib")
local codec = require("ha.codec")
local Catalog = require("ha.catalog")
local Choices = require("ha.choices")
local function wire(value)
  return codec.decode(codec.encode(value))
end
local requests = {}
local function request(message, callback)
  requests[#requests + 1] = { message = message, callback = callback }
end
local catalog = Catalog.new(request, function()
  error("unexpected native fallback")
end, function(rows, active)
  return Choices.enrich(rows, request, active)
end)
local function open(force)
  local result = {}
  catalog:refresh(force):next(function(value)
    result.metadata = value
  end, function(error)
    result.failure = error.kind
  end)
  return result
end
local function answer(index, value)
  requests[index].callback(true, wire(value))
end
local function metadata(hidden)
  return {
    ["switch.a"] = {
      entity_id = "switch.a",
      id = string.rep("a", 32),
      platform = "lab",
      disabled_by = codec.null,
      hidden_by = hidden and "user" or codec.null,
      entity_category = codec.null,
    },
    ["light.b"] = {
      entity_id = "light.b",
      id = string.rep("b", 32),
      platform = "lab",
      disabled_by = codec.null,
      hidden_by = codec.null,
      entity_category = codec.null,
    },
  }
end
local upstream = string.rep("c", 64)
local function confirmation()
  return { response = { version = 1, revision = upstream, page = 1, pages = 1, total = 2, unchanged = true } }
end
T.section("registry eligibility is revision checked even when companion descriptors are unchanged")
local first = open()
answer(1, {
  response = {
    version = 1,
    revision = upstream,
    page = 1,
    pages = 1,
    total = 2,
    unchanged = false,
    entities = codec.array({
      {
        entity_id = "switch.a",
        domain = "switch",
        name = "A",
        device_id = string.rep("d", 32),
        attributes = codec.object({}),
      },
      {
        entity_id = "light.b",
        domain = "light",
        name = "B",
        device_id = string.rep("d", 32),
        attributes = { supported_color_modes = codec.array({ "brightness" }) },
      },
    }),
  },
})
T.eq("no snapshot before scoped metadata completes", catalog.snapshot, nil)
T.eq("native metadata scope is exact", requests[2].message.type, "config/entity_registry/get_entries")
answer(2, metadata(false))
T.eq("two independent Light choices", catalog:read(first.metadata.revision, nil, "light").total, 2)
T.eq("Switch choice omits dimmer", catalog:read(first.metadata.revision, nil, "switch").total, 1)
local revision = first.metadata.revision
T.truthy("public revision includes eligibility, separate from upstream", revision ~= upstream)
local snapshot = catalog.snapshot
local unchanged = open()
T.eq("known upstream revision used for confirmation", requests[3].message.service_data.revision, upstream)
answer(3, confirmation())
answer(4, metadata(false))
T.eq("unchanged projected metadata retains shared snapshot", catalog.snapshot, snapshot)
T.eq("unchanged revision stable", unchanged.metadata.revision, revision)
local changed = open()
answer(5, confirmation())
answer(6, metadata(true))
T.truthy("registry-only eligibility change updates public revision", changed.metadata.revision ~= revision)
T.eq("new Switch page excludes hidden endpoint", catalog:read(changed.metadata.revision, nil, "switch").total, 0)
local old, failure = catalog:read(revision, 2, "light")
T.eq("old cursor rejected", old, nil)
T.eq("old cursor identifies changed revision", failure, "revision_changed")
T.eq("raw descriptor is retained for a later unhide", #catalog.snapshot.rows, 2)
local restored = open()
answer(7, confirmation())
answer(8, metadata(false))
T.eq("restored eligibility reuses original content revision", restored.metadata.revision, revision)
T.eq("unhidden endpoint returns without redownloading descriptors", catalog:read(revision, nil, "switch").total, 1)
T.eq("only scoped verification and metadata reads occurred", #requests, 8)

T.section("versioned helper transfers verify metadata once and reuse a confirmed snapshot")
local helperGroup = {
  entity_id = "light.test_group",
  domain = "light",
  name = "Group",
  is_group = true,
  attributes = { supported_color_modes = codec.array({ "brightness" }) },
}
local device, registry = string.rep("d", 32), string.rep("e", 32)
local choiceId = "device:" .. device .. ":" .. registry
local helperPhysical = {
  entity_id = choiceId,
  domain = "switch",
  name = "Switch",
  attributes = {
    device_choice = {
      type = "device_choice",
      version = 1,
      choice_id = choiceId,
      device_id = device,
      kind = "switch",
      source_load = { domain = "switch", entity_id = "switch.a", registry_id = registry },
    },
  },
}
local newUpstream = string.rep("e", 64)
local function helperPage(index, eligibility, values, rev)
  return {
    response = {
      version = 1,
      eligibility_version = eligibility,
      revision = rev or newUpstream,
      page = index,
      pages = 2,
      total = 2,
      unchanged = not values,
      entities = values and codec.array(values),
    },
  }
end
local mixed = open()
answer(9, helperPage(1, 1, { helperGroup }))
T.eq("next page requests the same upstream revision", requests[10].message.service_data.revision, newUpstream)
answer(10, helperPage(2, nil, { helperPhysical }))
T.eq("mixed eligibility guarantees reject the transfer", mixed.failure, "invalid_catalog")
T.eq("failed transfer kept prior dataset", catalog.snapshot.revision, revision)
T.eq("partially replaced metadata cannot authorize a previous selection", catalog.verified, nil)
local staleChoice, staleReason = catalog:choice("switch.a", "switch", revision)
T.eq("old descriptor is retired for setup", staleChoice, nil)
T.eq("old chooser can ask for a new list", staleReason, "catalog_unverified")
local projected = open()
answer(11, helperPage(1, 1, { helperGroup }))
answer(12, helperPage(2, 1, { helperPhysical }))
local projectedRevision = projected.metadata.revision
T.eq("supported helper needs only its two pages", #requests, 12)
T.eq("Light includes both helper endpoints", catalog:read(projectedRevision, nil, "light").total, 2)
T.eq("Switch excludes the dimmable group", catalog:read(projectedRevision, nil, "switch").total, 1)
local projectedSnapshot = catalog.snapshot
catalog:invalidate()
local reverified = open()
answer(13, helperPage(1, 1))
T.eq("reconnect needs only one helper confirmation", #requests, 13)
T.eq("confirmed helper revision returns the same dataset", reverified.metadata.revision, projectedRevision)
T.eq("confirmed helper revision retains the pool and indices", catalog.snapshot, projectedSnapshot)
local malformed = open()
answer(14, helperPage(1, 1, { helperGroup }, upstream))
helperPhysical.attributes.device_choice.source_load.registry_id = string.rep("f", 32)
answer(15, helperPage(2, 1, { helperPhysical }, upstream))
T.eq("helper source must match its descriptor identity", malformed.failure, "invalid_endpoint_metadata")
helperPhysical.attributes.device_choice.source_load.registry_id = registry
local downgraded = open()
answer(16, helperPage(1, 2))
T.eq("changed guarantee requests full descriptors", requests[17].message.service_data.revision, nil)
answer(17, helperPage(1, 2, { helperGroup }))
answer(18, helperPage(2, 2, { helperPhysical }))
T.eq(
  "unknown eligibility guarantee keeps exact registry checks",
  requests[19].message.type,
  "config/entity_registry/get_entries"
)
local registryEntries = metadata(false)
registryEntries["light.test_group"] = registryEntries["light.b"]
registryEntries["light.test_group"].entity_id = "light.test_group"
registryEntries["light.b"] = nil
registryEntries["switch.a"].id = registry
registryEntries["switch.a"].hidden_by = "user"
answer(19, registryEntries)
T.eq(
  "unknown eligibility guarantee cannot bypass hidden flag",
  catalog:read(downgraded.metadata.revision, nil, "switch").total,
  0
)

T.section("absent helper still uses scoped native data and exact registry entries")
local deferred = require("deferred")
catalog = Catalog.new(request, function()
  local work = deferred.new()
  work:resolve(wire(codec.array({
    { entity_id = "switch.a", name = "Switch", domain = "switch", device_id = device, attributes = codec.object({}) },
    { entity_id = "light.b", name = "Light", domain = "light", device_id = device, attributes = codec.object({}) },
  })))
  return work
end, function(rows, active)
  return Choices.enrich(rows, request, active)
end)
local native = open()
requests[20].callback(false, { kind = "not_found" })
T.eq(
  "native fallback still queries exact registry entries",
  requests[21].message.type,
  "config/entity_registry/get_entries"
)
answer(21, metadata(true))
T.eq("native fallback excludes the hidden endpoint", catalog:read(native.metadata.revision, nil, "light").total, 1)
T.eq("native discovery remains identified in metadata", native.metadata.source, "native")

T.section("companion choices join native helpers and proven aliases in the same list")
local helperId, wrapperId = "input_boolean.lamp", "light.decorative"
local nativeRows = wire(codec.array({
  { entity_id = helperId, name = "Lamp helper", domain = "input_boolean", attributes = codec.object() },
  { entity_id = wrapperId, name = "Decorative lights", domain = "light", attributes = codec.object() },
  { entity_id = "switch.a", name = "Raw relay", domain = "switch", attributes = codec.object() },
}))
catalog = Catalog.new(request, function()
  local work = deferred.new()
  work:resolve(nativeRows)
  return work
end, function(rows, active, isNative)
  return Choices.enrich(rows, request, active, isNative)
end, true)
local combined = open()
local nextMessage = #requests
local physical = helperPage(1, 1, { helperPhysical })
physical.response.total, physical.response.pages = 1, 1
answer(nextMessage, physical)
T.eq(
  "supplement inspects only native load IDs",
  requests[#requests].message.entity_ids,
  { helperId, wrapperId, "switch.a" }
)
local entries = metadata(false)
entries[helperId] = codec.null
entries[wrapperId] = wire({
  entity_id = wrapperId,
  id = string.rep("f", 32),
  platform = "switch_as_x",
  disabled_by = codec.null,
  hidden_by = codec.null,
  entity_category = codec.null,
  options = { switch_as_x = { entity_id = "switch.a", invert = false } },
})
entries["light.b"] = nil
answer(#requests, entries)
local combinedRevision = combined.metadata.revision
local list = catalog:read(combinedRevision, nil, "light")
T.eq("only the most capable physical row and the independent native helper remain", list.total, 2)
local enhanced = catalog:choice(helperPhysical.entity_id, "light", combinedRevision)
T.eq("wrapper entity ID follows the richer row", enhanced.entity_aliases, { wrapperId })
T.eq(
  "native helper is eligible in both families",
  catalog:choice(helperId, "switch", combinedRevision).domain,
  "input_boolean"
)
T.eq(
  "unknown IDs are not eligible",
  { catalog:choice("light.badid", "light", combinedRevision) },
  { [2] = "unsupported_endpoint" }
)
local known = #requests
local same = open()
local function unchangedCombined()
  local response = helperPage(1, 1)
  response.response.total, response.response.pages = 1, 1
  return response
end
answer(known + 1, unchangedCombined())
T.eq("an unchanged companion only confirms the revision", #requests, known + 1)
T.eq("warm open reuses the complete merged list", same.metadata.revision, combinedRevision)
local forced = open(true)
answer(known + 2, unchangedCombined())
T.eq(
  "explicit refresh queries the exact native registry again",
  requests[known + 3].message.entity_ids,
  { helperId, wrapperId, "switch.a" }
)
answer(known + 3, entries)
T.eq("unchanged refreshed catalog keeps its revision", forced.metadata.revision, combinedRevision)

local wrapped = wire(helperPhysical)
wrapped.entity_id = "device:" .. device .. ":" .. entries[wrapperId].id
wrapped.domain = "light"
wrapped.attributes.device_choice.choice_id = wrapped.entity_id
wrapped.attributes.device_choice.source_load =
  { entity_id = wrapperId, registry_id = entries[wrapperId].id, domain = "light" }
local owner = open()
local response = helperPage(1, 1, { wrapped }, string.rep("e", 64))
response.response.total, response.response.pages = 1, 1
answer(#requests, response)
answer(#requests, entries)
local opts = catalog:read(owner.metadata.revision, 1, "light")
T.eq("when the companion picks the wrapper the native raw relay is still deduplicated", opts.total, 2)
local winner = catalog:choice(wrapped.entity_id, "light", owner.metadata.revision)
T.eq("source relay ID finds the companion wrapper", winner.entity_aliases, { "switch.a" })
T.finish()
