local T = require("testlib")
local function reviewRemoval(wizard, tested, reviewed, evidence)
  return wizard:reviewRemoval(tested, reviewed, evidence, wizard:state().removalScope)
end

local codec = require("ha.codec")
local deferred = require("deferred")
local persist = require("lib.persist")
local assess = require("ha.migration-assessment")
local migrationSelection = require("ha.migration-selection")
require("drivers-common-public.global.handlers")
local coordinator, source, replacement, relay = 42, 51, 261, 80
local keypad = 81
local revision = 2026111901
local entity = "switch.ac"
local oldLink, newLink, relayOwner, relayPort, selection, writes, programs, rejectTransfer
local attachedPrograms, powerPrograms, destinationOn, destinationNamedOn, destinationOff
local oldName, visibleName, retired, rejectRename
local sourceVersion, sourceMode, sourceEntity, olderPresent
local stagedName, replacementPresent, duplicatePrepared, replacementRoom
local keypadOwner, keypadPort, legacyPeer, unsafeRelay, extraPeer, failKeypadBind, buttonOverride
local preparedTarget, targetReads, extraConnection, missingOriginalPort, missingReplacementBindings, legacyOwner
local physical = ("a"):rep(32)
local endpoint = ("b"):rep(32)
local choice = "device:" .. physical .. ":" .. endpoint
local event = "event.hall_gestures"
local function resolved(value)
  local task = deferred.new()
  task:resolve(value)
  return task
end
local function topology()
  return { oldLink, newLink, relayOwner, relayPort, selection }
end
local function fixture()
  persist:delete("HA.SwitchUpgrade.v1")
  oldLink, newLink, relayOwner, relayPort, selection = coordinator, coordinator, source, 1, "reserved"
  writes, programs, rejectTransfer = 0, false, false
  attachedPrograms = false
  powerPrograms, destinationOn, destinationNamedOn, destinationOff = false, 0, 0, 0
  oldName, visibleName, retired, rejectRename = "Hall switch", "Rehearsal replacement", false, false
  sourceVersion, sourceMode, sourceEntity, olderPresent = "106", nil, entity, false
  stagedName, replacementPresent, duplicatePrepared = "Home Assistant Switch", true, false
  replacementRoom = 7
  keypadOwner, keypadPort, legacyPeer = nil, nil, false
  unsafeRelay, extraPeer, failKeypadBind, buttonOverride = false, nil, nil, nil
  preparedTarget, targetReads = entity, 0
  extraConnection, missingOriginalPort, missingReplacementBindings = false, false, false
  legacyOwner = nil
end
local function report()
  if retired then
    return nil
  end
  local edges = relayOwner == source
      and {
        { binding = 1, owner = source, direction = "output", device = relay, port = 5 },
      }
    or {}
  if keypadOwner == source then
    edges[#edges + 1] = { binding = 200, owner = source, direction = "output", device = keypad, port = 6 }
  end
  return {
    id = source,
    file = "HA.Switch.c4z",
    name = oldName,
    family = "switch",
    version = sourceVersion,
    mode = sourceMode,
    room = "Hall",
    room_id = 7,
    interfaces = sourceMode ~= "bridge" and sourceMode ~= "buttons",
    bindingsVerified = true,
    entity = sourceEntity,
    edges = edges,
    programs = {
      readable = true,
      attached = attachedPrograms and { { device = source, event = 12, actionCount = 1 } } or {},
      incoming = programs and { { device = 95, event = 8, actionCount = 1 } } or powerPrograms and {
        { device = 95, event = 5100, actionCount = 1, commands = { ["Turn On"] = 1 } },
        { device = 95, event = 5101, actionCount = 1, commands = { ["Turn Off"] = 1 } },
      } or {},
    },
  }
end

package.loaded["ha.migration-assessment"] = {
  deviceLabel = assess.deviceLabel,
  programReference = assess.programReference,
  switchMigrationModeIssue = assess.switchMigrationModeIssue,
  switchSelectionIssue = assess.switchSelectionIssue,
  destination = assess.destination,
  connectionPeer = function(id)
    return id == relay and "Fireplace timer in Patio" or "Keypad in Hall",
      not (id == relay and unsafeRelay or id == keypad and legacyPeer)
  end,
  programmingSnapshot = function()
    return {}
  end,
  sources = function()
    return retired and {} or { { id = source } }
  end,
  assess = report,
  deviceProgramming = function()
    return {
      readable = true,
      incoming = {
        { device = 95, event = 5100, commands = { TurnOn = destinationOn, ["Turn On"] = destinationNamedOn } },
        { device = 95, event = 5101, commands = { ["Turn Off"] = destinationOff } },
      },
    }
  end,
}
package.loaded["ha.installed-suite"] = {
  upgradeRevision = function(id)
    return id == coordinator and revision or nil
  end,
}
local function projectDevice(id)
  if id == replacement and replacementPresent then
    return {
      id = id,
      file = "Control4.HA.Switch.c4z",
      family = "switch",
      room_id = replacementRoom,
      provider = newLink,
      input = 1,
      name = stagedName,
      selected = selection == "blank" and "" or (sourceEntity == event and choice or entity),
    }
  end
end
package.loaded["ha.commissioning-project"] = {
  device = projectDevice,
  inventory = function()
    local rows = { projectDevice(replacement) }
    if duplicatePrepared then
      local extra = projectDevice(replacement)
      extra.id = replacement + 2
      rows[2] = extra
    end
    if legacyOwner then
      rows[#rows + 1] = legacyOwner
    end
    if extraPeer then
      rows[#rows + 1] = extraPeer
    end
    return rows
  end,
}
local realContract = require("ha.contract")
realContract.provider = function(id)
  return id == replacement and newLink or nil
end
function C4:GetDeviceID()
  return coordinator
end
function C4:GetProxyDevicesById(id)
  return id == replacement and 262 or nil
end
function C4:GetDeviceDisplayName(id)
  return id == 262 and visibleName or oldName
end
function RenameDevice(id, name)
  assert(
    newLink == coordinator
      and (oldLink == 0 and relayOwner == replacement or oldLink == coordinator and relayOwner == source),
    "Rename requires a verified staging or cutover topology"
  )
  if id == source then
    oldName = name
  elseif id == 262 and not rejectRename then
    visibleName = name
  end
end
function C4:GetDevices(filter)
  if filter.DeviceIds == "95" then
    return { [95] = { driverFileName = "light_v2.c4i", deviceName = "Hallway light", roomName = "Hall" } }
  end
  if filter.DeviceIds == "59" and olderPresent then
    return { [59] = {} }
  end
  return not retired and filter.DeviceIds == tostring(source) and { [source] = {} } or {}
end
function C4:GetDevicesByC4iName()
  return replacementPresent and { [replacement] = true } or {}
end
function C4:GetBoundProviderDevice(id, _)
  if id == source then
    return oldLink
  end
  if id == replacement then
    return newLink
  end
  if id == relay then
    return relayOwner
  end
  if id == keypad then
    return keypadOwner
  end
end
function C4:Unbind(id, input)
  writes = writes + 1
  if id == source and input == 999 then
    oldLink = 0
  elseif id == replacement and input == 1 then
    newLink = 0
  elseif id == relay and input == 5 then
    relayOwner, relayPort = 0, 0
  elseif id == keypad and input == 6 then
    keypadOwner, keypadPort = 0, 0
  else
    error("unexpected unbind")
  end
end
local Upgrade = require("ha.switch-upgrade")
function GetDeviceBindings(id, _, _, _, _)
  if id == source then
    return {
      [1] = not missingOriginalPort and { deviceid = source, provider = true } or nil,
      [200] = { deviceid = source, provider = true },
      [999] = {
        deviceid = source,
        isbound = oldLink ~= 0,
        boundprovider = oldLink > 0 and { bound = { deviceid = oldLink, bindingid = 1 } } or nil,
      },
    }
  elseif id == relay then
    return {
      [5] = {
        deviceid = relay,
        isbound = relayOwner ~= 0,
        boundprovider = relayOwner > 0 and { bound = { deviceid = relayOwner, bindingid = relayPort } } or nil,
      },
    }
  elseif id == replacement then
    if missingReplacementBindings then
      return {}
    end
    local consumers = relayOwner == replacement and { { deviceid = relay, bindingid = 5 } } or {}
    if extraConnection then
      consumers[#consumers + 1] = { deviceid = 86, bindingid = 9 }
    end
    return {
      [1] = { deviceid = replacement, provider = false },
      [2] = {
        deviceid = replacement,
        provider = true,
        isbound = #consumers > 0,
        boundconsumers = consumers,
      },
      [300] = {
        deviceid = replacement,
        provider = true,
        isbound = keypadOwner == replacement,
        boundconsumers = keypadOwner == replacement and { { deviceid = keypad, bindingid = 6 } } or nil,
      },
    }
  elseif id == keypad then
    return {
      [6] = {
        deviceid = keypad,
        isbound = keypadOwner > 0,
        boundprovider = keypadOwner > 0 and { bound = { deviceid = keypadOwner, bindingid = keypadPort } } or nil,
      },
    }
  end
  return {}
end
function SendUIRequest(id, request, args)
  if request == "HA_SWITCH_COPY_SETTINGS" then
    assert(id == replacement and args.SOURCE == tostring(source) and selection == "blank" and newLink == coordinator)
    return "<upgrade>copied</upgrade>"
  end
  if request == "HA_SELECTION_IDENTITY" then
    if extraPeer and id == extraPeer.id then
      local load = extraPeer.load or require("ha.contract").loadDomain(extraPeer.selected) and extraPeer.selected
      return XMLTag(
        "selection",
        C4:Base64Encode(codec.encode(codec.object({
          key = extraPeer.selected,
          load = load,
          mode = extraPeer.mode or "Home Assistant device",
          registry = extraPeer.registry,
          gesture = extraPeer.gesture,
          device = extraPeer.device,
          control = extraPeer.control,
          buttons = extraPeer.gesture ~= nil,
          stable = true,
          ready = true,
        })))
      )
    end
    assert(id == replacement)
    local behavior = buttonOverride
      or (sourceMode == "buttons" and "Buttons only" or "Control device and report presses")
    local mode = behavior == "Buttons only" and behavior or "Home Assistant device"
    local config
    if selection ~= "blank" then
      config = { key = projectDevice(id).selected }
      if sourceEntity == event then
        config.device_id, config.gesture_entity_id, config.control_id = physical, event, "hall"
        config.controlled_load = { entity_id = entity, registry_id = endpoint }
      end
    end
    local oldBehavior, oldStatus = Properties["Button behavior"], Properties["Driver Status"]
    Properties["Button behavior"] = behavior
    Properties["Driver Status"] = selection == "ready"
        and (mode == "Buttons only" and "Buttons connected" or "Device connected")
      or "Waiting for device"
    local owner = {
      config = config,
      inputReady = true,
      mode = function()
        return mode
      end,
      usesButtons = function()
        return config and config.gesture_entity_id ~= nil
      end,
    }
    UIR.suppressDebug[request] = true
    UIR[request] = function()
      return migrationSelection.encode(owner)
    end
    local reply = UIRequest(request, args)
    UIR[request] = nil
    assert(type(ParseXml(reply).selection) == "string", "selection reply must fit the template XML contract")
    Properties["Button behavior"], Properties["Driver Status"] = oldBehavior, oldStatus
    return reply
  end
  assert(id == replacement and request == "HA_SWITCH_UPGRADE_STATUS" and args.ENTITY == entity)
  return "<upgrade>" .. selection .. "</upgrade>"
end
function Bind(id, port, consumer, input)
  writes = writes + 1
  if consumer == source and input == 999 and id == coordinator and port == 1 then
    assert(newLink == 0, "rollback must disconnect the replacement first")
    oldLink = coordinator
  elseif consumer == replacement and input == 1 and id == coordinator and port == 1 then
    if selection == "matching" then
      assert(oldLink == 0, "the configured replacement cannot reconnect before release")
      selection = "ready"
    end
    newLink = coordinator
  elseif consumer == relay and input == 5 then
    relayOwner, relayPort = id, port
  elseif consumer == keypad and input == 6 then
    if id == replacement and failKeypadBind then
      return failKeypadBind()
    end
    keypadOwner, keypadPort = id, port
  else
    error("unexpected bind")
  end
end
function RefreshNavs() end

local hub = {
  online = true,
  connection = {
    readState = function(_, id)
      assert(id == entity)
      return resolved(
        codec.object({ entity_id = entity, state = "off", attributes = codec.object({ friendly_name = "AC" }) })
      )
    end,
  },
  transfer = {
    directSwitch = function(_, device, target)
      assert(device == replacement and target == entity and oldLink == 0 and newLink == coordinator)
      local task = deferred.new()
      if rejectTransfer then
        task:reject("not confirmed")
      else
        selection = "ready"
        task:resolve(true)
      end
      return task
    end,
  },
}
local function wizard()
  return Upgrade.new(hub, function() end)
end

T.section("Quick Setup offers migration only for this Coordinator’s work")
fixture()
local availability = wizard()
T.eq("a linked older switch makes migration available", availability:availability(), { count = 1, pending = false })
oldLink = coordinator + 1
T.eq("a switch on another Coordinator does not count", availability:availability(), { count = 0, pending = false })
retired = true
T.eq("the entry stays hidden with no legacy drivers", availability:availability(), { count = 0, pending = false })
T.eq("checking availability makes no changes", writes, 0)

T.section("prototype modes are verified before offering a cutover")
do
  fixture()
  sourceVersion, sourceMode = "107", nil
  local controller = wizard()
  local row = controller:list()[1]
  T.eq("the prototype stays visible when it requires attention", controller:availability().count, 1)
  T.eq("the mode is blocked before deployment", row.state, "blocked")
  T.check(
    "the message tells the installer where to check the mode or get migration instructions",
    row.message:find("Operation Mode", 1, true) ~= nil
  )
  T.truthy("a blocked row cannot be reviewed for automatic migration", controller:review({ source }).error)
  T.eq("control and ownership are untouched", topology(), { 42, 42, 51, 1, "reserved" })
  T.eq("no writes occurred", writes, 0)
end
fixture()
sourceVersion, sourceMode = "107", "direct"
local prototype = wizard()
local prototypeReview = prototype:review({ source })
T.eq(
  "a known direct prototype can use the same explicit operation",
  prototype:start(prototypeReview.token, true).rows[1].state,
  "upgraded"
)
T.eq("only the prototype replacement owns the load and relay", topology(), { 0, 42, 261, 2, "ready" })

T.section("explicit batch uses a saved replacement and verifies its exact relay")
fixture()
local upgrade = wizard()
T.eq("opening checks the source on this Coordinator", upgrade:list()[1].state, "ready")
local review = upgrade:review({ source })
T.eq("review shows the original name the new driver will use", review.rows[1].finalName, "Hall switch")
T.eq("review reports the scope of its programming check", review.rows[1].programming, "none")
T.truthy("backup confirmation is required", upgrade:start(review.token, false).error)
T.eq("listing and review leave control intact", writes, 0)
T.eq("one start performs and verifies the upgrade", upgrade:start(review.token, true).rows[1].state, "upgraded")
T.eq("only the replacement owns the load and relay", topology(), { 0, 42, 261, 2, "ready" })
T.eq("the new driver inherits the name and the old driver is labeled", { oldName, visibleName }, {
  "Hall switch (old driver 51)",
  "Hall switch",
})
T.eq("finished state survives reopening", wizard():state().rows[1].state, "upgraded")
T.eq("no verified programming is shown when none was moved", wizard():state().rows[1].verifiedActions, nil)
T.eq("old source is no longer offered", #upgrade:list(), 0)
T.eq("the entry remains available until cleanup", wizard():availability(), { count = 0, pending = true })
do
  local sources, getDevices = assess.sources, C4.GetDevices
  local before = writes
  local file = upgrade.batch.records[1].source.file
  assess.sources = function()
    error("Unexpected project discovery")
  end
  function C4:GetDevices(filter)
    return filter.DeviceIds == tostring(source) and { [source] = { driverFileName = file } } or {}
  end
  local owner, response = { switchUpgrade = wizard() }, nil
  local page = require("lib.ui.page")
  local send = page.send
  page.send = function(command, data)
    if command == "HA_SWITCH_UPGRADE_REPLY" then
      response = data
    end
  end
  require("ha.switch-upgrade-page").install(function()
    return owner
  end)
  UIR.HA_SWITCH_UPGRADE({
    DATA = C4:Base64Encode(JSON:encode({ action = "availability", request = "reopen", includeStatus = true })),
  })
  assess.sources, C4.GetDevices, page.send = sources, getDevices, send
  T.eq("reopening returns the saved result without scanning other drivers", {
    response.request,
    response.pending,
    response.status and response.status.rows[1].state,
    response.error,
    writes,
  }, { "reopen", true, "upgraded", nil, before })
end
T.truthy("cleanup review requires testing confirmation", reviewRemoval(upgrade, false).error)
T.eq("only the safely retired driver is offered", reviewRemoval(upgrade, true, true).rows, {
  {
    id = 51,
    name = "Hall switch (old driver 51)",
    room = "Hall",
    state = "ready",
    message = "Ready to remove in Composer.",
  },
})
programs = true
T.eq(
  "new programming blocks removal",
  reviewRemoval(upgrade, true, true).rows[1].message,
  "Keep this driver and check its name, connections and programming."
)
programs = false
relayOwner, relayPort = 99, 5
T.eq("a redirected relay blocks removal", reviewRemoval(upgrade, true, true).rows[1].state, "blocked")
relayOwner, relayPort = replacement, 2
retired = true
T.eq(
  "cleanup checks removal after the installer deletes the old driver",
  reviewRemoval(upgrade, true, true).rows[1].message,
  "Removed from Control4."
)
T.eq("the entry clears when the retired driver is gone", wizard():availability(), { count = 0, pending = false })

T.section("a subsequent batch preserves outstanding removal review")
fixture()
olderPresent = true
local older =
  { id = 59, name = "Previous switch", room = "Office", programs = { attached = {}, incoming = {}, readable = true } }
persist:set(
  "HA.SwitchUpgrade.v1",
  codec.encode({
    token = "previous",
    revision = revision,
    records = {
      {
        source = older,
        phase = "upgraded",
        namesVerified = true,
        retiredName = "Previous switch (old driver 59)",
      },
    },
  }),
  true
)
upgrade = wizard()
review = upgrade:review({ source })
local second = upgrade:start(review.token, true)
T.eq("new result and earlier cleanup both survive", { second.rows[1].id, second.rows[2].id }, { source, 59 })
T.eq(
  "a cold reopen retains the earlier removal row",
  reviewRemoval(wizard(), true, true).rows[2].name,
  "Previous switch (old driver 59)"
)

T.section("replacement names remain valid at a multibyte boundary")
fixture()
selection = "blank"
oldName = ("A"):rep(104) .. "é and the rest"
local _, records = wizard():list()
local savedName = codec.storedObject(codec.encode(codec.object({ name = records[source].name })))
T.eq("the staged name survives checkpoint decoding", savedName and savedName.name, ("A"):rep(104) .. " (new driver)")

T.section("an unconfirmed add can only resume one exact blank replacement without another add")
fixture()
replacementPresent, selection, newLink = false, "blank", 0
local companions = require("lib.companions")
local addSelected, afterAdd = companions.addSelected, companions.afterAdd
local adds, lateReceipt = 0, nil
companions.addSelected = function(_, need, late)
  adds = adds + 1
  stagedName = need.name
  lateReceipt = late
  local pending = deferred.new()
  pending:reject("native add receipt timed out")
  return pending
end
companions.afterAdd = function()
  return resolved()
end
upgrade = wizard()
review = upgrade:review({ source })
T.eq("times out without releasing the old switch", upgrade:start(review.token, true).rows[1].state, "adding")
T.eq("a missing candidate does not retry AddDevice", wizard():resume().rows[1].state, "adding")
replacementPresent, duplicatePrepared = true, true
T.eq("ambiguous names cannot authorize cutover", wizard():resume().rows[1].state, "adding")
duplicatePrepared, newLink = false, coordinator + 1
T.eq("a candidate attached to another Coordinator stays untouched", wizard():resume().rows[1].state, "adding")
T.eq("unsuccessful rechecks made no controller writes", { adds, writes, oldLink }, { 1, 0, coordinator })
newLink = coordinator
T.eq("reopening resumes the one validated driver", wizard():resume().rows[1].state, "upgraded")
T.eq("only one native add was requested", adds, 1)
fixture()
replacementPresent, selection, newLink = false, "blank", 0
upgrade = wizard()
review = upgrade:review({ source })
T.eq("another timeout awaits the Director receipt", upgrade:start(review.token, true).rows[1].state, "adding")
local firstName = stagedName
lateReceipt(nil)
T.eq("late definitive failure becomes eligible for a deliberate retry", wizard():state().rows[1].state, "pending")
T.eq("explicit retry can request one fresh add", wizard():resume().rows[1].state, "adding")
T.eq("separate attempts have distinct exact names", stagedName == firstName, false)
T.eq("failed attempts never release the source", { adds, writes, oldLink }, { 3, 0, coordinator })
lateReceipt(nil)
sourceEntity = "switch.unrelated"
T.eq("a changed original is shown before another add", wizard():resume().rows[1].state, "attention")
T.eq("no add or controller write after the original selection changes", { adds, writes }, { 3, 0 })
companions.addSelected, companions.afterAdd = addSelected, afterAdd

T.section("button switches create a blank driver in the same room and keep the original name after testing")
for mode, behavior in pairs({ bridge = "Control device and report presses", buttons = "Buttons only" }) do
  fixture()
  sourceVersion, sourceMode, sourceEntity = "107", mode, nil
  replacementPresent, selection, newLink = false, "blank", 0
  local additions = 0
  companions.addSelected = function(_, need)
    additions = additions + 1
    T.eq("the replacement uses the original room", need.room, 7)
    T.eq("it adds the HA Switch package", need.file, "Control4.HA.Switch.c4z")
    stagedName, visibleName, replacementPresent = need.name, need.name, true
    return resolved({ id = replacement })
  end
  companions.afterAdd = function()
    return resolved()
  end
  local controller = wizard()
  local plan = controller:review({ source })
  T.eq("review names the exact new Button behavior", plan.rows[1].buttonBehavior, behavior)
  T.eq("preview only reads the project", { additions, writes }, { 0, 0 })
  T.truthy("cannot create before backup confirmation", controller:start(plan.token, false).error)
  local created = controller:start(plan.token, true).rows[1]
  T.eq(
    "the wizard shows the actual staged name in the original room",
    { created.state, created.replacement, created.room },
    { "manual", "Hall switch (new driver)", "Hall" }
  )
  T.eq(
    "staging connects only the blank replacement",
    { additions, writes, table.concat(topology(), ",") },
    { 1, 1, "42,42,51,1,blank" }
  )
  T.eq("the wizard confirms copied settings from the child", created.copiedSettings, true)

  controller = wizard()
  T.eq("the same checkpoint resumes without another add", controller:resume().rows[1].state, "manual")
  T.truthy("a staged original cannot be added again", controller:review({ source }).error)
  T.eq("there is still only one created replacement", additions, 1)
  T.truthy("naming requires the test confirmation", controller:finishNames(plan.token, source, false).error)
  T.truthy("a stale naming confirmation is rejected", controller:finishNames("stale", source, true).error)
  T.truthy("naming waits for an actual cutover", controller:finishNames(plan.token, source, true).error)
  T.eq("both drivers retain their names", { oldName, visibleName }, { "Hall switch", "Hall switch (new driver)" })
  T.eq("a verified old relay can be moved through the wizard", created.relayMigration, "available")
  T.truthy(
    "moving the relay requires the original to release control",
    controller:moveManualRelays(plan.token, source, true).error
  )
  oldLink, selection = 0, "ready"
  T.truthy("naming waits for the relay handoff", controller:finishNames(plan.token, source, true).error)
  T.truthy("a stale relay request cannot move the relay", controller:moveManualRelays("stale", source).error)
  T.eq(
    "moves and verifies the exact saved relay",
    controller:moveManualRelays(plan.token, source, true).rows[1].relayMigration,
    "moved"
  )
  T.eq("the relay now connects to the replacement", { relayOwner, relayPort }, { replacement, 2 })
  rejectRename = true
  T.eq(
    "a failed name handoff stays resumable",
    controller:finishNames(plan.token, source, true).rows[1].state,
    "manual"
  )
  T.eq("the old name was saved before the rename failed", oldName, "Hall switch (old driver 51)")
  rejectRename = false
  controller = wizard()
  local result = controller:finishNames(plan.token, source, true)
  T.eq(
    "the replacement takes the exact original name",
    { result.rows[1].state, visibleName },
    { "upgraded", "Hall switch" }
  )
  T.eq("the original stays identifiable for cleanup", result.rows[1].oldDriver, "Hall switch (old driver 51)")
  T.eq("naming does not change any bindings", writes, 3)
  T.truthy("manual naming does not waive the scene and programming check", reviewRemoval(controller, false).error)
  programs = true
  T.eq(
    "removal review protects an original with remaining programming",
    reviewRemoval(controller, false, true).rows[1].state,
    "blocked"
  )
  programs = false
  T.eq(
    "the detached driver can be reviewed separately without another test confirmation",
    reviewRemoval(controller, false).rows[1].state,
    "ready"
  )
  relayOwner, relayPort = 0, 0
  T.eq("removal is blocked if the transferred relay is lost", reviewRemoval(controller, false).rows[1].state, "blocked")
  retired = true
  T.eq(
    "the section can disappear after the old driver is removed",
    controller:availability(),
    { count = 0, pending = false }
  )
end
companions.addSelected, companions.afterAdd = addSelected, afterAdd

T.section("review detects the connected keypad and relay before automatic button cutover")
local originalReadState = hub.connection.readState
local function buttonCutoverCase()
  fixture()
  sourceVersion, sourceMode, sourceEntity = "107", "bridge", event
  replacementPresent, selection, newLink = false, "blank", 0
  keypadOwner, keypadPort = source, 200
  companions.addSelected = function(_, need)
    stagedName, visibleName, replacementPresent = need.name, need.name, true
    return resolved({ id = replacement })
  end
  companions.afterAdd = function()
    return resolved()
  end
  local load = codec.object({
    entity_id = entity,
    name = "Fireplace relay",
    domain = "switch",
    registry_id = endpoint,
    available = true,
  })
  local catalog = require("ha.catalog").new()
  local catalogRevision = ("7"):rep(64)
  catalog.verified = catalog.generation
  catalog.snapshot = {
    revision = catalogRevision,
    gestureChoices = {},
    indices = { switch = { 1 } },
    byId = { [choice] = 1 },
    rows = {
      {
        entity_id = choice,
        name = "Fireplace",
        families = { "switch" },
        entity_aliases = { "light.fireplace_alias" },
        attributes = {
          device_choice = { device_id = physical, source_load = load, area = "Patio" },
        },
      },
    },
  }
  hub.catalog = catalog
  catalog.refresh = function()
    return resolved({ revision = catalogRevision })
  end
  hub.connection.readState = function(_, target)
    if target == preparedTarget and target ~= entity then
      return resolved(codec.object({
        entity_id = target,
        state = "on",
        attributes = codec.object({ friendly_name = "Reassigned relay" }),
      }))
    end
    assert(target == event)
    targetReads = targetReads + 1
    return resolved(codec.object({
      entity_id = event,
      state = "2026-11-19T21:00:00Z",
      attributes = codec.object({
        bridge_source_device_id = physical,
        bridge_contract_version = "1.0",
        bridge_control_id = "hall",
        bridge_load = preparedTarget == entity and codec.null
          or codec.object({ entity_id = preparedTarget, domain = "switch" }),
      }),
    }))
  end
  hub._request = function(_, request, callback)
    assert(
      request.service == "prepare_device"
        and request.service_data.device_id == physical
        and request.service_data.source_registry_id == endpoint
    )
    callback(
      true,
      codec.object({
        response = codec.object({
          version = 1,
          device_id = physical,
          source_load = load,
          controlled_load = preparedTarget == entity and load
            or codec.object({ entity_id = preparedTarget, domain = "switch", registry_id = ("c"):rep(32) }),
          controlled_load_origin = preparedTarget == entity and "selected_endpoint" or "explicit_link",
          gesture_entity_id = event,
          control_id = "hall",
          input_ready = true,
        }),
      })
    )
  end
  hub.transfer.preparedSwitch = function(_, device, config)
    assert(device == replacement and config.key == choice and oldLink == 0 and newLink == coordinator)
    if rejectTransfer then
      local task = deferred.new()
      task:reject("not confirmed")
      return task
    end
    selection = "ready"
    return resolved(true)
  end
  return wizard()
end
do
  local controller = buttonCutoverCase()
  local plan = controller:review({ source })
  T.eq("the review identifies the endpoints with names and rooms", plan.rows[1].connections, {
    { role = "Relay", target = "Fireplace timer in Patio", transfer = true },
    { role = "On button", target = "Keypad in Hall", transfer = true },
  })
  T.eq("review performs no changes", writes, 0)
  local outcome = controller:start(plan.token, true).rows[1]
  T.eq(
    "the original stays connected until the exact load is confirmed",
    { outcome.state, outcome.targetToConfirm.entity, oldLink },
    { "target", entity, coordinator }
  )
  T.truthy(
    "a stale load confirmation is refused",
    controller:approveTarget("stale", source, outcome.targetToConfirm.key, true).error
  )
  outcome = controller:approveTarget(plan.token, source, controller:state().rows[1].targetToConfirm.key, true).rows[1]
  T.eq("the replacement takes the verified HA selection", outcome.connectedAutomatically, true)
  T.eq(
    "the old connection and both exact ports move",
    { oldLink, relayOwner, relayPort, keypadOwner, keypadPort },
    { 0, replacement, 2, replacement, 300 }
  )
  T.eq(
    "verified transfer automatically applies the original name",
    { outcome.state, visibleName },
    { "upgraded", "Hall switch" }
  )

  controller = buttonCutoverCase()
  hub.catalog.snapshot.gestureChoices[event] = hub.catalog.snapshot.rows[1]
  plan = controller:review({ source })
  T.eq("review shows the exact catalog load for Start approval", plan.rows[1].reviewedLoad.entity, entity)
  outcome = controller:start(plan.token, true).rows[1]
  T.eq("a verified default load transfers directly from Start", {
    outcome.state,
    outcome.targetToConfirm,
    outcome.connectedAutomatically,
    outcome.tested,
    visibleName,
    oldLink,
    relayOwner,
    keypadOwner,
  }, {
    "upgraded",
    nil,
    true,
    nil,
    "Hall switch",
    0,
    replacement,
    replacement,
  })
  T.truthy("automatic transfer still requires testing before removal", reviewRemoval(controller, false).error)
  T.eq("testing opens the separate removal review", reviewRemoval(controller, true, true).rows[1].state, "ready")

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.eq("the older release has saved one unconfigured replacement", outcome.state, "target")
  local previousRevision = revision
  local completed = codec.storedObject(codec.encode(controller.batch.records[1]))
  completed.source.id, completed.destination = source + 100, replacement + 100
  completed.phase, completed.namesVerified, completed.tested = "upgraded", true, true
  completed.targetToConfirm = nil
  controller.batch.records[2] = completed
  controller:save()
  revision = revision + 1
  controller = wizard()
  T.eq("a resumed page shows the sequence only as a release recheck", controller:state().releaseChanged, true)
  local writesBeforeUpgrade = writes
  T.truthy("a stale request cannot carry the migration forward", controller:resume("old token").error)
  hub.online = false
  T.truthy("an offline controller keeps the saved recheck retryable", controller:resume(plan.token).error)
  hub.online = true
  extraConnection = true
  T.truthy("a changed topology cannot carry the staged record forward", controller:resume(plan.token).error)
  T.eq(
    "release validation is read-only while blocked",
    { oldLink, relayOwner, writes },
    { coordinator, source, writesBeforeUpgrade }
  )
  extraConnection = false
  outcome = controller:resume(plan.token).rows[1]
  T.eq("release recheck preserves the pending load and still requires explicit approval", {
    outcome.state,
    outcome.targetToConfirm.entity,
    controller.batch.revision,
    oldLink,
    relayOwner,
    writes,
    controller.batch.records[2],
  }, { "target", entity, revision, coordinator, source, writesBeforeUpgrade, completed })
  controller = wizard()
  T.falsy("review resumes at load confirmation after a reload", controller:state().releaseChanged)
  local readState = hub.connection.readState
  local failureKind = "timeout"
  hub.connection.readState = function()
    local pending = deferred.new()
    pending:reject({ kind = failureKind })
    return pending
  end
  outcome = controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true).rows[1]
  T.eq(
    "a failed Home Assistant read keeps the adopted row retryable",
    { outcome.state, oldLink },
    { "attention", coordinator }
  )
  failureKind = "retired"
  outcome = controller:resume().rows[1]
  T.eq(
    "a superseded Home Assistant connection also allows retry",
    { outcome.state, oldLink },
    { "attention", coordinator }
  )
  hub.connection.readState = function(_, target)
    return resolved(codec.object({ entity_id = target, state = "unavailable", attributes = codec.object({}) }))
  end
  outcome = controller:resume().rows[1]
  T.eq(
    "a temporarily unavailable gesture entity also allows retry",
    { outcome.state, oldLink },
    { "attention", coordinator }
  )
  hub.connection.readState = readState
  outcome = controller:resume().rows[1]
  T.eq(
    "explicit approval resumes the same staged replacement on the new release",
    { outcome.state, controller.batch.revision, controller.batch.records[1].addAttempt, relayOwner },
    { "upgraded", revision, 1, replacement }
  )
  revision = previousRevision

  controller = buttonCutoverCase()
  hub.catalog.snapshot.gestureChoices[event] = hub.catalog.snapshot.rows[1]
  preparedTarget = "switch.reassigned"
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.eq(
    "Start approval for the catalog load cannot authorize a different prepared link",
    { outcome.state, outcome.targetToConfirm.entity, oldLink },
    { "target", preparedTarget, coordinator }
  )

  controller = buttonCutoverCase()
  sourceMode = "buttons"
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.eq(
    "a verified Buttons only device needs no load confirmation",
    { outcome.connectedAutomatically, oldLink },
    { true, 0 }
  )

  controller = buttonCutoverCase()
  legacyPeer = true
  plan = controller:review({ source })
  T.eq("a keypad that also needs migration is flagged early", plan.rows[1].connections[2].transfer, false)
  outcome = controller:start(plan.token, true).rows[1]
  T.eq(
    "an unresolved peer leaves the original in control",
    { outcome.connectedAutomatically, oldLink, relayOwner, keypadOwner },
    { nil, coordinator, source, source }
  )
  legacyPeer = false
  T.eq(
    "the same reviewed peer can be rechecked after migration",
    controller:recheckConnections(plan.token, source).rows[1].state,
    "target"
  )

  controller = buttonCutoverCase()
  rejectTransfer = true
  plan = controller:review({ source })
  controller:start(plan.token, true)
  outcome = controller:approveTarget(plan.token, source, controller:state().rows[1].targetToConfirm.key, true).rows[1]
  T.eq(
    "failed setup reconnects the original and keeps every link",
    { outcome.state, oldLink, newLink, relayOwner, keypadOwner },
    { "restored", coordinator, 0, source, source }
  )
  rejectTransfer, preparedTarget = false, "switch.reassigned"
  local reads = targetReads
  outcome = wizard():resume().rows[1]
  T.eq(
    "cold retry reads HA and asks for a changed load before releasing the original",
    { targetReads > reads, outcome.state, outcome.targetToConfirm.entity, oldLink },
    { true, "target", preparedTarget, coordinator }
  )
  T.eq("explicit links show the exact load's friendly name", outcome.targetToConfirm.name, "Reassigned relay")

  controller = buttonCutoverCase()
  attachedPrograms = true
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.eq(
    "attached programming keeps the original connected",
    { outcome.state, oldLink, relayOwner },
    { "review", coordinator, source }
  )
  T.check(
    "attached programming instructions explain how to clear the old event",
    outcome.details[1].instruction:find("Then remove the actions from this event on the old driver.", 1, true)
  )
  T.eq("only recreating the new event does not clear the old event", controller:resume().rows[1].state, "review")
  attachedPrograms = false
  outcome = controller:resume().rows[1]
  T.eq("the moved programming still needs explicit review", outcome.confirmProgramming, true)
  T.eq(
    "confirmed programming continues to load verification",
    controller:resume(plan.token, { source }).rows[1].state,
    "target"
  )

  for _, choice in ipairs({ "light.fireplace_alias", false }) do
    controller = buttonCutoverCase()
    extraPeer = { id = 90, provider = coordinator, selected = choice or nil }
    plan = controller:review({ source })
    controller:start(plan.token, true)
    outcome = controller:approveTarget(plan.token, source, controller:state().rows[1].targetToConfirm.key, true).rows[1]
    T.eq(
      "an equivalent alias or unreadable peer keeps the original connected",
      { outcome.state, oldLink, relayOwner },
      { "attention", coordinator, source }
    )
  end

  controller = buttonCutoverCase()
  extraPeer = { id = 90, provider = coordinator, selected = "device:other:control", load = entity }
  plan = controller:review({ source })
  controller:start(plan.token, true)
  outcome = controller:approveTarget(plan.token, source, controller:state().rows[1].targetToConfirm.key, true).rows[1]
  T.eq(
    "a different device selection can still own the same effective load",
    { outcome.state, oldLink },
    { "attention", coordinator }
  )

  for _, peer in ipairs({
    { provider = 77, selected = choice, load = "switch.renamed", registry = endpoint },
    { provider = 77, selected = "event.renamed", gesture = "event.renamed", device = physical, control = "hall" },
    { legacy = true, legacy_provider = coordinator, legacy_mode = "bridge", selected = "event.other_gestures" },
    { legacy = true, legacy_provider = 77, legacy_mode = "bridge", selected = "event.other_gestures" },
  }) do
    controller = buttonCutoverCase()
    peer.id, peer.name, peer.room = 90, "Another switch", "Kitchen"
    extraPeer = peer
    plan = controller:review({ source })
    outcome = controller:start(plan.token, true).rows[1]
    local proposal = outcome.targetToConfirm
    T.eq(
      "confirmation identifies the exact catalog load and HA area",
      { proposal.name, proposal.area, proposal.entity },
      { "Fireplace relay", "Patio", entity }
    )
    outcome = controller:approveTarget(plan.token, source, proposal.key, true).rows[1]
    T.eq(
      "another Coordinator or an unresolved legacy bridge can own the same function",
      { outcome.state, oldLink, relayOwner },
      { peer.legacy and "manual" or "attention", coordinator, source }
    )
    T.contains("the installer can find the related driver", outcome.message, "Another switch in Kitchen")
  end

  controller = buttonCutoverCase()
  extraPeer = { id = 90, provider = 77, selected = entity, registry = ("c"):rep(32) }
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  outcome = controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true).rows[1]
  T.eq(
    "different registry IDs distinguish identical entity names across Coordinators",
    { outcome.connectedAutomatically, oldLink },
    { true, 0 }
  )

  controller = buttonCutoverCase()
  sourceMode = "buttons"
  extraPeer = { id = 90, provider = coordinator, selected = choice, load = entity, registry = endpoint }
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.eq(
    "a load-only owner does not conflict with a Buttons-only migration",
    { outcome.connectedAutomatically, oldLink },
    { true, 0 }
  )

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  extraConnection = true
  local before = writes
  outcome = controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true).rows[1]
  T.eq(
    "an extra replacement connection blocks cutover before any changes",
    { outcome.state, oldLink, relayOwner, writes },
    { "attention", coordinator, source, before }
  )
  extraConnection = false
  outcome = controller:resume().rows[1]
  T.eq("cutover can resume after the extra connection is removed", outcome.connectedAutomatically, true)

  controller = buttonCutoverCase()
  legacyOwner = { id = 92, legacy = true, legacy_provider = coordinator, selected = "event.other_gestures" }
  extraPeer = { id = 90, provider = 77, selected = choice, load = "switch.renamed", registry = endpoint }
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  outcome = controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true).rows[1]
  T.eq(
    "an ambiguous legacy peer cannot mask a verified conflict on a later row",
    { outcome.state, oldLink },
    { "attention", coordinator }
  )

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, false)
  oldLink, selection = 0, "ready"
  legacyOwner = {
    id = 92,
    name = "Legacy bridge",
    room = "Kitchen",
    legacy = true,
    legacy_provider = coordinator,
    selected = "event.other_gestures",
  }
  T.contains(
    "manual connection transfer pauses when another legacy load is unresolved",
    controller:moveManualRelays(plan.token, source, true).error,
    "Legacy bridge in Kitchen"
  )
  T.eq(
    "checking an unresolved owner leaves each connection with the original",
    { relayOwner, keypadOwner },
    { source, source }
  )
  legacyOwner = nil
  extraPeer = { id = 90, name = "Other load owner", room = "Kitchen", provider = coordinator, selected = entity }
  T.contains(
    "a newly conflicting driver blocks manual connection transfer",
    controller:moveManualRelays(plan.token, source, true).error,
    "Other load owner in Kitchen"
  )
  T.eq("manual transfer leaves both connections unchanged", { relayOwner, keypadOwner }, { source, source })
  relayOwner, relayPort, keypadOwner, keypadPort = replacement, 2, replacement, 300
  outcome = controller:finishNames(plan.token, source, true).rows[1]
  T.eq(
    "even a manually wired replacement cannot complete with a verified conflict",
    { outcome.state, oldName },
    { "manual", "Hall switch" }
  )

  controller = buttonCutoverCase()
  local readyGate = deferred.new()
  function controller:waitReady()
    return readyGate
  end
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true)
  extraConnection = true
  readyGate:resolve(true)
  T.eq(
    "an extra connection during feedback restores the original without rewiring",
    { controller:state().rows[1].state, oldLink, newLink, relayOwner, keypadOwner },
    { "restored", coordinator, 0, source, source }
  )

  controller = buttonCutoverCase()
  legacyPeer = true
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.eq("an unresolved connection uses the manual path", outcome.state, "manual")
  oldLink, newLink, relayOwner, relayPort, selection = 0, coordinator, replacement, 2, "ready"
  outcome = controller:finishNames(plan.token, source, true).rows[1]
  T.eq(
    "manual completion waits for the original keypad connection",
    { outcome.state, keypadOwner, oldName },
    { "manual", source, "Hall switch" }
  )

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  failKeypadBind = function()
    missingOriginalPort = true
  end
  outcome = controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true).rows[1]
  T.eq(
    "rollback stops before detaching any working connection when the original port is missing",
    { outcome.state, oldLink, newLink, relayOwner },
    { "recovery", 0, coordinator, replacement }
  )

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  local recovery = "Restore the project backup before continuing."
  local recoveryRow = { id = 93, name = "Another switch", programs = { readable = true, attached = {}, incoming = {} } }
  controller.batch.records[2] = { source = recoveryRow, phase = "recovery", message = recovery }
  controller:save()
  before = writes
  T.eq(
    "approving another row cannot bypass the backup restore",
    controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, true).error,
    recovery
  )
  T.eq("the shared runner enforces recovery", controller:run().error, recovery)
  T.eq(
    "recovery blocks naming and removal review",
    { controller:finishNames().error, reviewRemoval(controller, true, true).error },
    { recovery, recovery }
  )
  T.eq(
    "recovery keeps the other row's approval and all connections untouched",
    { controller:state().rows[1].state, oldLink, writes },
    { "target", coordinator, before }
  )

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  controller:start(plan.token, true)
  buttonOverride = "Buttons only"
  outcome = controller:approveTarget(plan.token, source, controller:state().rows[1].targetToConfirm.key, true).rows[1]
  T.eq(
    "a changed mode cannot release the original",
    { outcome.state, oldLink, relayOwner },
    { "attention", coordinator, source }
  )

  controller = buttonCutoverCase()
  plan = controller:review({ source })
  controller:start(plan.token, true)
  failKeypadBind = function()
    controller:destroy()
  end
  controller:approveTarget(plan.token, source, controller:state().rows[1].targetToConfirm.key, true)
  T.eq(
    "an interruption saves the previously moved relay and pending keypad",
    { oldLink, relayOwner, keypadOwner },
    { 0, replacement, 0 }
  )
  failKeypadBind = nil
  outcome = wizard():resume().rows[1]
  T.eq(
    "a cold reopen finishes only the pending keypad link",
    { outcome.connectedAutomatically, relayOwner, keypadOwner, keypadPort },
    { true, replacement, replacement, 300 }
  )
  controller = buttonCutoverCase()
  plan = controller:review({ source })
  outcome = controller:start(plan.token, true).rows[1]
  T.truthy(
    "approval for a different proposal cannot transfer the current one",
    controller:approveTarget(plan.token, source, "old proposal", true).error
  )
  outcome = controller:approveTarget(plan.token, source, outcome.targetToConfirm.key, false).rows[1]
  T.eq(
    "the installer can fall back to Composer with the original still linked",
    { outcome.state, oldLink },
    { "manual", coordinator }
  )
end
hub.connection.readState, hub.catalog, hub._request, hub.transfer.preparedSwitch = originalReadState, nil, nil, nil
companions.addSelected, companions.afterAdd = addSelected, afterAdd

T.section("direct cutover cannot rewire an unverified relay")
fixture()
unsafeRelay = true
upgrade = wizard()
review = upgrade:review({ source })
T.eq("review flags the unverified relay", review.rows[1].connections[1].transfer, false)
T.eq("the unchanged connection needs review before cutover", upgrade:start(review.token, true).rows[1].state, "review")
T.eq(
  "the original stays connected with its original relay",
  { oldLink, relayOwner, writes },
  { coordinator, source, 0 }
)

T.section("recheck verifies the exact original connection after a Composer move")
unsafeRelay = false
for _, invalid in ipairs({ { 0, 0 }, { 99, 2 }, { replacement, 300 } }) do
  relayOwner, relayPort = unpack(invalid)
  local row = wizard():resume(review.token).rows[1]
  T.eq("a changed endpoint stays unresolved", { row.state, row.unresolvedConnections }, { "review", true })
  T.eq("a changed endpoint does not release the original or rewire anything", { oldLink, writes }, { coordinator, 0 })
end
relayOwner, relayPort = replacement, 2
T.eq("the exact Composer move completes migration", wizard():resume(review.token).rows[1].state, "upgraded")
T.eq("the already moved relay is left in place", topology(), { 0, 42, 261, 2, "ready" })
T.eq("only the old Home Assistant connection was disconnected", writes, 1)

fixture()
unsafeRelay = true
upgrade = wizard()
review = upgrade:review({ source })
upgrade:start(review.token, true)
unsafeRelay, relayOwner, relayPort, extraConnection = false, replacement, 2, true
local extra = wizard():resume(review.token).rows[1]
T.eq("an unreviewed replacement edge still prevents migration", { extra.state, oldLink, writes }, {
  "attention",
  coordinator,
  0,
})
T.contains("the installer is directed to the extra connection", extra.message, "extra connections")

fixture()
programs = true
upgrade = wizard()
review = upgrade:review({ source })
T.eq("a verified relay can wait on a programming review", upgrade:start(review.token, true).rows[1].state, "review")
programs, relayOwner, relayPort, rejectTransfer = false, replacement, 2, true
local rechecked = wizard():resume(review.token)
T.eq("the manual connection move does not waive programming review", rechecked.rows[1].confirmProgramming, true)
T.eq("failed feedback triggers restoration", wizard():resume(review.token, { source }).rows[1].state, "restored")
T.eq("restoration reconnects the original relay and Home Assistant", topology(), { 42, 0, 51, 1, "reserved" })

fixture()
extraPeer =
  { id = 90, name = "Fixture light", room = "Kitchen", family = "light", provider = coordinator, selected = entity }
upgrade = wizard()
review = upgrade:review({ source })
local directOutcome = upgrade:start(review.token, true).rows[1]
T.eq(
  "direct cutover checks other driver families for the same load",
  { directOutcome.state, oldLink, relayOwner },
  { "attention", coordinator, source }
)
T.contains("direct ownership reports the other driver and room", directOutcome.message, "Fixture light in Kitchen")

fixture()
legacyOwner = {
  id = 92,
  legacy = true,
  legacy_provider = coordinator,
  selected = "event.other_gestures",
  name = "Wall control",
  room = "Kitchen",
}
upgrade = wizard()
review = upgrade:review({ source })
directOutcome = upgrade:start(review.token, true).rows[1]
T.eq(
  "an unresolved bridge leaves direct control with the original",
  { directOutcome.state, oldLink, writes },
  { "attention", coordinator, 0 }
)
T.contains(
  "a direct migration names which bridge to migrate first",
  directOutcome.message,
  "Finish migrating Wall control in Kitchen first"
)

fixture()
local coldCatalog, catalogGate = require("ha.catalog").new(), deferred.new()
hub.catalog = coldCatalog
coldCatalog.refresh = function()
  return catalogGate
end
extraPeer = { id = 90, family = "light", provider = coordinator, selected = "light.ac_alias" }
upgrade = wizard()
review = upgrade:review({ source })
upgrade:start(review.token, true)
T.eq(
  "direct migration waits for its initial catalog before checking ownership",
  { oldLink, writes },
  { coordinator, 0 }
)
coldCatalog.verified = coldCatalog.generation
coldCatalog.snapshot = { rows = { { entity_id = entity, entity_aliases = { "light.ac_alias" }, attributes = {} } } }
catalogGate:resolve({})
T.eq(
  "direct migration recognizes the catalog alias as an owner",
  { upgrade:state().rows[1].state, oldLink, writes },
  { "attention", coordinator, 0 }
)
hub.catalog = nil

fixture()
relayOwner, relayPort = 0, 0
missingReplacementBindings = true
upgrade = wizard()
review = upgrade:review({ source })
T.eq(
  "an unreadable topology is insufficient even when there is no relay to move",
  { upgrade:start(review.token, true).rows[1].state, oldLink, writes },
  { "attention", coordinator, 0 }
)

T.section("a replacement moved during HA read never gains control or receives relays")
fixture()
local readState = hub.connection.readState
local readGate = deferred.new()
hub.connection.readState = function()
  return readGate
end
upgrade = wizard()
review = upgrade:review({ source })
upgrade:start(review.token, true)
replacementRoom = 8
readGate:resolve(codec.object({ entity_id = entity, state = "off", attributes = codec.object({}) }))
T.eq("a bound replacement in the wrong room cannot displace the original", topology(), { 42, 42, 51, 1, "reserved" })
T.eq("a changed room needs attention", upgrade:state().rows[1].state, "attention")
T.eq("the moved replacement authorized zero writes", writes, 0)
hub.connection.readState = readState

T.section("an unchanged missing-load checkpoint can be revalidated across a suite update")
do
  fixture()
  local oldRevision = revision
  hub.connection.readState = function()
    local result = deferred.new()
    result:reject({ kind = "not_found" })
    return result
  end
  local controller = wizard()
  local plan = controller:review({ source })
  local blocked = controller:start(plan.token, true).rows[1]
  T.eq(
    "missing load retains the original and the staged replacement",
    { blocked.state, oldLink, relayOwner, writes },
    { "attention", coordinator, source, 0 }
  )
  T.contains(
    "the row says the selected switch could not be found",
    blocked.message,
    "couldn’t find the selected switch"
  )
  hub.connection.readState = readState
  revision = oldRevision + 1
  controller = wizard()
  T.eq("reopening preserves the retry reason", controller:state().rows[1].message, blocked.message)
  replacementRoom = 8
  T.truthy("a moved replacement still blocks release revalidation", controller:resume(plan.token).error)
  replacementRoom = 7
  T.eq("revalidation leaves ownership and bindings in place", controller:resume(plan.token).rows[1].state, "attention")
  T.eq(
    "the batch revision can advance without writes",
    { controller.batch.revision, oldLink, relayOwner, writes },
    { revision, coordinator, source, 0 }
  )
  T.eq(
    "the next explicit retry can finish loading the repaired entity",
    controller:resume(plan.token).rows[1].state,
    "upgraded"
  )
  revision = oldRevision
end

fixture()
readGate = deferred.new()
hub.connection.readState = function()
  return readGate
end
upgrade = wizard()
review = upgrade:review({ source })
upgrade:start(review.token, true)
unsafeRelay = true
readGate:resolve(codec.object({ entity_id = entity, state = "off", attributes = codec.object({}) }))
T.eq(
  "a relay that becomes ineligible during the HA read stays with the original",
  { upgrade:state().rows[1].state, oldLink, relayOwner, writes },
  { "attention", coordinator, source, 0 }
)
hub.connection.readState = readState

fixture()
readGate = deferred.new()
hub.connection.readState = function()
  return readGate
end
upgrade = wizard()
review = upgrade:review({ source })
upgrade:start(review.token, true)
upgrade.batch.records[1].phase = "cutover"
oldLink, newLink, selection = 0, 0, "matching"
upgrade:save()
upgrade:destroy()
extraPeer = { id = 90, family = "light", provider = coordinator, selected = entity }
upgrade = wizard()
upgrade:resume()
T.eq(
  "cold rollback resume does not reconnect the configured replacement before verifying ownership",
  { newLink, writes },
  { 0, 0 }
)
readGate:resolve(codec.object({ entity_id = entity, state = "off", attributes = codec.object({}) }))
T.eq(
  "a conflict during rollback resume reconnects only the original",
  { upgrade:state().rows[1].state, oldLink, newLink, relayOwner },
  { "restored", coordinator, 0, source }
)
hub.connection.readState = readState

T.section("an explicit resume restores interrupted cutover control after a suite update")
for _, interruption in ipairs({ "waiting for feedback", "both detached", "original changed", "other driver pending" }) do
  fixture()
  local previousRevision = revision
  local transfer = hub.transfer.directSwitch
  hub.transfer.directSwitch = function()
    return deferred.new()
  end
  upgrade = wizard()
  review = upgrade:review({ source })
  T.eq(
    "migration persists cutover before waiting on the replacement",
    upgrade:start(review.token, true).rows[1].state,
    "cutover"
  )
  T.eq("original released control", oldLink, 0)
  if interruption == "other driver pending" then
    local pending = codec.storedObject(codec.encode(upgrade.batch.records[1]))
    pending.source.id, pending.phase, pending.destination = source + 100, "pending", nil
    upgrade.batch.records[2] = pending
    upgrade:save()
  end
  upgrade:destroy()
  revision = revision + 1
  hub.online = false
  if interruption == "both detached" then
    newLink = 0
  elseif interruption == "original changed" then
    sourceEntity = "switch.unrelated"
  end
  local writesBefore = writes
  upgrade = wizard()
  T.eq("reopened Quick Setup offers explicit restoration", upgrade:state().interruptedCutover, true)
  T.truthy("a stale request cannot restore the original", upgrade:resume("stale token").error)
  T.eq("opening and stale actions do not change any connection", writes, writesBefore)
  local outcome = upgrade:resume(review.token)
  if interruption == "original changed" then
    T.eq("the backup is required when original identity no longer matches", outcome.rows[1].state, "recovery")
    T.eq("refused recovery does not write any connection", writes, writesBefore)
  elseif interruption == "other driver pending" then
    T.eq(
      "recovery restores original control without adopting unverified work",
      { outcome.rows[1].state, outcome.rows[2].state, oldLink, newLink, upgrade.batch.revision },
      { "recovery", "pending", coordinator, 0, previousRevision }
    )
  else
    T.eq("verified restoration persists across reopening", wizard():state().rows[1].state, "restored")
    T.eq("restoration works offline without reconnecting the replacement", topology(), { 42, 0, 51, 1, "reserved" })
    T.check(
      "offline restoration reports connections without claiming load control",
      outcome.rows[1].message:find("connections were restored", 1, true)
    )
    T.eq("restored migration can retry on the updated release", upgrade.batch.revision, revision)
    hub.online = true
    hub.transfer.directSwitch = transfer
    T.eq("a separate retry completes the migration", wizard():resume().rows[1].state, "upgraded")
  end
  hub.online = true
  hub.transfer.directSwitch = transfer
  revision = previousRevision
end

T.section("a partial rename resumes without disconnecting the active driver")
fixture()
rejectRename = true
upgrade = wizard()
review = upgrade:review({ source })
T.eq("names stay pending and removal is unavailable", upgrade:start(review.token, true).canReviewRemoval, false)
T.eq("a partial rename leaves the verified control path intact", topology(), { 0, 42, 261, 2, "ready" })
T.eq("the old driver is clearly labeled even if the new name has not changed", oldName, "Hall switch (old driver 51)")
rejectRename = false
programs = true
T.eq(
  "retrying direct naming checks programs that point to the original again",
  wizard():finishNames().rows[1].state,
  "naming"
)
programs = false
T.eq("reopening can finish names", wizard():finishNames().rows[1].state, "upgraded")
T.eq("the second rename completes", visibleName, "Hall switch")

T.section("a partial rename before programming resumes without transferring control")
fixture()
powerPrograms, rejectRename = true, true
upgrade = wizard()
review = upgrade:review({ source })
local namingPaused = upgrade:start(review.token, true)
T.eq("programming waits for both names to be verified", namingPaused.rows[1].state, "attention")
T.eq("the old name is recorded while the original still controls the load", oldName, "Hall switch (old driver 51)")
T.eq("the failed rename leaves both existing connections and the relay in place", topology(), {
  42,
  42,
  51,
  1,
  "reserved",
})
rejectRename = false
local namedForProgramming = wizard():resume().rows[1]
T.eq("reopening shows the correct names and the original programming step", {
  namedForProgramming.state,
  namedForProgramming.oldDriver,
  namedForProgramming.replacement,
  namedForProgramming.details[1].action,
}, { "review", "Hall switch (old driver 51)", "Hall switch", "Turn On" })

T.section("manual references keep the old owner and can be checked again")
fixture()
programs = true
upgrade = wizard()
review = upgrade:review({ source })
T.eq("planned manual work is visible at review", review.rows[1].message, "Prepare a replacement for review")
T.eq("preview shows detected references before confirmation", review.rows[1].programming, "found")
T.eq("the reference identifies the programming location", #review.rows[1].details, 1)
local paused = upgrade:start(review.token, true).rows[1]
T.eq("programming references park the replacement", paused.state, "review")
T.eq("the replacement uses the original name before programming", paused.replacement, "Hall switch")
T.eq("the still-connected source has the old-driver name", paused.oldDriver, "Hall switch (old driver 51)")
T.eq("manual work leaves the original controlling and wired", topology(), { 42, 42, 51, 1, "reserved" })
programs = false
local afterRemoval = wizard():resume()
T.eq("deleting the last old reference does not prove the replacement", afterRemoval.rows[1].state, "review")
T.eq("the response asks the installer to confirm the manual work", afterRemoval.rows[1].confirmProgramming, true)
T.eq("the original still controls the load before confirmation", topology(), { 42, 42, 51, 1, "reserved" })
T.truthy("a stale page cannot confirm another saved migration", wizard():resume("old-token", { source }).error)
T.truthy("the confirmation applies only to the named source", wizard():resume(afterRemoval.token, { source + 1 }).error)
programs = true
local changed = wizard():resume(afterRemoval.token, { source })
T.eq("a reference restored after the check keeps the wizard paused", changed.rows[1].state, "review")
T.eq("confirmation is unavailable while an old reference remains", changed.rows[1].confirmProgramming, nil)
T.eq("a confirmation attempt cannot transfer a load with new old references", topology(), { 42, 42, 51, 1, "reserved" })
programs = false
T.eq("the installer can recheck after removing the reference", wizard():resume().rows[1].confirmProgramming, true)
T.eq(
  "a current confirmation uses the same replacement",
  wizard():resume(afterRemoval.token, { source }).rows[1].state,
  "upgraded"
)

T.section("removing an old action cannot substitute for moving it")
fixture()
powerPrograms, destinationOn = true, 1
upgrade = wizard()
review = upgrade:review({ source })
local work = review.rows[1].details
T.eq("each power action gets an instruction", #work, 2)
T.eq(
  "the supported proxy event is named",
  { work[1].location, work[1].event },
  { "Hallway light in Hall", "Turned On" }
)
T.eq(
  "the second action specifies what to change",
  work[2].instruction,
  "Change the Turn Off action to use the new driver."
)
T.eq("original remains in control for the initial edit", upgrade:start(review.token, true).rows[1].state, "review")
powerPrograms = false
destinationOff = 1
T.eq("a pre-existing destination action does not satisfy the plan", wizard():resume().rows[1].state, "review")
local pending = wizard():state().rows[1].details
T.eq("reopened worklist shows only the missing action", #pending, 1)
T.eq("the missing action is specific", pending[1].instruction, "Add Turn On on the new driver.")
T.eq("the original remains connected while a move is unverified", topology(), { 42, 42, 51, 1, "reserved" })
T.eq("a missing mapped action does not ask for a manual confirmation", wizard():state().rows[1].confirmProgramming, nil)
destinationNamedOn = 1
T.eq(
  "adding the named action satisfies the plan alongside the saved compact action",
  wizard():resume().rows[1].state,
  "upgraded"
)
T.eq("the result keeps the names of the actions verified at cutover", wizard():state().rows[1].verifiedActions, {
  { location = "Hallway light in Hall", event = "Turned On", eventId = 5100, command = "Turn On" },
  { location = "Hallway light in Hall", event = "Turned Off", eventId = 5101, command = "Turn Off" },
})
destinationNamedOn = 0
T.eq("removal blocks if the moved action goes missing", reviewRemoval(wizard(), true, true).rows[1].state, "blocked")
destinationNamedOn = 1
T.eq(
  "removal proceeds once both moved actions are restored",
  reviewRemoval(wizard(), true, true).rows[1].state,
  "ready"
)

T.section("rollback after moving programming restores control but leaves the edited scripts")
for _, version in ipairs({ "106", "107" }) do
  fixture()
  sourceVersion, sourceMode = version, version == "107" and "direct" or nil
  powerPrograms = true
  upgrade = wizard()
  review = upgrade:review({ source })
  T.eq(
    "preserves original control while the installer moves programming",
    upgrade:start(review.token, true).rows[1].state,
    "review"
  )
  powerPrograms, destinationNamedOn, destinationOff = false, 1, 1
  rejectTransfer = true
  local rollback = wizard():resume()
  local row = rollback.rows[1]
  T.eq("failed transfer restores the original connection for " .. version, row.state, "restored")
  T.eq("only the original controls the switch after rollback", topology(), { 42, 0, 51, 1, "reserved" })
  T.eq("programming edits stay on the staged replacement", { destinationNamedOn, destinationOff }, { 1, 1 })
  T.eq("the old driver is unavailable for removal", rollback.canReviewRemoval, false)
  T.check(
    "recovery tells the installer how to restore edited programming",
    row.message:find("Restore the project backup to undo those edits.", 1, true)
  )
  rejectTransfer = false
  T.eq("retry reuses the confirmed programming and replacement", wizard():resume().rows[1].state, "upgraded")
end

T.section("a failed transfer restores only the original after disabling the replacement")
for _, version in ipairs({ "106", "107" }) do
  fixture()
  sourceVersion, sourceMode = version, version == "107" and "direct" or nil
  rejectTransfer = true
  upgrade = wizard()
  review = upgrade:review({ source })
  T.eq(
    "failed configuration returns a verified recovery for " .. version,
    upgrade:start(review.token, true).rows[1].state,
    "restored"
  )
  T.eq(
    "original ownership returns and the relay stays in place for " .. version,
    topology(),
    { 42, 0, 51, 1, "reserved" }
  )
end

T.section("retry may reuse a configured replacement only after releasing the original")
fixture()
local ordinaryTransfer = hub.transfer.directSwitch
hub.transfer.directSwitch = function()
  selection = "matching"
  local task = deferred.new()
  task:reject("late or missing feedback")
  return task
end
upgrade = wizard()
review = upgrade:review({ source })
T.eq("rollback leaves the selected replacement detached", upgrade:start(review.token, true).rows[1].state, "restored")
T.eq("only the old driver owns the load after rollback", topology(), { 42, 0, 51, 1, "matching" })
hub.transfer.directSwitch = function()
  error("retry must reuse the existing detached selection")
end
T.eq("retry binds only after the old owner releases", wizard():resume().rows[1].state, "upgraded")
T.eq("migration leaves a single replacement owner", topology(), { 0, 42, 261, 2, "ready" })
hub.transfer.directSwitch = ordinaryTransfer

T.section("changed original facts prevent rollback from transferring ownership")
fixture()
hub.transfer.directSwitch = function()
  sourceEntity = "switch.unrelated"
  local task = deferred.new()
  task:reject("project changed")
  return task
end
upgrade = wizard()
review = upgrade:review({ source })
T.eq("a changed original requires manual recovery", upgrade:start(review.token, true).rows[1].state, "recovery")
T.eq("rollback never connects the changed original or moves the relay", topology(), { 0, 42, 51, 1, "reserved" })
hub.transfer.directSwitch = ordinaryTransfer

T.section("a failed deferred readiness read settles through rollback")
fixture()
hub.transfer.directSwitch = function()
  selection = "matching"
  return resolved(true)
end
local timer, originalTimer = nil, SetTimer
SetTimer = function(_, _, callback)
  timer = callback
  return true
end
upgrade = wizard()
review = upgrade:review({ source })
T.truthy("readiness schedules a verification tick", upgrade:start(review.token, true).running and timer)
local installed = require("ha.installed-suite")
local revisionRead = installed.upgradeRevision
installed.upgradeRevision = function()
  error("test readback fault")
end
timer()
installed.upgradeRevision, SetTimer = revisionRead, originalTimer
T.eq("the failure settles with one verified owner", upgrade:state().rows[1].state, "restored")
T.eq("rollback detaches the unverified replacement", topology(), { 42, 0, 51, 1, "matching" })
hub.transfer.directSwitch = ordinaryTransfer
T.finish()
