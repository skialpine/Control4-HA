-- The driver entry points, template UIR, selection state, Coordinator and private
-- protocol are real. The fixtures supply Director bindings and HA replies.
local T = require("testlib")
local clock = require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local ids = require("ha.identities")
local Hub = require("ha.hub")
local metrics = require("ha.performance").shared
local deferred = require("deferred")
local persist = require("lib.persist")
local constants = require("constants")
local root = (arg[0]:match("^(.*[/])") or "") .. "../"
local coordinator, consumer = 10, 21
local current = consumer
local saved = "HA.DeviceSelection"
local config, family, links, pushes, attribs, selected, icons, levels
local providerId = coordinator
local requestedLEDLink
local function coordinatorInput()
  return family == "light" and ids.lightCoordinatorBinding or ids.coordinatorBinding
end
local function wire(value)
  return codec.decode(codec.encode(value))
end

local function at(device, fn)
  local previous = current
  current = device
  local ok, result = pcall(fn)
  current = previous
  assert(ok, result)
  return result
end

function C4:GetVersionInfo()
  return { version = "3.4.3" }
end
function C4:GetDriverConfigInfo(key)
  return ({ config = config, minimum_os_version = ids.minimumOS, version = "20261117" })[key]
end
function C4:GetDeviceID()
  return current
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:UpdatePropertyList(name, _, selectedValue)
  Properties[name] = selectedValue
end
function C4:SetPropertyAttribs(name, value)
  attribs[name] = value
end
function C4:GetBoundProviderDevice(device, binding)
  if device ~= consumer then
    return 0
  end
  if binding == coordinatorInput() then
    return providerId
  end
  local bound = links[binding] and links[binding].boundprovider
  return bound and bound.bound.deviceid or 0
end
function C4:GetDeviceDisplayName(device)
  return ({ [30] = "Stair Lights", [31] = "Hall Light", [32] = "Kitchen Light" })[device]
end
function C4:GetBindingsByDevice(device)
  local records = {}
  if device == consumer then
    for _, record in pairs(links) do
      records[#records + 1] = record
    end
  end
  if providerId ~= 0 then
    records[#records + 1] = {
      bindingid = device == coordinator and ids.coordinatorBinding or coordinatorInput(),
      provider = device == coordinator,
      bindingclasses = { { class = ids.coordinatorClass } },
      boundprovider = device == consumer and {
        bound = { deviceid = coordinator, bindingid = 1, boundclasses = { ids.coordinatorClass } },
      } or nil,
      boundconsumers = device == coordinator and {
        { deviceid = consumer, bindingid = coordinatorInput(), boundclasses = { ids.coordinatorClass } },
      } or nil,
    }
  end
  return { bindings = records }
end
function C4:SendDataToUI(command, params)
  pushes[#pushes + 1] = { command = command, data = codec.decode(params.json) }
end
function C4:SendToProxy(binding, command, params)
  if command == "REQUEST_BUTTON_COLORS" then
    requestedLEDLink = binding
  elseif binding == ids.proxy and command == "ICON_CHANGED" then
    icons[#icons + 1] = params.icon
  elseif binding == ids.proxy and command == "LIGHT_BRIGHTNESS_CHANGED" then
    levels[#levels + 1] = params.LIGHT_BRIGHTNESS_CURRENT
  end
end
local function request(command, params)
  local raw = params and { DATA = C4:Base64Encode(JSON:encode(params)) } or {}
  UIR[command](raw)
end
local function last(command, tag)
  for i = #pushes, 1, -1 do
    local pushed = pushes[i]
    if pushed.command == command and (not tag or pushed.data.request == tag) then
      return pushed.data
    end
  end
end
local function view(tag)
  tag = tag or "state"
  request("HA_SETUP_GET", { request = tag })
  return assert(last("HA_SETUP_STATE", tag))
end
local function advanced()
  request("_GET_PROPERTIES")
  local map = {}
  for _, item in ipairs(last("PROPERTIES").properties) do
    map[item.name] = item
  end
  return map
end
local function setProperty(name, value)
  request("_SET_PROPERTY", { property = name, value = value })
end
local function restart()
  OnDriverDestroyed()
  ShimPersistLand()
  OnDriverInit()
  OnDriverLateInit()
end

local function fixture(driverFamily, beforeInit)
  if OnDriverDestroyed then
    OnDriverDestroyed()
  end
  T.unload("^ha%.device%-driver$", "^lib%.ui%.tab%-properties$")
  persist:delete(saved)
  persist:delete("HA.LightOperationMode")
  PropertyVisibility, PropertyConfig = nil, nil
  family = driverFamily
  local path = root .. "drivers/" .. family .. "/"
  local xml = assert(io.open(path .. "driver.xml"))
  local body = xml:read("*a")
  xml:close()
  config = assert(body:match("<config>(.-)</config>"))
  config = config:gsub("<!%-%- #embed %.%./%.%./src/ha/endpoint%-properties%.xml %-%->", function()
    local properties = assert(io.open(root .. "src/ha/endpoint-properties.xml"))
    local shared = properties:read("*a")
    properties:close()
    return shared
  end)
  links, pushes, attribs, selected, icons, levels = {}, {}, {}, {}, {}, {}
  for connection in XMLgCapture(body, "connection") do
    local class = XMLCapture(connection, "classname")
    if class == "BUTTON_LINK" then
      local id = tonumber(XMLCapture(connection, "id"))
      assert(not links[id], "duplicate BUTTON_LINK ID")
      links[id] = {
        bindingid = id,
        provider = XMLCapture(connection, "consumer"):lower() == "false",
        bindingclasses = { { class = class } },
      }
    end
  end
  providerId = coordinator
  for prop in config:gmatch("<property>(.-)</property>") do
    local name = assert(prop:match("<name>(.-)</name>"))
    Properties[name] = prop:match("<default>(.-)</default>") or ""
  end
  local connection = { state = "connected", sent = {}, native = {}, reads = {} }
  function connection:send(message)
    self.sent[#self.sent + 1] = wire(message)
    return true
  end
  function connection:readCatalog()
    local promise = deferred.new()
    self.native[#self.native + 1] = promise
    return promise
  end
  function connection:readState(entity)
    local promise = deferred.new()
    self.reads[#self.reads + 1] = { entity = entity, promise = promise }
    return promise
  end
  local hub = at(coordinator, function()
    return Hub.new(connection, function(device, data)
      at(device, function()
        EC.HA_SUITE_V1({ PAYLOAD = codec.encode(data) })
      end)
    end)
  end)
  -- Catalog policy and combined discovery have their own protocol fixtures.
  hub.catalog.supplement = false
  function SendSecretToDevice(device, command, params)
    assert(device == coordinator and command == "HA_SUITE_V1")
    local decoded = codec.decode(params.PAYLOAD)
    if decoded.op == "select" then
      selected[#selected + 1] = decoded.entities
    end
    at(device, function()
      hub:receive(decoded)
    end)
  end
  function connection:reply(kind, result, failure)
    local pending = assert(table.remove(self.sent, 1), "Expected HA " .. kind)
    T.eq("expected HA operation", pending.service or pending.type, kind)
    at(coordinator, function()
      self.onMessage(wire({
        id = pending.id,
        type = "result",
        success = failure == nil,
        result = result,
        error = failure and { code = failure } or nil,
      }))
    end)
    return pending
  end
  function connection:completeRead(entity, state, attrs, failure)
    local read = assert(table.remove(self.reads, 1))
    T.eq("state read targets the exact entity", read.entity, entity)
    at(coordinator, function()
      if failure then
        read.promise:reject({ kind = failure })
      else
        read.promise:resolve(wire({ entity_id = entity, state = state, attributes = codec.object(attrs or {}) }))
      end
    end)
  end
  function connection:snapshot(entity, state, attrs)
    local pending = self:reply("subscribe_trigger")
    self:completeRead(entity, state, attrs)
    return pending.id
  end
  dofile(path .. "driver.lua")
  if beforeInit then
    beforeInit()
  end
  OnDriverInit()
  OnDriverLateInit()
  return connection, hub
end

T.section("suite updater can identify the executing revision even when unconfigured")
for _, driver in ipairs({ "light", "switch" }) do
  fixture(driver, function()
    T.eq(driver .. " does not report a running revision before initialization", UIR.HA_SUITE_RUNNING_VERSION(), nil)
  end)
  T.eq(
    driver .. " reports its executing revision after startup",
    UIR.HA_SUITE_RUNNING_VERSION(),
    "<version>20261117</version>"
  )
  OnDriverDestroyed()
  T.eq(driver .. " retired Lua does not report a running revision", UIR.HA_SUITE_RUNNING_VERSION(), nil)
end

T.section("A staged Light reads back settings before it accepts a selection")
do
  local connection, hub = fixture("light")
  local compatibility = require("ha.light-compatibility")
  local entity = "light.migration_color"
  local planned = wire({ kind = "Color and white temperature", format = "HS", range = "2700-5500" })
  local key = "HA.LightCompatibility.v2"
  local other = "light.other_migration_target"
  persist:set(key, codec.encode(codec.object({ [other] = codec.object({ kind = "Dimmable" }) })))
  ShimPersistLand()
  local outcome
  local function observe(work)
    work:next(function()
      outcome = true
    end, function(failure)
      outcome = failure.kind
    end)
  end
  local write = C4.PersistSetValue
  C4.PersistSetValue = function(self, name, ...)
    if name ~= key then
      return write(self, name, ...)
    end
  end
  at(coordinator, function()
    observe(hub.transfer:stageLightSettings(consumer, entity, planned))
  end)
  T.eq("a queued write has not been accepted", outcome, nil)
  clock.run(100)
  C4.PersistSetValue = write
  T.eq("a storage failure rejects staging", outcome, "configuration_unconfirmed")
  T.eq("failed staging leaves the child unselected", { #connection.sent, persist:get(saved, nil, true) }, { 0 })
  outcome = nil
  at(coordinator, function()
    observe(hub.transfer:stageLightSettings(consumer, entity, planned))
  end)
  T.eq("the receipt waits for Director storage", outcome, nil)
  ShimPersistLand()
  clock.run(100)
  T.eq("the same transfer can retry a failed write", outcome, true)
  T.truthy("storage has the exact approved settings", compatibility.sameStoredMigration(entity, planned))
  T.eq("the write preserves settings for other targets", compatibility.read(other).kind, "Dimmable")
  T.eq("successful staging does not subscribe or select", { #connection.sent, persist:get(saved, nil, true) }, { 0 })
  local mismatch = wire({ kind = "Color and white temperature", format = "XY", range = "2700-5500" })
  at(coordinator, function()
    observe(hub.transfer:directLoad(consumer, "light", entity, "Migration light", mismatch))
  end)
  T.eq("selection rejects settings that differ from staged storage", outcome, "configuration_unconfirmed")
  T.eq("a mismatched selection did not subscribe", #connection.sent, 0)
  at(coordinator, function()
    observe(hub.transfer:directLoad(consumer, "light", entity, "Migration light", planned))
  end)
  T.eq("verified selection can now subscribe", outcome, true)
  connection:snapshot(entity, "off", {
    supported_color_modes = codec.array({ "rgb", "color_temp" }),
    min_color_temp_kelvin = 2000,
    max_color_temp_kelvin = 6500,
  })
  T.eq("the replacement becomes ready with genuine HA feedback", view().status, "Device connected")
end

T.section("A blank replacement can recover a missed selection reply or commissioning offer")
for _, missed in ipairs({ "select", "selected", "commission_offer" }) do
  local connection, hub = fixture("light")
  local deliver, dropped, applications = hub.emit, false, 0
  hub.emit = function(device, message)
    if not dropped and message.kind == missed then
      dropped = true
      return
    end
    if message.kind == "commission_apply" then
      applications = applications + 1
    end
    deliver(device, message)
  end
  if missed == "select" then
    local send = SendSecretToDevice
    function SendSecretToDevice(device, command, params)
      if not dropped and codec.decode(params.PAYLOAD).op == "select" then
        dropped = true
        return
      end
      return send(device, command, params)
    end
  end
  if missed ~= "commission_offer" then
    at(consumer, restart)
  end
  local result, gatewayReleased
  at(coordinator, function()
    hub.transfer
      :directLoad(consumer, "light", "switch.fixture", "Fixture", nil, {
        beforeApply = function()
          T.eq("the gate runs before applying the selection", applications, 0)
          gatewayReleased = true
          return true
        end,
      })
      :next(function(value)
        result = value
      end)
  end)
  T.eq(missed .. " loss leaves the first attempt waiting without releasing the gateway", {
    dropped,
    applications,
    gatewayReleased,
  }, { true, 0 })
  at(coordinator, function()
    clock.run(250)
  end)
  T.eq(
    missed .. " is recovered by the first targeted retry",
    { result, gatewayReleased, applications, #connection.sent },
    { true, true, 1, 1 }
  )
  at(coordinator, function()
    clock.run(5500)
  end)
  T.eq("a successful claim never reapplies the selection", applications, 1)
end

T.section("A replacement selection must be durable as well as ready")
do
  local connection, hub = fixture("light")
  local migrationSelection = require("ha.migration-selection")
  local function readIdentity(expectedSettings)
    return at(consumer, function()
      local original = C4.SendUIRequest
      C4.SendUIRequest = function(_, _, command, params)
        return UIR[command](params)
      end
      local result = migrationSelection.read(consumer, expectedSettings, true)
      C4.SendUIRequest = original
      return assert(result)
    end)
  end
  ShimPersistLater(true)
  at(coordinator, function()
    hub.transfer:directLoad(consumer, "light", "switch.fixture", "Fixture")
  end)
  -- Native feedback can arrive before the deferred selection write is visible.
  connection:snapshot("switch.fixture", "off")
  local identity = readIdentity()
  T.eq("runtime feedback alone is not a saved selection", { identity.ready, identity.saved }, { true, false })
  ShimPersistLand()
  identity = readIdentity()
  T.eq(
    "the exact selection is verified after native persistence lands",
    { identity.ready, identity.saved },
    { true, true }
  )
  T.eq(
    "a different expected setting fails readback",
    readIdentity(codec.object({ kind = "Dimmable" })).settings_verified,
    false
  )
end

T.section("A dropped registration update or apply acknowledgment recovers without replay")
for _, lost in ipairs({ "select", "commission_ack" }) do
  local connection, hub = fixture("light")
  local send, deliver = SendSecretToDevice, hub.emit
  local dropped, applications = false, 0
  function SendSecretToDevice(device, command, params)
    if not dropped and codec.decode(params.PAYLOAD).op == lost then
      dropped = true
      return
    end
    return send(device, command, params)
  end
  function hub.emit(device, data)
    if data.kind == "commission_apply" then
      applications = applications + 1
    end
    return deliver(device, data)
  end
  if lost == "select" then
    local stale = hub.consumers[consumer]
    at(consumer, function()
      OBC[ids.lightCoordinatorBinding](ids.lightCoordinatorBinding)
    end)
    T.eq("a missed same-binding update leaves the old registration in the Coordinator", hub.consumers[consumer], stale)
  end
  local result
  at(coordinator, function()
    hub.transfer
      :directLoad(consumer, "light", "switch.fixture", "Fixture", nil, {
        beforeApply = function()
          return true
        end,
        applied = function()
          return at(consumer, function()
            local response = UIR.HA_SELECTION_IDENTITY({ VERIFY_SAVED = "true" })
            local payload = assert(response:match("^<selection>(.+)</selection>$"))
            local identity = codec.decode(C4:Base64Decode(payload))
            return identity.key == "switch.fixture" and identity.stable and identity.saved
          end)
        end,
      })
      :next(function(value)
        result = value
      end)
    if lost == "select" then
      clock.run(2000)
    end
  end)
  T.truthy(lost .. " was lost on the real wire", dropped)
  T.eq("the replacement receives a single apply", applications, 1)
  if lost == "commission_ack" then
    T.falsy("the transfer waits for exact saved selection when the acknowledgment is lost", result)
    ShimPersistLand()
  end
  at(coordinator, function()
    clock.run(6000)
  end)
  T.eq("verified selection hands off to readiness even while state is delayed", { result, applications }, { true, 1 })
  connection:snapshot("switch.fixture", "off")
  T.eq("late feedback confirms the replacement is usable", view().status, "Device connected")
end

local device = string.rep("d", 32)
local relay = "switch.fixture"
local gesture = "event.fixture_buttons"
local choiceId = "device:" .. device .. ":none"
local remote = {
  entity_id = choiceId,
  name = "Patio buttons",
  domain = "event",
  attributes = {
    device_choice = {
      type = "device_choice",
      version = 1,
      choice_id = choiceId,
      device_id = device,
      name = "Patio buttons",
      kind = "remote",
      area = "Patio",
    },
  },
}
local function result(rows, unchanged, revision)
  return {
    response = {
      version = 1,
      eligibility_version = 1,
      revision = string.rep(revision or "a", 64),
      page = 1,
      pages = 1,
      total = #rows,
      unchanged = unchanged,
      entities = not unchanged and codec.array(rows) or nil,
    },
  }
end
local function browse(tag)
  request("HA_SETUP_BROWSE", { request = tag })
end
local function choose(tag, choice, revision)
  request("HA_SETUP_CHOOSE", { request = tag, choice_id = choice, revision = revision })
end
local function pickResult(tag)
  return assert(last("HA_SETUP_RESULT", tag), "missing setup result " .. tag)
end
-- The far end of this connection is a light's keypad-facing provider.
-- Read both local link roles from the actual manifest, as Composer does.
local function bindTarget(id, device, providerBinding)
  local input, output = assert(links[id]), assert(links[providerBinding])
  assert(not input.provider and output.provider, "a target link must consume a light provider")
  assert(input.bindingclasses[1].class == output.bindingclasses[1].class, "binding classes differ")
  input.boundprovider = device and { bound = { deviceid = device, bindingid = providerBinding } } or nil
  OBC[id](id)
end

T.section("Device Setup and troubleshooting agree when a direct Light cannot confirm its state")
for _, accepted in ipairs({ false, true }) do
  local c = fixture("light")
  setProperty("Manual entity ID", "light.recovery")
  c:completeRead("light.recovery", "off")
  local attrs = { friendly_name = "Stair dimmer", supported_color_modes = codec.array({ "brightness" }) }
  c:snapshot("light.recovery", "off", attrs)
  local savedSelection = persist:get(saved, nil, true)
  T.eq("the dimmer is ready before the command", {
    view().status,
    Properties["Selected Device"],
    advanced()["Device feedback"].value,
  }, { "Device connected", "Stair dimmer", "Receiving current state" })

  local command
  if accepted then
    ExecuteCommand("Turn On", {})
    command = c:reply("turn_on")
  else
    ReceivedFromProxy(ids.proxy, "SET_LEVEL", { LEVEL = 100 })
    command = c.sent[1]
  end
  T.eq("both native entry points send to the selected dimmer", command.target.entity_id, "light.recovery")
  at(coordinator, function()
    clock.run(accepted and 1000 or 10000)
  end)
  c:completeRead("light.recovery", nil, nil, "read_failed")
  T.eq("all setup surfaces show unavailability and an actionable next step", {
    view().status,
    Properties["Driver Status"],
    Properties["Next step"],
    advanced()["Device feedback"].value,
  }, {
    "Device unavailable",
    "Device unavailable",
    "Open Device Setup and select Refresh device state.",
    "Device unavailable",
  })
  T.eq("missing feedback leaves the selected device and subscription alone", {
    persist:get(saved, nil, true),
    #selected,
    #c.sent,
  }, { savedSelection, 2, accepted and 0 or 1 })

  local retry = view()
  T.eq("state refresh is the offered recovery action", { retry.retry, retry.feedback_retry }, { true, true })
  request("HA_SETUP_RETRY", { request = "feedback-failure", feedback = true })
  c:completeRead("light.recovery", nil, nil, "read_failed")
  T.truthy("a failed retry answers without taking away recovery", last("HA_SETUP_RESULT", "feedback-failure").error)
  T.eq("the same selected device can still be refreshed", view().feedback_retry, true)
  request("HA_SETUP_RETRY", { request = "feedback-success", feedback = true })
  attrs.brightness = 102
  c:completeRead("light.recovery", "on", attrs)
  T.eq("refresh restores the same device and its actual level", {
    view().status,
    Properties["Selected Device"],
    advanced()["Device feedback"].value,
    tonumber(levels[#levels]),
  }, { "Device connected", "Stair dimmer", "Receiving current state", 40 })
  T.eq(
    "refresh reply confirms the read completed",
    last("HA_SETUP_RESULT", "feedback-success").message,
    "Device state refreshed."
  )
  T.falsy("the recovery action disappears when confirmed", view().feedback_retry)
  request("HA_SETUP_RETRY", { request = "feedback-stale", feedback = true })
  T.truthy("a stale refresh cannot take the setup retry route", last("HA_SETUP_RESULT", "feedback-stale").error)
end

T.section("Light readiness and capabilities follow the native adapter")
do
  local c = fixture("light")
  setProperty("Manual entity ID", "light.recovery")
  c:completeRead("light.recovery", "off")
  local attrs = { supported_color_modes = codec.array({ "brightness" }) }
  c:snapshot("light.recovery", "on", attrs)
  T.eq("unusable brightness feedback is unavailable on both surfaces", {
    view().status,
    advanced()["Device feedback"].value,
    view().feedback_retry,
  }, { "Device unavailable", "Device unavailable", true })
  attrs.brightness = 102
  request("HA_SETUP_RETRY", { request = "brightness-recovery", feedback = true })
  c:completeRead("light.recovery", "on", attrs)
  T.eq("usable feedback restores dimming and clears the recovery action", {
    view().status,
    view().capabilities,
    view().feedback_retry,
  }, { "Device connected", { "On and off", "Brightness" } })
  setProperty("Light type override", "On/off")
  T.eq("the native override changes the displayed capabilities immediately", view().capabilities, { "On and off" })
end

T.section("A chooser handler failure answers its own tab without waiting for the browser timer")
do
  local c = fixture("light")
  local consumer = require("ha.consumer")
  local requestCatalog = consumer.request
  consumer.request = function()
    error("private request details")
  end
  browse("request-error")
  consumer.request = requestCatalog
  T.eq(
    "synchronous chooser failure is correlated and sanitized",
    last("HA_SETUP_PAGE", "request-error").error,
    "The driver could not request the device list. Reload devices to try again."
  )
  local page = require("ha.setup-page")
  local formatChoices = page.choices
  page.choices = function()
    error("private catalog details")
  end
  browse("format-error")
  c:reply("get_devices", result({ remote }, false))
  page.choices = formatChoices
  T.eq(
    "reply formatting failure is correlated and sanitized",
    last("HA_SETUP_PAGE", "format-error").error,
    "The driver could not display the device list. Reload devices to try again."
  )
end

T.section("The existing diagnostics action prints a recorded release failure once")
for _, family in ipairs({ "light", "switch" }) do
  fixture(family)
  local function printDiagnostics()
    return T.capture(function()
      ExecuteCommand("PrintDiagnostics", {})
    end)
  end
  local ok, _, output = printDiagnostics()
  T.truthy(
    family .. " diagnostics includes gesture count and last sequence",
    ok and output:find("Button events: 0 | Last sequence: 0", 1, true)
  )
  T.falsy("an empty command result adds no diagnostics line", output:find("Last command result", 1, true))
  local message = require("ha.setup-page").explain("connected_release_failed")
  require("lib.values"):update("Last Command Result", message, "STRING")
  ok, _, output = printDiagnostics()
  local line = "Last command result | " .. message
  local first, last = output:find(line, 1, true)
  T.check(
    "the existing action prints the actionable result once",
    ok and first and not output:find(line, last + 1, true)
  )
end

T.section("Technical identifiers stay in Advanced")
do
  local names = require("ha.setup-page").basicNames
  local config =
    { name = "event.button", manual = true, key = "event.button", controlled_load = { entity_id = "light.lamp" } }
  local selectedName, targetName = names(config, "Home Assistant device", "light.lamp")
  T.eq(
    "raw source and target names never appear in the basic rows",
    { selectedName, targetName },
    { "Manually selected device" }
  )
  config.name, config.controlled_load_origin = "Kitchen", "explicit_link"
  selectedName, targetName = names(config, "Home Assistant device", "Kitchen")
  T.eq(
    "separate control with a matching name keeps its target row",
    { selectedName, targetName },
    { "Kitchen", "Kitchen" }
  )
  T.eq(
    "opaque device identities never become labels",
    require("ha.setup-page").friendlyName("device:" .. string.rep("a", 32) .. ":none"),
    nil
  )
end

T.section("Native settings appear on fresh and previously configured drivers")
for _, kind in ipairs({ "light", "switch" }) do
  for _, savedNo in ipairs({ false, true }) do
    fixture(kind, function()
      Properties["Show advanced settings"] = savedNo and "No" or nil
      Properties["Debug Mode"] = savedNo and "On" or nil
    end)
    T.eq(kind .. " exposes applicable settings immediately", {
      attribs["Manual entity ID"],
      attribs["Log Mode"],
      attribs["Latency Diagnostics"],
      attribs["Button behavior"],
    }, { 0, 0, 0, constants.HIDE_PROPERTY })
    T.excludes(kind .. " omits the retired logging control from its manifest", config, "<name>Debug Mode</name>")
    T.eq(kind .. " Advanced omits the retired logging control", advanced()["Debug Mode"], nil)
    T.eq(kind .. " native Properties hides a saved Debug Mode value", attribs["Debug Mode"], savedNo and 1 or nil)
  end
end

T.section("Light boots safely and discovers an eligible native load without the optional helper")
do
  local c = fixture("light")
  T.eq("boot selects no endpoint", #selected[#selected], 0)
  T.eq("boot makes no HA request", #c.sent, 0)
  T.eq("boot status", view().status, "Not configured")
  T.eq("unconfigured Light can review older drivers", view().migration_available, true)
  T.eq("fresh native setup shows an unselected device without a target row", {
    Properties["Selected Device"],
    attribs["Selected Device"],
    attribs.Controls,
  }, { "Not selected", 0, constants.HIDE_PROPERTY })
  T.truthy("manual entry is available in Advanced", advanced()["Manual entity ID"])
  T.eq("inapplicable button override is hidden", advanced()["Button behavior"], nil)
  setProperty("Button behavior", "Buttons only")
  T.eq("hidden setting is refused", last("PROPERTY_ERROR").property, "Button behavior")

  local function native()
    c:reply("get_devices", nil, "not_found")
    local load = {
      entity_id = relay,
      name = "Patio relay",
      domain = "switch",
      device_id = device,
      attributes = codec.object({}),
    }
    table.remove(c.native, 1):resolve(wire(codec.array({ load })))
    local null = codec.null
    c:reply("config/entity_registry/get_entries", {
      [relay] = { entity_id = relay, platform = "lab", disabled_by = null, hidden_by = null, entity_category = null },
    })
  end
  browse("browse-native")
  native()
  local page = assert(last("HA_SETUP_PAGE", "browse-native"))
  T.eq("native mode described", page.helper, false)
  T.eq("one compatible endpoint", { page.total, page.choices[1].id }, { 1, relay })
  T.eq("read-only browsing persists no device", persist:get(saved, nil, true), nil)
  T.eq("browsing had no control subscription", #selected, 1)
  T.eq("browsing did not read state", #c.reads, 0)

  choose("choose-native", relay, page.revision)
  T.eq("choosing a listed load starts only its normal subscription", #c.sent, 1)
  T.eq("choosing does not request separate availability verification", #c.reads, 0)
  T.eq("choose reports success", pickResult("choose-native").error, nil)
  T.eq(
    "native selection persists the exact load",
    codec.decode(persist:get(saved, nil, true)).controlled_load.entity_id,
    relay
  )
  c:snapshot(relay, "off", { friendly_name = "Patio relay" })
  T.eq("simple load has no physical-indicator settings to configure", view().indicator_hint, nil)
  T.eq("view shows confirmed load", { view().status, view().target }, { "Device connected", "Patio relay" })

  browse("native-cached-list")
  T.eq(
    "opening the unchanged native list reuses its verified revision",
    last("HA_SETUP_PAGE", "native-cached-list").revision,
    page.revision
  )
  T.eq("opening another native picker makes no HA request", { #c.sent, #c.native }, { 0, 0 })
  request("HA_SETUP_BROWSE", { request = "native-unavailable-list", refresh = true })
  c:reply("get_devices", nil, "not_found")
  local unavailable = "switch.sleeping"
  table.remove(c.native, 1):resolve(wire(codec.array({
    {
      entity_id = unavailable,
      name = "Sleeping relay",
      domain = "switch",
      available = false,
      attributes = codec.object(),
    },
  })))
  c:reply("config/entity_registry/get_entries", { [unavailable] = codec.null })
  local nextPage = assert(last("HA_SETUP_PAGE", "native-unavailable-list"))
  choose("native-unavailable", unavailable, nextPage.revision)
  T.check(
    "cached unavailability gives an actionable result",
    pickResult("native-unavailable").error:find("unavailable")
  )
  T.eq(
    "the working load remains bound without a second HA call",
    { view().selected_id, #c.sent, #c.reads },
    { relay, 0, 0 }
  )

  for _, id in pairs(ids.lightLinks) do
    T.truthy("a keypad can operate the Light through its Button Link", links[id].provider)
    links[id].boundconsumers = { { deviceid = 32, bindingid = 71 } }
  end
  for _, id in pairs(ids.targetLinks) do
    T.eq("each target link can connect to a light provider", links[id].provider, false)
  end
  bindTarget(ids.targetLinks.top, nil, ids.lightLinks.top)
  T.eq("incoming keypad cannot become the app target", view().target, "Patio relay")
  bindTarget(ids.targetLinks.top, 30, ids.lightLinks.top)
  bindTarget(ids.targetLinks.toggle, 30, ids.lightLinks.toggle)
  T.eq("shared destination needs no selector", advanced()["App Control Link"], nil)
  T.eq("paddles with one destination select that light automatically", view().target, "Stair Lights")
  T.eq(
    "Automatic names the exact Control4 target resolved from the links",
    view().button_behavior_summary,
    "The app controls Stair Lights through Control4."
  )
  T.eq("the mode choices name the Home Assistant and Control4 targets separately", {
    advanced()["Button behavior"].choice_labels["Home Assistant device"],
    advanced()["Button behavior"].choice_labels["Connected Control4 light"],
  }, { "Home Assistant · Patio relay", "Control4 · Stair Lights" })
  T.eq("native landing identifies both the HA selection and its connected target", {
    Properties["Selected Device"],
    Properties.Controls,
    attribs.Controls,
  }, { "Patio relay", "Stair Lights", 0 })
  bindTarget(ids.targetLinks.bottom, 31, ids.lightLinks.bottom)
  T.eq("distinct paddle destinations need one explicit target", view().status, "Choose a connected light")
  T.eq(
    "Automatic explains an unresolved link without naming a guessed target",
    view().button_behavior_summary,
    "Choose which connected Control4 light or lighting group the app will control."
  )
  local appChoice = advanced()["App Control Link"]
  T.eq("two linked devices are listed once each by name", appChoice.choices, { "Automatic", "Top", "Bottom" })
  T.eq("the options identify the actual linked devices", {
    appChoice.choice_labels.Top,
    appChoice.choice_labels.Bottom,
  }, { "Stair Lights", "Hall Light" })
  local getDisplayName = C4.GetDeviceDisplayName
  function C4:GetDeviceDisplayName(device)
    return device == 31 and "Stair Lights" or getDisplayName(self, device)
  end
  appChoice = advanced()["App Control Link"]
  C4.GetDeviceDisplayName = getDisplayName
  T.eq("two different devices with the same name stay distinguishable", {
    appChoice.choice_labels.Top,
    appChoice.choice_labels.Bottom,
  }, { "Stair Lights · Top", "Stair Lights · Bottom" })
  setProperty("App Control Link", "Toggle")
  T.eq(
    "the web picker rejects a role omitted from the current options",
    last("PROPERTY_ERROR").property,
    "App Control Link"
  )
  setProperty("App Control Link", "Bottom")
  T.eq("the prototype's explicit Bottom choice selects only that button's target", view().target, "Hall Light")
  bindTarget(ids.targetLinks.app, 32, ids.lightLinks.toggle)
  T.eq("explicit App Control Link wins", view().target, "Kitchen Light")
  T.eq(
    "Advanced omits the selector while a dedicated app link controls the target",
    advanced()["App Control Link"],
    nil
  )
  bindTarget(ids.targetLinks.app, nil, ids.lightLinks.toggle)
  T.eq("removing the dedicated link restores the explicit Bottom choice", view().target, "Hall Light")
  bindTarget(ids.targetLinks.top, 31, ids.lightLinks.top)
  T.eq(
    "deduplication keeps the saved role as the representative of its device",
    advanced()["App Control Link"].choices,
    { "Automatic", "Bottom", "Toggle" }
  )
  bindTarget(ids.targetLinks.toggle, 31, ids.lightLinks.toggle)
  T.eq("three links to the same device hide the selector", advanced()["App Control Link"], nil)
  T.eq("hiding the selector preserves its saved role", Properties["App Control Link"], "Bottom")
  bindTarget(ids.targetLinks.top, 30, ids.lightLinks.top)
  bindTarget(ids.targetLinks.toggle, 30, ids.lightLinks.toggle)
  bindTarget(ids.targetLinks.bottom, nil, ids.lightLinks.bottom)
  T.eq("an unlinked saved choice waits for the user's next step", view().status, "Choose a connected light")
  setProperty("App Control Link", "Automatic")
  T.eq("removing the second destination restores the common target", view().target, "Stair Lights")
  bindTarget(ids.targetLinks.bottom, 31, ids.lightLinks.bottom)
  setProperty("Button behavior", "Home Assistant device")
  T.eq("explicit mode wins over bindings", selected[#selected][1], relay)
  T.truthy("linked-light choices can be rendered before the installer changes mode", advanced()["App Control Link"])
  T.eq("the linked-light selector is hidden during Home Assistant control", view().app_link_available, nil)
  setProperty("App Control Link", "Top")
  T.eq("an inactive app link choice is refused", last("PROPERTY_ERROR").property, "App Control Link")
  setProperty("Button behavior", "Automatic")
  T.eq(
    "Automatic reveals the linked-light selector with the status push",
    last("HA_SETUP_STATE").app_link_available,
    true
  )
  setProperty("Button behavior", "Home Assistant device")
  c.sent, c.reads = {}, {}
  restart()
  T.eq("reload retains operating override", Properties["Button behavior"], "Home Assistant device")
  T.eq("reload selects saved endpoint without discovery", selected[#selected][1], relay)
  for _, request in ipairs(c.sent) do
    T.check(
      "reload sends only subscription maintenance",
      request.type == "subscribe_trigger" or request.type == "unsubscribe_events"
    )
  end

  setProperty("Manual entity ID", "light.not valid")
  T.truthy("bad manual ID gets an actionable status", view().manual_status)
  T.eq("setup marks a rejected edit for its field", view().rejected_manual, "light.not valid")
  T.eq("native Properties show the same recovery action", Properties["Next step"], view().manual_status)
  T.eq("invalid manual input preserves the active route", selected[#selected], { relay })
  T.eq("invalid manual input preserves the saved picker choice", codec.decode(persist:get(saved, nil, true)).key, relay)
  setProperty("Manual entity ID", "light.manual")
  T.eq("unverified manual setup preserves the active route", selected[#selected], { relay })
  c:completeRead("light.manual", "off")
  T.eq("checking a corrected ID clears the field error", view().rejected_manual, nil)
  T.eq("manual setup routes only the exact entered ID", selected[#selected][1], "light.manual")
  T.eq("manual setup is explicitly persisted", codec.decode(persist:get(saved, nil, true)).manual, true)
end

T.section("Manual cover selection keeps the verified device when the new class is wrong")
for _, familyName in ipairs({ "garage", "blinds" }) do
  local c = fixture(familyName)
  local garage = familyName == "garage"
  setProperty("Manual entity ID", "cover.original")
  c:completeRead("cover.original", "closed", { device_class = garage and "garage" or "shade" })
  local savedSelection = persist:get(saved, nil, true)
  T.truthy("a compatible cover is saved", savedSelection)
  setProperty("Manual entity ID", "cover.wrong_class")
  c:completeRead("cover.wrong_class", "open", { device_class = garage and "shade" or "garage" })
  T.eq("incorrect cover class preserves the previous target", selected[#selected], { "cover.original" })
  T.eq("the approved selection stays saved", persist:get(saved, nil, true), savedSelection)
  T.truthy("the installer gets a compatible device recovery action", view().manual_status:find("driver type", 1, true))
end

T.section("Light and Switch operate a manually selected toggle helper without HA Gesture Bridge")
for _, familyName in ipairs({ "light", "switch" }) do
  local c = fixture(familyName)
  local helper = "input_boolean.patio"
  local attrs = {
    friendly_name = "Patio toggle",
    supported_color_modes = codec.array({ "xy" }),
    brightness = 50,
  }
  local function power(action)
    if familyName == "light" then
      ReceivedFromProxy(ids.proxy, action == "turn_on" and "ON" or "OFF", {})
    elseif action == "toggle" then
      ReceivedFromProxy(ids.proxy, "SELECT", {})
    else
      ReceivedFromProxy(ids.relay, action == "turn_on" and "CLOSE" or "OPEN", {})
    end
  end
  local function feedback()
    return familyName == "light" and levels[#levels] or icons[#icons]
  end
  local off, on = "off", "on"
  if familyName == "light" then
    off, on = 0, 100
  end

  browse("helper-free-browse")
  c:reply("get_devices", nil, "not_found")
  at(coordinator, function()
    table.remove(c.native, 1):resolve(wire(codec.array({})))
  end)
  T.eq("picker still completes without the optional integration", last("HA_SETUP_PAGE", "helper-free-browse").total, 0)
  T.eq("helper-free browsing does not configure a load", selected[#selected], {})
  T.eq("helper-free browsing does not persist a load", persist:get(saved, nil, true), nil)

  setProperty("Manual entity ID", helper)
  T.eq("the entered toggle has no routing authority before verification", selected[#selected], {})
  c:completeRead(helper, nil, nil, "not_found")
  T.check("a missing helper offers a retry", view().manual_status:find("Enter the entity ID", 1, true))
  T.eq("a missing helper creates no subscription", #c.sent, 0)

  setProperty("Manual entity ID", helper)
  c:completeRead(helper, "off", attrs)
  T.eq("a verified toggle selects its exact entity", selected[#selected], { helper })
  T.eq("the persisted toggle retains its domain", codec.decode(persist:get(saved, nil, true)).controlled_load, {
    entity_id = helper,
    domain = "input_boolean",
  })
  power("turn_on")
  T.eq("verification alone does not permit control before the snapshot", #c.sent, 1)
  local subscription = c:snapshot(helper, "off", attrs)
  T.eq("binary capability ignores unrelated light attributes", view().capabilities, { "On and off" })
  T.eq("the initial snapshot confirms Off", feedback(), off)
  metrics:reset()
  metrics:setEnabled(true)

  local function checkService(action)
    power(action)
    local before = feedback()
    local rpc = c:reply(action)
    T.eq("the service targets only the exact helper", { rpc.domain, rpc.target, rpc.service_data }, {
      "input_boolean",
      { entity_id = helper },
      {},
    })
    T.eq("service acceptance adds no load feedback", feedback(), before)
  end
  local function update(state)
    at(coordinator, function()
      c.onMessage(wire({
        id = subscription,
        type = "event",
        event = { variables = { trigger = { to_state = { entity_id = helper, state = state, attributes = attrs } } } },
      }))
    end)
  end
  checkService("turn_on")
  update("on")
  T.eq("the helper's pushed state confirms On", feedback(), on)
  if familyName == "switch" then
    checkService("toggle")
  end
  update("off")
  T.eq("the helper's pushed state confirms Off", feedback(), off)
  update("on")
  checkService("turn_off")
  T.eq("Coordinator records HA service acceptance under the helper domain", {
    metrics:report().operations["request.input_boolean.on"].outcomes.accepted,
    metrics:report().operations["request.input_boolean.off"].outcomes.accepted,
  }, { 1, 1 })
  metrics:setEnabled(false)
  update("unavailable")
  power("turn_on")
  T.eq("unavailable helper loses control authority", #c.sent, 0)
  T.eq("the lost helper is shown as unavailable", view().status, "Device unavailable")
end

T.section("Switch uses the optional helper only after Apply, retaining a pending choice across reload")
do
  local c = fixture("switch")
  local dimmer = "light.fixture"
  T.eq("Switch is initially unconfigured", view().status, "Not configured")
  T.eq("unconfigured Switch can review older drivers", view().migration_available, true)
  browse("browse-switch")
  c:reply("get_devices", result({ remote }, false))
  local page = assert(last("HA_SETUP_PAGE", "browse-switch"))
  T.eq("Switch shows device-friendly helper metadata", { page.helper, page.choices[1].name }, { true, "Patio buttons" })
  T.eq("browse creates no HA control", #c.sent, 0)
  T.eq("no pending selection before Apply", persist:get(saved, nil, true), nil)
  choose("denied", choiceId, page.revision)
  T.eq("setup is pending before reply", view().status, "Setting up your device")
  T.eq("pending selection owns no HA endpoint", #selected[#selected], 0)
  local prep = c:reply("prepare_device", nil, "unauthorized")
  T.eq("preparation derives device from catalog", prep.service_data.device_id, device)
  T.check("permission denial has a human explanation", pickResult("denied").error:find("denied access", 1, true))
  T.truthy("retry is offered for a denied request", view().retry)
  restart()
  T.eq("reload does not rerun preparation", #c.sent, 0)
  T.eq("pending selection reloads", view().status, "Setup needs attention")

  request("HA_SETUP_RETRY", { request = "retry" })
  c:reply("prepare_device", {
    response = {
      version = 1,
      device_id = device,
      input_ready = false,
      control_id = "buttons",
      gesture_entity_id = gesture,
      controlled_load = { entity_id = dimmer, domain = "light", available = false },
      controlled_load_origin = "explicit_link",
    },
  })
  T.eq(
    "explicit unavailable link stays selected",
    codec.decode(persist:get(saved, nil, true)).controlled_load.entity_id,
    dimmer
  )
  T.eq("unavailable explicit link is disclosed", view().status, "Device unavailable")
  T.check(
    "Automatic leaves an unreported linked load unnamed",
    view().button_behavior_summary:find("Home Assistant has not reported the controlled load’s name yet.", 1, true)
  )
  T.eq(
    "Switch never exposes connected-C4 mode",
    table.concat(advanced()["Button behavior"].choices, ","),
    "Automatic,Control linked device only,Control device and report presses,Buttons only"
  )
  T.eq("gesture state is not reported ready before a snapshot", view().capabilities[1], "Button presses")
  T.eq("reply uses the retrying tab's request", pickResult("retry").request, "retry")

  local snapshots = {
    [dimmer] = {
      state = "on",
      attributes = { friendly_name = "Linked patio light", supported_color_modes = codec.array({ "brightness", "hs" }) },
    },
    [gesture] = {
      state = "2026-11-17T12:00:00Z",
      attributes = {
        bridge_source_device_id = device,
        bridge_control_id = "buttons",
        bridge_sources = codec.array({ { ready = true } }),
      },
    },
  }
  for _ = 1, 2 do
    c:reply("subscribe_trigger")
    local read = assert(table.remove(c.reads, 1))
    local snapshot = assert(snapshots[read.entity])
    snapshot.entity_id = read.entity
    at(coordinator, function()
      read.promise:resolve(wire(snapshot))
    end)
  end
  T.eq("the originally unavailable link gets fresh evidence", view().target, "Linked patio light")
  T.eq("the labels distinguish the controlled light from its paddle", {
    advanced()["Button behavior"].choice_labels["Control linked device only"],
    advanced()["Button behavior"].choice_labels["Control device and report presses"],
  }, { "Control Linked patio light only", "Control Linked patio light + presses" })
  T.eq(
    "the Automatic explanation names both routes",
    view().button_behavior_summary,
    "The app controls Linked patio light through Home Assistant. Use button presses from Patio buttons in Control4 Programming."
  )
  T.eq("Switch exposes only relevant capabilities", view().capabilities, { "On and off", "Button presses" })
  setProperty("Button behavior", "Control linked device only")
  T.eq("load-only Switch keeps the linked load and releases the event source", selected[#selected], { dimmer })
  T.eq(
    "the live device-only explanation updates without reopening the page",
    last("HA_SETUP_STATE").button_behavior_summary,
    "The app controls Linked patio light through Home Assistant. This mode turns off button presses in Control4 Programming."
  )
  T.eq("load-only view removes button capabilities", view().capabilities, { "On and off" })
  T.eq(
    "load-only view removes indicator and button diagnostics",
    { view().indicator_lease, advanced()["Last Gesture"] },
    {}
  )
  c:reply("unsubscribe_events")
  ReceivedFromProxy(ids.relay, "OPEN", {})
  T.eq("load-only relay controls the originally selected linked device", c:reply("turn_off").target.entity_id, dimmer)
  restart()
  T.eq("load-only persists across driver restart without the button source", selected[#selected], { dimmer })
  view("reopen-switch-setup")
  setProperty("Button behavior", "Control device and report presses")
  T.eq("combined mode selects the same load and reinstates button events", selected[#selected], { dimmer, gesture })
  setProperty("Button behavior", "Automatic")
  T.eq("Automatic keeps both endpoints for a prepared Switch", selected[#selected], { dimmer, gesture })
  setProperty("Button behavior", "Buttons only")
  T.eq("buttons-only retires load routing", selected[#selected], { gesture })
  T.eq(
    "a buttons-only explanation names the source and shows app control off",
    last("HA_SETUP_STATE").button_behavior_summary,
    "App control is off. Use button presses from Patio buttons in Control4 Programming."
  )
  setProperty("Button behavior", "Automatic")
  T.eq("switching back to Automatic shows the cached name before fresh HA feedback", {
    Properties["Button behavior"],
    last("HA_SETUP_STATE").button_behavior_summary,
  }, {
    "Automatic",
    "The app controls Linked patio light through Home Assistant. Use button presses from Patio buttons in Control4 Programming.",
  })
end

T.section("A later explicit edit invalidates a second tab's outstanding preparation")
do
  local c = fixture("switch")
  browse("tab-one-browse")
  c:reply("get_devices", result({ remote }, false))
  local page = assert(last("HA_SETUP_PAGE", "tab-one-browse"))
  browse("tab-two-browse")
  c:reply("get_devices", result({ remote }, true))
  T.eq("two tabs receive their own browse responses", last("HA_SETUP_PAGE", "tab-two-browse").revision, page.revision)

  local oldRevision = string.rep("b", #page.revision)
  choose("tab-one-stale", choiceId, oldRevision)
  T.check("outdated picker must reopen", pickResult("tab-one-stale").error:find("device list changed", 1, true))
  T.eq("stale selection sends no preparation", #c.sent, 0)

  choose("tab-two-apply", choiceId, page.revision)
  setProperty("Manual entity ID", relay)
  c:reply("prepare_device", {
    response = { version = 1, device_id = device, input_ready = false, gesture_entity_id = gesture },
  })
  T.check("outstanding Apply got a retirement result", pickResult("tab-two-apply").error ~= nil)
  T.eq("manual validation has no routing authority before its response", selected[#selected], {})
  c:completeRead(relay, "on")
  T.eq("obsolete reply cannot restore the prior routing target", selected[#selected], { relay })
  T.eq(
    "obsolete reply cannot restore the prior persisted choice",
    codec.decode(persist:get(saved, nil, true)).key,
    relay
  )
  T.eq("manual value remains the only selected ID", Properties["Manual entity ID"], relay)
end

T.section("Light and Switch keep the active target through picker and manual replacement failures and restart")
for _, familyName in ipairs({ "light", "switch" }) do
  local c = fixture(familyName)
  local function endpoint(digit, entity, name)
    local deviceId, registryId = string.rep(digit, 32), string.rep("0", 32)
    local id = "device:" .. deviceId .. ":" .. registryId
    return {
      entity_id = id,
      name = "Patio control",
      domain = "switch",
      attributes = {
        device_choice = {
          type = "device_choice",
          version = 1,
          choice_id = id,
          device_id = deviceId,
          name = "Patio control",
          area = "Patio",
          kind = "switch",
          source_load = { entity_id = entity, registry_id = registryId, domain = "switch", name = name },
        },
      },
    }
  end
  local replacement = "switch.replacement"
  local original = endpoint("a", relay, "Patio load")
  local alternative = endpoint("b", replacement, "Patio accent light")
  local rows = { original, alternative }
  local function resolve(choice, tag, available)
    choose(tag, choice.entity_id, last("HA_SETUP_PAGE", "picker").revision)
    local deviceChoice = choice.attributes.device_choice
    local resolvedLoad = wire(deviceChoice.source_load)
    resolvedLoad.available = available
    c:reply("prepare_device", {
      response = {
        version = 1,
        device_id = deviceChoice.device_id,
        input_ready = false,
        source_load = deviceChoice.source_load,
        controlled_load = resolvedLoad,
        controlled_load_origin = "selected_endpoint",
      },
    })
  end
  browse("picker")
  c:reply("get_devices", result(rows, false))
  local list = last("HA_SETUP_PAGE", "picker").choices
  T.eq("matching picker names show distinct load labels", { list[1].target, list[2].target }, {
    "Patio load",
    "Patio accent light",
  })
  resolve(original, "initial")
  T.eq("first selection succeeds", pickResult("initial").error, nil)
  local subscription = c:snapshot(relay, "off", { friendly_name = "Actual patio load" })
  T.eq("picker state distinguishes the exact selection and the actual target", { view().selected_id, view().target }, {
    original.entity_id,
    "Actual patio load",
  })
  T.eq(
    familyName .. " native Properties distinguish the selected wall control from the working load",
    { Properties["Selected Device"], Properties.Controls, attribs.Controls },
    { "Patio control", "Actual patio load", 0 }
  )
  local count = #selected
  local originalRecord = persist:get(saved, nil, true)
  resolve(alternative, "replace", false)
  T.eq("resolution keeps active feedback", view().status, "Device connected")
  T.eq("resolution cannot change subscriptions before checking availability", #selected, count)
  if familyName == "light" then
    ReceivedFromProxy(ids.proxy, "ON", {})
  else
    ReceivedFromProxy(ids.proxy, "SELECT", {})
  end
  local command = c:reply(familyName == "light" and "turn_on" or "toggle")
  T.eq("the current app control works during validation", command.target.entity_id, relay)
  at(coordinator, function()
    c.onMessage(wire({
      type = "event",
      id = subscription,
      event = {
        variables = {
          trigger = {
            to_state = {
              entity_id = relay,
              state = "on",
              attributes = { friendly_name = "Actual patio load" },
            },
          },
        },
      },
    }))
  end)
  T.check("unavailable replacement gets a clear error", pickResult("replace").error:find("is unavailable", 1, true))
  T.eq("failed replacement leaves status and subscriptions intact", { view().status, #selected }, {
    "Device connected",
    count,
  })
  T.eq("replacement failure retains the persisted device", persist:get(saved, nil, true), originalRecord)
  T.eq("failed replacement offers an explicit retry", view().retry, true)
  local requestsBeforeRefresh = #c.sent
  request("HA_SETUP_RETRY", { request = "stale-feedback-refresh", feedback = true })
  T.truthy("a stale state refresh cannot retry a failed replacement", pickResult("stale-feedback-refresh").error)
  T.eq("a stale state refresh leaves the pending choice and active device alone", {
    #c.sent,
    persist:get(saved, nil, true),
    view().retry,
  }, { requestsBeforeRefresh, originalRecord, true })

  setProperty("Manual entity ID", replacement)
  T.eq("manual property displays the accepted value while a check is pending", Properties["Manual entity ID"], "")
  c:completeRead(replacement, nil, nil, "not_found")
  T.check(
    "missing manual replacement gives a recovery action",
    view().manual_status:find("Enter the entity ID", 1, true)
  )
  T.eq("failed manual entry preserves the route", selected[#selected], { relay })
  T.eq("failed manual entry preserves the saved choice", persist:get(saved, nil, true), originalRecord)
  setProperty("Manual entity ID", replacement)
  local late = assert(table.remove(c.reads, 1)).promise
  at(coordinator, function()
    clock.run(12000)
  end)
  T.check("abandoned manual check has a bounded timeout", view().manual_status:find("too long", 1, true))
  setProperty("Manual entity ID", replacement)
  local retired = assert(table.remove(c.reads, 1)).promise
  Properties["Manual entity ID"] = replacement
  restart()
  T.eq(
    "restart restores the committed device and canonical field",
    { selected[#selected], Properties["Manual entity ID"] },
    {
      { relay },
      "",
    }
  )
  at(coordinator, function()
    local response = wire({ entity_id = replacement, state = "on", attributes = codec.object({}) })
    late:resolve(response)
    retired:resolve(response)
  end)
  T.eq("positive late callbacks cannot replace the committed device", persist:get(saved, nil, true), originalRecord)

  c.sent = {}
  resolve(alternative, "replace-verified")
  T.eq("the valid preparation sends no extra HA verification", #c.reads, 0)
  T.eq("successful verification completes the request", pickResult("replace-verified").error, nil)
  T.eq("a verified picker replacement becomes the only active route", selected[#selected], { replacement })
  T.eq("the replacement is persisted", codec.decode(persist:get(saved, nil, true)).key, alternative.entity_id)
end

T.section("Gesture capability and connection status use source metadata before the first press")
do
  local c = fixture("switch")
  browse("buttons-browse")
  c:reply("get_devices", result({ remote }, false))
  choose("buttons-choose", choiceId, last("HA_SETUP_PAGE", "buttons-browse").revision)
  c:reply("prepare_device", {
    response = {
      version = 1,
      device_id = device,
      input_ready = false,
      control_id = "buttons",
      gesture_entity_id = gesture,
    },
  })
  T.eq("a remote without a load defaults to buttons only", view().target, "Buttons only")
  T.eq("the preparation reply alone does not prove the buttons are connected", view().status, "Waiting for buttons")
  local led = { id = "led-1", status = "ready" }
  local attrs = {
    bridge_contract_version = "1.0",
    bridge_source_device_id = device,
    bridge_control_id = "buttons",
    bridge_update_kind = "status",
    bridge_sources = codec.array({ { id = "native-source", ready = true, availability = "available" } }),
    bridge_led_version = 1,
    bridge_leds = codec.array({ led }),
  }
  T.truthy("selected physical device explains missing indicator settings", view().indicator_hint)
  local subscription = c:snapshot(gesture, "unknown", attrs)
  T.eq("source metadata proves buttons are connected without a timestamp", view().status, "Buttons connected")
  T.eq("ready buttons use their own Navigator icon", icons[#icons], "buttons")
  T.eq("buttons-only app still cannot toggle a load", ReceivedFromProxy(ids.proxy, "SELECT"), false)
  T.eq(
    "read-only legacy indicator metadata does not advertise an adjustable indicator",
    view().capabilities,
    { "Button presses" }
  )

  local otherDevice = string.rep("b", 32)
  local otherKey, otherGesture = "device:" .. otherDevice .. ":none", "event.other_buttons"
  local other = wire(remote)
  other.entity_id = otherKey
  other.attributes.device_choice.choice_id = otherKey
  other.attributes.device_choice.device_id = otherDevice
  browse("other-buttons")
  c:reply("get_devices", result({ other }, false, "b"))
  choose("replace-buttons", otherKey, last("HA_SETUP_PAGE", "other-buttons").revision)
  c:reply("prepare_device", {
    response = {
      version = 1,
      device_id = otherDevice,
      input_ready = false,
      control_id = "other",
      gesture_entity_id = otherGesture,
    },
  })
  T.check("unready prepared buttons cannot replace the working source", pickResult("replace-buttons").error)
  T.eq("the original buttons remain active after a failed verification", { view().status, icons[#icons] }, {
    "Buttons connected",
    "buttons",
  })

  local function update(state, deviceId)
    attrs.bridge_source_device_id = deviceId
    at(coordinator, function()
      c.onMessage(wire({
        id = subscription,
        type = "event",
        event = { variables = { trigger = { to_state = { entity_id = gesture, state = state, attributes = attrs } } } },
      }))
    end)
  end
  update("unknown", string.rep("f", 32))
  T.eq("a foreign source cannot report this device ready", view().status, "Waiting for buttons")
  T.eq("foreign indicator capability is ignored", view().capabilities, { "Button presses" })
  update("unavailable", device)
  T.eq("an unavailable bridge is not ready despite older source metadata", view().status, "Waiting for buttons")
  T.eq("lost buttons show the unavailable Navigator icon", icons[#icons], "unavailable")
end

T.section("Both family tabs show only live writable indicators and write a single explicit setting")
for _, familyName in ipairs({ "light", "switch" }) do
  local c = fixture(familyName)
  if familyName == "light" then
    bindTarget(ids.targetLinks.bottom, 31, ids.lightLinks.top)
  end
  browse("indicator-browse")
  c:reply("get_devices", result({ remote }, false))
  choose("indicator-device", choiceId, last("HA_SETUP_PAGE", "indicator-browse").revision)
  c:reply("prepare_device", {
    response = {
      version = 1,
      device_id = device,
      input_ready = false,
      control_id = "buttons",
      gesture_entity_id = gesture,
    },
  })
  T.eq(familyName .. " indicators are absent before evidence", view().indicators, nil)
  if familyName == "switch" then
    T.eq("Switch global indicator policy is absent before live evidence", advanced()["LED Behavior"], nil)
  end
  local channel = {
    id = "top",
    label = "Top indicator",
    button_id = "top",
    available = true,
    colors = codec.array({ "000000", "FF0000", "00FF00" }),
    color_supported = true,
    color = "000000",
    brightness_supported = true,
    brightness_levels = codec.array({ 25, 75 }),
    brightness = 25,
    behaviors = codec.array({ "always_on", "always_off" }),
    behavior = "always_off",
  }
  local attrs = {
    bridge_contract_version = "1.0",
    bridge_led_version = 1,
    bridge_led_command_version = 2,
    bridge_source_device_id = device,
    bridge_control_id = "buttons",
    bridge_session_id = "gesture_session",
    bridge_leds = codec.array({
      channel,
      {
        id = "bottom",
        label = "Unavailable",
        button_id = "bottom",
        available = false,
        behaviors = codec.array({ "always_on" }),
      },
    }),
  }
  if familyName == "light" then
    attrs.bridge_sources = codec.array({ { id = "native", ready = true, availability = "available" } })
  end
  local subscription = c:snapshot(gesture, "unknown", attrs)
  T.eq(familyName .. " startup/selection never sends LED commands", #c.sent, 0)
  local page = view()
  T.eq("only one writable channel is offered", #page.indicators, 1)
  T.eq(
    "a single indicator can include the linked-light choice in its behavior control",
    page.indicator_policy,
    familyName == "light" and "single" or nil
  )
  T.eq("black becomes a separately explicit behavior choice", page.indicators[1].colors, { "FF0000", "00FF00" })
  T.eq("verified hardware settings replace the missing-data explanation", page.indicator_hint, nil)
  T.eq("discovered exact brightness steps are offered verbatim", page.indicators[1].levels, { 25, 75 })
  T.eq("indicator policy keeps saved values and supplies readable labels", advanced()["LED Behavior"].choice_labels, {
    ["Use Device Setting"] = "Keep current LED setting",
    ["Follow Load"] = "On when the device is on",
    ["Follow Load (Inverted)"] = "On when the device is off",
    ["Always On"] = "Always on",
    ["Always Off"] = "Always off",
    ["Follow Bound Device"] = "Follow the linked light",
  })
  local function change(id, field, value, lease, tag)
    request(
      "HA_SETUP_INDICATOR",
      { request = tag, lease = lease or page.indicator_lease, id = id, field = field, value = value }
    )
  end
  change("bottom", "behavior", "always_on", nil, "unavailable")
  change("top", "brightness", 50, nil, "bad-step")
  change("top", "color", "000000", nil, "black")
  change("top", "color", "FF0000", "retired", "retired")
  T.eq("unavailable channels, invalid steps, black and stale selections send nothing", #c.sent, 0)
  for _, tag in ipairs({ "unavailable", "bad-step", "black", "retired" }) do
    T.truthy("explicit refusal for " .. tag, pickResult(tag).error)
  end

  change("top", "color", "FF0000", nil, "color")
  change("top", "behavior", "always_on", nil, "overlap")
  T.truthy("overlap refused", pickResult("overlap").error)
  local call = c:reply("set_led")
  T.eq("color keeps behavior untouched in exact helper v2 payload", call.service_data, {
    entity_id = gesture,
    led_id = "top",
    color = "FF0000",
  })
  T.eq("acceptance does not fabricate color while indicator remains off", view().indicators[1].color, nil)
  T.eq("off behavior is still shown", view().indicators[1].behavior, "always_off")
  T.eq("request gets correlated acceptance", pickResult("color").error, nil)

  local function update()
    at(coordinator, function()
      c.onMessage(wire({
        id = subscription,
        type = "event",
        event = {
          variables = { trigger = { to_state = { entity_id = gesture, state = "unknown", attributes = attrs } } },
        },
      }))
    end)
  end
  channel.behavior, channel.color, channel.brightness = nil, nil, nil
  update()
  local changing = last("HA_SETUP_STATE")
  T.eq("live update keeps writable controls while the switch reads back its settings", {
    changing.request == nil,
    changing.indicator_lease,
    changing.indicators and changing.indicators[1].colors,
    changing.indicators and changing.indicators[1].behaviors,
    changing.indicators and changing.indicators[1].brightness_supported,
    changing.capabilities,
  }, { true, page.indicator_lease, { "FF0000", "00FF00" }, { "always_on", "always_off" }, true, page.capabilities })
  change("top", "color", "00FF00", nil, "second-color")
  T.eq("a second color change is accepted without reopening setup", c:reply("set_led").service_data, {
    entity_id = gesture,
    led_id = "top",
    color = "00FF00",
  })
  T.eq("the second color request gets a correlated reply", pickResult("second-color").error, nil)
  channel.behavior, channel.color, channel.brightness = "always_on", "00FF00", 25
  update()
  local confirmed = last("HA_SETUP_STATE")
  T.eq("live feedback displays the second confirmed color without reopening setup", {
    confirmed.request == nil,
    confirmed.indicators and confirmed.indicators[1].color,
  }, { true, "00FF00" })
  channel.behaviors[3] = "follow_load_inverted"
  channel.behavior, channel.color, channel.configured_color = "follow_load_inverted", nil, "00FF00"
  update()
  local following = last("HA_SETUP_STATE").indicators[1]
  T.eq("hardware-follow readback carries the saved color without asserting the LED is lit", {
    following.configured_color,
    following.behavior,
    following.color,
  }, { "00FF00", "follow_load_inverted" })
  channel.configured_color = "123456"
  update()
  T.eq("a saved color outside the device palette is not displayed", view().indicators[1].configured_color, nil)
  channel.behaviors[3], channel.configured_color = nil, nil
  channel.behavior, channel.color, channel.brightness = "always_off", "000000", 25
  update()
  change("top", "brightness", 75, nil, "brightness")
  T.eq("brightness is a distinct change", c:reply("set_led").service_data, {
    entity_id = gesture,
    led_id = "top",
    brightness = 75,
  })
  T.eq("service acceptance still shows the earlier exact brightness", view().indicators[1].brightness, 25)
  channel.brightness = 75
  update()
  T.eq("latest HA evidence updates brightness", view().indicators[1].brightness, 75)
  change("top", "behavior", "always_on", nil, "behavior")
  T.eq("explicit behavior applies only that setting", c:reply("set_led").service_data, {
    entity_id = gesture,
    led_id = "top",
    behavior = "always_on",
  })
  T.eq(
    "behavior still shows the last confirmed hardware state at acceptance",
    view().indicators[1].behavior,
    "always_off"
  )
  channel.behavior, channel.color = "always_on", "FF0000"
  update()
  T.eq("later HA evidence confirms both behavior and color", {
    view().indicators[1].behavior,
    view().indicators[1].color,
  }, { "always_on", "FF0000" })
  local other = {
    id = "remote",
    button_id = "scene",
    label = "Scene",
    available = true,
    color_supported = true,
    colors = codec.array({ "000000", "FFFFFF" }),
    brightness_supported = false,
    behaviors = codec.array({}),
  }
  attrs.bridge_leds[3] = other
  update()
  T.eq(
    "Composer lists live channels in role order",
    GetCommandParamList("Set LED Current Color", "Button"),
    { "Top", "Scene [remote]" }
  )
  T.eq("per-channel brightness list", GetCommandParamList("Set LED Brightness", "Button"), { "Top" })
  T.eq(
    "behaviors include supported options in original order",
    GetCommandParamList("Set LED Behavior", "Behavior"),
    { "Always On", "Always Off" }
  )
  ExecuteCommand("Set LED Current Color", { Button = "Old name [remote]", Color = "fffffe" })
  T.eq("saved renamed indicator resolves by stable ID and maps to palette", c:reply("set_led").service_data, {
    entity_id = gesture,
    led_id = "remote",
    color = "FFFFFF",
  })
  T.eq(
    "black current color is never sent as a power command",
    ExecuteCommand("Set LED Current Color", { Button = "Top", Color = "000000" }),
    false
  )
  T.eq(
    "out-of-range programmed brightness is refused",
    ExecuteCommand("Set LED Brightness", { Button = "0", Brightness = "101" }),
    false
  )
  T.eq("invalid and unsupported programming sends nothing", #c.sent, 0)
  ExecuteCommand("Set LED Brightness", { Button = "0", Brightness = "50" })
  T.eq(
    "a saved program retains nearest-step behavior with ties going lower",
    c:reply("set_led").service_data.brightness,
    25
  )
  ExecuteCommand("Set LED Behavior", { Button = "Top", Behavior = "Always Off" })
  T.eq("saved behavior label maps to independent setting", c:reply("set_led").service_data.behavior, "always_off")
  if familyName == "light" then
    PersistData = { LEDColors = { buttons = { top = { ON_COLOR = "FF0000", OFF_COLOR = "000000" } } } }
    ExecuteCommand("Set LED On Color", { Button = "Top", Color = "00ff02" })
    ExecuteCommand("Set LED Off Color", { Button = "Top", Color = "000000" })
    T.eq("saved tracking colors use the predecessor store and palette", PersistData.LEDColors.buttons.top, {
      ON_COLOR = "00FF00",
      OFF_COLOR = "000000",
    })
    T.eq("saving tracking colors does not change hardware", #c.sent, 0)
  end
  other.color_supported = false
  update()
  T.eq(
    "a fixed-color channel blocks the entire bulk write",
    ExecuteCommand("Set All LED Colors", { Color = "00ff00" }),
    false
  )
  T.eq("no first channel writes on bulk validation failure", #c.sent, 0)
  other.color_supported = true
  update()
  ExecuteCommand("Set All LED Colors", { Color = "00ff00" })
  T.eq("bulk command affects each live channel in stable ID order", {
    c:reply("set_led").service_data,
    c:reply("set_led").service_data,
  }, {
    { led_id = "remote", entity_id = gesture, color = "FFFFFF" },
    { led_id = "top", entity_id = gesture, color = "00FF00" },
  })
  if familyName == "light" then
    T.eq("bulk saved on/off colors persist per channel", PersistData.LEDColors.buttons.top, {
      ON_COLOR = "00FF00",
      OFF_COLOR = "00FF00",
    })
    PersistData = nil
  end
  ExecuteCommand("Set LED Behavior", { Button = "Top", Behavior = "Always Off" })
  ExecuteCommand("Set LED Behavior", { Button = "Top", Behavior = "Always On" })
  T.eq("opposing writes while awaiting acceptance stay in order", {
    c:reply("set_led").service_data.behavior,
    c:reply("set_led", nil, "rejected").service_data.behavior,
  }, { "always_off", "always_on" })
  T.eq(
    "asynchronous rejection reaches existing command result",
    Variables["Last Command Result"],
    "Home Assistant rejected this indicator setting. Check its current settings before trying again."
  )
  if familyName == "light" then
    attrs.bridge_leds[3] = nil
    channel.color, channel.behavior = "FF0000", "always_on"
    update()
    T.eq(
      "shown follow policies use only common device capabilities",
      advanced()["LED Behavior"].choices,
      { "Use Device Setting", "Always On", "Always Off", "Follow Bound Device" }
    )
    T.eq("source hidden until following chosen", advanced()["LED Feedback Source"], nil)
    requestedLEDLink = nil
    change("top", "behavior", "follow_bound", "retired", "stale-follow")
    T.truthy("a retired setup page cannot change the policy", pickResult("stale-follow").error)
    change("top", "behavior", "follow_bound", nil, "follow-bound")
    T.eq(
      "the same selector can save the linked-light policy",
      pickResult("follow-bound").message,
      "Indicator behavior saved."
    )
    T.eq("the reopened page shows the linked-light policy as active", view().indicator_following, true)
    change("top", "behavior", "always_off", nil, "reject-leaving-follow")
    T.eq(
      "new tracking writes wait for the explicit hardware mode change",
      ReceivedFromProxy(ids.targetLinks.bottom, "MATCH_LED_STATE", { STATE = 1 }),
      false
    )
    T.eq(
      "hardware mode is sent through the same indicator command",
      c:reply("set_led", nil, "rejected").service_data.behavior,
      "always_off"
    )
    T.truthy("a rejected hardware mode is reported in Device Setup", pickResult("reject-leaving-follow").error)
    T.eq("rejection preserves the previous policy and reported mode", {
      view().indicator_following,
      view().indicators[1].behavior,
    }, { true, "always_on" })
    change("top", "behavior", "always_off", nil, "accept-leaving-follow")
    c:reply("set_led")
    T.eq("acceptance disables tracking and waits for hardware readback", {
      Properties["LED Behavior"],
      view().indicators[1].behavior,
    }, { "Use Device Setting", "always_on" })
    channel.behavior = "always_off"
    update()
    T.eq("reopened Device Setup shows the confirmed hardware mode", view().indicators[1].behavior, "always_off")
    channel.behavior = "always_on"
    update()
    change("top", "behavior", "follow_bound", nil, "follow-again")
    local tracking = view().indicators[1]
    T.eq(
      "bound tracking offers black and both device colors",
      tracking.tracking_colors,
      { "000000", "00FF00", "FF0000" }
    )
    change("top", "on_color", "FF0000", view().indicator_lease, "tracked-on")
    T.eq("saving a web tracking color succeeds", pickResult("tracked-on").message, "Indicator color saved.")
    T.eq(
      "palette-capable lights expose native color fields",
      { attribs["LED Indicator"], attribs["LED On Color"], attribs["LED Off Color"] },
      { 0, 0, 0 }
    )
    T.eq("native saved color mirrors the web selection", Properties["LED On Color"], "255,0,0")
    Properties["LED On Color"] = "0,255,0"
    OnPropertyChanged("LED On Color")
    T.eq("native original color field updates the same preference", view().indicators[1].on_color, "00FF00")
    T.eq("saving either tracked color never actuates a light", #c.sent, 0)
    change("top", "off_color", "123456", view().indicator_lease, "invalid-track")
    T.truthy("unsupported tracking color is rejected", pickResult("invalid-track").error)
    T.eq("only linked paddle is chosen for an explicit follow request", Properties["LED Feedback Source"], "Bottom")
    T.eq("choosing follow requests feedback only from the chosen link", requestedLEDLink, ids.targetLinks.bottom)
    T.eq(
      "feedback source list includes only bound links",
      advanced()["LED Feedback Source"].choices,
      { "Disabled", "Bottom" }
    )
    T.eq(
      "wrong link cannot drive indicator hardware",
      ReceivedFromProxy(ids.targetLinks.top, "MATCH_LED_STATE", { STATE = true }),
      false
    )
    T.eq(
      "unparseable feedback cannot turn indicators off",
      ReceivedFromProxy(ids.targetLinks.bottom, "MATCH_LED_STATE", { STATE = "unset" }),
      false
    )
    ExecuteCommand("Set LED On Color", { Button = "Top", Color = "00FF00" })
    ExecuteCommand("Set LED Off Color", { Button = "Top", Color = "000000" })
    T.eq("configuring follow and its colors issues no HA writes", #c.sent, 0)
    ReceivedFromProxy(ids.targetLinks.bottom, "MATCH_LED_STATE", { STATE = " TRUE " })
    T.eq(
      "bound target on sets independently saved color and explicit power together",
      c:reply("set_led").service_data,
      {
        entity_id = gesture,
        led_id = "top",
        color = "00FF00",
        behavior = "always_on",
      }
    )
    ReceivedFromProxy(ids.targetLinks.bottom, "MATCH_LED_STATE", { STATE = "0" })
    T.eq("bound target off with saved black explicitly controls power", c:reply("set_led").service_data, {
      entity_id = gesture,
      led_id = "top",
      color = "000000",
      behavior = "always_off",
    })
    requestedLEDLink = nil
    T.truthy("original refresh action is effective", ExecuteCommand("LUA_ACTION", { ACTION = "RefreshLEDFeedback" }))
    T.eq(
      "refresh asks the chosen link and leaves HA untouched",
      { requestedLEDLink, #c.sent },
      { ids.targetLinks.bottom, 0 }
    )
    local previous = links[ids.targetLinks.bottom].boundprovider
    links[ids.targetLinks.bottom].boundprovider = nil
    T.eq(
      "lost binding rejects feedback before OBC",
      ReceivedFromProxy(ids.targetLinks.bottom, "MATCH_LED_STATE", { STATE = 0 }),
      false
    )
    links[ids.targetLinks.bottom].boundprovider = previous
    change("top", "behavior", "use_device_setting", nil, "keep-device-setting")
    T.eq("keeping the current LED setting shows the reported mode again", view().indicator_following, nil)
    T.eq("disabling tracking leaves existing hardware untouched", #c.sent, 0)
    T.eq(
      "disabled tracking ignores subsequent feedback",
      ReceivedFromProxy(ids.targetLinks.bottom, "MATCH_LED_STATE", { STATE = 0 }),
      false
    )
    -- The control is still selected when a second link is added. Its cached
    -- metadata is delivered by the Coordinator on the replacement selection.
    bindTarget(ids.targetLinks.top, 32, ids.lightLinks.top)
    Properties["LED Feedback Source"] = "Disabled"
    requestedLEDLink = nil
    setProperty("LED Behavior", "Follow Bound Device")
    T.eq("two different destinations require an explicit source", Properties["LED Feedback Source"], "Disabled")
    T.eq("ambiguous choice does not query either light", requestedLEDLink, nil)
    T.eq("refresh with no source remains inert", ExecuteCommand("RefreshLEDFeedback"), false)
    setProperty("LED Feedback Source", "Top")
    T.eq("explicit source queries the chosen light", requestedLEDLink, ids.targetLinks.top)
    requestedLEDLink = nil
    setProperty("LED Feedback Source", "Disabled")
    update()
    T.eq("an explicitly disabled source survives new evidence", Properties["LED Feedback Source"], "Disabled")
    T.eq("fresh metadata never issues an LED request", requestedLEDLink, nil)
    PersistData = nil
  else
    T.eq("a color-only Switch indicator prevents device-wide behavior changes", advanced()["LED Behavior"], nil)
    setProperty("LED Behavior", "Always Off")
    T.eq("unsupported global behavior writes nothing", #c.sent, 0)
    other.behaviors = codec.array({ "always_off", "follow_load" })
    other.behavior = "follow_load"
    update()
    T.eq("a switch with multiple indicators can still apply behavior to all of them", view().indicator_policy, "all")
    T.eq(
      "Switch offers only behaviors supported on every available indicator",
      advanced()["LED Behavior"].choices,
      { "Use Device Setting", "Always Off" }
    )
    T.truthy(
      "native Switch LED Status names the currently available indicator",
      Properties["LED Status"]:find("Top indicator", 1, true)
    )
    T.eq("viewing Switch LED controls never changes hardware", #c.sent, 0)
    setProperty("LED Behavior", "Always Off")
    T.eq("explicit device-wide policy addresses each supported Switch indicator", {
      c:reply("set_led").service_data,
      c:reply("set_led").service_data,
    }, {
      { entity_id = gesture, led_id = "remote", behavior = "always_off" },
      { entity_id = gesture, led_id = "top", behavior = "always_off" },
    })
    T.eq("acceptance alone leaves reported indicator behavior unchanged", view().indicators[1].behavior, "always_on")
    setProperty("LED Behavior", "Use Device Setting")
    T.eq("Use Device Setting leaves hardware alone", #c.sent, 0)
  end
  channel.colors = codec.array({ "00FF00" })
  update()
  change("top", "color", "FF0000", nil, "palette-changed")
  T.eq("child rechecks changed capabilities before sending", #c.sent, 0)
  T.truthy("removed palette value rejected", pickResult("palette-changed").error)
  channel.label, channel.color_supported, channel.brightness_supported = "Locator LED", false, false
  channel.colors = codec.array({ "000000" })
  channel.behaviors = codec.array({ "follow_load", "follow_load_inverted", "always_off" })
  channel.color, channel.behavior, other.available = nil, "follow_load_inverted", false
  update()
  local locator = view().indicators[1]
  T.eq("locator LED presents only its three writable behaviors", locator.behaviors, channel.behaviors)
  T.eq("locator LED displays confirmed behavior", locator.behavior, "follow_load_inverted")
  T.eq("locator LED has no color or brightness editor", { locator.colors, locator.brightness_supported }, { nil, nil })
  if familyName == "light" then
    T.eq("locator LED has no native tracking-color options", GetCommandParamList("Set LED On Color", "Button"), {})
    T.eq(
      "locator LED hides native tracking properties",
      { attribs["LED Indicator"], attribs["LED On Color"], attribs["LED Off Color"] },
      { 1, 1, 1 }
    )
    T.eq(
      "saved native color commands cannot configure locator LED tracking",
      ExecuteCommand("Set LED Off Color", { Button = "Top", Color = "000000" }),
      false
    )
    T.eq("unsupported tracking color does not save preferences", PersistData, nil)
  end
  channel.available, other.available = false, false
  update()
  local noIndicators = view()
  T.eq("unavailable channels have guidance and no adjustable capability", {
    noIndicators.indicators == nil,
    noIndicators.indicator_hint ~= nil,
    table.concat(noIndicators.capabilities or {}, ","):find("Indicator lights", 1, true) ~= nil,
  }, { true, true, false })
  channel.available, other.available = true, true
  attrs.bridge_led_command_version = 1
  update()
  T.eq("older versions show no available controls", view().indicators, nil)
end

T.section("Physical picker upgrades retain the saved mode, exact linked target and device identity")
do
  local sourceId, targetId = string.rep("a", 32), string.rep("b", 32)
  local target = "light.linked_lamp"
  local function prior(mode, change)
    local source = { entity_id = relay, domain = "switch", available = true, registry_id = sourceId }
    local saved = {
      choice = {
        type = "device_choice",
        version = 1,
        name = "Original paddle",
        kind = "switch",
        device_id = device,
        source_load = wire(source),
        choice_id = "device:" .. device .. ":" .. sourceId,
        gesture_entity_id = gesture,
      },
      result = {
        version = 1,
        input_ready = true,
        device_id = device,
        control_id = "buttons",
        source_load = source,
        gesture_entity_id = gesture,
        controlled_load_origin = "explicit_link",
        controlled_load = { entity_id = target, domain = "light", registry_id = targetId, available = true },
      },
    }
    return fixture("light", function()
      PersistData = { DeviceSelection = saved }
      Properties["Operation Mode"] = mode
      Properties["Entity ID"] = mode == "Control HA Device" and target or gesture
      if change then
        change(saved)
      end
    end)
  end
  prior("Programming Events Only")
  T.eq(
    "a restored prototype button exposes its original mode selector",
    { attribs["Operation Mode"], attribs["Button behavior"] },
    { 0, constants.HIDE_PROPERTY }
  )
  Properties["Operation Mode"] = "Control HA Device"
  OnPropertyChanged("Operation Mode")
  T.eq(
    "changing the old mode uses the retained picker target",
    { Properties["Entity ID"], selected[#selected] },
    { target, { target } }
  )
  restart()
  T.eq("an explicitly changed prototype mode survives reload", selected[#selected], { target })
  Properties["Operation Mode"] = "Control HA Device with Button Events"
  OnPropertyChanged("Operation Mode")
  T.eq(
    "changing to bridge mode selects the original source and target",
    { Properties["Entity ID"], selected[#selected] },
    { gesture, { target, gesture } }
  )
  Properties["Operation Mode"] = "Programming Events Only"
  OnPropertyChanged("Operation Mode")
  T.eq("the old programming mode removes load authority", selected[#selected], { gesture })
  T.eq("read-only native state mirrors the chosen device", Properties["Selected Device"], "Original paddle")
  T.eq(
    "native Basic shows the selected device and the custom Advanced list omits its duplicate",
    { attribs["Selected Device"], advanced()["Selected Device"] },
    { 0 }
  )
  local entries = {
    [target] = { entity_id = target, id = targetId, platform = "demo" },
    [relay] = { entity_id = relay, id = sourceId, device_id = device, platform = "demo" },
  }
  for _, mode in ipairs({
    "Control HA Device",
    "Control HA Device with Button Events",
    "Programming Events Only",
    "Control Connected C4 Light",
  }) do
    local c = prior(mode)
    local entities = selected[#selected]
    local hasLoad = mode == "Control HA Device" or mode == "Control HA Device with Button Events"
    local hasButtons = mode ~= "Control HA Device"
    local expected = {}
    if hasLoad then
      expected[#expected + 1] = target
    end
    if hasButtons then
      expected[#expected + 1] = gesture
    end
    T.eq("restored subscriptions for " .. mode, entities, expected)
    T.eq("device identity stays physical", view().selected_id, "device:" .. device .. ":" .. sourceId)
    local sources = {
      bridge_contract_version = "1.1",
      bridge_source_device_id = device,
      bridge_control_id = "buttons",
      bridge_session_id = "fixture",
      bridge_load = { entity_id = target, domain = "light", available = true },
      bridge_sources = codec.array({ { id = "native", ready = true, availability = "available" } }),
    }
    while c.sent[1] and c.sent[1].type == "subscribe_trigger" do
      local id = c:reply("subscribe_trigger").trigger.entity_id
      c:completeRead(
        id,
        id == target and "off" or "unknown",
        id == target and { supported_color_modes = { "onoff" } } or sources
      )
    end
    if hasLoad then
      ExecuteCommand("Turn On")
      T.eq("load waits for saved identity before control", #c.sent, 1)
      local verify = c:reply("config/entity_registry/get_entries", entries)
      T.eq("only exact load and source registry records are read", verify.entity_ids, { target, relay })
      T.eq("confirmed saved load is ready", view().status, "Device connected")
      ExecuteCommand("Turn On")
      T.eq("saved service uses linked bulb and never the relay", c:reply("turn_on").target.entity_id, target)
    else
      ExecuteCommand("Turn On")
      T.eq("saved non-load mode issues no HA service", #c.sent, 0)
    end
  end
  local c = prior("Control HA Device")
  c:snapshot(target, "off", { supported_color_modes = { "onoff" } })
  local replaced = wire(entries)
  replaced[target].id = string.rep("e", 32)
  c:reply("config/entity_registry/get_entries", replaced)
  T.eq("same name with a different registry record is rejected", view().status, "Check the saved device")
  ExecuteCommand("Turn On")
  T.eq("unverified replacement stays idle", #c.sent, 0)
  c = prior("Control HA Device")
  c:snapshot(target, "off", { supported_color_modes = { "onoff" } })
  local wrongOwner = wire(entries)
  wrongOwner[relay].device_id = string.rep("e", 32)
  c:reply("config/entity_registry/get_entries", wrongOwner)
  T.eq("same saved entity on a different physical device is rejected", view().status, "Check the saved device")
  c = prior("Control HA Device with Button Events")
  local subscriptions = {}
  while c.sent[1] and c.sent[1].type == "subscribe_trigger" do
    local packet = c:reply("subscribe_trigger")
    subscriptions[packet.trigger.entity_id] = packet.id
  end
  local sourceState = {
    bridge_contract_version = "1.1",
    bridge_source_device_id = device,
    bridge_control_id = "buttons",
    bridge_session_id = "fixture",
    bridge_load = { entity_id = target, domain = "light", available = true },
    bridge_sources = codec.array({ { id = "wall", ready = true, availability = "available" } }),
  }
  local foreign = wire(sourceState)
  foreign.bridge_source_device_id = string.rep("e", 32)
  while c.reads[1] do
    local entity = c.reads[1].entity
    c:completeRead(
      entity,
      entity == target and "off" or "unknown",
      entity == target and { supported_color_modes = { "onoff" } } or foreign
    )
  end
  c:reply("config/entity_registry/get_entries", entries)
  ExecuteCommand("Turn On")
  T.eq("even a registry-verified target waits for the saved event source", #c.sent, 0)
  local function pushSource(attributes)
    at(coordinator, function()
      c.onMessage(wire({
        id = subscriptions[gesture],
        type = "event",
        event = {
          variables = { trigger = { to_state = { entity_id = gesture, state = "unknown", attributes = attributes } } },
        },
      }))
    end)
  end
  pushSource(sourceState)
  ExecuteCommand("Turn On")
  T.eq("live matching source restores only the saved linked light", c:reply("turn_on").target.entity_id, target)
  local relinked = wire(sourceState)
  relinked.bridge_load.entity_id = "light.new_link"
  pushSource(relinked)
  ExecuteCommand("Turn On")
  T.eq("changed companion link never drives the old light or relay", #c.sent, 0)
  pushSource(sourceState)
  pushSource(foreign)
  ExecuteCommand("Turn On")
  T.eq("a replaced button source retires linked-light command authority", #c.sent, 0)
  c = prior("Control HA Device", function()
    PersistData.ControllerModeOverride = true
    links[ids.targetLinks.top].boundprovider = { bound = { deviceid = 31, bindingid = ids.lightLinks.top } }
  end)
  T.eq("prototype's explicit HA override survives an existing Control4 link", selected[#selected], { target })
  c = prior("Control HA Device", function()
    links[ids.targetLinks.top].boundprovider = { bound = { deviceid = 31, bindingid = ids.lightLinks.top } }
  end)
  T.eq("unoverridden original link selects the connected Control4 light", selected[#selected], { gesture })
  c = prior("Programming Events Only", function()
    persist:set(saved, "false", true)
  end)
  T.eq("prior explicit clear wins over intact physical picker data", selected[#selected], {})
  c = prior("Programming Events Only")
  local savedKey = view().selected_id
  OnPropertyChanged("Entity ID")
  T.eq(
    "native property replay keeps the physical selection and button mode",
    { view().selected_id, selected[#selected], #c.reads },
    { savedKey, { gesture }, 0 }
  )
  PersistData.DeviceSelection = nil
  restart()
  T.eq("a restart uses the suite's normalized record", view().selected_id, savedKey)
  T.eq("normal reload retains buttons-only routing", selected[#selected], { gesture })
  c = prior("Control HA Device", function(saved)
    saved.result.controlled_load.registry_id = nil
  end)
  c:snapshot(target, "off", { supported_color_modes = { "onoff" } })
  ExecuteCommand("Turn On")
  T.eq("unresolved explicit link never falls back to wall relay", #c.sent, 0)
  T.eq("unresolved link is actionable", view().status, "Check the saved device")
  c = prior("Control HA Device", function(saved)
    saved.result.source_load.registry_id = targetId
  end)
  T.eq("crossed source ID invalidates the whole record", selected[#selected], {})
  T.eq("crossed record has no traffic", #c.sent, 0)
  c = prior("Control HA Device", function(saved)
    Properties["Entity ID"] = relay
  end)
  T.eq("manual field conflicting with saved load is never adopted", selected[#selected], {})
  c = prior("Programming Events Only", function()
    Properties["Button behavior"] = "Home Assistant device"
  end)
  T.eq(
    "native Properties expose the overriding mode",
    { attribs["Operation Mode"], attribs["Button behavior"] },
    { constants.HIDE_PROPERTY, constants.SHOW_PROPERTY }
  )
  T.eq("prior explicit suite override wins over prototype mode", selected[#selected], { target, gesture })
  PersistData = nil
end

T.section("An in-place Light update restores only an established direct target")
do
  local entity = "light.original"
  local c = fixture("light", function()
    Properties["Entity ID"] = entity
  end)
  T.eq("prototype direct target is restored exactly", selected[#selected], { entity })
  T.eq("normal subscription is the only HA request", #c.sent, 1)
  c:snapshot(entity, "off", { friendly_name = "Original light", supported_color_modes = { "onoff" } })
  T.eq("existing device is shown after feedback", view().title, "Original light")
  T.eq("a configured Light hides the migration panel", view().migration_available, false)
  T.eq(
    "native next step points to the device picker",
    Properties["Next step"],
    "To change this device, open Device Setup."
  )
  T.eq(
    "a direct light shows its friendly name once",
    { Properties["Selected Device"], attribs.Controls },
    { "Original light", constants.HIDE_PROPERTY }
  )
  T.eq("legacy entity field is hidden in Properties", attribs["Entity ID"], constants.HIDE_PROPERTY)
  T.eq("legacy mode field is hidden in Properties", attribs["Operation Mode"], constants.HIDE_PROPERTY)
  T.eq("legacy entity field is excluded from Advanced", advanced()["Entity ID"], nil)
  T.eq("legacy mode field is excluded from Advanced", advanced()["Operation Mode"], nil)
  setProperty("Manual entity ID", "")
  restart()
  T.eq("clearing setup suppresses old configuration on restart", selected[#selected], {})
  T.eq("the original property copy remains available for rollback", Properties["Entity ID"], entity)
  C4:PersistSetValue(saved, false, true)
  ShimPersistLand()
  persist._persist[saved] = nil
  Properties["Manual entity ID"] = entity
  restart()
  T.eq(
    "a cold boolean clear suppresses stale fields without an error",
    { selected[#selected], Properties["Manual entity ID"], view().status },
    { {}, "", "Not configured" }
  )

  c = fixture("light", function()
    Properties["Entity ID"] = entity
    Properties["Manual entity ID"] = "light.suite"
  end)
  T.eq("existing suite selection wins over the predecessor property", selected[#selected], { "light.suite" })
  T.eq("its subscription is the only HA request", #c.sent, 1)

  for _, scenario in ipairs({
    { reason = "untouched BP default", entity = "light.table_lamp" },
    { reason = "gesture mode", mode = "Control HA Device with Button Events" },
    { reason = "buttons only", mode = "Programming Events Only" },
    { reason = "connected mode", mode = "Control Connected C4 Light" },
    { reason = "legacy link", binding = ids.targetLinks.top },
    { reason = "pending old selection", old = { DeviceSelection = { choice = {} } } },
    { reason = "old override", old = { ControllerModeOverride = true } },
    { reason = "existing suite mode", override = "Buttons only" },
    { reason = "broken suite record", saved = "{}" },
    { reason = "unsuitable target", entity = "event.button" },
  }) do
    PersistData = scenario.old
    c = fixture("light", function()
      Properties["Entity ID"] = scenario.entity or entity
      Properties["Operation Mode"] = scenario.mode or Properties["Operation Mode"]
      Properties["Button behavior"] = scenario.override or Properties["Button behavior"]
      if scenario.binding then
        links[scenario.binding] = { boundprovider = { bound = { deviceid = 31 } } }
      end
      if scenario.saved then
        persist:set(saved, scenario.saved, true)
      end
    end)
    PersistData = nil
    T.eq("no replacement target for " .. scenario.reason, selected[#selected], {})
    T.eq("no HA request for " .. scenario.reason, #c.sent, 0)
  end

  c = fixture("light", function()
    C4:AddVariable("ENTITY_ID", "light.conflict", "STRING")
    Properties["Entity ID"] = entity
  end)
  T.eq("disagreement with the BP programming variable prevents restoration", selected[#selected], {})
  T.eq("disagreement requires no HA request", #c.sent, 0)

  c = fixture("light", function()
    require("lib.values"):update("ENTITY_ID", entity, "STRING")
    Properties["Entity ID"] = entity
    Properties["Operation Mode"] = ""
  end)
  T.eq("BP direct property's value agrees with its live variable", selected[#selected], { entity })
  c:snapshot(entity, "off", { supported_color_modes = { "onoff" } })
  setProperty("Manual entity ID", "light.replacement")
  T.eq("unverified changes preserve the old programming value", Variables.ENTITY_ID, entity)
  c:completeRead("light.replacement", "off")
  T.eq("the programming variable follows a confirmed explicit selection", Variables.ENTITY_ID, "light.replacement")
  setProperty("Manual entity ID", "")
  T.eq("explicitly clearing selection clears the old programming value", Variables.ENTITY_ID, "")

  local function writeOriginal(value)
    Properties["Entity ID"] = value
    OnPropertyChanged("Entity ID")
  end
  writeOriginal("light.changed")
  T.eq("old property holds last accepted value during verification", Properties["Entity ID"], entity)
  T.eq("pending original write cannot restore control", selected[#selected], {})
  c:completeRead("light.changed", "on")
  T.eq("original property selects a verified target through the shared manual path", {
    Properties["Entity ID"],
    Properties["Manual entity ID"],
    Variables.ENTITY_ID,
    selected[#selected],
  }, { "light.changed", "light.changed", "light.changed", { "light.changed" } })
  local record = persist:get(saved, nil, true)
  writeOriginal("light.not valid")
  T.eq(
    "invalid original edit keeps accepted raw value and target",
    { Properties["Entity ID"], persist:get(saved, nil, true) },
    { "light.changed", record }
  )
  writeOriginal("light.missing")
  c:completeRead("light.missing", nil, nil, "not_found")
  T.eq(
    "unavailable original edit keeps accepted setup and raw value",
    { Properties["Entity ID"], persist:get(saved, nil, true) },
    { "light.changed", record }
  )
  writeOriginal("light.abandoned")
  local abandoned = assert(table.remove(c.reads, 1)).promise
  restart()
  at(coordinator, function()
    abandoned:resolve(wire({ entity_id = "light.abandoned", state = "on", attributes = codec.object({}) }))
  end)
  T.eq(
    "original edit from a retired owner cannot replace accepted selection",
    { Properties["Entity ID"], selected[#selected] },
    { "light.changed", { "light.changed" } }
  )
  writeOriginal("")
  restart()
  T.eq(
    "clearing original property survives restart",
    { Properties["Entity ID"], Variables.ENTITY_ID, selected[#selected] },
    { "", "", {} }
  )
end

T.section("Native prototype Light browsing and explicit selection use the shared verified catalog")
do
  local c = fixture("light")
  local returned
  BrowseHALightDevices(nil, function(rows)
    returned = rows
  end, "patio", "gesture")
  c:reply("get_devices", result({ remote }, false))
  T.eq("native callback applies button and search filters", returned[1].value, choiceId)
  T.eq("dimmer filter omits remote", #BrowseHALightDevices(nil, nil, "", "dimmer"), 0)
  T.eq("browsing preserves unconfigured target", persist:get(saved, nil, true), nil)
  ExecuteCommand("RefreshEntities", {})
  c:reply("get_devices", result({ remote }, true))
  T.eq("refresh leaves target unchanged", persist:get(saved, nil, true), nil)
  ExecuteCommand("SelectDevice", { Device = codec.encode(wire(remote.attributes.device_choice)) })
  c:reply("prepare_device", {
    response = {
      version = 1,
      device_id = device,
      input_ready = false,
      control_id = "buttons",
      gesture_entity_id = gesture,
    },
  })
  T.eq(
    "packed prototype action selects verified physical device",
    codec.decode(persist:get(saved, nil, true)).key,
    choiceId
  )
end
T.section("Custom prototype catalog sensor affects only displayed names")
do
  local c = fixture("light")
  local group =
    { domain = "light", entity_id = "light.group", name = "Group", is_group = true, attributes = codec.object({}) }
  local sensor = "sensor.renamed_catalog"
  function c:readCatalogNames(entity)
    T.eq("only the configured sensor is read", entity, sensor)
    local pending = deferred.new()
    local state = wire({
      entity_id = sensor,
      state = "1",
      attributes = {
        catalog_names_version = 1,
        catalog_contract_version = "1.1",
        catalog_names_revision = string.rep("a", 64),
        catalog_names_total = 1,
        catalog_names_pages = 1,
        catalog_names_page_001 = {
          { entity_id = group.entity_id, domain = "light", friendly_name = "Custom group", area_name = "Family room" },
        },
      },
    })
    pending:resolve(assert(require("ha.catalog-names").parse(state, sensor)))
    return pending
  end
  Properties["Discovery Catalog Entity ID"] = sensor
  OnPropertyChanged("Discovery Catalog Entity ID")
  c:reply("get_devices", result({ group }, false))
  local list = BrowseHALightDevices(nil, nil, "family room", "all")
  T.eq(
    "custom sensor metadata overlays verified endpoint",
    { list[1].text, list[1].value },
    { "Custom group [light.group]", group.entity_id }
  )
  T.eq("sensor change and refresh do not choose the device", persist:get(saved, nil, true), nil)
  Properties["Entity Selection"] = list[1].text
  OnPropertyChanged("Entity Selection")
  T.eq("verified native picker commit does not refresh Home Assistant", #c.sent, 1)
  T.eq("native property action selects exact group", codec.decode(persist:get(saved, nil, true)).key, group.entity_id)
  c:snapshot(group.entity_id, "off")
  ExecuteCommand("RefreshEntities", {})
  c:completeRead(group.entity_id, "on")
  T.eq("refresh reads fresh selected state without a new subscription", levels[#levels], 100)
  c:reply("get_devices", result({ group }, true))
  require("c4_fixtures").coldStoredObject(saved)
  restart()
  T.eq(
    "native object cold read restores the exact selected group",
    { view().selected_id, selected[#selected] },
    { group.entity_id, { group.entity_id } }
  )
end
T.section("Switch Device Setup uses custom catalog names only for display")
do
  local c = fixture("switch")
  local sensor = "sensor.switch_names"
  local calls = 0
  local item =
    { domain = "switch", entity_id = "switch.garden", name = "Garden", is_group = true, attributes = codec.object({}) }
  function c:readCatalogNames(id)
    calls = calls + 1
    T.eq("the requested Switch sensor matches the saved override", id, sensor)
    local pending = deferred.new()
    if calls == 1 then
      pending:resolve({ [item.entity_id] = { name = "Patio lamps", area = "Outside" } })
    else
      pending:reject({ kind = "not_found" })
    end
    return pending
  end
  setProperty("Discovery Catalog Entity ID", sensor)
  for _, tag in ipairs({ "override", "missing" }) do
    request("HA_SETUP_BROWSE", { request = tag })
    c:reply("get_devices", result({ item }, false))
    local page = assert(last("HA_SETUP_PAGE", tag))
    T.eq("the Switch catalog keeps the verified device identity", page.choices[1].id, item.entity_id)
    if tag == "override" then
      T.eq(
        "custom name and room appear in the Switch chooser",
        { page.choices[1].name, page.choices[1].area },
        { "Patio lamps", "Outside" }
      )
    else
      T.eq(
        "a missing custom sensor returns usable original names with a warning",
        { page.choices[1].name, page.catalogWarning },
        { "Garden", true }
      )
    end
  end
  setProperty("Discovery Catalog Entity ID", "invalid sensor name")
  request("HA_SETUP_BROWSE", { request = "invalid" })
  c:reply("get_devices", result({ item }, false))
  local page = assert(last("HA_SETUP_PAGE", "invalid"))
  T.eq(
    "an invalid custom sensor still permits browsing verified devices",
    { page.choices[1].id, page.catalogWarning, calls },
    { item.entity_id, true, 2 }
  )
  T.eq("browsing Switch aliases never selects a device", view().selected_id, nil)
end

T.section("Manually configured prototype event entities recover from their exact registry identity")
do
  local target, registry, loadRegistry = "light.saved_link", string.rep("a", 32), string.rep("b", 32)
  local attrs = {
    bridge_contract_version = "1.0",
    bridge_control_id = "saved-wall",
    bridge_session_id = "initial",
    bridge_update_kind = "snapshot",
    bridge_sources = codec.array({ { id = "source", ready = true, availability = "available" } }),
    bridge_buttons = codec.array({
      {
        id = "top",
        label = "Paddle",
        gestures = codec.array({
          { id = "press_2", kind = "press", press_count = 2, label = "double press" },
        }),
      },
    }),
    bridge_load = { entity_id = target, domain = "light", available = true },
  }
  local entries = {
    [gesture] = {
      entity_id = gesture,
      id = registry,
      platform = "ha_gesture_bridge",
      unique_id = "saved-wall",
      disabled_by = codec.null,
    },
    [target] = { entity_id = target, id = loadRegistry, platform = "demo", disabled_by = codec.null },
  }
  local function original(mode)
    return fixture("light", function()
      Properties["Entity ID"], Properties["Operation Mode"] = gesture, mode
    end)
  end
  local function settle(c, data, registryRows)
    local sourceSubscription
    for _ = 1, 16 do
      if c.sent[1] then
        local op = c.sent[1].type
        if op == "subscribe_trigger" then
          local packet = c:reply(op)
          if packet.trigger.entity_id == gesture then
            sourceSubscription = packet.id
          end
        elseif op == "unsubscribe_events" then
          c:reply(op)
        elseif op == "config/entity_registry/get_entries" then
          c:reply(op, registryRows)
        else
          error("Unexpected recovery operation " .. op)
        end
      elseif c.reads[1] then
        local read = table.remove(c.reads, 1)
        at(coordinator, function()
          read.promise:resolve(wire({
            entity_id = read.entity,
            state = read.entity == gesture and "unknown" or "off",
            last_updated = "2026-11-17T12:00:00Z",
            attributes = read.entity == gesture and data or { supported_color_modes = { "onoff" } },
          }))
        end)
      else
        return sourceSubscription
      end
    end
    error("event recovery did not settle")
  end
  local c = original("Control HA Device with Button Events")
  T.eq("unverified raw event starts with a read-only event subscription", selected[#selected], { gesture })
  ExecuteCommand("Turn On")
  T.eq("recovery cannot send a service before proof", #c.sent, 1)
  local subscription = settle(c, attrs, entries)
  local config = codec.decode(persist:get(saved, nil, true))
  T.eq("manual fixture pins both exact registry entries without inventing a physical source", {
    config.event_registry_id,
    config.controlled_load.registry_id,
    config.device_id,
  }, { registry, loadRegistry })
  ExecuteCommand("Turn On")
  T.eq("a verified manual event drives only its declared load", c:reply("turn_on").target.entity_id, target)
  local function push(data, time)
    at(coordinator, function()
      c.onMessage(wire({
        id = subscription,
        type = "event",
        event = {
          variables = {
            trigger = {
              to_state = {
                entity_id = gesture,
                state = "2026-11-17T12:00:01Z",
                last_updated = time,
                attributes = data,
              },
            },
          },
        },
      }))
    end)
  end
  local double = wire(attrs)
  double.bridge_update_kind, double.event_type, double.button_id = "gesture", "press", "top"
  double.gesture_id, double.press_count, double.gesture_session_id = "press_2", 2, "initial"
  double.gesture_sequence, double.gesture_event_id, double.gesture_occurred_at = 1, "initial:1", "2026-11-17T12:00:01Z"
  Properties["Log Mode"], Properties["Log Level"] = "Print", "4 - Debug"
  OnPropertyChanged("Log Mode")
  OnPropertyChanged("Log Level")
  local logged, _, gestureOutput = T.capture(function()
    push(double, "2026-11-17T12:00:01Z")
  end)
  T.check(
    "the shared logger prints the delivered button event",
    logged and gestureOutput:find("Button event 1 delivered to Control4", 1, true)
  )
  Properties["Log Mode"] = "Off"
  OnPropertyChanged("Log Mode")
  T.eq("verified old manual event emits its native double press", Properties["Gesture Count"], "1")
  local relinked = wire(attrs)
  relinked.bridge_load.entity_id = "light.another"
  push(relinked, "2026-11-17T12:00:02Z")
  ExecuteCommand("Turn On")
  T.eq("changing the helper link cannot drive the saved target or the new one", #c.sent, 0)
  T.eq("registry-verified event still has no authority to change a physical LED", view().indicator_lease, nil)
  restart()
  local replaced = wire(entries)
  replaced[target].id = string.rep("f", 32)
  settle(c, attrs, replaced)
  ExecuteCommand("Turn On")
  T.eq("after reload a replacement registry entry blocks the working service", #c.sent, 0)
  T.eq(
    "a refused registry replacement never overwrites its pin",
    codec.decode(persist:get(saved, nil, true)).controlled_load.registry_id,
    loadRegistry
  )
  setProperty("Manual entity ID", "")
  restart()
  T.eq("explicit clear suppresses event-only recovery", selected[#selected], {})

  c = original("Programming Events Only")
  settle(c, attrs, entries)
  T.eq("programming-only recovery ignores the configured load", selected[#selected], { gesture })
  T.eq("legacy source without a physical device advertises its verified buttons", view().status, "Buttons connected")
  ExecuteCommand("Turn On")
  T.eq("manual events only cannot control the HA light", #c.sent, 0)
  local foreign = wire(entries)
  foreign[gesture].platform = "other"
  c = original("Control Connected C4 Light")
  settle(c, attrs, foreign)
  T.eq(
    "foreign-platform event registry entry never supplies physical identity",
    codec.decode(persist:get(saved, nil, true)).control_id,
    nil
  )
  T.truthy("registry rejection offers a retry without another catalog", view().retry)
  request("HA_SETUP_RETRY", { request = "retry-event" })
  T.truthy("retry starts an exact saved entity read", pickResult("retry-event").message)
  settle(c, attrs, entries)
  T.eq(
    "a registry recovery after retry restores the saved control",
    codec.decode(persist:get(saved, nil, true)).control_id,
    "saved-wall"
  )
  c = original("Programming Events Only")
  c:snapshot(gesture, "unknown", attrs)
  setProperty("Manual entity ID", "")
  c:reply("config/entity_registry/get_entries", entries)
  T.eq("a positive late registry reply cannot revive a cleared selection", selected[#selected], {})
end

T.section("migration remains idle until the user starts a review")
do
  for _, familyName in ipairs({ "light", "switch" }) do
    fixture(familyName)
    local oldRead = C4.GetDevices
    local reads = 0
    function C4:GetDevices(filter)
      if type(filter.C4iNames) == "string" and filter.C4iNames:find("HA.Switch.c4z,HA.Light.c4z", 1, true) then
        reads = reads + 1
        return {}
      end
      return oldRead(self, filter)
    end
    view("migration-idle")
    T.eq("normal device setup does not start migration inventory", reads, 0)
    request("HA_MIGRATION", { request = "explicit-review", action = "open" })
    T.eq(
      "explicit read-only review uses real template handler",
      last("HA_MIGRATION_RESULT", "explicit-review").phase,
      "choose"
    )
    T.eq("one read after explicit review", reads, 1)
    C4.GetDevices = oldRead
  end
end

T.section("New security and media drivers select, confirm feedback and keep the same route on reload")
do
  local endpoints = {
    {
      folder = "lock",
      entity = "lock.fixture",
      before = "unlocked",
      after = "locked",
      reported = "Locked",
      binding = 5001,
      command = "LOCK",
      action = "lock",
    },
    {
      folder = "alarm",
      entity = "alarm_control_panel.fixture",
      before = "disarmed",
      after = "armed_home",
      reported = "Armed home",
      attributes = { supported_features = 1 },
      binding = 5002,
      command = "PARTITION_ARM",
      params = { ArmType = "Home" },
      action = "alarm_arm_home",
    },
    {
      folder = "media-player",
      entity = "media_player.fixture",
      before = "paused",
      after = "playing",
      reported = "Playing",
      attributes = { supported_features = 16384 },
      binding = 5001,
      command = "PLAY",
      action = "media_play",
    },
  }
  for _, endpoint in ipairs(endpoints) do
    local c = fixture(endpoint.folder, function()
      Properties["Manual entity ID"] = ""
      Properties["Log Mode"] = "Off"
    end)
    local attrs = codec.object(endpoint.attributes or {})
    local function command()
      return ReceivedFromProxy(endpoint.binding, endpoint.command, endpoint.params)
    end
    T.eq(endpoint.folder .. " control waits for a configured device", command(), false)
    setProperty("Manual entity ID", endpoint.entity)
    c:completeRead(endpoint.entity, endpoint.before, attrs)
    local subscription = c:snapshot(endpoint.entity, endpoint.before, attrs)
    T.eq(
      endpoint.folder .. " saved selection is the exact confirmed endpoint",
      selected[#selected],
      { endpoint.entity }
    )
    local previous = Variables.State
    T.eq(endpoint.folder .. " native driver sends a command", command(), true)
    T.eq(
      endpoint.folder .. " Coordinator accepts the exact endpoint",
      c:reply(endpoint.action).target.entity_id,
      endpoint.entity
    )
    T.eq(endpoint.folder .. " waits for a report after service acceptance", Variables.State, previous)
    at(coordinator, function()
      c.onMessage(wire({
        id = subscription,
        type = "event",
        event = {
          variables = {
            trigger = {
              to_state = { entity_id = endpoint.entity, state = endpoint.after, attributes = attrs },
            },
          },
        },
      }))
    end)
    T.eq(endpoint.folder .. " publishes confirmed new state", Variables.State, endpoint.reported)
    restart()
    T.eq(endpoint.folder .. " reload keeps the same route", selected[#selected], { endpoint.entity })
    T.eq(endpoint.folder .. " reload clears feedback until resync", Variables.State, "Unavailable")
    T.eq(endpoint.folder .. " reload suppresses control without fresh feedback", command(), false)
    for _, message in ipairs(c.sent) do
      T.check(
        endpoint.folder .. " reload leaves only subscription maintenance",
        message.type == "subscribe_trigger" or message.type == "unsubscribe_events"
      )
    end
    if c.sent[1] and c.sent[1].type == "unsubscribe_events" then
      c:reply("unsubscribe_events")
    end
    c:snapshot(endpoint.entity, endpoint.after, attrs)
    T.eq(endpoint.folder .. " reload resync restores confirmed feedback", Variables.State, endpoint.reported)
    OnDriverDestroyed()
  end
end

T.section("Security and media diagnostics omit private Home Assistant fields")
do
  local log = require("lib.logging")
  local pin, signed = "67543108", "https://example.invalid/art?token=private-fixture"
  local alarm, player = "alarm_control_panel.fixture", "media_player.fixture"
  local function blankSelection()
    Properties["Manual entity ID"] = ""
    Properties["Log Mode"] = "Off"
  end
  local c = fixture("alarm", blankSelection)
  setProperty("Manual entity ID", alarm)
  local policy = { supported_features = 1, code_format = "number", code_arm_required = true, code = pin }
  c:completeRead(alarm, "disarmed", policy)
  c:snapshot(alarm, "disarmed", policy)
  log:allowTraceAndUltra(true)
  log:setLogMode("Print")
  log:setLogLevel("5 - Trace")
  metrics:reset()
  metrics:setEnabled(true)
  local ok, failure, output = T.capture(function()
    T.truthy(
      "the real driver sends a code entered on the native partition",
      ReceivedFromProxy(5002, "PARTITION_ARM", {
        ArmType = "Home",
        UserCode = pin,
      })
    )
    local message = assert(table.remove(c.sent, 1))
    T.eq(
      "the code is confined to the exact HA service request",
      { message.target.entity_id, message.service_data.code },
      {
        alarm,
        pin,
      }
    )
    at(coordinator, function()
      c.onMessage(wire({
        id = message.id,
        type = "result",
        success = false,
        error = { code = "not_allowed", message = "Rejected synthetic code " .. pin },
      }))
    end)
    EC.PrintDiagnostics()
    view("alarm-debug")
    advanced()
  end)
  T.check("alarm diagnostic capture completed", ok, failure)
  T.contains("Coordinator trace was active", output, "completed: rejected")
  T.contains("the installer sees a permission error", Variables["Last Command Result"], "denied access")
  T.excludes("controller logs and action diagnostics omit the code", output, pin)
  T.excludes(
    "alarm properties, variables, and Device Setup omit the code",
    codec.encode({
      Properties,
      Variables,
      pushes,
    }),
    pin
  )
  T.excludes("exported timing statistics omit the code", codec.encode(metrics:report()), pin)

  c = fixture("media-player", blankSelection)
  setProperty("Manual entity ID", player)
  local attrs = {
    supported_features = 16384,
    media_title = "Fixture title",
    media_artist = signed,
    entity_picture = signed,
    source_list = codec.array({ "Playlist", signed }),
  }
  log:setLogMode("Print")
  log:setLogLevel("5 - Trace")
  metrics:setEnabled(true)
  ok, failure, output = T.capture(function()
    c:completeRead(player, "paused", attrs)
    c:snapshot(player, "paused", attrs)
    view("player-debug")
    advanced()
    EC.PrintDiagnostics()
  end)
  T.check("media diagnostic capture completed", ok, failure)
  T.eq("public track text remains visible", Variables.MEDIA_TITLE, "Fixture title")
  T.excludes("media diagnostics omit private artwork URLs", output, "private-fixture")
  T.excludes(
    "media properties, variables, and Device Setup omit private URLs",
    codec.encode({
      Properties,
      Variables,
      pushes,
    }),
    "private-fixture"
  )
  T.excludes("exported timing statistics omit private URLs", codec.encode(metrics:report()), "private-fixture")
  metrics:setEnabled(false)
  metrics:reset()
  log:setLogMode("Off")
  log:setLogLevel("3 - Info")
  OnDriverDestroyed()
end
T.finish()
