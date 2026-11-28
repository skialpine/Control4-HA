-- Uses the actual deployment library and the template's Director simulator.
local T = require("testlib")
local fixtures = require("c4_fixtures")
local clock = fixtures.virtualClock()
local Commissioning = require("ha.commissioning")
local Transfer = require("ha.commission-transfer")
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
local gestureChoices
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
function catalog:gestureChoice(gesture)
  return gestureChoices[gesture]
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
  local file = row and row.driverFileName
  if file == lightFile or file == ids.packages.binary_sensor.file or file == ids.packages.sensor.file then
    return ids.lightCoordinatorBinding
  end
  return ids.coordinatorBinding
end
function C4:GetDeviceData(id, tag)
  if legacy[id] then
    return legacy[id][tag]
  end
  local project = self:GetDevices({ DeviceIds = tostring(id) })[id]
  if project and model[project.driverFileName] then
    if tag == "model" then
      return model[project.driverFileName]
    elseif tag == "version" then
      return "2026112501"
    end
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
  local store = ShimFiles("C4Z_ROOT")
  store[lightFile], store[switchFile] = "Installed light archive", "Installed switch archive"
  store[ids.packages.fan.file], store[ids.packages.garage.file] = nil, nil
  ShimFiles("C4Z/c4z")[ids.packages.fan.file] = nil
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
  gestureChoices = {}
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
do
  local getBindings, calls = GetDeviceBindings, {}
  function GetDeviceBindings(device, ...)
    calls[device] = (calls[device] or 0) + 1
    return getBindings(device, ...)
  end
  local project = require("ha.commissioning-project")
  project.inventory(true)
  T.eq("one inventory reads both consumer inputs and their shared Coordinator output once", {
    calls[configuration[1].id],
    calls[configuration[2].id],
    calls[me],
  }, { 1, 1, 1 })
  project.inventory(true)
  T.eq("a fresh inventory reads the Coordinator output again", calls[me], 2)
  GetDeviceBindings = getBindings
end
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

T.section("A deleted driver from an interrupted add can be recreated without duplicating a hidden driver")
for _, choice in ipairs({ A, B }) do
  local family = choice.family
  commissioning = start()
  failConfiguration = true
  preview = await(commissioning:preview(request(choice))).value
  operation = await(commissioning:execute(preview.id))
  ShimAnswerAdds()
  T.eq(family .. " setup was interrupted after the add", operation.value.items[1].reason, "timeout")
  local receipt = codec.decode(persist:get("HA.Commissioning", nil, true))[choice.choice_id]
  T.eq(family .. " receipt retains the added device ID", receipt.phase, "added")
  local original = receipt.device_id
  local input = consumerInput(original)
  local devices = C4:GetDevices()
  devices[10] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" }
  devices[11] = { deviceName = "Office", driverFileName = "roomdevice.c4i" }
  local originalDevice = devices[original]
  ShimSetDeviceHidden(original, true)
  preview = await(commissioning:preview(request(choice))).value
  T.eq(family .. " with an active link remains blocked when hidden", preview.items[1].reason, "unresolved_add")
  ShimSetDeviceHidden(original, false)
  C4:Unbind(original, input)
  devices[original] = nil
  setProjectDevices(devices)
  failConfiguration = false
  preview = await(commissioning:preview(request(choice))).value
  T.eq(family .. " can be recreated once the abandoned driver is gone", preview.items[1].decision, "add")
  T.eq(family .. " preview alone never adds a driver", addCount, 1)
  devices[original] = originalDevice
  setProjectDevices(devices)
  T.eq(family .. " rechecks absence on confirmation", await(commissioning:execute(preview.id)).error, "preview_changed")
  T.eq(family .. " never duplicates the reappeared driver", addCount, 1)
  devices[original] = nil
  setProjectDevices(devices)
  preview = await(commissioning:preview(request(choice))).value
  operation = await(commissioning:execute(preview.id))
  ShimAnswerAdds()
  clock.run(5000)
  T.eq(family .. " addition completes on explicit retry", operation.value and operation.value.complete, true)
  T.eq(family .. " adds exactly one new driver", addCount, 2)
end

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

T.section("A separate legacy gateway can already own a Quick Setup load")
do
  local assessment = require("ha.migration-assessment")
  local profile = require("ha.legacy-driver-profile")
  local assess, gateway = assessment.assess, profile.gateway
  local bound = 31
  local file = "chowmain_homeassistant_switch.c4z"
  commissioning = start({ [20] = { deviceName = "Legacy switch", driverFileName = file, roomId = 11 } })
  assessment.assess = function(id, options)
    if id == 20 then
      return { id = id, file = file, family = "switch", interfaces = true, entity = "switch.b" }
    end
    return assess(id, options)
  end
  profile.gateway = function()
    return bound
  end
  preview = await(commissioning:preview(request(B))).value
  T.eq("a known legacy owner requires review", preview.items[1].reason, "legacy_switch_match")
  bound = nil
  preview = await(commissioning:preview(request(B))).value
  T.eq("unknown gateway occupancy also needs review", preview.items[1].reason, "legacy_switch_unconfirmed")
  bound = 0
  preview = await(commissioning:preview(request(B))).value
  T.eq("a detached legacy instance leaves its saved target available", preview.items[1].decision, "add")
  bound = 31
  T.eq(
    "a new legacy binding invalidates prior add approval",
    await(commissioning:execute(preview.id)).error,
    "preview_changed"
  )
  T.eq("no second driver was added", addCount, 0)

  local scope = require("ha.installation-scope").new({
    online = true,
    epoch = 2,
    connection = { config = { origin = "https://current.test" } },
  })
  local http = require("lib.http")
  local get, networkAddresses, gatewayOrigin = http.get, profile.networkAddresses, profile.gatewayOrigin
  local proof = string.rep("a", 64)
  scope.hub._request = function(_, message, done)
    T.eq("commissioning reuses the fixed proof command", message.type, "ha_gesture_bridge/installation_proof")
    done(true, codec.object({ version = 1, nonce = string.rep("b", 32), proof = proof }))
  end
  profile.networkAddresses = function()
    return {}
  end
  profile.gatewayOrigin = function(id)
    return id == bound and "https://legacy.test:443" or nil
  end
  local alternate = string.rep("c", 64)
  http.get = function()
    local work = deferred.new()
    if alternate then
      work:resolve({
        code = 200,
        body = codec.encode(codec.object({
          version = 1,
          nonce = string.rep("b", 32),
          proof = alternate,
        })),
      })
    else
      work:reject({ code = 404 })
    end
    return work
  end
  commissioning.installation = scope
  local page = { cursor = 1, revision = revision, entities = { rows[A.choice_id], rows[B.choice_id] } }
  preview = await(commissioning:preview(request(B))).value
  T.eq("verified separate installations can reuse the entity ID", preview.items[1].decision, "add")
  T.eq(
    "a same-name entity from a separate installation stays offered",
    await(commissioning:browseChoices(page)).value.existing,
    {}
  )
  alternate = proof
  T.eq(
    "a route becoming an alias invalidates add approval",
    await(commissioning:execute(preview.id)).error,
    "preview_changed"
  )
  preview = await(commissioning:preview(request(B))).value
  T.eq("a verified alias retains its legacy owner", preview.items[1].reason, "legacy_switch_match")
  T.eq(
    "a verified alias hides the already configured choice",
    await(commissioning:browseChoices(page)).value.existing,
    {
      [B.choice_id] = true,
    }
  )
  alternate = nil
  preview = await(commissioning:preview(request(B))).value
  T.eq("a missing route proof still withholds addition", preview.items[1].decision, "review")
  T.eq("neither changed nor uncertain scope added anything", addCount, 0)
  alternate = string.rep("c", 64)
  preview = await(commissioning:preview(request(B))).value
  operation = await(commissioning:execute(preview.id))
  T.eq("fresh separate evidence allows the approved add", addCount, 1)
  alternate = proof
  ShimAnswerAdds()
  T.eq(
    "a changed route after add is caught before configuring the new driver",
    operation.value.items[1].reason,
    "preview_changed"
  )
  T.eq("the added instance was not configured", #configuration, 0)
  alternate = string.rep("c", 64)
  preview = await(commissioning:preview(request(B))).value
  T.eq("stable separate evidence can resume the same instance", preview.items[1].decision, "resume")
  operation = await(commissioning:execute(preview.id))
  T.truthy("the separate installation permits configuration after readback", operation.value.complete)
  T.eq(
    "the verified add was reused and the legacy owner kept its binding",
    { addCount, #configuration, bound },
    { 1, 1, 31 }
  )
  http.get, profile.networkAddresses, profile.gatewayOrigin = get, networkAddresses, gatewayOrigin
  assessment.assess, profile.gateway = assess, gateway
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

T.section("A configured suite driver using a unique button event owns the matching Quick Setup choice")
commissioning = start({ [20] = { deviceName = "Primary Toilet", driverFileName = interimFile, roomId = 11 } })
selected[20] = gesture
C4:Bind(me, 1, 20, 1, class)
main = physicalChoice("b", "light.a", "Primary Toilet control")
gestureChoices[gesture] = main.choice_id
local gesturePage = { cursor = 1, revision = revision, entities = { rows[main.choice_id] } }
T.eq(
  "same-device button selection is shown as already in Control4",
  commissioning:existingChoices(gesturePage),
  { [main.choice_id] = true }
)
preview = await(commissioning:preview(request(main))).value
T.eq(
  "preview shows the existing button driver without assuming it controls the load",
  { preview.items[1].decision, preview.items[1].device_id, preview.items[1].reason },
  { "review", 20, "button_device_match" }
)
T.eq(
  "explicit preview cannot add a duplicate physical control",
  await(commissioning:execute(preview.id)).error,
  "review_required"
)
accent = physicalChoice("c", "light.accent", "Independent load")
gesturePage.entities[2] = rows[accent.choice_id]
gestureChoices[gesture] = nil
T.eq("an ambiguous shared gesture alone does not hide separate loads", commissioning:existingChoices(gesturePage), {})

T.section("A connected Control4 light accounts for its selected button device")
do
  local physical = string.rep("a", 32)
  local button = { choice_id = "device:" .. physical .. ":none", family = "switch", room_id = 11 }
  local previous = "device:" .. physical .. ":" .. string.rep("b", 32)
  commissioning = start({ [20] = { deviceName = "Existing Light", driverFileName = lightFile, roomId = 11 } })
  selected[20] = previous
  C4:Bind(me, 1, 20, ids.lightCoordinatorBinding, class)
  local row = {
    entity_id = button.choice_id,
    name = "Wall Button",
    domain = "event",
    family = "switch",
    families = { "light", "switch" },
    attributes = { device_choice = { device_id = physical, gesture_entity_id = gesture, kind = "remote" } },
  }
  rows[button.choice_id] = row
  gestureChoices[gesture] = button.choice_id
  local identity = codec.object({
    buttons = true,
    device = physical,
    gesture = gesture,
    key = previous,
    mode = "Connected Control4 light",
    ready = true,
    stable = true,
  })
  ShimSetUIRequest(function(id, command)
    if id == 20 and command == "HA_SELECTION_IDENTITY" then
      return "<selection>" .. C4:Base64Encode(codec.encode(identity)) .. "</selection>"
    end
    return ""
  end)
  local page = { cursor = 1, revision = revision, entities = { row, rows[A.choice_id] } }
  T.eq(
    "browse counts the exact existing button but leaves independent loads available",
    commissioning:existingChoices(page),
    { [button.choice_id] = true }
  )
  local matched = await(commissioning:preview(request(button))).value.items[1]
  T.eq("review finds the existing connected Light without creating a duplicate", {
    matched.decision,
    matched.device_id,
    matched.reason,
  }, { "review", 20, "button_device_match" })
  identity.buttons = false
  T.eq("an inactive selection does not account for the buttons", commissioning:existingChoices(page), {})
  identity.buttons, identity.gesture = true, "event.other_button"
  T.eq("a different event never counts just because the physical ID matches", commissioning:existingChoices(page), {})
  identity.gesture = gesture
  C4:Unbind(20, ids.lightCoordinatorBinding)
  T.eq("an unbound retained selection cannot hide the choice", commissioning:existingChoices(page), {})
  T.eq("browse never adds or configures a driver", { addCount, #configuration }, { 0, 0 })
end

T.section("A native choice accounts for a load configured with a physical selection")
do
  local device, first, second = string.rep("a", 32), string.rep("b", 32), string.rep("c", 32)
  commissioning = start({ [20] = { deviceName = "Existing Load", driverFileName = interimFile, roomId = 11 } })
  selected[20] = "device:" .. device .. ":" .. first
  C4:Bind(me, 1, 20, 1, class)
  endpoint("switch.other_load", "switch", "Other load")
  local source, entries = {}, {}
  for id, registry in pairs({ [B.choice_id] = first, ["switch.other_load"] = second }) do
    local row = rows[id]
    row.device_id = device
    source[#source + 1] = row
    entries[id] = codec.object({
      entity_id = id,
      id = registry,
      device_id = device,
      platform = "test",
      disabled_by = codec.null,
      hidden_by = codec.null,
      entity_category = codec.null,
    })
  end
  local native = require("ha.choices").apply(source, entries, true)
  for _, row in ipairs(native) do
    rows[row.entity_id] = row
  end
  local page = { cursor = 1, revision = revision, entities = native }
  T.eq("only the exact configured registry load is hidden", commissioning:existingChoices(page), {
    [B.choice_id] = true,
  })
  preview = await(commissioning:preview(request(B))).value
  T.eq("direct review still finds the owner under the old choice format", preview.items[1].device_id, 20)
end

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
T.eq("no hidden timer errors", clock.errors, {})

T.section("A new physical device under the same entity ID needs new approval")
commissioning = start()
rows["light.a"].device_id = string.rep("a", 32)
preview = await(commissioning:preview(request(A))).value
operation = await(commissioning:execute(preview.id))
rows["light.a"].device_id, revision = string.rep("b", 32), secondRevision
ShimAnswerAdds()
T.eq("the replacement under the same name is withheld", operation.value.items[1].reason, "preview_changed")
T.eq("the add receipt is retained without configuring it", { addCount, #configuration }, { 1, 0 })

T.section("Quick Setup configures the created drivers over the real selection transfer")
start()
local hub = { online = true, catalog = catalog, prefix = "TestCommission.", consumers = {} }
function hub:_owns(id)
  return C4:GetBoundProviderDevice(id, consumerInput(id)) == me
end
local transfer = Transfer.new(hub)
function hub:_emit(consumer, kind, data)
  local op, arguments
  if kind == "commission_offer" then
    op, arguments = "commission_claim", { accept = true }
  else
    assert(kind == "commission_apply")
    T.eq(
      "the new driver receives the verified Home Assistant load",
      data.config.controlled_load.entity_id,
      data.config.key
    )
    selected[consumer.device] = data.config.key
    op, arguments = "commission_ack", { applied = true }
  end
  transfer:receive(consumer, { op = op, request_id = data.ticket, arguments = codec.object(arguments) })
end
commissioning = Commissioning.new(catalog, function(id, query)
  hub.consumers[id] = { device = id, session = "new-device" }
  return transfer:start(id, query)
end)
local transferPlan = await(commissioning:preview(request(B, A))).value
T.eq("the review shows the source name", transferPlan.items[1].source_name, "Fan")
local transferRun = await(commissioning:execute(transferPlan.id))
ShimAnswerAdds()
clock.run(5000)
ShimAnswerAdds()
clock.run(5000)
local transferResult = transferRun.value
T.eq("adding and binding also configures both new drivers", transferResult.complete, true)
T.eq("the drivers store the selected catalog identities", {
  selected[transferResult.items[1].device_id],
  selected[transferResult.items[2].device_id],
}, { "switch.b", "light.a" })
local light = transferResult.items[2].device_id
local binaryLoad = await(transfer:directLoad(light, "light", "switch.binary", "Binary load"))
T.eq("the verified transfer can keep a switch entity in the Light family", selected[light], "switch.binary")
T.falsy("the Light accepted the verified binary selection", binaryLoad.error)
T.section("A mixed-family draft checks and uses each catalog independently")
do
  start()
  local fanFile = ids.packages.fan.file
  model[fanFile] = ids.packages.fan.model
  local store = ShimFiles("C4Z_ROOT")
  local carried = "Bundled fan archive"
  ShimFiles("C4Z/c4z")[fanFile], ShimFiles("C4Z/c4z")[lightFile] = carried, "Bundled light archive"
  local fanRevision = secondRevision
  local scoped = {}
  endpoint("fan.lab", "fan", "Lab Fan")
  function scoped:refresh()
    return deferred.new():resolve({ revision = fanRevision })
  end
  function scoped:choice(id, family)
    return catalog:choice(id, family)
  end
  commissioning = Commissioning.new(catalog, configure, nil, function(family)
    return family == "fan" and scoped or catalog
  end)
  local choices = request(A, { choice_id = "fan.lab", family = "fan", room_id = 11, name = "Lab Fan" })
  choices.choices[2].revision = fanRevision
  local mixed = assert(await(commissioning:preview(choices)).value)
  T.eq("both families appear in a mixed preview", { mixed.items[1].family, mixed.items[2].family }, { "light", "fan" })
  T.eq("preview does not install the missing package", store[fanFile], nil)
  fanRevision = string.rep("c", 64)
  T.eq(
    "changed fan selection prevents all project writes",
    await(commissioning:execute(mixed.id)).error,
    "revision_changed"
  )
  T.eq("no driver added from the stale preview", addCount, 0)
  T.eq("stale confirmation does not install the missing package", store[fanFile], nil)
  choices.choices[2].revision = fanRevision
  mixed = assert(await(commissioning:preview(choices)).value)
  local executing = await(commissioning:execute(mixed.id))
  T.eq("existing Light keeps its installed archive", store[lightFile], "Installed light archive")
  T.eq("the next package is staged only when its row is reached", store[fanFile], nil)
  ShimAnswerAdds()
  clock.run(5000)
  T.eq("the confirmed fan package is staged before Director answers", store[fanFile], carried)
  ShimAnswerAdds()
  clock.run(5000)
  local outcome = assert(executing.value)
  T.truthy("confirmed mixed preview creates the selected drivers", outcome.complete)
  T.eq("fan was configured from the fan catalog", configuration[2].query.revision, fanRevision)
  local fan = require("ha.commissioning-project").device(outcome.items[2].device_id)
  T.eq(
    "fan has the selected room, Coordinator and saved device",
    { fan.room_id, fan.provider, fan.selected },
    { 11, me, "fan.lab" }
  )
end

T.section("A mixed project commissions and reopens every endpoint family")
do
  local commissioning = start(nil, true)
  local families = require("ha.endpoint-families")
  local project = require("ha.commissioning-project")
  local carried = ShimFiles("C4Z/c4z")
  local store = ShimFiles("C4Z_ROOT")
  local choices = { A, B }
  for index, family in ipairs(families.order) do
    local package = ids.packages[family]
    local choiceId = families[family].domain .. ".lab_" .. family
    model[package.file] = package.model
    carried[package.file] = "Bundled " .. family .. " archive"
    endpoint(choiceId, family, "Lab " .. family)
    rows[choiceId].domain = package.domain
    if family == "garage" then
      rows[choiceId].attributes.device_class = "garage"
    end
    choices[#choices + 1] = { choice_id = choiceId, family = family, room_id = 10 + index % 2 }
  end
  local plan = assert(await(commissioning:preview(request(unpack(choices)))).value)
  T.eq("review lists every family without adding drivers", { #plan.items, addCount }, { #choices, 0 })
  local run = await(commissioning:execute(plan.id))
  for _ in ipairs(choices) do
    ShimAnswerAdds()
    clock.run(5000)
  end
  local result = assert(run.value)
  T.truthy("mixed commissioning completes", result.complete)
  for index, choice in ipairs(choices) do
    local item = result.items[index]
    local device = assert(project.device(item.device_id), choice.family .. ": " .. tostring(item.reason))
    T.eq(choice.family .. " has the expected package, room, Coordinator and saved endpoint", {
      device.file,
      device.room_id,
      device.provider,
      device.selected,
    }, { ids.packages[choice.family].file, choice.room_id, me, choice.choice_id })
  end

  local reopened = Commissioning.new(catalog, configure)
  local repeatPlan = assert(await(reopened:preview(request(unpack(choices)))).value)
  local repeatRun = assert(await(reopened:execute(repeatPlan.id)).value)
  T.eq("reopening and confirming again preserves every driver and selection", {
    repeatRun.complete,
    addCount,
    #configuration,
  }, { true, #choices, #choices })
  for _, family in ipairs(families.order) do
    local file = ids.packages[family].file
    carried[file], store[file] = nil, nil
  end
end

T.section("An unreadable original cover can own either type of cover")
do
  local plan = { family = "garage", domain = "cover", name = "Test garage", room_id = 10, keys = {} }
  local original = { id = 20, legacy = true, family = "blinds", review_only = true }
  T.eq("an unreadable Blinds driver blocks a second owner of the same domain", {
    require("ha.commissioning-project").decide(plan, { original }, nil, me),
  }, { "review", 20, "legacy_blinds_unconfirmed" })
  original.family = "fan"
  T.eq("an unrelated unreadable family does not block the garage", {
    require("ha.commissioning-project").decide(plan, { original }, nil, me),
  }, { "add" })
end

T.section("A missing package can be imported without leaving an unresolved add")
do
  local commissioning = start()
  local fanFile = ids.packages.fan.file
  model[fanFile] = ids.packages.fan.model
  endpoint("fan.lab", "fan", "Lab Fan")
  local draft = request({ choice_id = "fan.lab", family = "fan", room_id = 11 })
  local plan = assert(await(commissioning:preview(draft)).value)
  local result = assert(await(commissioning:execute(plan.id)).value)
  T.eq("missing bundled file reports the install step", result.items[1].reason, "driver_install_failed")
  T.eq("Director receives no add after a missing archive", addCount, 0)
  T.eq("no unresolved add receipt is written", persist:get("HA.Commissioning", nil, true), nil)

  ShimFiles("C4Z/c4z")[fanFile] = "Bundled fan archive"
  local write = C4.FileWrite
  C4.FileWrite = function()
    return -1
  end
  plan = assert(await(commissioning:preview(draft)).value)
  result = assert(await(commissioning:execute(plan.id)).value)
  C4.FileWrite = write
  T.eq("failed archive write reports the same action", result.items[1].reason, "driver_install_failed")
  T.eq("a failed archive write leaves no add or staged file", { addCount, ShimFiles("C4Z_ROOT")[fanFile] }, { 0 })

  ShimFiles("C4Z_ROOT")[fanFile] = "Manually imported fan archive"
  plan = assert(await(commissioning:preview(draft)).value)
  local operation = await(commissioning:execute(plan.id))
  ShimAnswerAdds()
  clock.run(5000)
  T.eq("retry configures the requested endpoint", selected[operation.value.items[1].device_id], "fan.lab")
  T.eq("the manually imported archive is preserved", ShimFiles("C4Z_ROOT")[fanFile], "Manually imported fan archive")
end

T.section("Garage without a display proxy receives the requested name after AddDevice")
do
  start()
  local garageFile = ids.packages.garage.file
  local packageName = "Home Assistant Garage Door"
  model[garageFile] = ids.packages.garage.model
  ShimFiles("C4Z_ROOT")[garageFile] = "Existing garage archive"
  endpoint("cover.lab_garage", "garage", "Lab Garage")
  local read, add = C4.GetDeviceData, C4.AddDevice
  function C4:GetDeviceData(id, key)
    if key == "name" and read(self, id, "model") == model[garageFile] then
      return packageName
    end
    return read(self, id, key)
  end
  function C4:AddDevice(file, room, _, answer)
    return add(self, file, room, packageName, answer)
  end
  commissioning = Commissioning.new(catalog, configure)
  local draft = request({ choice_id = "cover.lab_garage", family = "garage", room_id = 10, name = "Lab Garage" })
  local plan = assert(await(commissioning:preview(draft)).value)
  local running = await(commissioning:execute(plan.id))
  ShimAnswerAdds()
  clock.run(5000)
  C4.GetDeviceData, C4.AddDevice = read, add
  local outcome = assert(running.value)
  T.truthy("the confirmed add completes despite Director choosing the default name", outcome.complete)
  local device = require("ha.commissioning-project").device(outcome.items[1].device_id)
  T.eq("the requested name, room and selected entity are saved", { device.name, device.room_id, device.selected }, {
    "Lab Garage",
    10,
    "cover.lab_garage",
  })
  local repeated = assert(await(commissioning:preview(draft)).value)
  T.eq("the saved Garage Door can be kept in a later preview", repeated.items[1].decision, "keep")
  local kept = assert(await(commissioning:execute(repeated.id)).value)
  T.eq("applying the later preview keeps the existing instance", kept.items[1].device_id, device.id)
  T.eq("opening setup again never repeats the add", addCount, 1)
end

T.finish()
