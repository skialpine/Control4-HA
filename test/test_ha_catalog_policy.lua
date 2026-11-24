-- Actual catalog + eligibility pipeline. Only HA RPC responses are faked.
local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
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

T.section("Cutover can independently recheck the exact registry result")
do
  local verification = Catalog.new(request)
  local registry = string.rep("a", 32)
  local observed
  local function verify(expected, unregistered)
    observed = nil
    verification:verifyLoadRegistry("switch.a", expected, unregistered):next(function(match)
      observed = match
    end)
    T.eq("only the exact reviewed entity is requested", requests[#requests].message.entity_ids, { "switch.a" })
  end
  verify(registry)
  answer(#requests, metadata(false))
  T.eq("a matching exact registry ID passes", observed, true)
  verify(registry)
  local replacement = metadata(false)
  replacement["switch.a"].id = string.rep("b", 32)
  answer(#requests, replacement)
  T.eq("the same entity name with a new registry ID is rejected", observed, false)
  verify(nil, true)
  answer(#requests, { ["switch.a"] = codec.null })
  T.eq("an acknowledged unregistered state remains explicit", observed, true)
  verify(nil, true)
  answer(#requests, { ["switch.a"] = { entity_id = "switch.a" } })
  T.eq("missing registry evidence does not count as unregistered", observed, false)
  verify(registry)
  verification:invalidate()
  answer(#requests, metadata(false))
  T.eq("a result from a retired connection is declined", observed, false)
  requests = {}
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
catalog = Catalog.new(request, function()
  local work = deferred.new()
  work:resolve(wire(codec.array({
    {
      entity_id = "switch.a",
      name = "Switch",
      domain = "switch",
      device_id = device,
      attributes = codec.object({}),
    },
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
local helperId, wrapperId = "input_boolean.lamp", "light.relay_wrapper"
local nativeRows = wire(codec.array({
  {
    entity_id = helperId,
    name = "Lamp helper",
    domain = "input_boolean",
    available = true,
    attributes = codec.object(),
  },
  { entity_id = wrapperId, name = "Relay light", domain = "light", attributes = codec.object() },
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
  "an installed Light finds its exact switch behind the companion card",
  catalog:exactLoadChoice("switch.a", "light"),
  enhanced
)
T.eq(
  "an independent native switch-like helper remains selectable by exact load",
  catalog:exactLoadChoice(helperId, "switch").entity_id,
  helperId
)
T.falsy(
  "a different alias does not replace the saved load during migration",
  catalog:exactLoadChoice(wrapperId, "light")
)
local _, _, aliasRegistry, aliasRegistryRead = catalog:loadDetails(wrapperId)
T.falsy("an alias does not borrow the canonical load’s registry evidence", aliasRegistry or aliasRegistryRead)
T.eq(
  "native helper is eligible in both families",
  catalog:choice(helperId, "switch", combinedRevision).domain,
  "input_boolean"
)
local _, _, helperRegistry, helperRegistryRead = catalog:loadDetails(helperId)
T.eq("an exact null registry reply marks a native helper unregistered", { helperRegistry, helperRegistryRead }, {
  [2] = true,
})
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
nativeRows[1].available = false
answer(known + 2, unchangedCombined())
T.eq(
  "explicit refresh queries the exact native registry again",
  requests[known + 3].message.entity_ids,
  { helperId, wrapperId, "switch.a" }
)
answer(known + 3, entries)
T.eq("an unrelated availability change preserves the merged list revision", forced.metadata.revision, combinedRevision)
local refreshedHelper = catalog:choice(helperId, "light", combinedRevision)
local refreshedChoice = catalog:choice(helperPhysical.entity_id, "light", combinedRevision)
T.eq("the refreshed choice still carries the latest availability", {
  refreshedHelper and refreshedHelper.available,
  refreshedChoice and refreshedChoice.entity_id,
}, { false, helperPhysical.entity_id })

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

T.section("A companion transfer revision can change while the Quick Setup draft stays valid")
catalog = Catalog.new(request, function()
  error("unexpected native fallback")
end, function()
  error("verified helper descriptors need no registry requests")
end)
local function oneCompanionPage(values, upstreamRevision)
  local reply = helperPage(1, 1, values, upstreamRevision)
  reply.response.total, reply.response.pages = 1, 1
  return reply
end
local sourceLoad = helperPhysical.attributes.device_choice.source_load
sourceLoad.available = true
local available = open()
answer(#requests, oneCompanionPage({ helperPhysical }, newUpstream))
local companionRevision = available.metadata.revision
local changedTransfer = string.rep("f", 64)
sourceLoad.available = false
local offline = open(true)
answer(#requests, oneCompanionPage({ helperPhysical }, changedTransfer))
T.eq("an availability-only companion update keeps the draft revision", offline.metadata.revision, companionRevision)
local fresh = catalog:choice(choiceId, "light", companionRevision)
T.eq(
  "the old draft revision sees fresh companion availability",
  fresh and fresh.attributes.device_choice.source_load.available,
  false
)
local confirmed = open()
T.eq(
  "subsequent companion reads confirm the new transfer revision",
  requests[#requests].message.service_data.revision,
  changedTransfer
)
answer(#requests, oneCompanionPage(nil, changedTransfer))
T.eq("confirmed transfer preserves the draft revision", confirmed.metadata.revision, companionRevision)
sourceLoad.name = "Renamed load"
local renamed = open(true)
answer(#requests, oneCompanionPage({ helperPhysical }, upstream))
T.truthy(
  "a structural change inside the same source descriptor requires review",
  renamed.metadata.revision ~= companionRevision
)

T.section("Native availability changes preserve an open revision, while renames still invalidate it")
local nativeAvailability = codec.array({
  { entity_id = "switch.a", domain = "switch", name = "Selected", available = true, attributes = codec.object() },
  { entity_id = "switch.b", domain = "switch", name = "Unrelated", available = true, attributes = codec.object() },
})
local nativeRegistry = metadata(false)
nativeRegistry["light.b"], nativeRegistry["switch.b"] = nil, codec.null
catalog = Catalog.new(function(_, callback)
  callback(false, { kind = "not_found" })
end, function()
  local work = deferred.new()
  work:resolve(wire(nativeAvailability))
  return work
end, function(values, active, isNative)
  return Choices.enrich(values, function(_, callback)
    callback(true, wire(nativeRegistry))
  end, active, isNative)
end)
local nativeRevision = open().metadata.revision
local _, _, registered, registryRead = catalog:loadDetails("switch.a")
T.eq("standalone loads retain the registry identity from scoped discovery", { registered, registryRead }, {
  string.rep("a", 32),
  true,
})
T.falsy(
  "standalone registry identity stays out of catalog page JSON",
  codec.encode(catalog:read(nativeRevision, nil, "switch").entities):find(registered, 1, true)
)
nativeAvailability[2].available = false
nativeRegistry["switch.a"].id = string.rep("e", 32)
T.eq(
  "availability and private registry evidence leave the public catalog revision stable",
  open(true).metadata.revision,
  nativeRevision
)
local _, _, refreshedRegistry, refreshedRegistryRead = catalog:loadDetails("switch.a")
T.eq("the same public revision sees fresh private registry evidence", { refreshedRegistry, refreshedRegistryRead }, {
  string.rep("e", 32),
  true,
})
local updated = catalog:read(nativeRevision, nil, "switch")
T.eq("the previous revision sees the fresh availability", updated and updated.entities[2].available, false)
local selected = catalog:choice("switch.a", "switch", nativeRevision)
T.eq("the selected switch remains unchanged", selected and selected.available, true)
nativeAvailability[2].name = "Renamed"
local renamedRevision = open(true).metadata.revision
T.truthy("a real list change still needs a fresh review", renamedRevision ~= nativeRevision)
nativeAvailability[2].attributes.supported_color_modes = codec.array({ "brightness" })
T.truthy("nested capability changes still need a fresh review", open(true).metadata.revision ~= renamedRevision)

T.section("An exact native registry read supplements a projected companion group")
local groupId = "light.test_group"
local group = wire({
  entity_id = groupId,
  name = "Kitchen group",
  domain = "light",
  is_group = true,
  attributes = codec.object(),
})
local groupRegistry = string.rep("9", 32)
for _, supplement in ipairs({ false, true }) do
  catalog = Catalog.new(request, function()
    local result = deferred.new()
    result:resolve(codec.array({ group }))
    return result
  end, function(rows, active, native)
    return Choices.enrich(rows, request, active, native)
  end, supplement)
  local pending = open()
  answer(#requests, oneCompanionPage({ group }, upstream))
  if supplement then
    T.eq("registry lookup requests only the group entity", requests[#requests].message.entity_ids, { groupId })
    answer(#requests, {
      [groupId] = {
        entity_id = groupId,
        id = groupRegistry,
        platform = "group",
        disabled_by = codec.null,
        hidden_by = codec.null,
        entity_category = codec.null,
      },
    })
  end
  T.truthy("the published group remains selectable", pending.metadata)
  local _, _, registry, observed = catalog:loadDetails(groupId)
  T.eq("only the exact registry response authorizes group identity", { registry, observed }, {
    supplement and groupRegistry or nil,
    supplement,
  })
end

T.section("A fresh HA proof keeps the native supplement warm through forced checks")
do
  local reads = 0
  local firstToken, secondToken = string.rep("1", 64), string.rep("2", 64)
  local function prove(token, values)
    local page = oneCompanionPage(values or { group }, upstream)
    page.response.native_revision = token
    if not values then
      page.response.unchanged, page.response.entities = true, nil
    end
    answer(#requests, page)
  end
  catalog = Catalog.new(request, function()
    reads = reads + 1
    return deferred.new():resolve(codec.array({ group }))
  end, function(rows, active, native)
    return Choices.enrich(rows, function(_, callback)
      callback(true, wire({ [groupId] = codec.null }))
    end, active, native)
  end, true)

  local cold = open(true)
  prove(firstToken, { group })
  T.eq("the native snapshot waits for closing evidence", cold.metadata, nil)
  T.eq(
    "closing request names the exact companion revision",
    requests[#requests].message.service_data.revision,
    upstream
  )
  prove(firstToken)
  T.truthy("matching proof publishes combined snapshot", cold.metadata)
  local warm = open(true)
  prove(firstToken)
  T.eq("warm forced refresh reuses native results from one HA reply", { reads, warm.metadata }, { 1, cold.metadata })

  local changed = open(true)
  prove(secondToken)
  T.eq("a native-only registry or projection change triggers a fresh supplement", reads, 2)
  prove(firstToken)
  T.eq("a change during the read cannot publish or bless the cache", changed.failure, "revision_changed")
  T.falsy("the old snapshot no longer authorizes that revision", catalog:hasVerifiedSnapshot())

  local retry = open(true)
  prove(secondToken)
  prove(secondToken)
  T.truthy("a stable retry publishes", retry.metadata)
  catalog:invalidate()
  local reconnect = open()
  prove(secondToken)
  T.eq("even a matching token cannot cross a transport generation", reads, 4)
  prove(secondToken)
  T.truthy("getting new evidence restores access after reconnect", reconnect.metadata)
end

T.section("Only a unique selectable physical choice claims its button event")
catalog = Catalog.new(request, function()
  error("unexpected native fallback")
end)
local gesture = "event.primary_control"
helperPhysical.attributes.device_choice.gesture_entity_id = gesture
local single = open()
answer(#requests, oneCompanionPage({ helperPhysical }, upstream))
T.truthy("single physical control is published", single.metadata)
T.eq("gesture resolves the exact unique physical choice", catalog:gestureChoice(gesture), choiceId)

local alternate = wire(helperPhysical)
local endpoint = string.rep("f", 32)
alternate.entity_id = "device:" .. device .. ":" .. endpoint
alternate.attributes.device_choice.choice_id = alternate.entity_id
alternate.attributes.device_choice.source_load = codec.object({
  domain = "switch",
  entity_id = "switch.independent",
  registry_id = endpoint,
  available = true,
})
local shared = open(true)
local response = oneCompanionPage({ helperPhysical, alternate }, newUpstream)
response.response.total = 2
answer(#requests, response)
T.truthy("both loads can use the same button event", shared.metadata)
T.eq("ambiguous button event is never assigned to either load", catalog:gestureChoice(gesture), nil)

T.section("Hidden active loads are installer fallbacks and a verified visible light takes precedence")
local switchId, plugId, lightId = "switch.relay", "switch.plug", "light.relay"
local nativeRows, savedRegistry = {}, {}
local function addLoad(id, hidden, online, platform)
  local row = { entity_id = id, domain = id:match("^[^.]+"), name = id, available = online, attributes = {} }
  nativeRows[#nativeRows + 1] = row
  local entry = {
    entity_id = id,
    id = string.format("%032x", #nativeRows),
    disabled_by = codec.null,
    hidden_by = hidden or codec.null,
    entity_category = codec.null,
    platform = platform or "test_fixture",
  }
  savedRegistry[id] = entry
  return entry
end
local relay = addLoad(switchId, "integration", true)
local plug = addLoad(plugId, "user", true)
plug.device_id, nativeRows[2].device_id = device, device
nativeRows[2].bridge_gesture_entity_id = "event.plug_control"
local wrapper = addLoad(lightId, nil, true, "switch_as_x")
wrapper.options = { switch_as_x = { entity_id = relay.id, invert = false } }
addLoad("switch.disabled", "user", true).disabled_by = "user"
addLoad("switch.offline", "integration", false)
local exported = addLoad("switch.export", "user", true, "control4")
local exportedWrapper = addLoad("light.export", "user", true, "switch_as_x")
exportedWrapper.options = { switch_as_x = { entity_id = exported.id, invert = false } }
addLoad("switch.diagnostic", "user", true).entity_category = "diagnostic"
local projectedLight = wire(helperPhysical)
projectedLight.entity_id = "device:" .. device .. ":" .. wrapper.id
projectedLight.domain = "light"
projectedLight.attributes.device_choice.choice_id = projectedLight.entity_id
projectedLight.attributes.device_choice.source_load =
  { entity_id = lightId, registry_id = wrapper.id, domain = "light" }
local projectedButtons = wire(helperPhysical)
projectedButtons.entity_id = "device:" .. device .. ":none"
projectedButtons.domain = "event"
local buttonDescriptor = projectedButtons.attributes.device_choice
buttonDescriptor.choice_id, buttonDescriptor.kind, buttonDescriptor.source_load =
  projectedButtons.entity_id, "remote", nil
buttonDescriptor.gesture_entity_id = "event.plug_control"
for _, companion in ipairs({ false, true }) do
  local function reply(message, callback)
    if message.type == "call_service" then
      if companion then
        local response = oneCompanionPage({ projectedLight, projectedButtons }, upstream)
        response.response.total = 2
        callback(true, wire(response))
      else
        callback(false, { kind = "not_found" })
      end
    else
      callback(true, wire(savedRegistry))
    end
  end
  catalog = Catalog.new(reply, function()
    local result = deferred.new()
    -- Convert empty attributes to a wire object, as native discovery does.
    for _, row in ipairs(nativeRows) do
      row.attributes = codec.object()
    end
    result:resolve(wire(codec.array(nativeRows)))
    return result
  end, function(rows, active, native)
    return Choices.enrich(rows, reply, active, native)
  end, true)
  local revision = open(true).metadata.revision
  local list = catalog:read(revision, nil, "light")
  T.eq(
    "installer shows the visible light, the only usable plug, and any separate button choice",
    list.total,
    companion and 3 or 2
  )
  local plugChoice = catalog:choice(plugId, "light", revision)
  T.truthy("the standalone plug is selectable", plugChoice)
  T.eq(
    "the native plug is recognized for the exact saved button source",
    catalog:gestureChoice("event.plug_control", plugChoice),
    plugId
  )
  if companion then
    local buttons = catalog:choice(projectedButtons.entity_id, "light", revision)
    T.eq(
      "the companion's button-only entry does not compete with its sole native load",
      { catalog:gestureChoice("event.plug_control", buttons), catalog:gestureChoice("event.plug_control") },
      { projectedButtons.entity_id, plugId }
    )
  end
  T.falsy("the underlying switch is represented by its light", catalog:choice(switchId, "light", revision))
  local target, entity, id = catalog:exactLoadChoice(switchId, "light")
  T.eq(
    "legacy Light preview uses the proven wrapper",
    { target.entity_id, entity, id },
    { lightId, lightId, wrapper.id }
  )
  T.eq(
    "legacy Switch can use the compatible binary light too",
    catalog:exactLoadChoice(switchId, "switch").entity_id,
    lightId
  )
  T.eq("legacy hidden plug remains eligible", catalog:exactLoadChoice(plugId, "light").entity_id, plugId)
  T.falsy("a hidden wrapper cannot bypass export exclusion", catalog:exactLoadChoice("light.export", "light"))
  local _, _, registry, known = catalog:loadDetails(plugId, true)
  T.eq("hidden fallback carries verified registry evidence", { registry, known }, { plug.id, true })
  local aliases = catalog:endpointKeys({ lightId })
  T.eq("ownership includes both endpoints", { aliases[lightId], aliases[switchId] }, { true, true })
  local function verify()
    local result
    catalog:verifyLoadRegistry(lightId, wrapper.id, false, switchId, relay.id):next(function(value)
      result = value
    end)
    return result
  end
  T.eq("fresh verification proves both IDs and their link", verify(), true)
  wrapper.options.switch_as_x.invert = true
  T.eq("an inverted or edited wrapper cannot replace the saved switch", verify(), false)
  wrapper.options.switch_as_x.invert = false
  wrapper.hidden_by = "user"
  T.eq("a wrapper hidden after review invalidates the approved plan", verify(), false)
  wrapper.hidden_by = codec.null
end
T.section("The native size limit counts eligible choices")
local candidates = codec.array({})
for index = 1, 5001 do
  local id = ("switch.candidate_%05d"):format(index)
  candidates[index] = codec.object({
    entity_id = id,
    domain = "switch",
    name = id,
    attributes = codec.object({}),
    c4_exported = index == 5001,
  })
end
catalog = Catalog.new(function(_, callback)
  callback(false, { kind = "not_found" })
end, function()
  local result = deferred.new()
  result:resolve(candidates)
  return result
end, function(rows, _, native)
  local registry = {}
  for _, row in ipairs(rows) do
    registry[row.entity_id] = codec.null
  end
  local result = deferred.new()
  result:resolve(Choices.apply(rows, registry, native))
  return result
end)
T.eq("5,000 choices plus an excluded mirror still publish", (open().metadata or {}).total, 5000)
candidates[5001].c4_exported = false
T.eq("5,001 eligible choices are rejected", open(true).failure, "invalid_endpoint_metadata")

T.finish()
