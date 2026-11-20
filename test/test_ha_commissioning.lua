-- Uses the actual deployment library and the template's Director simulator.
local T = require("testlib")
local fixtures = require("c4_fixtures")
local clock = fixtures.virtualClock()
local Commissioning = require("ha.commissioning")
local codec = require("ha.codec")
local ids = require("ha.identities")
local deferred = require("deferred")
local persist = require("lib.persist")
local nav = fixtures.captureTcpClient()

local firstRevision, secondRevision = string.rep("a", 64), string.rep("b", 64)
local lightFile, interimFile, switchFile = "HA.Light.c4z", "Control4.HA.Light.c4z", "Control4.HA.Switch.c4z"
local model = { [lightFile] = "HA Light", [interimFile] = "Control4.HA.Light", [switchFile] = "Control4.HA.Switch" }
local me = C4:GetDeviceID()
local class = ids.coordinatorClass
local selected, addCount, configuration, failConfiguration, changeRevision, refuseBind
local legacy, suiteVariableType
local revision, rows = firstRevision, {}
local catalog = {}
function catalog:refresh(force)
  assert(force, "Quick Setup must recheck native eligibility before adding or binding devices")
  local work = deferred.new()
  work:resolve({ revision = revision })
  return work
end
function catalog:choice(id, family)
  local row = rows[id]
  return row and row.family == family and row or nil
end
local function endpoint(id, family, name)
  rows[id] = {
    entity_id = id,
    name = name,
    domain = family,
    family = family,
    families = { family },
    attributes = codec.object({}),
    entity_aliases = {},
  }
end
local function configure(id, query)
  configuration[#configuration + 1] = { id = id, query = query }
  local work = deferred.new()
  if failConfiguration then
    work:reject({ kind = "timeout" })
  else
    selected[id] = query.choice_id
    if changeRevision then
      revision = secondRevision
    end
    work:resolve({})
  end
  return work
end

local originalProvider = C4.GetBoundProviderDevice
local originalBindings, originalAdd, originalBind = C4.GetBindingsByDevice, C4.AddDevice, C4.Bind
local function consumerInput(id)
  local row = C4:GetDevices({ DeviceIds = tostring(id) })[id]
  return row and row.driverFileName == lightFile and ids.lightCoordinatorBinding or ids.coordinatorBinding
end
function C4:GetDeviceData(id, tag)
  if legacy[id] then
    return legacy[id][tag]
  end
  local project = self:GetDevices({ DeviceIds = tostring(id) })[id]
  if tag == "model" and project then
    return model[project.driverFileName]
  end
end
function C4:GetDeviceVariables(id)
  if legacy[id] then
    assert(not legacy[id].variableReadFails)
    return legacy[id].variables
  end
  return { ["1001"] = { name = "Selected Endpoint", value = selected[id] or "", type = suiteVariableType } }
end
function C4:GetBoundProviderDevice(id, binding)
  if legacy[id] and binding == 999 then
    return legacy[id].provider or 0
  end
  return originalProvider(self, id, binding)
end
function C4:GetBindingsByDevice(id)
  if id == me then
    return originalBindings(self, id)
  end
  if legacy[id] then
    local provider = self:GetBoundProviderDevice(id, 999)
    local binding = {
      bindingid = 999,
      provider = false,
      bindingclasses = { { class = "HA_DEVICE" } },
      isbound = provider ~= 0,
      boundprovider = provider ~= 0 and { bound = { deviceid = provider, bindingid = 1 } } or nil,
    }
    return { bindings = legacy[id].missingBinding and {} or { binding } }
  end
  local input = consumerInput(id)
  local provider = self:GetBoundProviderDevice(id, input)
  local binding = { bindingid = input, provider = false, bindingclasses = { { class = class } } }
  if provider ~= 0 then
    binding.boundprovider = { bound = { deviceid = provider, bindingid = 1, boundclasses = { class } } }
    binding.isbound = true
  end
  return { bindings = { binding } }
end
function C4:AddDevice(...)
  addCount = addCount + 1
  return originalAdd(self, ...)
end
function C4:Bind(...)
  if not refuseBind then
    return originalBind(self, ...)
  end
end

local function setProjectDevices(devices, withoutLight)
  if not withoutLight then
    devices[19] = { deviceName = "Existing Suite Light", driverFileName = lightFile, roomId = 11 }
  end
  ShimSetDevices(devices)
end

local function start(existing, withoutLight)
  ShimResetDynamicBindings()
  ShimSetStaticBindings({ { id = 1, name = "Coordinator", provider = true, class = class, type = "CONTROL" } })
  local devices = {
    [10] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
    [11] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  }
  for id, value in pairs(existing or {}) do
    devices[id] = value
  end
  setProjectDevices(devices, withoutLight)
  ShimSetDriverFiles({ lightFile, switchFile })
  legacy, suiteVariableType = {}, "1"
  ShimSetUIRequest(function(id, command)
    local entity = legacy[id] and legacy[id].entity
    if entity and command == "GET_PROPERTIES" then
      return "<properties><property><name>Driver Version</name><value>"
        .. legacy[id].version
        .. "</value></property><property><name>Entity ID</name><value>"
        .. entity
        .. "</value></property></properties>"
    end
    return ""
  end)
  persist:delete("HA.Commissioning")
  selected, addCount, configuration = {}, 0, {}
  failConfiguration, changeRevision, refuseBind = false, false, false
  revision, rows = firstRevision, {}
  endpoint("light.a", "light", "Pendant")
  endpoint("switch.b", "switch", "Fan")
  return Commissioning.new(catalog, configure)
end

local function await(work)
  local result = {}
  work:next(function(value)
    result.value = value
  end, function(err)
    result.error = err.kind
  end)
  return result
end
local function request(...)
  return { revision = revision, choices = { ... } }
end
local A = { choice_id = "light.a", family = "light", room_id = 10 }
local B = { choice_id = "switch.b", family = "switch", room_id = 11 }

T.section("Only an explicit preview confirmation can add selected endpoints on the shared binding")
local commissioning = start()
local preview = await(commissioning:preview(request(A, B))).value
T.eq("preview leaves Director unchanged", addCount, 0)
T.eq("preview leaves no durable receipt", persist:get("HA.Commissioning", nil, true), nil)
T.eq("room from project", preview.items[1].room_name, "Kitchen")
T.eq("default name from eligible choice", preview.items[1].name, "Pendant")
T.eq("summary identifies the Home Assistant source", preview.items[1].source_name, "Pendant")
T.eq("new endpoint previews an add", preview.items[2].decision, "add")
T.eq("stray confirmation ID cannot add", await(commissioning:execute("other")).error, "preview_required")
local operation = await(commissioning:execute(preview.id))
T.eq("adds serialize", addCount, 1)
T.eq(
  "receipt precedes native reply",
  codec.decode(persist:get("HA.Commissioning", nil, true))["light.a"].phase,
  "pending"
)
T.eq("other previews cannot overlap commit", await(commissioning:preview(request(A))).error, "busy")
changeRevision = true
ShimAnswerAdds()
T.eq("first add has no error", operation.value and operation.value.items[1].reason, nil)
T.eq("new device selected before next add", #configuration, 1)
clock.run(5000)
T.eq("shared provider permits second add", addCount, 2)
ShimAnswerAdds()
clock.run(5000)
T.eq("batch completed", operation.value.complete, true)
T.eq(
  "separate room/family targets both added",
  { operation.value.items[1].status, operation.value.items[2].status },
  { "added", "added" }
)
T.eq("second commit uses refreshed revision after preparation", configuration[2].query.revision, secondRevision)
T.eq("both consumers use original provider", {
  C4:GetBoundProviderDevice(configuration[1].id, ids.lightCoordinatorBinding),
  C4:GetBoundProviderDevice(configuration[2].id, 1),
}, { me, me })
T.eq("new links refresh Navigator", #nav.writes, 2)
T.eq(
  "new light uses the canonical package",
  C4:GetDevices({ DeviceIds = tostring(configuration[1].id) })[configuration[1].id].driverFileName,
  lightFile
)
T.eq("replay requires a new preview", await(commissioning:execute(preview.id)).error, "preview_required")
require("c4_fixtures").coldStoredObject("HA.Commissioning")
commissioning = Commissioning.new(catalog, configure)
preview = await(commissioning:preview(request(A, B))).value
T.eq(
  "reload discovers exact completed instances",
  { preview.items[1].decision, preview.items[2].decision },
  { "keep", "keep" }
)
operation = await(commissioning:execute(preview.id))
T.eq("rerun adds nothing", addCount, 2)
T.eq("completed matches remain untouched", operation.value.items[2].status, "kept")

local aliased = {
  entity_id = "light.wrapper",
  attributes = codec.object({}),
  entity_aliases = { A.choice_id },
}
local inventoryPage =
  { cursor = 1, revision = secondRevision, entities = { rows[A.choice_id], rows[B.choice_id], aliased } }
T.eq("browse identifies existing drivers and catalog aliases without changing the project", {
  commissioning:existingChoices(inventoryPage),
  addCount,
}, { { [A.choice_id] = true, [B.choice_id] = true, [aliased.entity_id] = true }, 2 })

ShimSetDeviceHidden(configuration[2].id, true)
preview = await(commissioning:preview(request(B))).value
T.eq("a completed driver still bound to the Coordinator cannot be recreated", preview.items[1].decision, "review")
T.eq(
  "confirming a hidden existing driver adds nothing",
  await(commissioning:execute(preview.id)).error,
  "review_required"
)
ShimSetDeviceHidden(configuration[2].id, false)
local completedSwitch = configuration[2].id
C4:Unbind(completedSwitch, ids.coordinatorBinding)
C4:Bind(867, ids.coordinatorBinding, completedSwitch, ids.coordinatorBinding, class)
ShimSetDeviceHidden(completedSwitch, true)
preview = await(commissioning:preview(request(B))).value
T.eq("a driver hidden from inventory remains reserved even on another Coordinator", preview.items[1].decision, "review")
ShimSetDeviceHidden(completedSwitch, false)
local existing = C4:GetDevices()
C4:Unbind(configuration[2].id, ids.coordinatorBinding)
existing[configuration[2].id] = nil
existing[10] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" }
existing[11] = { deviceName = "Office", driverFileName = "roomdevice.c4i" }
setProjectDevices(existing)
T.eq("a fresh browse shows the device whose driver was deleted", commissioning:existingChoices(inventoryPage), {
  [A.choice_id] = true,
  [aliased.entity_id] = true,
})
preview = await(commissioning:preview(request(B))).value
T.eq("deleted completed Switch may be explicitly recreated", preview.items[1].decision, "add")
T.eq("preview alone does not recreate a deleted Switch", addCount, 2)
operation = await(commissioning:execute(preview.id))
ShimAnswerAdds()
clock.run(5000)
T.eq("a new confirmation recreates the deleted Switch", operation.value.complete, true)

T.section("Fresh and retained Light connections respect the Coordinator Director already chose")
do
  local other = 867
  -- Simulate Director's HA_DEVICE autobind immediately before the native AddDevice callback.
  for _, owner in ipairs({ me, other }) do
    commissioning = start()
    preview = await(commissioning:preview(request(A))).value
    local add = C4.AddDevice
    local added
    function C4:AddDevice(file, room, name, callback)
      return add(self, file, room, name, function(id, info)
        added = id
        C4:Bind(owner, 1, id, ids.lightCoordinatorBinding, class)
        callback(id, info)
      end)
    end
    operation = await(commissioning:execute(preview.id))
    C4.AddDevice = add
    ShimAnswerAdds()
    clock.run(5000)
    T.eq(
      "fresh Light keeps the actual native provider",
      C4:GetBoundProviderDevice(added, ids.lightCoordinatorBinding),
      owner
    )
    T.eq("only the approving Coordinator configures its fresh Light", #configuration, owner == me and 1 or 0)
    selected[added] = A.choice_id
    preview = await(commissioning:preview(request(A))).value
    T.eq(
      "a selected Light owned here is kept and a foreign selection requires review",
      preview.items[1].decision,
      owner == me and "keep" or "review"
    )
    T.eq(
      "a second preview neither steals nor duplicates a retained Light",
      { C4:GetBoundProviderDevice(added, ids.lightCoordinatorBinding), addCount },
      { owner, 1 }
    )
  end
end

T.section("Unknown adds cannot be repeated and late callbacks only save receipts")
commissioning = start()
local stagedChoice = { choice_id = A.choice_id, family = A.family, room_id = 11, name = "Hall Pendant" }
preview = await(commissioning:preview(request(stagedChoice))).value
operation = await(commissioning:execute(preview.id))
clock.run(30000)
T.eq("no Director callback is unresolved", operation.value.items[1].reason, "add_unconfirmed")
commissioning:destroy()
commissioning = Commissioning.new(catalog, configure)
preview = await(commissioning:preview(request(stagedChoice))).value
T.eq("a fresh instance refuses an unidentified add", preview.items[1].decision, "review")
T.eq("review plan cannot repeat AddDevice", await(commissioning:execute(preview.id)).error, "review_required")
ShimAnswerAdds()
T.eq("late callback does not configure a device", #configuration, 0)
T.eq("late callback leaves shared binding untouched", next(C4:GetBoundConsumerDevices(me, 1) or {}), nil)
local completed, staged = commissioning:existingChoices({
  cursor = 1,
  revision = revision,
  entities = { rows[A.choice_id] },
})
T.eq("a staged driver stays visible in the default list", completed, {})
T.eq("a reopened picker recovers the exact staged fields", staged[A.choice_id], {
  name = stagedChoice.name,
  room_id = stagedChoice.room_id,
  family = stagedChoice.family,
})
preview = await(commissioning:preview(request({
  choice_id = A.choice_id,
  name = staged[A.choice_id].name,
  room_id = staged[A.choice_id].room_id,
  family = staged[A.choice_id].family,
}))).value
T.eq("late native receipt is reusable", preview.items[1].decision, "resume")
operation = await(commissioning:execute(preview.id))
T.eq("resumes exact prior add", operation.value.items[1].status, "resumed")
T.eq("late completion only added one driver", addCount, 1)

T.section("Ambiguous SDK receipts are never treated as a definite rejection")
commissioning = start()
preview = await(commissioning:preview(request(stagedChoice))).value
local realAdd = C4.AddDevice
C4.AddDevice = function(_, _, _, _, callback)
  addCount = addCount + 1
  callback(nil)
end
operation = await(commissioning:execute(preview.id))
C4.AddDevice = realAdd
T.eq("invalid add reply needs review", operation.value.items[1].reason, "add_unconfirmed")
T.eq(
  "unknown outcome stays durable",
  codec.decode(persist:get("HA.Commissioning", nil, true))["light.a"].phase,
  "pending"
)
setProjectDevices({
  [11] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  [20] = { deviceName = "Hall Pendant", driverFileName = "Control4.HA.Light.c4z", roomId = 11 },
})
fixtures.coldStoredObject("HA.Commissioning")
commissioning = Commissioning.new(catalog, configure)
completed, staged = commissioning:existingChoices({ cursor = 1, revision = revision, entities = { rows[A.choice_id] } })
T.eq("lost callbacks still show the unfinished row", completed, {})
T.eq("a unique candidate restores its saved details after reopening", staged[A.choice_id], {
  name = stagedChoice.name,
  room_id = stagedChoice.room_id,
  family = stagedChoice.family,
})
preview = await(commissioning:preview(request(stagedChoice))).value
T.eq("preview discloses exact recovery candidate", {
  preview.items[1].decision,
  preview.items[1].device_id,
  preview.items[1].reason,
}, { "resume", 20, "recovered_candidate" })
T.eq("discovery leaves the candidate unconfigured", #configuration, 0)
operation = await(commissioning:execute(preview.id))
T.eq("explicitly approved recovery binds and configures that candidate", operation.value.items[1].device_id, 20)
T.eq("matched interim Light resumes on its original suite input", {
  C4:GetBoundProviderDevice(20, 1),
  C4:GetBoundProviderDevice(20, 999),
}, { me, 0 })
T.eq("unconfirmed initial add is never repeated", addCount, 1)

T.section("Interrupted bind/configure resumes only the reviewed root")
commissioning = start()
preview = await(commissioning:preview(request(A, B))).value
operation = await(commissioning:execute(preview.id))
refuseBind = true
ShimAnswerAdds()
T.eq("failed bind gets exact read-back error", operation.value.items[1].reason, "bind_unconfirmed")
T.eq("failure stops subsequent adds", operation.value.items[2].status, "not_started")
T.eq("failed bind never authorizes configure", #configuration, 0)
commissioning = Commissioning.new(catalog, configure)
preview = await(commissioning:preview(request(A))).value
T.eq("unbound exact add can resume", preview.items[1].decision, "resume")
refuseBind, failConfiguration = false, true
operation = await(commissioning:execute(preview.id))
T.eq("configuration response failure is surfaced", operation.value.items[1].reason, "timeout")
T.eq("failure adds no extra instance", addCount, 1)
commissioning = Commissioning.new(catalog, configure)
preview = await(commissioning:preview(request(A))).value
T.eq("bound exact add can resume", preview.items[1].decision, "resume")
failConfiguration = false
T.eq("resume waits for exact configuration receipt", await(commissioning:execute(preview.id)).value.complete, true)
T.eq("interruption still only added one driver", addCount, 1)

T.section("Lost final acknowledgment keeps an already configured driver in the default setup list")
commissioning = start()
preview = await(commissioning:preview(request(stagedChoice))).value
failConfiguration = true
operation = await(commissioning:execute(preview.id))
ShimAnswerAdds()
local receipt = codec.decode(persist:get("HA.Commissioning", nil, true))["light.a"]
T.eq("the timed-out configure keeps an incomplete receipt", { operation.value.items[1].reason, receipt.phase }, {
  "timeout",
  "added",
})
selected[receipt.device_id] = stagedChoice.choice_id
fixtures.coldStoredObject("HA.Commissioning")
commissioning = Commissioning.new(catalog, configure)
local stagePage = { cursor = 1, revision = revision, entities = { rows[A.choice_id] } }
completed, staged = commissioning:existingChoices(stagePage)
T.eq("the exact incomplete driver stays visible in the default list", completed, {})
T.eq("the saved room, name and type are supplied", staged[A.choice_id], {
  name = stagedChoice.name,
  room_id = stagedChoice.room_id,
  family = stagedChoice.family,
})
selected[19] = "switch.b"
rows[A.choice_id].entity_aliases = { "switch.b" }
completed, staged = commissioning:existingChoices(stagePage)
T.eq("another driver matching an alias prevents a resume hint", { completed[A.choice_id], next(staged) }, { true })
rows[A.choice_id].entity_aliases, selected[19] = {}, nil
preview = await(commissioning:preview(request(stagedChoice))).value
T.eq("explicit review resumes the existing driver", { preview.items[1].decision, preview.items[1].device_id }, {
  "resume",
  receipt.device_id,
})
operation = await(commissioning:execute(preview.id))
clock.run(5000)
T.eq("finishing setup neither adds nor reconfigures a driver", { operation.value.complete, addCount, #configuration }, {
  true,
  1,
  1,
})
completed, staged = commissioning:existingChoices(stagePage)
T.eq("finished setup returns to the existing-device filter", { completed[A.choice_id], next(staged) }, { true })

T.section("Preview rejects changed project, HA eligibility, duplicate intent and unrelated exact labels")
commissioning = start()
rows["light.a"].entity_aliases = { "switch.b" }
T.eq(
  "proven endpoint aliases cannot be selected twice",
  await(commissioning:preview(request(A, B))).error,
  "duplicate_selection"
)
rows["light.a"].entity_aliases = {}
preview = await(commissioning:preview(request(A))).value
revision = secondRevision
T.eq("changed HA revision requires new preview", await(commissioning:execute(preview.id)).error, "revision_changed")
preview = await(commissioning:preview(request(A))).value
setProjectDevices({
  [10] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
  [20] = { deviceName = "Pendant", driverFileName = "Control4.HA.Light.c4z", roomId = 10 },
})
T.eq(
  "changed existing-match decision requires new preview",
  await(commissioning:execute(preview.id)).error,
  "preview_changed"
)
preview = await(commissioning:preview(request(A))).value
T.eq("same label never claims an unrelated unconfigured driver", preview.items[1].reason, "name_in_use")
T.eq("unrelated instance not configured or added", addCount + #configuration, 0)

T.section("Both Director string type representations identify existing suite devices")
commissioning = start({ [20] = { deviceName = "Spare Light", driverFileName = "Control4.HA.Light.c4z", roomId = 11 } })
selected[20], suiteVariableType = "light.a", "STRING"
preview = await(commissioning:preview(request(A))).value
T.eq("symbolic string type is still accepted", preview.items[1].device_id, 20)
suiteVariableType = "2"
preview = await(commissioning:preview(request(A))).value
T.eq("numeric non-string type is unreadable", preview.items[1].reason, "project_identity_unreadable")

T.section("Quick Setup protects a Home Assistant device already assigned to an older Switch")
for _, version in ipairs({ "106", "107" }) do
  commissioning = start({ [20] = { deviceName = "Original switch", driverFileName = "HA.Switch.c4z", roomId = 11 } })
  legacy[20] = {
    model = "HA Switch",
    manufacturer = "BP",
    version = version,
    provider = me,
    entity = "switch.b",
    variables = { ["1001"] = { name = "ENTITY_ID", type = "1", value = "switch.b" } },
  }
  preview = await(commissioning:preview(request(B))).value
  T.eq("recognizes the original without offering a duplicate", preview.items[1].reason, "legacy_switch_match")
  local page = { cursor = 1, revision = firstRevision, entities = { rows[A.choice_id], rows[B.choice_id] } }
  T.eq("browse identifies the exact device on the legacy Coordinator binding", commissioning:existingChoices(page), {
    [B.choice_id] = true,
  })
  legacy[20].provider = me + 1
  page.cursor = 2
  T.eq("continuation uses the browse snapshot", commissioning:existingChoices(page), { [B.choice_id] = true })
  page.cursor = 1
  T.eq("same entity ID on another connection stays visible on fresh browse", commissioning:existingChoices(page), {})
  legacy[20].provider = me
  T.eq("requires review without making changes", await(commissioning:execute(preview.id)).error, "review_required")
  T.eq("did not add a second Switch", addCount, 0)
end

T.section("An already configured legacy Light is reviewed without taking ownership")
-- BP v106 declared Entity ID and ENTITY_ID (native lab variable 1001).
-- Prototype v1 declared the same property and put a selected gesture endpoint
-- there. Both used HA_DEVICE input 999 on the protocol device.
local legacyFile = lightFile
commissioning = start({
  [20] = { deviceName = "Legacy Hall Light", driverFileName = legacyFile, roomId = 11 },
  [21] = { deviceName = "Legacy Hall Light", driverFileName = legacyFile, roomId = 11, protocol = { [20] = {} } },
})
legacy[20] = {
  model = "HA Light",
  manufacturer = "BP",
  version = "106",
  provider = me,
  entity = "light.a",
  variables = { ["1001"] = { name = "ENTITY_ID", type = "1", value = "light.a" } },
}
legacy[21] = legacy[20]
local function reviewLegacy(label, choice, reason)
  local plan = await(commissioning:preview(request(choice or A))).value
  local item = plan.items[1]
  T.eq(label, { item.decision, item.reason, item.device_id }, { "review", reason or "legacy_light_match", 20 })
  T.eq("review shows the existing Light and its room", { item.name, item.family, item.room_id, item.room_name }, {
    "Legacy Hall Light",
    "light",
    11,
    "Office",
  })
  T.eq("preview leaves no deployment receipt", persist:get("HA.Commissioning", nil, true), nil)
  T.eq("review blocks deployment", await(commissioning:execute(plan.id)).error, "review_required")
end
reviewLegacy("BP v106 reports one protocol match, even when connected to this Coordinator")
legacy[20].entity = nil
reviewLegacy("BP variable works when the property is unavailable")
legacy[20].entity = "light.other"
reviewLegacy("disagreeing property and variable require review", A, "legacy_light_unconfirmed")

local deviceId = string.rep("a", 32)
local gesture = "event.fixture_gestures"
local function physicalChoice(registry, entity, name)
  local choiceId = "device:" .. deviceId .. ":" .. string.rep(registry, 32)
  endpoint(choiceId, "light", name)
  rows[choiceId].attributes.device_choice = codec.object({
    type = "device_choice",
    version = 1,
    choice_id = choiceId,
    device_id = deviceId,
    name = name,
    kind = "dimmer",
    gestures = "confirmed",
    gesture_entity_id = gesture,
    source_load = codec.object({ domain = "light", entity_id = entity, registry_id = string.rep(registry, 32) }),
  })
  return { choice_id = choiceId, family = "light", room_id = 10 }
end
local main = physicalChoice("b", "light.a", "Main Light")
local accent = physicalChoice("c", "light.accent", "Accent Light")
legacy[20].version, legacy[20].variables, legacy[20].entity, legacy[20].provider = 1, {}, gesture, nil
reviewLegacy("prototype v1 matches the physical choice's gesture entity while unbound", main)
rows[main.choice_id].family = "switch"
reviewLegacy("legacy Light remains identified even when requesting a Switch", {
  choice_id = main.choice_id,
  family = "switch",
  room_id = main.room_id,
})
rows[main.choice_id].family = "light"
preview = await(commissioning:preview(request(main, accent))).value
T.eq("two independently selected loads can both be reviewed when they share a gesture entity", {
  preview.items[1].reason,
  preview.items[2].reason,
}, { "legacy_light_match", "legacy_light_match" })
legacy[20].variableReadFails = true
reviewLegacy("a readable prototype property still identifies the device if the variable reader fails", main)
legacy[20].missingBinding = true
reviewLegacy("missing input binding does not clear a potential match", main, "legacy_light_unconfirmed")
legacy[20].missingBinding, legacy[20].entity = nil, "light.other"
rows[main.choice_id].attributes.device_choice.gesture_entity_id = "light.other"
preview = await(commissioning:preview(request(main))).value
T.eq("an unrelated load is never matched as gesture evidence", preview.items[1].decision, "add")
rows[main.choice_id].attributes.device_choice.gesture_entity_id = gesture
preview = await(commissioning:preview(request(main, accent))).value
T.eq("a shared gesture entity does not merge distinct HA loads", {
  preview.items[1].decision,
  preview.items[2].decision,
}, { "add", "add" })
setProjectDevices({
  [10] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
  [11] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  [20] = { deviceName = "Legacy Hall Light", driverFileName = legacyFile, roomId = 11 },
  [22] = { deviceName = "Legacy Porch Light", driverFileName = legacyFile, roomId = 11 },
})
legacy[22] = CopyTable(legacy[20], true)
legacy[20].entity, legacy[22].entity = gesture, gesture
preview = await(commissioning:preview(request(main))).value
T.eq("a multiple match never identifies one existing Light", {
  preview.items[1].reason,
  preview.items[1].device_id,
}, { "multiple_matches" })
T.eq("multiple matches block deployment", await(commissioning:execute(preview.id)).error, "review_required")
legacy[20].entity, legacy[22].entity = nil, nil
preview = await(commissioning:preview(request(main))).value
T.eq("multiple unreadable identities require project review", {
  preview.items[1].reason,
  preview.items[1].device_id,
}, { "project_identity_unreadable" })
T.eq("legacy inventory leaves state and the suite link untouched", {
  addCount,
  #configuration,
  next(C4:GetBoundConsumerDevices(me, 1) or {}),
}, { 0, 0 })

T.section("Light adds validate the canonical identity using the project inventory")
commissioning = start(nil, true)
preview = await(commissioning:preview(request(A))).value
T.eq("the first Light can be explicitly added to an empty project", preview.items[1].decision, "add")
operation = await(commissioning:execute(preview.id))
model[lightFile] = "Unverified model"
ShimAnswerAdds()
T.eq("an unverified native result stops before binding", operation.value.items[1].reason, "light_add_unverified")
T.eq(
  "unverified instance is not linked or configured",
  { #configuration, next(C4:GetBoundConsumerDevices(me, 1) or {}) },
  { 0 }
)
preview = await(commissioning:preview(request(A))).value
T.eq("the unresolved receipt prevents another add", preview.items[1].reason, "unresolved_add")
T.eq("review cannot duplicate an unverified add", await(commissioning:execute(preview.id)).error, "review_required")
T.eq("exactly one device was added", addCount, 1)
model[lightFile] = "HA Light"
commissioning = start()
preview = await(commissioning:preview(request(A))).value
T.eq("known canonical instance permits the canonical add", preview.items[1].decision, "add")
legacy[19] = {
  model = "HA Light",
  manufacturer = "BP",
  version = "106",
  entity = "light.other",
  variables = {},
}
T.eq(
  "legacy instance after preview invalidates confirmation",
  await(commissioning:execute(preview.id)).error,
  "preview_changed"
)
preview = await(commissioning:preview(request(A, B))).value
T.eq("legacy instance cannot attest the canonical package", preview.items[1].reason, "light_package_required")
T.eq("Switch keeps its independent package path", preview.items[2].decision, "add")
T.eq(
  "no unsafe add, configuration, or persistent receipt",
  { addCount, #configuration, persist:get("HA.Commissioning", nil, true) },
  { 0, 0 }
)
commissioning = start({ [20] = { deviceName = "Pendant", driverFileName = interimFile, roomId = 10 } }, true)
selected[20] = "light.a"
C4:Bind(me, 1, 20, 1, class)
preview = await(commissioning:preview(request(A))).value
T.eq("an existing interim instance remains recognized without the canonical archive", {
  preview.items[1].decision,
  preview.items[1].device_id,
}, { "keep", 20 })

T.section("A device added while eligibility changes is left unlinked for explicit review")
commissioning = start()
preview = await(commissioning:preview(request(A))).value
operation = await(commissioning:execute(preview.id))
revision, rows["light.a"] = secondRevision, nil
ShimAnswerAdds()
T.eq("changed endpoint rechecks before binding", operation.value.items[1].reason, "preview_changed")
T.eq("newly ineligible endpoint never configures", #configuration, 0)
T.eq("newly ineligible endpoint leaves shared binding untouched", next(C4:GetBoundConsumerDevices(me, 1) or {}), nil)
endpoint("light.a", "light", "Pendant")
preview = await(commissioning:preview(request(A))).value
T.eq("restored eligibility can reuse the confirmed add", preview.items[1].decision, "resume")
T.eq("recovery completes without a duplicate", await(commissioning:execute(preview.id)).value.complete, true)
T.eq("exactly one device was added", addCount, 1)
T.eq("no hidden timer errors", #clock.errors, 0)
T.finish()
