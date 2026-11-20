local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
local persist = require("lib.persist")
local assess = require("ha.migration-assessment")
local coordinator, source, replacement, relay = 42, 51, 261, 80
local revision = 2026111901
local entity = "switch.ac"
local oldLink, newLink, relayOwner, relayPort, selection, writes, programs, rejectTransfer
local powerPrograms, destinationOn, destinationNamedOn, destinationOff
local oldName, visibleName, retired, rejectRename
local sourceVersion, sourceMode, sourceEntity, olderPresent
local stagedName, replacementPresent, duplicatePrepared, replacementRoom
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
  powerPrograms, destinationOn, destinationNamedOn, destinationOff = false, 0, 0, 0
  oldName, visibleName, retired, rejectRename = "Hall switch", "Rehearsal replacement", false, false
  sourceVersion, sourceMode, sourceEntity, olderPresent = "106", nil, entity, false
  stagedName, replacementPresent, duplicatePrepared = "Home Assistant Switch", true, false
  replacementRoom = 7
end
local function report()
  if retired then
    return nil
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
    interfaces = true,
    entity = sourceEntity,
    edges = relayOwner == source and {
      { binding = 1, owner = source, direction = "output", device = relay, port = 5 },
    } or {},
    programs = {
      readable = true,
      attached = {},
      incoming = programs and { { device = 95, event = 8, actionCount = 1 } } or powerPrograms and {
        { device = 95, event = 5100, actionCount = 1, commands = { ["Turn On"] = 1 } },
        { device = 95, event = 5101, actionCount = 1, commands = { ["Turn Off"] = 1 } },
      } or {},
    },
  }
end

package.loaded["ha.migration-assessment"] = {
  programReference = assess.programReference,
  switchMigrationModeIssue = assess.switchMigrationModeIssue,
  switchSelectionIssue = assess.switchSelectionIssue,
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
      selected = selection == "blank" and "" or entity,
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
  assert(oldLink == 0 and newLink == coordinator and relayOwner == replacement, "Rename requires verified cutover")
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
end
function C4:Unbind(id, input)
  writes = writes + 1
  if id == source and input == 999 then
    oldLink = 0
  elseif id == replacement and input == 1 then
    newLink = 0
  elseif id == relay and input == 5 then
    relayOwner, relayPort = 0, 0
  else
    error("unexpected unbind")
  end
end
local Upgrade = require("ha.switch-upgrade")
function GetDeviceBindings(id, _, _, _, _)
  if id == source then
    return {
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
    return { [2] = { deviceid = replacement, provider = true } }
  end
  return {}
end
function SendUIRequest(id, request, args)
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
for _, mode in ipairs({ "bridge", "buttons", false }) do
  fixture()
  sourceVersion, sourceMode = "107", mode or nil
  local controller = wizard()
  local row = controller:list()[1]
  T.eq("the prototype stays visible when it requires attention", controller:availability().count, 1)
  T.eq("the mode is blocked before deployment", row.state, "blocked")
  T.check(
    "the message tells the installer where to check the mode or get migration instructions",
    row.message:find(mode and "Documentation" or "Operation Mode", 1, true) ~= nil
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
T.truthy("cleanup review requires testing confirmation", upgrade:reviewRemoval(false).error)
T.eq("only the safely retired driver is offered", upgrade:reviewRemoval(true).rows, {
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
  upgrade:reviewRemoval(true).rows[1].message,
  "Keep this driver and check its name, connections and programming."
)
programs = false
relayOwner, relayPort = 99, 5
T.eq("a redirected relay blocks removal", upgrade:reviewRemoval(true).rows[1].state, "blocked")
relayOwner, relayPort = replacement, 2
retired = true
T.eq(
  "cleanup checks removal after the installer deletes the old driver",
  upgrade:reviewRemoval(true).rows[1].message,
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
      { source = older, phase = "upgraded", namesVerified = true, retiredName = "Previous switch (old driver 59)" },
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
  wizard():reviewRemoval(true).rows[2].name,
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

T.section("a partial rename resumes without disconnecting the active driver")
fixture()
rejectRename = true
upgrade = wizard()
review = upgrade:review({ source })
T.eq("names stay pending and removal is unavailable", upgrade:start(review.token, true).canReviewRemoval, false)
T.eq("a partial rename leaves the verified control path intact", topology(), { 0, 42, 261, 2, "ready" })
T.eq("the old driver is clearly labeled even if the new name has not changed", oldName, "Hall switch (old driver 51)")
rejectRename = false
T.eq("reopening can finish names", wizard():finishNames().rows[1].state, "upgraded")
T.eq("the second rename completes", visibleName, "Hall switch")

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
T.eq("manual steps identify the prepared proxy by its visible name", paused.replacement, "Rehearsal replacement")
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
T.eq("removal blocks if the moved action goes missing", wizard():reviewRemoval(true).rows[1].state, "blocked")
destinationNamedOn = 1
T.eq("removal proceeds once both moved actions are restored", wizard():reviewRemoval(true).rows[1].state, "ready")

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
