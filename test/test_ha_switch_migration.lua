local T = require("testlib")
local codec = require("ha.codec")
local persist = require("lib.persist")
local assessment = require("ha.migration-assessment")
local migration = require("ha.switch-migration")
local ids = require("ha.identities")
local raw, variables, property, version, link, peer, changes, programs, reads, failBind
local roles =
  { [1] = "RELAY", [999] = "HA_DEVICE", [200] = "BUTTON_LINK", [201] = "BUTTON_LINK", [202] = "BUTTON_LINK" }
local owner = {
  consumer = {
    readiness = {
      view = function()
        return { available = true, evidence_ready = true }
      end,
    },
  },
  mode = function()
    return "Home Assistant device"
  end,
}
local secret = "PRIVATE_TEST_PAYLOAD"
local function fixture(v)
  persist:delete("HA.SwitchMigration.v1")
  version, link, peer, changes, reads, failBind = v, 10, { id = 51, port = 1 }, 0, 0, false
  property, variables = "switch.hall", "switch.hall"
  owner.config, owner.working, owner.pending = nil, nil, nil
  programs = {
    event_mgr = {
      { deviceid = 51, eventid = 100, codeitem = { device = 0, cmdcond = { xml = secret } } },
      { deviceid = 101, eventid = 2, codeitem = { device = 0, subitems = { { device = 51, display = secret } } } },
      { deviceid = 102, eventid = 3, codeitem = { device = 999, cmdcond = { xml = secret } } },
    },
  }
end
function C4:GetDeviceID()
  return 54
end
function C4:GetDevices(filter)
  reads = reads + 1
  local b = { deviceName = "Hall switch", roomId = 7, roomName = "Hall", driverFileName = "HA.Switch.c4z" }
  if filter.C4iNames or filter.DeviceIds == "51" then
    return { [51] = b }
  end
  if filter.DeviceIds == "54" then
    return {
      [54] = { deviceName = "Replacement", roomId = 7, roomName = "Hall", driverFileName = ids.packages.switch.file },
    }
  end
  if filter.DeviceIds == "102" then
    return { [102] = { driverFileName = "agent.c4i" } }
  end
  return {}
end
function C4:GetDeviceData(_, tag)
  return ({ model = "HA Switch", manufacturer = "BP", version = version })[tag]
end
function C4:GetDeviceVariables()
  return { [1001] = { name = "ENTITY_ID", value = variables, type = "STRING" } }
end
function GetDeviceProperties()
  return { ["Entity ID"] = property, ["Operation Mode"] = version == "107" and "Direct" or nil, secret = secret }
end
function C4:GetAllCodeItems()
  return programs
end
function GetDeviceBindings(id)
  if id == 51 then
    local rows = {}
    for port, class in pairs(roles) do
      rows[port] = {
        deviceid = 51,
        bindingid = port,
        provider = port ~= 999,
        bindingclasses = { { class = class } },
        isbound = false,
      }
    end
    if peer.id == 51 then
      rows[1].boundconsumers = { { deviceid = 80, bindingid = 5 } }
      rows[1].isbound = true
    end
    if link ~= 0 then
      rows[999].boundprovider = { bound = { deviceid = link, bindingid = 1 } }
      rows[999].isbound = true
    end
    return rows
  elseif id == 80 then
    return {
      [5] = {
        deviceid = id,
        isbound = peer.id ~= 0,
        boundprovider = peer.id ~= 0 and { bound = { deviceid = peer.id, bindingid = peer.port } } or nil,
      },
    }
  elseif id == 54 then
    return { [2] = { deviceid = 54, provider = true, bindingclasses = { { class = "RELAY" } } } }
  end
  return {}
end
function C4:GetBoundProviderDevice(id)
  return id == 51 and link or peer.id
end
function C4:Unbind(id, port)
  assert(id == 80 and port == 5)
  changes = changes + 1
  peer = { id = 0, port = 0 }
end
function Bind(id, port, to, input, class)
  assert(to == 80 and input == 5 and class == "RELAY")
  changes = changes + 1
  if failBind then
    error(secret)
  end
  peer = { id = id, port = port }
end
UIR = UIR or {}
UIR.suppressDebug = UIR.suppressDebug or {}
local function attach()
  migration.install(
    function(cmd, response, cb)
      T.eq("migration exposes a single explicit request", cmd, "HA_MIGRATION")
      raw = cb
    end,
    "switch",
    function()
      return owner
    end
  )
end
local function action(name, params)
  params = params or {}
  params.action = name
  params.request = "test-" .. name
  local result
  raw(owner, params, function(value)
    result = value
  end)
  T.check(
    "private program bodies, properties and API errors remain private",
    not codec.encode(result):find(secret, 1, true)
  )
  return result
end
for _, v in ipairs({ "106", "107" }) do
  T.section("explicit migration and interruption recovery, version " .. v)
  fixture(v)
  attach()
  T.eq("handler installation does not inspect or modify the project", { reads, changes }, { 0, 0 })
  T.eq("opening the tool lists current original", action("open").sources[1].id, 51)
  local preview = action("preview", { source = 51 })
  T.truthy("source interface and live entity verified", preview.can_save)
  local visible = table.concat(preview.lines, " ")
  T.check(
    "lists original and other program owners",
    visible:find("device 51, event 100", 1, true) and visible:find("device 101, event 2", 1, true)
  )
  T.eq("cancel has no effect", action("cancel", { token = preview.token }).phase, "closed")
  T.truthy("cancelled token cannot save", action("save", { token = preview.token, backup = true }).error)
  preview = action("preview", { source = 51 })
  T.truthy("backup confirmation required", action("save", { token = preview.token }).error)
  variables = "switch.other"
  T.truthy("changed project invalidates preview", action("save", { token = preview.token, backup = true }).error)
  variables = property
  local oldDevices = C4.GetDevices
  C4.GetDevices = function(self, filter)
    if filter.C4iNames == ids.packages.switch.file then
      return { [79] = { driverFileName = ids.packages.switch.file } }
    end
    return oldDevices(self, filter)
  end
  local oldRead = SendUIRequest
  SendUIRequest = function()
    return "<migration>in-use</migration>"
  end
  preview = action("preview", { source = 51 })
  T.truthy(
    "a competing replacement plan preserves the old owner",
    action("save", { token = preview.token, backup = true }).error
  )
  C4.GetDevices, SendUIRequest = oldDevices, oldRead
  preview = action("preview", { source = 51 })
  T.eq("confirmation only saves a plan", action("save", { token = preview.token, backup = true }).phase, "staged")
  local deferred = require("deferred")
  owner.consumer.request = function(_, kind, entity)
    T.eq("availability check is read-only for the exact target", { kind, entity }, { "verify_target", "switch.hall" })
    local result = deferred.new()
    result:reject({ kind = "unavailable" })
    return result
  end
  T.truthy("failed HA preflight keeps source in control", action("check").error)
  owner.consumer.request = function()
    local result = deferred.new()
    result:resolve({ status = "verified" })
    return result
  end
  T.eq("check before disconnect confirms a usable replacement route", action("check").can_configure, false)
  T.truthy("configured old source blocks use of saved settings", action("configure", { confirmed = true }).error)
  T.eq("all earlier stages preserve original relay", { peer.id, changes }, { 51, 0 })
  require("c4_fixtures").coldStoredObject("HA.SwitchMigration.v1")
  attach()
  local reopened = action("open")
  T.eq("resumes from durable checkpoint", reopened.phase, "staged")
  T.eq(
    "active old switch hides unsafe and premature actions",
    { reopened.can_configure, reopened.can_transfer, reopened.can_rollback },
    { false, false, false }
  )
  T.truthy("moving needs separate confirmation", action("transfer").error)
  T.truthy("old owner must be retired first", action("transfer", { confirmed = true }).error)
  property, variables, link = "", "", 0
  T.truthy("verified target readiness required", action("transfer", { confirmed = true }).error)
  T.eq(
    "retired source offers configuration only",
    { action("status").can_configure, action("status").can_transfer },
    { true, false }
  )
  local change = UpdateProperty
  Properties["Manual entity ID"] = ""
  UpdateProperty = function(name, value, notify)
    T.eq(
      "confirmed transfer uses standard verified manual property",
      { name, value, notify },
      { "Manual entity ID", "switch.hall", true }
    )
  end
  T.eq("saved setup can run only after original retires", action("configure", { confirmed = true }).phase, "staged")
  UpdateProperty = change
  owner.config = { controlled_load = { entity_id = "switch.hall" } }
  failBind = true
  T.truthy("failed bind returns a private actionable error", action("transfer", { confirmed = true }).error)
  T.eq("mid-transfer disconnection is inspectable", peer.id, 0)
  failBind = false
  attach()
  T.eq("interrupted operation resumes on saved pair", action("transfer", { confirmed = true }).phase, "staged")
  T.eq("relay readback matches suite mapping", peer, { id = 54, port = 2 })
  T.eq(
    "completed relay phase offers instructions instead of another move",
    { action("status").can_transfer, action("status").can_rollback },
    { false, false }
  )
  local done = changes
  action("transfer", { confirmed = true })
  T.eq("retry does not alter the verified pair", changes, done)
  T.truthy("active replacement blocks rollback", action("rollback", { confirmed = true }).error)
  owner.config = nil
  peer = { id = 99, port = 2 }
  T.truthy("foreign provider cannot be stolen", action("rollback", { confirmed = true }).error)
  peer = { id = 54, port = 2 }
  T.eq("explicit restore verifies the old provider", action("rollback", { confirmed = true }).phase, "staged")
  T.eq("old relay restored exactly", peer, { id = 51, port = 1 })
end
T.section("Light assessment resolves the protocol and proxy and never offers replacement writes")
for _, ver in ipairs({ "106", "1" }) do
  fixture(ver)
  local oldLookup, oldData, oldBindings = C4.GetDevices, C4.GetDeviceData, GetDeviceBindings
  C4.GetDevices = function(_, filter)
    if filter.DeviceIds == "61" then
      return { [61] = { protocol = { [60] = {} } } }
    end
    return {
      [60] = {
        deviceName = "Desk light",
        roomName = "Office",
        roomId = 10,
        driverFileName = "HA.Light.c4z",
        proxies = { [61] = { driverFileName = "light_v2.c4i" } },
      },
    }
  end
  C4.GetDeviceData = function(_, id, tag)
    return ({ manufacturer = "BP", model = "HA Light", version = ver })[tag]
  end
  GetDeviceBindings = function(id)
    if id == 61 then
      return {}
    end
    local bindings = {}
    for _, port in ipairs({ 999, 5001, 200, 201, 202, 203, 204, 205 }) do
      if ver == "1" or (port ~= 203 and port ~= 204 and port ~= 205) then
        bindings[port] = {
          deviceid = 60,
          provider = port ~= 999 and not (port >= 203 and port <= 205),
          bindingclasses = {
            { class = port == 999 and "HA_DEVICE" or port == 5001 and "LIGHT_V2" or "BUTTON_LINK" },
          },
        }
      end
    end
    return bindings
  end
  local r = assessment.assess(61)
  T.eq(
    "source metadata, topology and proxy match exact Light source",
    { r.id, r.family, r.version, r.interfaces, r.proxies[1].id },
    { 60, "light", ver, true, 61 }
  )
  migration.install(
    function(_, _, cb)
      raw = cb
    end,
    "light",
    function()
      return owner
    end
  )
  local show = action("preview", { source = 61 })
  T.eq("Light assessment remains read-only", show.can_save, false)
  T.truthy("even direct save call is refused on Light", action("save", { token = show.token, backup = true }).error)
  C4.GetDevices, C4.GetDeviceData, GetDeviceBindings = oldLookup, oldData, oldBindings
end
T.finish()
