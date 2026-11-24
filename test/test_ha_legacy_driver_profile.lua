local T = require("testlib")
local assessment = require("ha.migration-assessment")
local project = require("ha.commissioning-project")
local Upgrade = require("ha.switch-upgrade")

local filename = "chowmain_homeassistant_light.c4z"
local room = {
  roomId = 7,
  roomName = "Hall",
  deviceName = "Legacy lamp",
  driverFileName = filename,
  proxies = { [81] = { driverFileName = "light_v2.c4i" } },
}
local metadata = { manufacturer = "Home Assistant", model = "Home Assistant Light ", version = "20261008" }
local properties = {
  ["Device Address Selection"] = "Automatic",
  ["Entity ID Selected"] = "[switch.lamp] Hall lamp",
  ["Entity ID"] = "light.stale_manual",
}
local bindings = {}
for _, id in ipairs({ 5, 81, 82, 83, 86, 87, 88, 91, 92, 93, 5001 }) do
  local class = id == 5 and "HOMEASSISTANT_DEVICES" or id == 5001 and "LIGHT_V2" or "BUTTON_LINK"
  bindings[id] = { bindingclasses = { { class = class } }, provider = id ~= 5 }
end

function C4:GetDevices(filter)
  if filter.DeviceIds == "80" or filter.C4iNames and filter.C4iNames:find(filename, 1, true) then
    return { [80] = room }
  end
  if filter.DeviceIds == "81" then
    return { [81] = { protocol = { [80] = true }, driverFileName = "light_v2.c4i" } }
  end
  return {}
end

function C4:GetDeviceData(_, field)
  return metadata[field]
end

function GetDeviceBindings(id)
  return id == 80 and bindings or {}
end

function GetDeviceProperties()
  return properties
end

T.section("Legacy HA sources require their declared protocol and proxy")
T.eq("existing migration discovery remains scoped", #assessment.sources("light"), 0)
T.eq("the explicit review can discover the Light", #assessment.sources("light", true), 1)
local function inspect()
  return assessment.assess(81, { skipPrograms = true })
end
local light = inspect()
T.truthy("matching bindings and proxy are recognized", light.interfaces)
T.eq("automatic selection keeps the switch-as-Light target", { light.family, light.entity }, { "light", "switch.lamp" })
T.eq(
  "the owned unavailable event maps by exact source identity",
  assessment.programReference({ device = 80, event = 1 }, light).replacementEventId,
  require("ha.identities").lightUnavailableEvent
)
T.eq(
  "the same event ID on a different device has no mapping",
  assessment.programReference({
    device = 81,
    event = 1,
  }, light).replacementEventId,
  nil
)
room.proxies[82] = { driverFileName = "light_v2.c4i" }
T.falsy("multiple proxies are ambiguous", inspect().interfaces)
room.proxies[82] = nil
bindings[87].provider = false
T.falsy("mismatched binding direction blocks qualification", inspect().interfaces)
bindings[87].provider = true
metadata.version = "20261009"
T.eq("unqualified revisions are rejected", inspect(), nil)
metadata.version = "20261008"
properties["Device Address Selection"] = "Manual"
T.truthy("conflicting manual and current target remains unresolved", inspect().selection_disagrees)
properties["Entity ID Selected"] = "light.stale_manual"
T.eq("verified manual selection resolves", inspect().entity, "light.stale_manual")
properties["Entity ID Selected"] = "[No Devices Selected]"
T.eq("the live empty automatic selector does not conflict with a manual entity", inspect().entity, "light.stale_manual")
properties["Entity ID Selected"] = "light.stale_manual"
T.eq("unreadable compatibility settings stay unresolved", inspect().compatibility, nil)
properties["Light Type"] = "Color / CCT"
properties["Preferred Color Mode"] = "HS"
properties["Color Temperature (K) - Minimum"] = "2750"
properties["Color Temperature (K) - Maximum"] = "5500"
T.eq("review projects only recognized settings", inspect().compatibility, {
  kind = "Color and white temperature",
  format = "HS",
  minK = 2750,
  maxK = 5500,
})

T.section("Incoming native proxy actions keep their known semantics")
local function action(target, command)
  return { device = target, cmdcond = { xml = "<devicecommand><command>" .. command .. "</command></devicecommand>" } }
end
local references = assessment.assess(81, {
  lighting = { scenes = {}, groups = {} },
  programming = {
    event_mgr = {
      {
        deviceid = 120,
        eventid = 7,
        codeitem = { device = 0, subitems = { action(81, "OFF"), action(81, "UNMAPPED") } },
      },
    },
  },
}).programs
T.eq("agent event and both references are inventoried", {
  references.incoming[1].device,
  references.incoming[1].event,
  references.incoming[1].actionCount,
}, { 120, 7, 2 })
T.eq("only a known unconditional power action is mapped", references.incoming[1].commands, { TurnOff = 1 })

T.section("An identity check can skip scene snapshots while still verifying programming")
do
  local previous, projectReads = C4.GetProjectItems, 0
  function C4:GetProjectItems()
    projectReads = projectReads + 1
    return "<systemitems/>"
  end
  local programming = { event_mgr = {} }
  local baseline = assessment.assess(81, { programming = programming })
  T.eq("a full legacy assessment reads device groups and scene definitions", projectReads, 2)
  projectReads = 0
  local current = assessment.assess(81, { programming = programming, skipLighting = true })
  T.eq("the cutover identity check runs without a redundant project read", projectReads, 0)
  T.eq("the identity check still captures the source and programming", {
    current.entity,
    current.interfaces,
    current.programs,
  }, { baseline.entity, baseline.interfaces, baseline.programs })
  C4.GetProjectItems = previous
end

T.section("Native Light power events can carry a single verified Timer Agent action")
do
  local previous = C4.GetProjectItems
  function C4:GetProjectItems()
    return "<systemitems><item><id>120</id><c4i>control4_agent_timer.c4i</c4i></item></systemitems>"
  end
  local action = {
    device = 120,
    type = 1,
    cmdcond = {
      xml = "<devicecommand><command>StartTimer</command><params><param><name>id</name>"
        .. '<value type="INTEGER"><static>7</static></value></param></params></devicecommand>',
    },
  }
  local event = { deviceid = 81, eventid = 5100, codeitem = { device = 0, subitems = { action } } }
  local function proof()
    local report = assessment.assess(81, {
      lighting = { scenes = {}, groups = {} },
      programming = { event_mgr = { event } },
    })
    return report.programs.attached[1].timerScript
  end
  local saved = proof()
  T.truthy("the saved timer command and argument produce a verification fingerprint", saved)
  action.cmdcond.xml = action.cmdcond.xml:gsub(">7<", ">8<")
  T.truthy("a different timer cannot pass the saved fingerprint", proof() ~= saved)
  action.device = 121
  T.falsy("an action on a different device cannot be accepted as a timer action", proof())
  action.device = 120
  event.codeitem.subitems[2] = { device = 120 }
  T.falsy("a multi-action script remains blocked", proof())
  C4.GetProjectItems = previous
end

T.section("Read-only ownership checks include additional legacy peers")
bindings[5].isbound = true
bindings[5].deviceid = 80
bindings[5].boundprovider = { bound = { deviceid = 45, bindingid = 5 } }
function C4:GetBoundProviderDevice(id, port)
  return id == 80 and port == 5 and 45 or 0
end
function C4:GetDevicesByC4iName(file)
  return file == "chowmain_homeassistant_gateway.c4z" and { [45] = true } or {}
end
T.eq("normal commissioning stays scoped", #project.inventory(), 0)
T.eq("additional inventory reports the verified provider and selection", {
  project.inventory(true)[1].legacy_provider,
  project.inventory(true)[1].selected,
}, { 45, "light.stale_manual" })
local wizard = {
  coordinator = 42,
  hub = {
    catalog = {
      endpointKeys = function(_, keys)
        return { [keys[1]] = true, ["light.stale_manual"] = true }
      end,
    },
  },
}
local source = { id = 90, origin = light.origin }
local free, conflict = Upgrade.checkOwnership(wizard, { source = source }, nil, {
  entity_id = "switch.alias",
  registry_id = "registry",
})
T.falsy("a verified alias cannot acquire a second owner", free)
T.eq("review can name the conflicting project device", conflict.name, "Legacy lamp")
bindings[5].boundprovider = nil
T.eq("incomplete binding evidence does not establish ownership", project.inventory(true)[1].legacy_provider, nil)
T.falsy(
  "inconclusive ownership keeps the review pending",
  Upgrade.checkOwnership(wizard, { source = source }, nil, {
    entity_id = "switch.alias",
    registry_id = "registry",
  })
)

T.section("The Switch profile has a distinct proxy and semantic relay")
local profile = require("ha.legacy-driver-profile").identify(
  "chowmain_homeassistant_switch.c4z",
  "Home Assistant Switch",
  "Home Assistant",
  "20261008"
)
T.eq("the Switch declares its own proxy and relay port", { profile.proxy, profile.bindings[10].class }, {
  "uibutton.c4i",
  "RELAY",
})
do
  local oldFilename, oldProxy, oldModel, oldBindings =
    filename, room.proxies[81].driverFileName, metadata.model, bindings
  filename = "chowmain_homeassistant_switch.c4z"
  room.driverFileName, room.proxies[81].driverFileName = filename, "uibutton.c4i"
  metadata.model = "Home Assistant Switch"
  bindings = {
    [5] = { bindingclasses = { { class = "HOMEASSISTANT_DEVICES" } }, provider = false },
    [10] = { bindingclasses = { { class = "RELAY" } }, provider = true },
    [5001] = { bindingclasses = { { class = "UIBUTTON" } }, provider = true },
  }
  local report = assessment.assess(80, {
    programming = {
      event_mgr = {
        { deviceid = 120, eventid = 7, codeitem = { device = 0, subitems = { action(81, "Select") } } },
      },
    },
  })
  T.truthy("the source identifies as the legacy Switch", report and report.interfaces)
  T.eq("its native Select retains Toggle semantics", report.programs.incoming[1].positions, { ["1"] = "Toggle" })
  filename, room.driverFileName, room.proxies[81].driverFileName = oldFilename, oldFilename, oldProxy
  metadata.model, bindings = oldModel, oldBindings
end
T.section("Configured gateway origins include the actual port and TLS choice")
do
  local legacy = require("ha.legacy-driver-profile")
  local previous = C4.GetNetworkConnections
  local rows = {
    { deviceid = 45, bindingid = 6001, address = "Unrelated.Test" },
    { deviceid = 45, bindingid = 6000, address = "Ha.Test" },
  }
  C4.GetNetworkConnections = function()
    return { IP = rows }
  end
  properties.Port, properties["Use SSL"] = "8124", "False"
  T.eq(
    "the legacy HTTP route includes its configured port",
    legacy.gatewayOrigin(45, legacy.networkAddresses()),
    "http://ha.test:8124"
  )
  T.eq(
    "the same host through a different route stays distinct",
    legacy.canonicalOrigin("https://ha.test:8444"),
    "https://ha.test:8444"
  )
  T.eq("implicit HTTPS port and host case normalize", legacy.canonicalOrigin("https://HA.Test/"), "https://ha.test:443")
  rows[3] = rows[2]
  T.eq(
    "ambiguous binding evidence does not provide an origin",
    legacy.gatewayOrigin(45, legacy.networkAddresses()),
    nil
  )
  C4.GetNetworkConnections = previous
end
T.section("The existing device review exposes additional legacy references read-only")
do
  require("drivers-common-public.global.lib")
  local review
  require("ha.switch-migration").install(function(_, _, callback)
    review = callback
  end, "light", function() end)
  function C4:GetAllCodeItems()
    return { event_mgr = {} }
  end
  function C4:GetProjectItems(filter)
    if filter == "AGENTS" then
      local state = "<State><all_scenes><AdvScene><name>Fixture scene</name><scene_id>0</scene_id>"
        .. "<all_members><AdvSceneMember><device_id>81</device_id><all_elements /></AdvSceneMember></all_members>"
        .. "</AdvScene></all_scenes></State>"
      return "<systemitems><item><c4i>control4_agent_adv_lighting.c4i</c4i><state>"
        .. XMLEncode(state)
        .. "</state></item></systemitems>"
    end
    return "<systemitems />"
  end
  local reply
  review({}, { action = "open" }, function(result)
    reply = result
  end)
  T.eq("the explicit review lists the additional source", reply.sources[1].id, 80)
  review({}, { action = "preview", source = 81 }, function(result)
    reply = result
  end)
  T.contains("the preview names the saved scene", table.concat(reply.lines, "\n"), "Fixture scene")
  T.falsy("read-only review cannot save a cutover", reply.can_save)
end

T.section("Migration scan waits for a verified device catalog")
do
  local deferred = require("deferred")
  local setupPage = require("ha.setup-page")
  local originalCommands = setupPage.commands
  local handler
  setupPage.commands = function()
    return function(_, _, callback)
      handler = callback
    end
  end
  local online = { verified = false, scanned = 0 }
  local request
  online.catalog = {
    hasVerifiedSnapshot = function()
      return online.verified
    end,
    refresh = function(_, force)
      request = deferred.new()
      request.force = force
      return request
    end,
  }
  online.switchUpgrade = {
    scanReadiness = function()
      return 2026112325
    end,
    list = function()
      online.scanned = online.scanned + 1
      return { { state = "ready", id = 80 } }
    end,
    start = function()
      return { started = true }
    end,
    resume = function()
      return { resumed = true }
    end,
  }
  online.online = true
  require("ha.switch-upgrade-page").install(function()
    return online
  end)
  setupPage.commands = originalCommands
  local reply
  local function send(params)
    reply = nil
    handler(online, params, function(result)
      reply = result
    end)
  end
  send({ action = "scan" })
  T.eq("a cold scan waits for discovery", { request.force, online.scanned }, { false, 0 })
  online.verified = true
  request:resolve({})
  T.eq("a successful discovery lets the scan offer the driver", reply.rows[1].state, "ready")
  send({ action = "scan", refresh = true })
  T.eq("refresh checks Home Assistant again before scanning", { request.force, online.scanned }, { true, 1 })
  request:reject({ kind = "timeout" })
  T.truthy("discovery failure is shown instead of an incorrect blocked driver list", reply.error)
  T.eq("failure never scans the stale catalog", online.scanned, 1)
  local records = { { source = { origin = "Legacy HA" }, phase = "prepared" } }
  online.switchUpgrade.preview = { records = records }
  send({ action = "start" })
  T.eq("legacy start waits for fresh registry data", { request.force, reply }, { true })
  request:resolve({})
  T.truthy("legacy start proceeds after catalog refresh", reply.started)
  online.switchUpgrade.batch = { records = records }
  request = nil
  send({ action = "resume" })
  T.eq("legacy resume reuses an available catalog for its exact runtime checks", { reply.resumed, request }, { true })
  online.verified = false
  send({ action = "resume" })
  T.eq("legacy resume refreshes after loss of the verified snapshot", { request.force, reply }, { true })
  request:reject({ kind = "timeout" })
  T.truthy("legacy resume reports failed recovery of its catalog", reply.error)
  send({ action = "resume" })
  online.verified = true
  request:resolve({})
  T.truthy("reconnection allows resume without an unrelated browse", reply.resumed)
end

T.finish()
