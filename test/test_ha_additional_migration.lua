local T = require("testlib")
local function reviewRemoval(wizard, tested, reviewed, evidence)
  return wizard:reviewRemoval(tested, reviewed, evidence, wizard:state().removalScope)
end

local Upgrade = require("ha.switch-upgrade")
local assess = require("ha.migration-assessment")
local project = require("ha.commissioning-project")
local selection = require("ha.migration-selection")
local profile = require("ha.legacy-driver-profile")
local lighting = require("ha.migration-lighting")
local installed = require("ha.installed-suite")
local ids = require("ha.identities")
local deferred = require("deferred")
local contract = require("ha.contract")
local codec = require("ha.codec")
local compatibility = require("ha.light-compatibility")
local metrics = require("ha.performance").shared

local readLighting = lighting.read
local revision, gateway, coordinator = 2026112210, 30, 40
local function resolved(value)
  local promise = deferred.new()
  promise:resolve(value)
  return promise
end
local function settings(id, rate)
  local saved = tostring(rate)
  return {
    version = 2,
    scenes = { [id] = { [0] = { id = 0, name = "Patio", saved = saved } } },
    groups = {},
    members = { scenes = { ["0"] = { [tostring(id)] = saved } }, groups = {} },
  }
end
local emptyPrograms = { readable = true, incoming = {}, attached = {} }
local function fixture(family)
  family = family or "light"
  local savedLighting = family == "light" and settings(52, 750)
    or { version = 2, scenes = {}, groups = {}, members = { scenes = {}, groups = {} } }
  local original = {
    id = 51,
    file = "chowmain_homeassistant_" .. family .. ".c4z",
    name = "Light",
    family = family,
    version = "20261008",
    origin = "Legacy HA",
    room_id = 7,
    room = "Room",
    interfaces = true,
    entity = "switch.lamp",
    compatibility = family == "light" and { kind = "On/off" } or nil,
    proxies = { { id = 52 } },
    lighting = lighting.checkpoint(savedLighting),
    edges = {},
    programs = emptyPrograms,
  }
  local input = family == "light" and ids.lightCoordinatorBinding or ids.coordinatorBinding
  local replacement = { id = 61, family = family, room_id = 7, name = "New Driver", input = input, provider = 0 }
  local record = {
    source = original,
    name = replacement.name,
    destination = replacement.id,
    gateway = gateway,
    endpoint = { origin = "https://ha.test:443", unregistered = true },
    phase = "prepared",
    mappedConnections = {},
    deviceName = "Lamp",
  }
  local f = {
    link = gateway,
    settings = savedLighting,
    calls = {},
    record = record,
    original = original,
    replacement = replacement,
    programs = emptyPrograms,
    originalPrograms = emptyPrograms,
    originalOrigin = "https://ha.test:443",
  }
  assess.assess = function()
    local live = {}
    for key, value in pairs(original) do
      live[key] = value
    end
    live.programs = f.originalPrograms
    return live
  end
  assess.deviceProgramming = function()
    return f.programs
  end
  lighting.read = function(_, _, _, full)
    if f.sceneReads then
      f.sceneReads[#f.sceneReads + 1] = full and "all" or "affected"
    end
    return f.settings
  end
  project.device = function()
    return replacement
  end
  profile.gateway = function()
    return f.link
  end
  profile.networkAddresses = function()
    return {}
  end
  profile.gatewayOrigin = function()
    return f.originalOrigin
  end
  selection.read = function()
    if f.selected then
      return {
        stable = true,
        ready = f.ready ~= false,
        settings_verified = f.settingsVerified ~= false,
        saved = true,
        mode = "Home Assistant device",
        key = f.target or original.entity,
        load = f.target or original.entity,
      }
    end
    return { key = "", stable = true }
  end
  installed.upgradeRevision = function(_, _, deviceFamily)
    return (not deviceFamily or deviceFamily == family) and revision
  end
  contract.provider = function()
    return replacement.provider
  end
  function C4:GetProxyDevicesById()
    return 62
  end
  function GetDeviceBindings()
    return { [input] = { deviceid = replacement.id, provider = false } }
  end
  function C4:Unbind(id)
    if id == original.id then
      f.calls[#f.calls + 1] = "release old"
      f.link = 0
    else
      f.calls[#f.calls + 1] = "release replacement"
      replacement.provider = 0
    end
  end
  function Bind(provider, port, id, input)
    f.restoredBinding = { provider, port, id, input }
    f.link = provider
  end
  f.wizard = setmetatable({
    coordinator = coordinator,
    serial = 0,
    batch = { revision = revision },
    save = function() end,
    confirmCutover = function()
      return resolved(true)
    end,
    notify = function() end,
    checkOwnership = function()
      return not f.duplicate
    end,
    bindReplacement = function()
      T.eq("only a blank replacement can bind before gateway release", f.link, f.selected and 0 or gateway)
      f.calls[#f.calls + 1] = "bind replacement"
      replacement.provider = coordinator
    end,
    waitReady = function()
      f.calls[#f.calls + 1] = "read feedback"
      if f.afterSelection then
        f.afterSelection()
      end
      return resolved(true)
    end,
    finishRecordNames = function()
      f.calls[#f.calls + 1] = "verify names"
    end,
    hub = {
      online = true,
      catalog = {
        hasVerifiedSnapshot = function()
          return true
        end,
        loadDetails = function()
          return nil, nil, f.registry, f.registryUnknown ~= true
        end,
        verifyLoadRegistry = function(_, entity, registry, unregistered, oldEntity, oldRegistry)
          if f.target then
            return resolved(
              entity == f.target
                and registry == f.targetRegistry
                and not unregistered
                and oldEntity == original.entity
                and oldRegistry == f.registry
                and not f.registryMismatch
            )
          end
          return resolved(
            entity == original.entity
              and registry == f.registry
              and (not f.registry) == (unregistered == true)
              and f.registryMismatch ~= true
          )
        end,
      },
      connection = {
        config = { origin = "https://ha.test" },
        readState = function(_, entity)
          f.calls[#f.calls + 1] = "read HA"
          local state
          if f.feedback then
            state = f.feedback()
          end
          return resolved(state or codec.object({ entity_id = entity, state = "off", attributes = codec.object({}) }))
        end,
      },
      transfer = {
        stageLightSettings = function(_, _, entity, proposed)
          T.eq("settings stay on the blank replacement while the original controls the load", {
            entity,
            proposed,
            f.link,
            f.selected,
          }, { original.entity, record.lightSettings, gateway })
          f.calls[#f.calls + 1] = "stage settings"
          return f.settingsReceipt or resolved(true)
        end,
        directLoad = function(_, _, deviceFamily, entity, _, proposed, migration)
          T.eq("the original remains connected until the replacement claims the selection", f.link, gateway)
          return migration
            .beforeApply(function()
              return true
            end)
            :next(function(released)
              T.truthy("the claimed selection can release the verified original gateway", released)
              if not released then
                error({ kind = "configuration_unconfirmed", step = "releasing" }, 0)
              end
              T.eq(
                "retains the device family and approved entity",
                { deviceFamily, entity },
                { family, f.target or original.entity }
              )
              if record.lightSettings then
                T.eq("selection can check the same saved settings", proposed, record.lightSettings)
                T.eq("selection only follows release of the original", f.link, 0)
              end
              f.calls[#f.calls + 1] = "select"
              f.selected = true
              return true
            end)
        end,
      },
    },
  }, Upgrade)
  return f
end

T.section("Additional legacy Light remains authoritative while the scene is unresolved")
local f = fixture()
f.wizard:applyAdditional(f.record, 61)
T.eq("the staged review guides the exact scene move", f.record.phase, "review")
T.contains("the message points to Composer", f.record.message, "Advanced Lighting")
T.eq("no control connection has changed", f.link, gateway)
f.settings = settings(62, 500)
f.wizard:applyAdditional(f.record, 61)
T.contains("edited settings block cutover", f.record.message, "Check the saved settings of Patio")
T.eq("no HA or control calls before reference verification", #f.calls, 0)

T.section("A visible light can safely replace the hidden relay of a legacy Light")
for _, changed in ipairs({ false, true }) do
  f = fixture()
  f.settings, f.target = settings(62, 750), "light.lamp"
  f.registry, f.targetRegistry = string.rep("a", 32), string.rep("b", 32)
  f.wizard.hub.catalog.exactLoadChoice = function()
    return { name = "Lamp" }, f.target, f.targetRegistry
  end
  f.record.endpoint = {
    origin = "https://ha.test:443",
    entity = f.target,
    source_registry = f.registry,
    registry = f.targetRegistry,
  }
  f.registryMismatch = changed
  local succeeded = false
  f.wizard:applyAdditional(f.record, 61):next(function()
    succeeded = true
  end)
  T.eq("the approved wrapper cuts over only while the registry relationship is verified", succeeded, not changed)
  T.eq("a changed relationship leaves control with the original", f.link, changed and gateway or 0)
  T.eq("new feedback uses the reviewed light", f.selected == true, not changed)
end

T.section("Timer programming must move to the matching replacement events")
for _, change in ipairs({ "none", "wrong timer", "wrong event", "duplicate on original" }) do
  f = fixture()
  f.settings = settings(62, 750)
  local function timers(device, event, proof)
    return {
      readable = true,
      incoming = {},
      attached = {
        { device = device, event = 5100, timerScript = "start" },
        { device = device, event = event, timerScript = proof },
      },
    }
  end
  f.record.source.programs = timers(52, 5101, "stop")
  f.programs = timers(62, change == "wrong event" and 5102 or 5101, change == "wrong timer" and "other" or "stop")
  if change == "duplicate on original" then
    f.originalPrograms = f.record.source.programs
  end
  f.wizard:applyAdditional(f.record, 61)
  T.eq(
    "only the exact event and timer on the new driver release the old driver",
    f.link,
    change == "none" and 0 or gateway
  )
end

T.section("An unavailable legacy Light explains the retry without transferring the load")
do
  local blocked = fixture()
  blocked.settings = settings(62, 750)
  blocked.wizard.batch.records = { blocked.record }
  blocked.wizard.destination = function()
    return resolved(61)
  end
  blocked.feedback = function()
    return codec.object({
      entity_id = blocked.original.entity,
      state = "unavailable",
      attributes = codec.object({}),
    })
  end
  local row = blocked.wizard:run().rows[1]
  T.eq("the original stays connected with no replacement selected", { row.state, blocked.link, blocked.selected }, {
    "attention",
    gateway,
  })
  T.contains(
    "the reason and next action are visible",
    row.message,
    "light is unavailable in Home Assistant. Retry when"
  )
end

T.section("Legacy migration recovers once from a Home Assistant state read timeout")
for _, outcome in ipairs({ "recovered", "timed out again", "registry changed", "registry mismatch", "closed" }) do
  local scenario = fixture()
  scenario.settings = settings(62, 750)
  scenario.wizard.batch.records = { scenario.record }
  scenario.wizard.destination = function()
    return resolved(61)
  end
  local catalog = scenario.wizard.hub.catalog
  local verifyRegistry, registryReads = catalog.verifyLoadRegistry, 0
  catalog.verifyLoadRegistry = function(...)
    registryReads = registryReads + 1
    return verifyRegistry(...)
  end
  local connection = scenario.wizard.hub.connection
  local readState, stateReads = connection.readState, 0
  local firstRead = deferred.new()
  connection.readState = function(self, entity)
    stateReads = stateReads + 1
    if stateReads == 1 then
      return firstRead
    end
    if outcome == "timed out again" then
      local timeout = deferred.new()
      timeout:reject({ kind = "timeout" })
      return timeout
    end
    return readState(self, entity)
  end

  scenario.registryMismatch = outcome == "registry mismatch"
  scenario.wizard:run()
  T.eq("pending state read leaves the original connected", { scenario.link, #scenario.calls }, { gateway, 0 })
  scenario.registryMismatch = outcome == "registry changed"
  if outcome == "closed" then
    scenario.wizard:destroy()
  end
  firstRead:reject({ kind = "timeout" })

  local expectedReads = (outcome == "closed" or outcome == "registry mismatch") and 1 or 2
  T.eq("the same migration tries the read at most twice", stateReads, expectedReads)
  if outcome == "recovered" then
    T.eq("the original is released after fresh evidence", { scenario.record.phase, scenario.link, registryReads }, {
      "naming",
      0,
      3,
    })
  else
    T.eq("a failed or closed preflight does not change either driver", {
      scenario.link,
      scenario.replacement.provider,
      scenario.selected,
      registryReads,
    }, { gateway, 0, nil, expectedReads })
  end
  if outcome == "timed out again" then
    T.contains("a persistent timeout is reported", scenario.record.message, "took too long")
  end
end

T.section("A matching saved scene permits a verified staged cutover")
f = fixture()
f.settings = settings(62, 750)
f.wizard:applyAdditional(f.record, 61)
T.eq("cutover releases, configures and verifies in safe order", f.calls, {
  "read HA",
  "bind replacement",
  "release old",
  "select",
  "read feedback",
  "verify names",
})
T.eq("names remain a separate resumable phase", f.record.phase, "naming")

T.section("Immediate naming reuses read-only cutover checks")
do
  local scenario = fixture()
  scenario.settings, scenario.sceneReads = settings(62, 750), {}
  local checkedOwners, names = 0, { [52] = scenario.original.name, [62] = scenario.replacement.name }
  local previousRename, previousDisplay, readOriginal = RenameDevice, C4.GetDeviceDisplayName, assess.assess
  assess.assess = function(...)
    local current = readOriginal(...)
    current.name = names[52]
    return current
  end
  RenameDevice = function(id, name)
    names[id] = name
  end
  function C4:GetDeviceDisplayName(id)
    return names[id]
  end
  scenario.wizard.checkOwnership = function()
    checkedOwners = checkedOwners + 1
    return true
  end
  scenario.wizard.batch.records = { scenario.record }
  scenario.wizard.finishRecordNames = nil
  scenario.wizard:applyAdditional(scenario.record, 61)
  T.eq("cutover and naming succeed with one full scene check", {
    scenario.record.phase,
    scenario.sceneReads,
    checkedOwners,
  }, { "upgraded", { "affected", "all", "affected" }, 2 })

  scenario.record.phase = "naming"
  scenario.settings = settings(62, 500)
  T.falsy("a separate naming retry rejects a newly changed scene", scenario.wizard:finishRecordNames(scenario.record))
  T.eq("the retry reads the affected scene again", scenario.sceneReads[4], "affected")
  RenameDevice, C4.GetDeviceDisplayName, assess.assess = previousRename, previousDisplay, readOriginal
end

T.section("Explicit Light settings are staged and confirmed before releasing the original")
local function colorLight()
  local scenario = fixture()
  scenario.original.entity = "light.lamp"
  scenario.original.compatibility = { kind = "Color and white temperature", format = "HS", minK = 2700, maxK = 5500 }
  scenario.record.lightSettings =
    compatibility.migrationSettings(scenario.original.entity, scenario.original.compatibility)
  scenario.settings = settings(62, 750)
  scenario.settingsReceipt = deferred.new()
  scenario.feedback = function()
    return codec.object({
      entity_id = "light.lamp",
      state = "on",
      attributes = codec.object({
        brightness = 120,
        supported_color_modes = codec.array({ "rgb", "color_temp" }),
        min_color_temp_kelvin = 2000,
        max_color_temp_kelvin = 6500,
      }),
    })
  end
  return scenario
end

do
  local scenario = colorLight()
  local sources, inventory, lightingSnapshot = assess.sources, project.inventory, lighting.snapshot
  assess.sources = function(_, includeAdditional)
    return includeAdditional and { { id = 51, origin = "Legacy HA" } } or {}
  end
  project.inventory = function()
    return {}
  end
  lighting.snapshot = function()
    return {}
  end
  scenario.wizard.hub.catalog.exactLoadChoice = function()
    return { name = "Lamp" }
  end
  local rows = scenario.wizard:list()
  T.eq("an explicit supported light can be selected for review", rows[1].state, "ready")
  local preview = scenario.wizard:review({ 51 })
  T.eq("review displays the original and proposed overrides", preview.rows[1].lightSettings, {
    original = { kind = "Color and white temperature", format = "HS", range = "2700-5500" },
    replacement = { kind = "Color and white temperature", format = "HS", range = "2700-5500" },
  })
  scenario.original.compatibility.kind = "Automatic"
  rows = scenario.wizard:list()
  T.eq("an unqualified legacy capability setting is visibly blocked", rows[1].state, "blocked")
  T.contains("the row identifies the unsupported settings", rows[1].message, "verified mapping")
  assess.sources, project.inventory, lighting.snapshot = sources, inventory, lightingSnapshot
end

f = colorLight()
f.wizard:applyAdditional(f.record, 61)
T.eq(
  "only a blank binding and settings write precede readback",
  f.calls,
  { "read HA", "bind replacement", "stage settings" }
)
T.eq("the old driver remains authoritative while settings are saving", f.link, gateway)
f.settingsReceipt:resolve(true)
T.eq("cutover uses fresh HA state and confirms replacement feedback before naming", f.calls, {
  "read HA",
  "bind replacement",
  "stage settings",
  "read HA",
  "release old",
  "select",
  "read feedback",
  "verify names",
})
T.eq("the replacement is ready to name after verified cutover", f.record.phase, "naming")

f = colorLight()
f.wizard:applyAdditional(f.record, 61)
f.settingsReceipt:reject({ kind = "configuration_unconfirmed" })
T.eq(
  "a rejected write retains the original and keeps the replacement unselected",
  { f.record.phase, f.link, f.selected },
  {
    "review",
    gateway,
  }
)
T.contains("the rejection explains the next action", f.record.message, "Check the new driver’s settings")

f = colorLight()
f.wizard:applyAdditional(f.record, 61)
local colorFeedback = f.feedback
f.feedback = function()
  local state = colorFeedback()
  state.attributes.supported_color_modes = codec.array({ "brightness" })
  return state
end
f.settingsReceipt:resolve(true)
T.eq("changed capability feedback prevents cutover", { f.record.phase, f.link, f.selected }, { "review", gateway })
T.contains("the review identifies the feedback problem", f.record.message, "supports the settings you reviewed")

f = colorLight()
f.wizard.batch.records = { f.record }
f.wizard:run()
f.registryMismatch = true
f.settingsReceipt:resolve(true)
T.eq("new registry results prevent release even while cached preview matches", { f.link, f.selected }, { gateway })

f = colorLight()
f.wizard.batch.records = { f.record }
f.afterSelection = function()
  f.registryMismatch = true
end
f.wizard:run()
f.settingsReceipt:resolve(true)
T.eq(
  "a registry mismatch after selection restores the original connection",
  { f.record.phase, f.link },
  { "recovery", gateway }
)
T.eq("the replacement cannot be renamed after registry drift", f.calls[#f.calls], "release replacement")

T.section("Incoming native power actions must reach the exact replacement event")
local function incoming(command, event, position)
  return {
    readable = true,
    attached = {},
    incoming = {
      {
        device = 17,
        event = event,
        actionCount = 1,
        commands = { [command] = 1 },
        positions = { [tostring(position or 1)] = command },
      },
    },
  }
end
f = fixture()
f.settings = settings(62, 750)
f.original.programs = incoming("TurnOff", 2)
f.originalPrograms = f.original.programs
f.programs = incoming("Turn Off", 2)
f.wizard:applyAdditional(f.record, 61)
T.eq("duplicate action on the old driver blocks cutover", f.link, gateway)
f.originalPrograms, f.programs = emptyPrograms, incoming("Turn Off", 3)
f.wizard:applyAdditional(f.record, 61)
T.eq("an otherwise matching command on another event blocks cutover", f.link, gateway)
f.programs = incoming("Turn Off", 2, 2)
f.wizard:applyAdditional(f.record, 61)
T.eq("moving a command to another position changes the reviewed script", f.link, gateway)
f.programs = incoming("Turn Off", 2)
f.wizard:applyAdditional(f.record, 61)
T.eq("the exact moved native action passes readback", f.record.phase, "naming")

f = fixture("switch")
f.original.programs = incoming("Toggle", 2)
f.originalPrograms = emptyPrograms
f.programs = incoming("Toggle", 2)
f.wizard:applyAdditional(f.record, 61)
T.eq("the mapped native Toggle passes Switch recheck", f.record.phase, "naming")

T.section("Unverifiable staged programming has a recovery path")
f = fixture()
f.original.programs = { readable = true, attached = { { device = 51, event = 2 } }, incoming = {} }
f.wizard:applyAdditional(f.record, 61)
T.eq("a saved owned event cannot cause cutover", { f.record.phase, f.link, #f.calls }, { "recovery", gateway, 0 })
T.contains("the saved plan explains how to recover", f.record.message, "Restore the project backup")

T.section("An unverifiable stage after a suite update gives a useful check")
f = fixture()
f.record.phase = "review"
f.wizard.batch.records, f.wizard.batch.token = { f.record }, "staged-before-update"
installed.upgradeRevision = function()
  return revision + 1
end
f.selected = true
local unverified = f.wizard:resume(f.wizard.batch.token)
T.eq("a newer release leaves the original connected", { f.record.phase, f.link, #f.calls }, { "review", gateway, 0 })
T.contains("the installer is directed to check the two drivers", unverified.error, "Check the original and replacement")

T.section("A verified blank legacy stage survives a suite update")
f = fixture()
f.original.bindingsVerified = true
f.settings = settings(62, 750)
f.record.phase = "review"
f.wizard.batch.records, f.wizard.batch.token = { f.record }, "staged-before-update"
installed.upgradeRevision = function()
  return revision + 1
end
f.wizard:resume(f.wizard.batch.token)
T.eq("one Continue carries the approved stage forward and applies it", {
  f.wizard.batch.revision,
  f.record.phase,
  f.link,
}, { revision + 1, "naming", 0 })

T.section("Quick Setup retries the migration list from fresh readiness checks")
do
  local uiPage = require("lib.ui.page")
  local sendPage, inventory = uiPage.send, project.inventory
  local updateRevision = installed.upgradeRevision
  f = fixture()
  local wizard, owner = f.wizard, f.wizard.hub
  owner.switchUpgrade = wizard
  require("ha.switch-upgrade-page").install(function()
    return owner
  end)
  local reply, version, checks, catalogReads, projectReads, lists
  checks, catalogReads, projectReads, lists = 0, 0, 0, 0
  uiPage.send = function(_, data)
    reply = data
  end
  installed.upgradeRevision = function()
    checks = checks + 1
    return version
  end
  owner.catalog.refresh = function(_, force)
    T.truthy("manual Refresh requests a fresh Home Assistant catalog", force)
    catalogReads = catalogReads + 1
    return resolved(true)
  end
  project.inventory = function()
    projectReads = projectReads + 1
    return {}
  end
  owner.installation = {
    prepare = function()
      return resolved({})
    end,
  }
  wizard.list = function(_, _, actual)
    lists = lists + 1
    T.eq("scan uses the rechecked running revision", actual, revision)
    return { { state = "ready" } }
  end
  local function scan()
    UIR.HA_SWITCH_UPGRADE({
      DATA = C4:Base64Encode(JSON:encode({
        request = "readiness",
        action = "scan",
        refresh = true,
      })),
    })
    return reply
  end
  owner.online = false
  T.eq("an offline scan reports a connection wait with no inventory reads", {
    scan().waiting,
    checks,
    catalogReads,
    projectReads,
    lists,
  }, { "home_assistant", 0, 0, 0, 0 })
  owner.online = true
  T.eq("an online scan can report a version wait without reading the catalog", {
    scan().waiting,
    checks,
    catalogReads,
    projectReads,
    lists,
  }, { "driver_versions", 1, 0, 0, 0 })
  version = revision
  T.eq("a fresh scan opens the migration list in the same page", {
    scan().rows[1].state,
    checks,
    catalogReads,
    projectReads,
    lists,
  }, { "ready", 3, 1, 1, 1 })
  uiPage.send, project.inventory, installed.upgradeRevision = sendPage, inventory, updateRevision
end

T.section("A cutover waits for the exact durable gateway checkpoint")
do
  local key, persist = "HA.SwitchUpgrade.v1", require("lib.persist")
  local nativeTimer, timers = C4.SetTimer, {}
  function C4:SetTimer(delay, callback)
    T.eq("checkpoint retry uses the bounded readback interval", delay, 125)
    timers[#timers + 1] = callback
    return true
  end
  f = fixture("switch")
  f.wizard.batch.records, f.wizard.batch.token = { f.record }, "gateway-checkpoint"
  f.wizard.save, f.wizard.confirmCutover = nil, nil
  ShimPersistLater(false)
  f.wizard:save()
  ShimPersistLater(true)
  f.wizard:run()
  T.eq("a cached cutover cannot release the old gateway", {
    codec.storedObject(C4:PersistGetValue(key, true)).records[1].phase,
    f.link,
    f.selected,
  }, { "prepared", gateway })
  ShimPersistLand()
  local actual = C4:PersistGetValue(key, true)
  local readPersist = C4.PersistGetValue
  for _, field in ipairs({ "token", "destination", "source", "scene attempt" }) do
    local mismatched = codec.storedObject(actual)
    if field == "token" then
      mismatched.token = "another-operation"
    elseif field == "destination" then
      mismatched.records[1].destination = 66
    elseif field == "source" then
      mismatched.records[1].source.id = 66
    else
      mismatched.records[1].sceneRemovalAttempt = 1
    end
    function C4:PersistGetValue(name, encrypted)
      return name == key and codec.encode(mismatched) or readPersist(self, name, encrypted)
    end
    table.remove(timers, 1)()
    T.eq("a different " .. field .. " cannot release the old gateway", { f.link, f.selected }, { gateway })
  end
  C4.PersistGetValue = readPersist
  table.remove(timers, 1)()
  T.eq(
    "the exact persisted cutover permits release and naming",
    { f.link, f.selected, f.record.phase },
    { 0, true, "naming" }
  )
  ShimPersistLater(false)
  persist:delete(key)
  C4.SetTimer = nativeTimer
end

T.section("The scene checkpoint distinguishes an older attempt from a changed plan")
do
  local key, intentKey = "HA.SwitchUpgrade.v1", "HA.SwitchUpgrade.SceneRemoval.v1.1"
  local persist, log = require("lib.persist"), require("lib.logging")
  local trace, setTimer = log.trace, C4.SetTimer
  local messages, pending = {}, {}
  function log:trace(message, ...)
    if message:find("Scene migration removal checkpoint", 1, true) == 1 then
      messages[#messages + 1] = message:format(...)
    end
  end
  function C4:SetTimer(_, callback)
    pending[#pending + 1] = callback
    return true
  end
  local scenario = fixture()
  local batch = scenario.wizard.batch
  batch.token, batch.records = "synthetic-private-token", { scenario.record }
  scenario.record.phase, scenario.record.movingScenes, scenario.record.sceneRemovalAttempt = "cutover", true, 2
  local encoded = codec.encode(batch)
  for _, reason in ipairs({
    "saved scene attempt older than the active attempt",
    "saved scene settings differ",
    "saved migration batch differs",
  }) do
    messages = {}
    local durable = codec.storedObject(encoded)
    if reason == "saved scene attempt older than the active attempt" then
      durable.records[1].sceneRemovalAttempt = 1
    elseif reason == "saved scene settings differ" then
      durable.records[1].source.lighting.version = 1
    else
      durable.token = "different-synthetic-token"
    end
    persist:set(key, codec.encode(durable), true)
    local failure
    scenario.wizard:checkpointSceneRemoval(scenario.record):next(nil, function(problem)
      failure = problem.reason
    end)
    while #pending > 0 do
      table.remove(pending, 1)()
    end
    T.eq("a rejected plan never writes removal intent", { failure, C4:PersistGetValue(intentKey, true) }, {
      "scene_checkpoint_unavailable",
    })
    T.eq("a repeated failure emits its reason at the first and last check", messages, {
      "Scene migration removal checkpoint check 1: " .. reason,
      "Scene migration removal checkpoint unavailable after 17 checks: " .. reason,
    })
  end
  log.trace, C4.SetTimer = trace, setTimer
  persist:delete(key)
end

T.section("A prior update warning can be rechecked before a scene move")
do
  local GetProjectItems, SendUIRequest, SetTimer = C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer
  local persist = require("lib.persist")
  local page = require("lib.ui.page")
  local pending = {}
  local members = { [0] = { [52] = true }, [1] = { [52] = true, [62] = true } }
  local offScene, stagedLevel, stagedRate, stagedColorRate, siblingCoordinates
  f = fixture()
  f.original.bindingsVerified = true
  f.record.sceneAttempted = revision
  f.record.phase = "recovery"
  f.record.message = "The drivers were updated during migration. Restore the project backup before starting again."
  local function sceneXml(id)
    local loads = {}
    for device in pairs(members[id]) do
      local level = id == offScene and (device == 62 and stagedLevel or 0) or 100
      local rate = id == offScene and device == 62 and stagedRate or 750
      local colorRate = id == offScene and device == 62 and stagedColorRate or 1000
      local x = device == 62 and "0.34" or device == 63 and siblingCoordinates and "0.31" or "0"
      local y = device == 62 and "0.37" or device == 63 and siblingCoordinates and "0.32" or "0"
      loads[#loads + 1] = (
        "<AdvSceneMember><device_id>%d</device_id><track_color_tracking>0</track_color_tracking>"
        .. "<track_color_x>%s</track_color_x><track_color_y>%s</track_color_y><all_elements><element>"
        .. "<level>%d</level><levelPresetID>%d</levelPresetID><levelRate>%d</levelRate>"
        .. "<colorRate>%d</colorRate><colorEnabled>False</colorEnabled>"
        .. "</element></all_elements></AdvSceneMember>"
      ):format(device, x, y, level, level == 0 and 0 or 1, rate, colorRate)
    end
    return ("<AdvScene><scene_id>%d</scene_id><name>Scene %d</name><all_members>%s</all_members>" .. "</AdvScene>"):format(
      id,
      id,
      table.concat(loads)
    )
  end
  local function snapshot()
    return "<systemitems><item><id>30</id><c4i>control4_agent_adv_lighting.c4i</c4i><state>"
      .. XMLEncode("<State><all_scenes>" .. sceneXml(0) .. sceneXml(1) .. "</all_scenes></State>")
      .. "</state></item></systemitems>"
  end
  local function lightingState()
    local scenes, saved = lighting.scenes(snapshot(), { [52] = true, [62] = true })
    return { version = 2, scenes = scenes, groups = {}, members = { scenes = saved, groups = {} } }
  end
  members[1][62] = nil
  f.original.lighting = lighting.checkpoint(lightingState())
  members[1][62] = true
  f.wizard.save = nil
  f.wizard.notify = function() end
  f.wizard.batch.records, f.wizard.batch.token = { f.record }, "scene-recovery"
  lighting.read = lightingState
  function C4:GetProjectItems()
    return snapshot()
  end
  function C4:SetTimer(_, callback)
    local timer = { Cancel = function() end }
    pending[#pending + 1] = function()
      callback(timer)
    end
    return timer
  end
  local sceneUnavailable
  function C4:SendUIRequest(_, command, params)
    if command == "GET_SCENE" then
      return not sceneUnavailable and sceneXml(params.SCENE_ID) or ""
    end
    local scene = members[params.SCENE_ID]
    if command == "ADD_MEMBERS" then
      scene[62] = true
    elseif params.SCENE_ID == 0 or params.MEMBER_ID == 62 then
      scene[params.MEMBER_ID] = nil
    end
    return ""
  end
  installed.upgradeRevision = function()
    return revision + 1
  end
  f.wizard:save()
  T.eq("opening a prior blanket warning offers verification", f.wizard:state().rows[1].state, "release_recheck")
  sceneUnavailable = true
  local unavailable = f.wizard:resume("scene-recovery")
  T.contains("an unreadable scene leaves the recheck available", unavailable.error, "check the scene members")
  T.eq("a failed read cannot change the saved stage", f.wizard:state().rows[1].state, "release_recheck")
  sceneUnavailable = false
  T.eq("an explicit check reopens the saved stage with the newer release", {
    f.wizard:resume("scene-recovery").rows[1].state,
    f.wizard.batch.revision,
    f.link,
    members[0][62],
    members[1][52],
    #f.calls,
  }, { "prepared", revision + 1, gateway, nil, true, 0 })

  T.section("An interrupted scene transfer requires backup recovery")
  ShimPersistLater(true)
  f.wizard:resume("scene-recovery")
  for _ = 1, 5 do
    table.remove(pending, 1)()
  end
  T.eq(
    "before the checkpoint lands both original scene members remain",
    { members[0][52], members[1][52] },
    { true, true }
  )
  ShimPersistLand()
  table.remove(pending, 1)()
  T.eq("the full cutover write alone cannot authorize original deletion", { members[0][52], members[1][52] }, {
    true,
    true,
  })
  ShimPersistLand()
  table.remove(pending, 1)()
  persist._persist["HA.SwitchUpgrade.v1"] = nil
  local reopened = Upgrade.new(f.wizard.hub, function() end)
  T.eq("reopening during the partial move shows recovery", reopened:state().rows[1].state, "recovery")
  T.contains(
    "Continue cannot repeat an interrupted move",
    reopened:resume("scene-recovery").error,
    "Restore the project backup"
  )
  local readPersist = C4.PersistGetValue
  function C4:PersistGetValue(key, encrypted)
    if key == "HA.SwitchUpgrade.SceneRemoval.v1.1" then
      error("simulated Director storage read failure")
    end
    return readPersist(self, key, encrypted)
  end
  T.eq("an unreadable removal intent keeps a cold wizard in recovery", {
    Upgrade.new(f.wizard.hub, function() end):state().rows[1].state,
    Upgrade.releaseBlocked(),
  }, { "recovery", true })
  C4.PersistGetValue = readPersist
  while #pending > 0 do
    table.remove(pending, 1)()
  end
  T.eq("the rejected removal keeps the working replacement connected and in both scenes", {
    f.record.phase,
    f.link,
    members[0][62],
    members[1][62],
  }, { "recovery", 0, true, true })
  T.eq("the current release does not offer a recheck of the partial move", f.wizard:state().rows[1].state, "recovery")
  installed.upgradeRevision = function()
    return revision + 2
  end
  T.contains(
    "a newer release still refuses to resume a partial move",
    f.wizard:resume("scene-recovery").error,
    "Restore the project backup"
  )
  T.eq("the failed recheck preserves scene membership and replacement control", {
    members[0][52],
    members[0][62],
    members[1][52],
    members[1][62],
    f.link,
  }, { nil, true, true, true, 0 })
  ShimPersistLater(false)
  persist:delete("HA.SwitchUpgrade.v1")

  T.section("Quick Setup resumes an interrupted two-scene migration after an update")
  local sendPage = page.send
  local log = require("lib.logging")
  local savedPrint, rename, displayName = print, RenameDevice, C4.GetDeviceDisplayName
  local readPersist = C4.PersistGetValue
  local intentKey = "HA.SwitchUpgrade.SceneRemoval.v1.1"
  local modes = {
    "absent",
    "earlier_cutover",
    "reusable",
    "changed",
    "checkpoint",
    "lost_feedback",
    "lost_feedback_staged",
    "changed_journal",
    "old_recovery",
    "moved_recovery",
  }
  for _, stagedOff in ipairs(modes) do
    siblingCoordinates = nil
    local movedRecovery = stagedOff == "moved_recovery"
    local existingAddition = stagedOff == "lost_feedback_staged"
    local lostFeedback = stagedOff == "lost_feedback" or existingAddition
    local checkpointUnavailable = stagedOff == "checkpoint" or stagedOff == "changed_journal" or lostFeedback
    local missingStage = stagedOff == "absent"
      or checkpointUnavailable and not existingAddition
      or stagedOff == "old_recovery"
    local receipts, operations = {}, {}
    local gatewayCheckpoint
    members = { [0] = { [52] = true, [63] = true }, [1] = { [52] = true, [63] = true } }
    offScene, stagedLevel, stagedRate, stagedColorRate = 1, 100, stagedOff == "changed" and 500 or 750, 1000
    f = fixture()
    f.original.bindingsVerified = true
    f.original.lighting = lighting.checkpoint(lightingState())
    members[1][62] = not missingStage or nil
    if movedRecovery then
      members[0][52], members[0][62], members[1][52] = nil, true, nil
      stagedLevel, stagedColorRate = 0, 750
      siblingCoordinates = true
    end
    local staleSnapshot = snapshot()
    function C4:GetProjectItems()
      return staleSnapshot
    end
    f.record.phase, f.record.lightingReview, f.record.sceneAttempted = "review", true, revision
    if stagedOff == "old_recovery" then
      f.record.phase, f.record.lightingReview = "recovery", nil
      f.record.message =
        "Quick Setup could not finish moving the lighting scenes and switching control to the new driver. Restore the project backup before continuing."
    elseif movedRecovery then
      f.record.phase, f.record.lightingReview = "recovery", nil
      f.record.message =
        "The original Home Assistant connection was restored. Restore the project backup to undo any reference changes."
    end
    f.wizard.batch.records, f.wizard.batch.token = { f.record }, "resume-scenes"
    f.wizard.save = nil
    f.wizard.notify = function() end
    if stagedOff == "earlier_cutover" then
      local unbind = C4.Unbind
      function C4:Unbind(id, ...)
        if id == f.original.id then
          gatewayCheckpoint = readPersist(self, "HA.SwitchUpgrade.v1", true)
        end
        return unbind(self, id, ...)
      end
      function C4:PersistGetValue(key, encrypted)
        if
          key == "HA.SwitchUpgrade.v1"
          and encrypted
          and gatewayCheckpoint
          and f.link == 0
          and (members[0][52] or members[1][52])
        then
          -- Director can return decoded tables whose empty maps have no JSON type.
          return JSON:decode(gatewayCheckpoint)
        end
        return readPersist(self, key, encrypted)
      end
    end
    f.wizard.hub.catalog.refresh = function(_, force)
      T.eq("continuing refreshes Home Assistant evidence", force, true)
      return resolved(true)
    end
    installed.upgradeRevision = function()
      return revision + 1
    end
    lighting.read = readLighting
    function C4:SendUIRequest(_, command, params)
      if command == "GET_SCENE" then
        -- Native scene readback includes inactive color fields absent from the saved project XML.
        return (
          sceneXml(params.SCENE_ID):gsub(
            "</element>",
            "<colorHue>110</colorHue><colorSaturation>35</colorSaturation>"
              .. "<colorTemperature>3200</colorTemperature></element>"
          )
        )
      end
      local scene = members[params.SCENE_ID]
      operations[#operations + 1] = { command, params.SCENE_ID }
      if command == "ADD_MEMBERS" then
        T.falsy("only the scene without a replacement gets an addition", scene[62])
        scene[62] = true
      elseif command == "EDIT_ELEMENT" then
        T.eq("Off is written to the staged member with its saved brightness fade", {
          params.MEMBER_ID,
          tonumber(params.level),
          tonumber(params.level_rate),
          f.link,
        }, { 62, 0, 750, 0 })
        -- A native read can lag the command. Director generates the Off preset
        -- and can copy the active brightness fade into the disabled color fade.
        pending[#pending + 1] = function()
          stagedLevel, stagedColorRate = 0, 750
        end
      elseif command == "DELETE_MEMBER" then
        if checkpointUnavailable then
          T.eq("a failed checkpoint can remove only a staged replacement", params.MEMBER_ID, 62)
          scene[params.MEMBER_ID] = nil
          return ""
        end
        T.eq(
          "both scenes must be staged and Off verified before an original is removed",
          { members[0][62], members[1][62], stagedLevel, f.link, f.selected },
          { true, true, 0, 0, true }
        )
        local saved = codec.storedObject(PersistGetValue("HA.SwitchUpgrade.v1", true))
        local intent = codec.storedObject(C4:PersistGetValue(intentKey, true))
        local phase = saved.records[1].phase
        T.truthy(
          "the full journal keeps the approved stage before the first delete",
          saved.records[1].movingScenes == true
            and (phase == "cutover" or phase == "scene_transfer" or stagedOff == "absent" and phase == "review")
        )
        T.eq("the removal intent is durable before the first delete", intent, {
          token = saved.token,
          revision = saved.revision,
          source = saved.records[1].source.id,
          destination = saved.records[1].destination,
          attempt = saved.records[1].sceneRemovalAttempt,
        })
        if stagedOff == "earlier_cutover" then
          persist._persist["HA.SwitchUpgrade.v1"] = nil
        end
        T.eq("a new wizard restores the destructive phase independently of the full journal", {
          Upgrade.new(f.wizard.hub, function() end):state().rows[1].state,
          Upgrade.releaseBlocked(),
        }, { "recovery", true })
        scene[params.MEMBER_ID] = nil
      end
      return ""
    end
    local owner, savedWizard = f.wizard.hub, f.wizard
    savedWizard:save()
    if stagedOff ~= "earlier_cutover" then
      require("c4_fixtures").coldStoredObject("HA.SwitchUpgrade.v1")
    end
    require("ha.switch-upgrade-page").install(function()
      return owner
    end)
    page.send = function(command, result)
      receipts[command] = result
    end
    local function request(action)
      UIR.HA_SWITCH_UPGRADE({
        DATA = C4:Base64Encode(JSON:encode({ request = action, action = action, token = "resume-scenes" })),
      })
      return receipts.HA_SWITCH_UPGRADE_REPLY
    end
    local GetDeviceID = C4.GetDeviceID
    function C4:GetDeviceID()
      return coordinator
    end
    local initial = request("status")
    C4.GetDeviceID = GetDeviceID
    f.wizard = owner.switchUpgrade
    T.eq("the opened driver reloads the approved batch at its saved revision", {
      f.wizard.batch.token,
      f.wizard.batch.revision,
    }, { "resume-scenes", revision })
    for _, method in ipairs({ "checkOwnership", "bindReplacement", "waitReady", "finishRecordNames" }) do
      f.wizard[method] = savedWizard[method]
    end
    local lines = {}
    if stagedOff == "absent" then
      f.wizard.waitReady, f.wizard.finishRecordNames = nil, nil
      local readOriginal, originalName = assess.assess, f.original.name
      assess.assess = function(...)
        local live = readOriginal(...)
        live.name = originalName
        return live
      end
      RenameDevice = function(id, name)
        if id == 52 then
          originalName = name
        else
          f.replacement.name = name
        end
      end
      function C4:GetDeviceDisplayName(id)
        return id == 52 and originalName or f.replacement.name
      end
      print = function(line, ...)
        if type(line) == "string" and line:find("[TRACE]", 1, true) then
          lines[#lines + 1] = line
        else
          savedPrint(line, ...)
        end
      end
      log:setLogMode("Print")
      log:setLogLevel("5 - Trace")
    end
    if stagedOff == "old_recovery" or movedRecovery then
      T.eq(
        "the updated release offers to verify the previously failed migration",
        initial.rows[1].state,
        "release_recheck"
      )
    else
      T.contains(
        "the saved newer build directs the installer to Continue",
        initial.rows[1].message,
        "Continue migration"
      )
    end
    T.falsy(
      "Quick Setup hides the earlier manual instructions while a new check is available",
      initial.rows[1].lightingReview
    )
    local saved = codec.storedObject(PersistGetValue("HA.SwitchUpgrade.v1", true))
    T.eq("opening Quick Setup leaves the saved review, scenes, and control unchanged", {
      saved.records[1].lightingReview,
      #operations,
      #f.calls,
    }, { stagedOff ~= "old_recovery" and not movedRecovery and true or nil, 0, 0 })
    local previousIntent
    if stagedOff == "changed_journal" then
      previousIntent = codec.encode({ token = "earlier-migration", revision = revision, source = 53, destination = 64 })
      C4:PersistSetValue(intentKey, previousIntent, true)
    end
    if checkpointUnavailable or stagedOff == "absent" then
      function C4:PersistGetValue(key, encrypted)
        local value = readPersist(self, key, encrypted)
        if stagedOff == "checkpoint" and key == intentKey then
          return nil
        end
        if lostFeedback and key == intentKey and value then
          f.ready = false
        end
        if stagedOff == "changed_journal" and key == "HA.SwitchUpgrade.v1" and f.link == 0 then
          local stored = codec.storedObject(value)
          if stored and stored.records[1].movingScenes then
            stored.records[1].source.lighting.version = 1
            return codec.encode(stored)
          end
        elseif stagedOff == "absent" and key == "HA.SwitchUpgrade.v1" and f.link == 0 then
          local stored = codec.storedObject(value)
          if stored and stored.records[1].movingScenes then
            -- Director can read back an earlier version of the full batch at the removal boundary.
            -- The previously approved scene plan is still intact.
            stored.records[1].phase, stored.records[1].message = "review", "Earlier saved checkpoint"
            return codec.encode(stored)
          end
        end
        return value
      end
    end
    if movedRecovery then
      stagedRate = 500
      T.contains(
        "changed lighting cannot authorize a cutover retry",
        request("resume").error,
        "check the scene members"
      )
      T.eq(
        "rejecting changed lighting touches neither scenes nor control",
        { #operations, #f.calls, f.link },
        { 0, 0, gateway }
      )
      stagedRate = 750
    end
    if stagedOff == "changed_journal" then
      metrics:reset()
      metrics:setEnabled(true)
    end
    request("resume")
    while #pending > 0 do
      table.remove(pending, 1)()
    end
    if stagedOff == "changed_journal" then
      T.eq("a rejected scene checkpoint is reported as a rejected cutover", {
        metrics:report().operations["migration.cutover"].outcomes,
        metrics:report().operations["migration.restore"].outcomes,
      }, { { rejected = 1 }, { ok = 1 } })
      metrics:setEnabled(false)
      metrics:reset()
    end
    local final = request("status")
    if movedRecovery then
      T.eq(
        "the recovery recognizes moved scenes despite inactive sibling coordinate drift",
        final.rows[1].state,
        "prepared"
      )
      T.contains("retry copy confirms the scenes already use the new driver", final.rows[1].message, "already use")
      T.eq("the saved migration check only reads scenes and bindings", { #operations, #f.calls }, { 0, 0 })
      local journal = assert(codec.storedObject(C4:PersistGetValue("HA.SwitchUpgrade.v1", true)))
      local recoveryRow = journal.records[1]
      C4:PersistSetValue(
        intentKey,
        codec.encode({
          token = journal.token,
          revision = journal.revision,
          source = recoveryRow.source.id,
          destination = recoveryRow.destination,
        }),
        true
      )
      T.eq("a successful recheck records that the scenes are already moved", recoveryRow.sceneMoveVerified, true)
      -- Model a saved recheck from before the explicit verification flag existed.
      recoveryRow.sceneMoveVerified = nil
      C4:PersistSetValue("HA.SwitchUpgrade.v1", codec.encode(journal), true)
      owner.switchUpgrade = nil
      persist._persist["HA.SwitchUpgrade.v1"] = nil
      C4.GetDeviceID = function()
        return coordinator
      end
      local refreshed = request("status")
      C4.GetDeviceID = GetDeviceID
      T.eq(
        "refresh with a retained intent keeps Continue available after the recheck",
        refreshed.rows[1].state,
        "prepared"
      )
      f.wizard = owner.switchUpgrade
      for _, method in ipairs({ "checkOwnership", "bindReplacement", "waitReady", "finishRecordNames" }) do
        f.wizard[method] = savedWizard[method]
      end
      local directLoad, trace = f.wizard.hub.transfer.directLoad, log.trace
      function f.wizard.hub.transfer:directLoad()
        T.eq("an unclaimed selection leaves the original gateway bound", f.link, gateway)
        local failure = deferred.new()
        failure:reject({ kind = "timeout", step = "offered" })
        return failure
      end
      request("resume")
      local failedCheck
      log.trace = function(_, format, value)
        if format == "Legacy migration saved cutover failure: %s" then
          failedCheck = value
        end
      end
      owner.switchUpgrade = nil
      require("c4_fixtures").coldStoredObject("HA.SwitchUpgrade.v1")
      C4.GetDeviceID = function()
        return coordinator
      end
      local afterFailure = request("status")
      C4.GetDeviceID, log.trace = GetDeviceID, trace
      T.eq(
        "refresh reads the saved failure after reloading the journal",
        failedCheck,
        "send replacement selection: timeout (offered)"
      )
      T.eq(
        "a subsequent failure can be checked again on the same release",
        { afterFailure.rows[1].state, f.link, #operations },
        {
          "release_recheck",
          gateway,
          0,
        }
      )
      f.wizard = owner.switchUpgrade
      for _, method in ipairs({ "checkOwnership", "bindReplacement", "waitReady", "finishRecordNames" }) do
        f.wizard[method] = savedWizard[method]
      end
      f.wizard.hub.transfer.directLoad = directLoad
      request("resume")
      request("resume")
      final = request("status")
    end
    if checkpointUnavailable or stagedOff == "old_recovery" then
      T.eq(
        "verified original scenes are eligible for another attempt",
        final.rows[1].state,
        checkpointUnavailable and "attention" or "prepared"
      )
      T.contains(
        "the installer sees the next action",
        final.rows[1].message,
        checkpointUnavailable and "Retry driver setup" or "Continue migration"
      )
      T.eq("the original connection and exact scene membership are preserved before retry", { f.link, members }, {
        gateway,
        {
          [0] = { [52] = true, [63] = true },
          [1] = { [52] = true, [62] = existingAddition or nil, [63] = true },
        },
      })
      if checkpointUnavailable then
        T.eq("only additions made by this attempt are cleaned up", operations, existingAddition and {
          { "ADD_MEMBERS", 0 },
          { "EDIT_ELEMENT", 1 },
          { "DELETE_MEMBER", 0 },
        } or {
          { "ADD_MEMBERS", 0 },
          { "ADD_MEMBERS", 1 },
          { "EDIT_ELEMENT", 1 },
          { "DELETE_MEMBER", 0 },
          { "DELETE_MEMBER", 1 },
        })
        T.eq(
          "cleanup retains an attempt only if a staged addition remains",
          not not f.wizard.batch.records[1].sceneAttempted,
          existingAddition
        )
        C4.PersistGetValue = readPersist
        T.eq(
          "verified cleanup clears only the removal intent written for this attempt",
          C4:PersistGetValue(intentKey, true),
          previousIntent
        )
        checkpointUnavailable, f.ready = false, true
        if not existingAddition then
          stagedLevel, stagedColorRate = 100, 1000
        end
        operations = {}
      else
        T.eq("the saved migration check only reads scenes and bindings", { #operations, #f.calls }, { 0, 0 })
      end
      request("resume")
      while #pending > 0 do
        table.remove(pending, 1)()
      end
      final = request("status")
    end
    if stagedOff == "absent" then
      log:setLogMode("Off")
      log:setLogLevel("3 - Info")
      print, RenameDevice, C4.GetDeviceDisplayName = savedPrint, rename, displayName
      local trace = table.concat(lines, "\n")
      local position = 1
      for _, message in ipairs({
        "Scene 1 saved-stage check: original membership verified",
        "Scene 2 saved-stage check: original membership verified",
        "saved stage verified on the updated release",
        "cutover checkpoint saved",
        "replacement selection accepted",
        "replacement feedback verified",
        "Scene 1 ADD_MEMBERS readback: verified",
        "Scene 2 EDIT_ELEMENT readback: verified",
        "Scene migration removal checkpoint verified after 1 checks",
        "Scene 2 remove original member readback: verified",
        "Scene migration verified",
        "Lighting comparison: current references verified",
        "cutover verified. Applying driver names.",
        "Ready for testing.",
        "run finished in phase upgraded",
      }) do
        local reached = trace:find(message, position, true)
        T.truthy("trace reaches " .. message, reached)
        position = reached and reached + #message or position
      end
    end
    if stagedOff == "changed" then
      T.truthy("an unrelated fade difference falls back to Composer guidance", final.rows[1].lightingReview)
      T.eq("the fallback changes neither scene nor control", { #operations, #f.calls, f.link }, { 0, 0, gateway })
    else
      local expected = { { "ADD_MEMBERS", 0 }, { "EDIT_ELEMENT", 1 }, { "DELETE_MEMBER", 0 }, { "DELETE_MEMBER", 1 } }
      if missingStage then
        table.insert(expected, 2, { "ADD_MEMBERS", 1 })
      elseif existingAddition then
        table.remove(expected, 2)
      elseif movedRecovery then
        expected = {}
      end
      T.eq("the operation stages both replacements, verifies Off, then removes both originals", operations, expected)
      T.eq("the final scene selections and original sibling memberships are correct", members, {
        [0] = { [62] = true, [63] = true },
        [1] = { [62] = true, [63] = true },
      })
      if stagedOff == "absent" then
        T.eq("one Continue moves selection and finishes naming after feedback", {
          final.rows[1].state,
          f.link,
          f.selected,
          f.replacement.name,
        }, { "upgraded", 0, true, f.original.name })
      else
        T.eq("one Continue moves selection and reaches naming after feedback", {
          final.rows[1].state,
          f.link,
          f.selected,
          f.calls[#f.calls],
        }, { "naming", 0, true, "verify names" })
      end
      request("resume")
      T.eq("another Continue cannot replay scene writes", #operations, #expected)
    end
    C4.PersistGetValue = readPersist
    persist:delete("HA.SwitchUpgrade.v1")
    persist:delete(intentKey)
  end
  page.send = sendPage
  C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer = GetProjectItems, SendUIRequest, SetTimer
end

T.section("Programming the wizard cannot verify is blocked before staging")
do
  local sources, snapshot, inventory = assess.sources, assess.programmingSnapshot, project.inventory
  local scenario = fixture()
  scenario.original.name = "Legacy Light"
  scenario.wizard.hub.catalog.exactLoadChoice = function()
    return { name = "Lamp" }
  end
  assess.sources = function(_, includeAdditional)
    return includeAdditional and { { id = 51, origin = "Legacy HA" } } or {}
  end
  assess.programmingSnapshot = function()
    return {}
  end
  project.inventory = function()
    return {}
  end
  scenario.originalPrograms = { readable = true, attached = { { device = 51, event = 2 } }, incoming = {} }
  local rows = scenario.wizard:list()
  T.eq("an owned event is blocked at discovery", rows[1].state, "blocked")
  T.contains("the row names the specific blocked event", rows[1].message, "Event 2")
  scenario.originalPrograms = incoming("TurnOff", 2)
  scenario.originalPrograms.incoming[1].positions = {}
  rows = scenario.wizard:list()
  T.eq("an unmapped incoming action is also blocked", rows[1].state, "blocked")
  assess.sources, assess.programmingSnapshot, project.inventory = sources, snapshot, inventory
end

T.section("The approved Home Assistant identity is required before writes")
f = fixture()
f.originalOrigin = "https://other.test:443"
f.wizard:applyAdditional(f.record, 61)
T.eq("a matching entity on a different installation stays on the old driver", { f.record.phase, f.link, #f.calls }, {
  "attention",
  gateway,
  0,
})
f = fixture()
f.record.endpoint.registry, f.registry = string.rep("a", 32), string.rep("b", 32)
f.wizard:applyAdditional(f.record, 61)
T.eq("a changed registry identity stays on the old driver", { f.record.phase, f.link, #f.calls }, {
  "attention",
  gateway,
  0,
})
f = fixture()
f.originalOrigin = nil
f.wizard:applyAdditional(f.record, 61)
T.eq("an unverified source stays attached", { f.record.phase, f.link, #f.calls }, { "attention", gateway, 0 })
f = fixture()
f.settings = settings(62, 750)
f.wizard.batch.records = { f.record }
local stateRead = deferred.new()
f.wizard.hub.connection.readState = function()
  return stateRead
end
f.wizard:run()
f.originalOrigin = "https://ha.test:8444"
stateRead:resolve(codec.object({ entity_id = f.original.entity, state = "off", attributes = codec.object({}) }))
T.eq("an endpoint change during the state read prevents cutover", { f.link, #f.calls }, { gateway, 0 })

T.section("Legacy routing proof is checked again before and after control transfers")
do
  local http = require("lib.http")
  local get, inventory = http.get, project.inventory
  local nonce, proof = string.rep("b", 32), string.rep("a", 64)
  local function scenario(route, alternate)
    local current = fixture()
    current.settings = settings(62, 750)
    current.originalOrigin = route
    current.record.endpoint.source_origin = route
    current.alternate = alternate
    local hub = current.wizard.hub
    hub.epoch = 2
    hub._request = function(_, message, done)
      assert(message.type == "ha_gesture_bridge/installation_proof")
      done(true, codec.object({ version = 1, nonce = nonce, proof = proof }))
    end
    hub.installation = require("ha.installation-scope").new(hub)
    http.get = function()
      return resolved({
        code = 200,
        body = codec.encode(codec.object({
          version = 1,
          nonce = nonce,
          proof = current.alternate,
        })),
      })
    end
    project.inventory = function()
      return {}
    end
    current.wizard.batch.records = { current.record }
    return current
  end
  local same = scenario("http://legacy.test:8124", proof)
  same.wizard:run()
  T.eq("a proven alias permits the reviewed cutover across ports", same.record.phase, "naming")
  local separate = scenario("https://other.test:443", string.rep("c", 64))
  separate.wizard:run()
  T.eq(
    "a proven separate installation with the same entity keeps control",
    { separate.link, #separate.calls },
    { gateway, 0 }
  )
  local changing = scenario("https://legacy.test:443", proof)
  changing.afterSelection = function()
    changing.alternate = string.rep("c", 64)
  end
  changing.wizard:run()
  T.eq("a changed route before naming rolls back the replacement", { changing.record.phase, changing.link }, {
    "recovery",
    gateway,
  })
  T.eq("the drift leaves the replacement disconnected", changing.replacement.provider, 0)
  http.get, project.inventory = get, inventory
end

T.section("Drift while awaiting feedback runs recovery before any renames")
f = fixture()
f.settings = settings(62, 750)
f.afterSelection = function()
  f.programs = incoming("Turn On", 2)
end
f.wizard.batch.records = { f.record }
f.wizard:run()
T.eq("moved scene references require a recheck after restoring the original", f.record.phase, "recovery")
T.eq("the original connection is restored", f.link, gateway)
T.eq("the last call releases the replacement without renaming", f.calls[#f.calls], "release replacement")

T.section("A duplicate owner cannot release the original")
f = fixture()
f.duplicate, f.settings = true, settings(62, 750)
f.wizard:applyAdditional(f.record, 61)
T.eq("late duplicate detection protects the original", f.link, gateway)
T.eq("the replacement remains disconnected", f.replacement.provider, 0)

T.section("Unmapped brightness, white-temperature and hue links keep the original in place")
for _, binding in ipairs({ 81, 82, 83, 86, 87, 88, 91, 92, 93 }) do
  f = fixture()
  f.settings = settings(62, 750)
  f.original.edges = {
    { owner = 51, binding = binding, direction = "output", device = 77, port = 1, class = "BUTTON_LINK" },
  }
  f.wizard.batch.records = { f.record }
  f.record.mappedConnections = nil
  f.wizard:applyAdditional(f.record, 61)
  local status = f.wizard:state()
  T.eq(
    "link " .. binding .. " stays in review with the original connected",
    { f.record.phase, f.link },
    { "review", gateway }
  )
  T.truthy("link " .. binding .. " remains visible", status.rows[1].unresolvedConnections)
  T.falsy("link " .. binding .. " cannot proceed to removal", status.canReviewRemoval)
  T.contains("the review points to Composer connections", f.record.message, "Composer")
  T.eq("no cutover command is sent while the link is unresolved", #f.calls, 0)
end

T.section("Recovery restores the original gateway before requesting project restoration")
f = fixture()
f.link, f.replacement.provider = 0, coordinator
T.truthy("the original connection can be restored", f.wizard:restoreControl(f.record))
T.eq("recovery restores the exact original gateway and port", f.restoredBinding, { gateway, 5, 51, 5 })
T.eq(
  "the replacement releases authority before reattaching the old device",
  { f.calls[1], f.link },
  { "release replacement", gateway }
)
T.eq("a verified rollback before scene edits can retry", f.record.phase, "attention")

T.section("A relay restore failure leaves the original gateway connected")
do
  local scenario = fixture()
  scenario.link, scenario.replacement.provider = 0, coordinator
  scenario.record.relayStarted = true
  local relays = require("ha.migration-relays")
  local canRestore = relays.canRestore
  relays.canRestore = function()
    return false
  end
  local restored = scenario.wizard:restoreControl(scenario.record)
  relays.canRestore = canRestore
  T.eq("relay failure remains visible after restoring the original connection", {
    restored,
    scenario.link,
    scenario.replacement.provider,
    scenario.record.phase,
  }, { false, gateway, 0, "recovery" })
end

T.section("A failed initial save leaves migration retryable")
do
  local scenario = fixture()
  scenario.wizard.batch.records = { scenario.record }
  scenario.wizard.save = function()
    error("fixture save failure")
  end
  local result = scenario.wizard:run()
  T.contains("the start reports a save failure", result.error, "Could not save migration progress")
  T.eq("failed save clears the running projection", scenario.wizard:state().running, false)
  T.eq("failed save does not change either binding", #scenario.calls, 0)
end

T.section("Retry adopts only the exact saved replacement selection and settings")
for _, matchingSettings in ipairs({ true, false }) do
  f = colorLight()
  f.settings = { version = 2, scenes = {}, groups = {}, members = { scenes = {}, groups = {} } }
  f.original.lighting = lighting.checkpoint(f.settings)
  f.link, f.replacement.provider, f.selected = 0, coordinator, true
  f.settingsVerified = matchingSettings
  f.record.phase = "cutover"
  f.wizard.batch.records = { f.record }
  T.truthy("a failed first attempt can reconnect the original gateway", f.wizard:restoreControl(f.record))
  f.calls = {}
  if matchingSettings then
    T.eq(
      "verified detached selection is eligible for retry",
      { f.record.phase, f.record.resumeSelection },
      { "attention", true }
    )
    f.wizard:run()
    T.eq("retry reuses the exact selection without commissioner apply", { f.record.phase, f.link, f.calls }, {
      "naming",
      0,
      { "read HA", "release old", "bind replacement", "read feedback", "verify names" },
    })
  else
    T.eq("different stored settings cannot give control back to the replacement", {
      f.record.phase,
      f.record.resumeSelection,
      f.link,
      f.replacement.provider,
    }, { "recovery", nil, gateway, 0 })
  end
end

T.section("Explicit approval and a saved staged driver are required before proceeding")
f = fixture()
f.record.reviewedLoad = { load = f.original.entity, name = "Lamp" }
local review = { token = "migration-approval", revision = revision, records = { f.record } }
f.wizard.batch, f.wizard.preview = nil, review
f.wizard.list = function()
  return {}, { [f.original.id] = f.record }, revision
end
T.truthy("a preview cannot start without a project backup", f.wizard:start(review.token, false).error)
T.eq("an unapproved migration does not touch the original", #f.calls, 0)
local journal
f.wizard.save = function(self)
  journal = codec.encode(self.batch)
end
f.wizard:start(review.token, true)
T.eq("approval checkpoints the existing staged record", f.record.phase, "review")
f.wizard.batch = codec.storedObject(journal)
T.truthy("a stale page cannot resume the saved batch", f.wizard:resume("previous-approval").error)
f.settings = settings(62, 750)
f.wizard:resume(review.token)
T.eq("resume reuses the saved replacement", f.wizard.batch.records[1].destination, 61)
T.eq("the journal can advance to naming after resume", f.wizard.batch.records[1].phase, "naming")

T.section("Start checks a fresh preview with the shared scene comparison")
do
  local function scene(x)
    local original = "<AdvSceneMember><device_id>52</device_id>"
      .. "<all_elements><element><level>100</level></element></all_elements></AdvSceneMember>"
    local sibling = (
      "<AdvSceneMember><device_id>63</device_id><track_color_tracking>0</track_color_tracking>"
      .. "<track_color_x>%s</track_color_x><track_color_y>0</track_color_y><all_elements><element>"
      .. "<colorEnabled>False</colorEnabled><level>100</level></element></all_elements></AdvSceneMember>"
    ):format(x)
    local sceneXml = "<State><all_scenes><AdvScene><scene_id>0</scene_id><name>Fixture</name><all_members>"
      .. original
      .. sibling
      .. "</all_members></AdvScene></all_scenes></State>"
    local xml = "<systemitems><item><id>30</id><c4i>control4_agent_adv_lighting.c4i</c4i><state>"
      .. XMLEncode(sceneXml)
      .. "</state></item></systemitems>"
    local refs, members = lighting.scenes(xml, { [52] = true })
    return lighting.checkpoint({
      version = 2,
      scenes = refs,
      groups = {},
      members = { scenes = members, groups = {} },
    })
  end
  local scenario = fixture()
  local approved = scenario.record
  approved.source.lighting = scene("0.1")
  local current = codec.storedObject(codec.encode(approved))
  current.source.lighting = scene("0.3")
  scenario.wizard.batch = nil
  scenario.wizard.preview = { token = "review-fixture", revision = revision, records = { approved } }
  scenario.wizard.list = function()
    return {}, { [approved.source.id] = current }, revision
  end
  scenario.wizard.run = function()
    return { started = true }
  end
  current.source.room_id = 98
  T.truthy("a real project change still blocks Start", scenario.wizard:start("review-fixture", true).error)
  current.source.room_id = approved.source.room_id
  T.truthy("equivalent saved scene settings pass Start", scenario.wizard:start("review-fixture", true).started)
  T.eq("Start retains the reviewed snapshot", approved.source.lighting, scene("0.1"))
end

T.section("A moved scene proof survives an unavailable read")
do
  local scenario = fixture()
  scenario.record.sceneMoveVerified = true
  scenario.wizard.batch.records = { scenario.record }
  scenario.settings = { version = 2, scenes = nil, groups = {}, members = { groups = {} } }
  scenario.wizard:applyAdditional(scenario.record, 61)
  T.truthy("a failed read keeps evidence that the scenes were already moved", scenario.record.sceneMoveVerified)
  T.eq("the subsequent explicit check remains available", scenario.wizard:state().rows[1].state, "release_recheck")
  T.eq("an unavailable read causes no scene or gateway writes", { scenario.link, #scenario.calls }, { gateway, 0 })
end

T.section("Feedback retries defer a full-version scan until the replacement is ready")
do
  local scenario = fixture()
  scenario.link, scenario.replacement.provider = 0, coordinator
  local previousTimer, previousVersion = SetTimer, installed.upgradeRevision
  local callback, counts, result = nil, 0, nil
  SetTimer = function(_, _, nextCheck)
    callback = nextCheck
    return true
  end
  installed.upgradeRevision = function(...)
    counts = counts + 1
    return previousVersion(...)
  end
  Upgrade.waitReady(scenario.wizard, scenario.record):next(function(value)
    result = value
  end)
  for _ = 1, 4 do
    callback()
  end
  T.eq("waiting reads the binding and selection without a full version scan", counts, 0)
  scenario.selected = true
  callback()
  T.eq("confirming feedback scans the suite once before advancing", { result, counts }, { true, 1 })
  SetTimer, installed.upgradeRevision = previousTimer, previousVersion
end

T.section("Removal uses current rather than previously verified reference state")
f = fixture()
f.settings, f.selected, f.link = settings(62, 750), true, 0
f.replacement.provider = coordinator
f.record.namesVerified, f.record.phase, f.record.retiredName = true, "upgraded", "Light (old driver 51)"
f.record.source = codec.storedObject(codec.encode(f.original))
f.original.name = f.record.retiredName
f.wizard.batch.records = { f.record }
function C4:GetDevices()
  return f.oldRemoved and {} or { [51] = {} }
end
function C4:GetDeviceDisplayName(id)
  return id == 52 and f.original.name or "Light"
end
T.truthy("old removal requires testing and reference review", reviewRemoval(f.wizard, false, false).error)
local shown = f.wizard:state().removalScope
T.truthy(
  "a different batch cannot inherit testing approval",
  f.wizard:reviewRemoval(true, true, nil, "previous" .. shown).error
)
local destination = f.record.destination
f.record.destination = destination + 1
T.truthy("a changed replacement cannot inherit testing approval", f.wizard:reviewRemoval(true, true, nil, shown).error)
T.eq("stale approval cannot mark any current driver tested", f.record.tested, nil)
f.record.destination = destination
T.eq(
  "an unchanged tested replacement permits separate removal review",
  reviewRemoval(f.wizard, true, true).rows[1].state,
  "ready"
)
f.settings = settings(62, 500)
T.eq("scene edit invalidates existing removal approval", reviewRemoval(f.wizard).rows[1].state, "blocked")
f.settings, f.oldRemoved = settings(62, 750), true
T.eq("actual removal is reported only after readback", reviewRemoval(f.wizard).rows[1].state, "removed")

T.section("Naming and removal carry the proven installation scope")
do
  local inventory, gatewayOrigin = project.inventory, profile.gatewayOrigin
  local otherOrigin = "https://other.test:443"
  local other = {
    id = 90,
    file = "chowmain_homeassistant_switch.c4z",
    legacy = true,
    legacy_provider = 33,
    selected = f.original.entity,
  }
  project.inventory = function()
    return { other }
  end
  profile.gatewayOrigin = function()
    return otherOrigin
  end
  f.oldRemoved = nil
  f.wizard.checkOwnership = nil
  f.wizard.hub.epoch = 7
  f.wizard.hub.catalog.endpointKeys = function(_, entities)
    return { [entities[1]] = true }
  end
  f.wizard.hub.installation = require("ha.installation-scope").new(f.wizard.hub)
  local evidence = { origin = "https://ha.test:443", epoch = 7, routes = { [otherOrigin] = "separate" } }
  f.record.phase, f.record.namesVerified = "naming", nil
  T.falsy("an unscoped duplicate blocks naming", Upgrade.finishRecordNames(f.wizard, f.record))
  T.truthy(
    "a proven separate installation permits naming",
    Upgrade.finishRecordNames(f.wizard, f.record, nil, evidence)
  )
  T.eq(
    "retirement verifies ownership using the same evidence",
    reviewRemoval(f.wizard, true, true, evidence).rows[1].state,
    "ready"
  )
  f.wizard.hub.epoch = 8
  T.eq(
    "stale scope cannot exclude the duplicate",
    reviewRemoval(f.wizard, true, true, evidence).rows[1].state,
    "blocked"
  )
  project.inventory, profile.gatewayOrigin = inventory, gatewayOrigin
end

T.section("Passive diagnostic spans preserve the migration command order")
local originalClock, stamp = metrics.clock, 0
local function monitored(enabled)
  stamp = 0
  local scenario = fixture()
  scenario.settings = settings(62, 750)
  scenario.wizard.batch.records = { scenario.record }
  scenario.wizard.waitReady = function(self, record)
    scenario.selected = false
    return Upgrade.waitReady(self, record)
  end
  local timer, originalSetTimer = nil, SetTimer
  SetTimer = function(name, delay, callback)
    scenario.calls[#scenario.calls + 1] = { name, delay }
    timer = function()
      stamp = stamp + delay
      callback()
    end
    return true
  end
  metrics:setEnabled(enabled)
  scenario.wizard:run()
  T.eq("cutover waits for actual replacement feedback", scenario.record.phase, "cutover")
  scenario.selected, scenario.ready = true, false
  timer()
  T.eq("a retry without feedback leaves cutover pending", scenario.record.phase, "cutover")
  scenario.ready = true
  timer()
  SetTimer = originalSetTimer
  T.eq("confirmed feedback permits naming", scenario.record.phase, "naming")
  return scenario.calls
end
metrics.clock = function()
  return stamp
end
metrics:reset()
T.eq("enabling diagnostics preserves calls and readiness polling", monitored(true), monitored(false))
local report = metrics:report()
metrics.clock = originalClock
T.eq("one stage, dependency and cutover sample was captured", {
  report.operations["migration.stage"].count,
  report.operations["migration.dependencies"].count,
  report.operations["migration.cutover"].count,
}, { 1, 1, 1 })
T.eq("existing polls time selection persistence and feedback separately", {
  report.operations["migration.selection_readback"].p50_ms,
  report.operations["migration.feedback_after_selection"].p50_ms,
  report.operations["migration.feedback"].p50_ms,
}, { 500, 500, 1000 })
T.eq("feedback timing reports both existing 500 ms poll waits", {
  report.operations["migration.feedback_poll_interval"].count,
  report.operations["migration.feedback_poll_interval"].min_ms,
  report.operations["migration.feedback_poll_interval"].max_ms,
}, { 2, 500, 500 })

T.section("Migration evidence timings separate the requests that overlap")
do
  local originalSources = assess.sources
  assess.sources = function()
    return {}
  end
  local function measure(enabled)
    stamp = 0
    local scenario = fixture()
    local hub = scenario.wizard.hub
    local state, preRegistry, postRegistry = deferred.new(), deferred.new(), deferred.new()
    local preInstallation, postInstallation = deferred.new(), deferred.new()
    local registryReads, installationReads = 0, 0
    scenario.settings = settings(62, 750)
    hub.connection.readState = function()
      scenario.calls[#scenario.calls + 1] = "read HA"
      return state
    end
    hub.catalog.verifyLoadRegistry = function()
      registryReads = registryReads + 1
      scenario.calls[#scenario.calls + 1] = "read registry"
      return registryReads == 1 and preRegistry or postRegistry
    end
    hub.installation = {
      relation = function()
        return "same", "https://ha.test:443", "https://ha.test:443"
      end,
      prepare = function()
        installationReads = installationReads + 1
        scenario.calls[#scenario.calls + 1] = "check installation"
        return installationReads == 1 and preInstallation or postInstallation
      end,
    }
    metrics:setEnabled(enabled)
    scenario.wizard:applyAdditional(scenario.record, 61)
    stamp = 30
    preInstallation:resolve({})
    stamp = 40
    preRegistry:resolve(true)
    T.eq("the original remains connected until the state read finishes", scenario.link, gateway)
    stamp = 65
    state:resolve(codec.object({ entity_id = scenario.original.entity, state = "off", attributes = codec.object({}) }))
    stamp = 80
    postInstallation:resolve({})
    T.eq("naming still waits for post-cutover registry readback", scenario.record.phase, "cutover")
    stamp = 100
    postRegistry:resolve(true)
    T.eq("fresh evidence permits naming", scenario.record.phase, "naming")
    return scenario.calls
  end
  local originalMode, originalLevel = Properties["Log Mode"], Properties["Log Level"]
  Properties["Log Mode"], Properties["Log Level"] = "Off", "3 - Info"
  metrics.clock = function()
    return stamp
  end
  metrics:reset()
  local unmeasured = measure(false)
  T.eq("disabled diagnostics collect no samples", next(metrics:report().operations), nil)
  T.eq("diagnostics preserve request and command order", measure(true), unmeasured)
  local operations = metrics:report().operations
  for operation, elapsed in pairs({
    ["migration.preflight_installation"] = 30,
    ["migration.preflight_registry"] = 10,
    ["migration.preflight_state"] = 35,
    ["migration.post_cutover_installation"] = 15,
    ["migration.post_cutover_registry"] = 35,
  }) do
    local result = operations[operation]
    T.eq(operation .. " measures its own wait once", {
      result and result.count,
      result and result.p50_ms,
      result and result.p95_ms,
      result and result.logging,
    }, { 1, elapsed, elapsed, { ["Off/3"] = 1 } })
  end
  Properties["Log Mode"], Properties["Log Level"] = originalMode, originalLevel
  metrics.clock, assess.sources = originalClock, originalSources
  metrics:reset()
end

local function monitoredRecovery(enabled)
  local scenario = fixture()
  scenario.link, scenario.replacement.provider = 0, coordinator
  metrics:setEnabled(enabled)
  local restored = scenario.wizard:restoreControl(scenario.record)
  return { restored, scenario.calls, scenario.link, scenario.restoredBinding }
end

T.eq(
  "timing preserves recovery command order and restored authority",
  monitoredRecovery(true),
  monitoredRecovery(false)
)
T.eq("recovery records a single successful sample", metrics:report().operations["migration.restore"].outcomes, {
  ok = 1,
})

if arg[1] == "--benchmark-recovery" then
  metrics.clock = function()
    return os.clock() * 1000
  end
  metrics.clockName = "Lua os.clock (process CPU time)"
  Properties["Log Mode"], Properties["Log Level"] = "Off", "3 - Info"
  local function recover()
    local outcome = monitoredRecovery(true)
    assert(outcome[1] and outcome[3] == gateway, "Fixture did not restore the original gateway")
    local binding = outcome[4]
    assert(
      binding[1] == gateway and binding[2] == 5 and binding[3] == 51 and binding[4] == 5,
      "Unexpected restored binding"
    )
  end
  for _ = 1, 32 do
    recover()
  end
  metrics:reset()
  for _ = 1, 64 do
    recover()
  end
  print(codec.encode(metrics:report()))
elseif arg[1] == "--benchmark-readiness" then
  metrics.clock = function()
    return stamp
  end
  metrics.clockName = "virtual Director timer (ms)"
  Properties["Log Mode"], Properties["Log Level"] = "Off", "3 - Info"
  metrics:reset()
  for _ = 1, 64 do
    monitored(true)
  end
  print(codec.encode(metrics:report()))
end

T.finish()
