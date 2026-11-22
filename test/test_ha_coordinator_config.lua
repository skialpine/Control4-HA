local T = require("testlib")
require("values_harness")
local F = require("c4_fixtures")
local log = require("lib.logging")
local clock = F.virtualClock()
local root = (arg[0]:match("^(.*[/])") or "") .. "../"
local source = assert(io.open(root .. "drivers/coordinator/driver.xml")):read("*a")
local runtime = "3.3.0"
function C4:GetDriverConfigInfo(key)
  if key == "config" then
    return source:match("<config>(.-)</config>")
  end
  return ({ minimum_os_version = "3.3.0", model = "HA Coordinator", version = "20261117" })[key]
end
function C4:GetVersionInfo()
  return { version = runtime }
end
function C4:UpdateProperty(key, value)
  Properties[key] = value
end
Properties["HA URL"], Properties["HA Token"], Properties["CA Certificate Path"] = "", "", ""
Properties["HA Host"], Properties["HA Protocol"], Properties["HA Port"] = "", "HTTP", ""
Properties["Driver Status"], Properties["Driver Version"], Properties["Last action"] = "", "", ""
Properties.Status, Properties["HA Version"], Properties["Debug Print"] = "Disconnected", "", "Off"
Properties["Latency Diagnostics"] = "Off"
local visibility = {}
function C4:SetPropertyAttribs(name, attribs)
  visibility[name] = attribs
end
Properties["Log Level"], Properties["Log Mode"] = "6 - Ultra", "Print and Log"
local output, emit = {}, print
print = function(...)
  local args = {}
  for i = 1, select("#", ...) do
    args[i] = tostring(select(i, ...))
  end
  output[#output + 1] = table.concat(args, " ")
end
function C4:DebugLog(message)
  output[#output + 1] = tostring(message)
end
-- Director may restore the old variable before the other saved properties.
C4:AddVariable("HA URL", "saved.example:8123", "STRING")
ShimUpdateDriver()
dofile(root .. "drivers/coordinator/driver.lua")

T.section("unconfigured startup and protected web configuration")
OnDriverInit()
T.eq("init retains a valid original variable while properties are loading", Variables["HA URL"], "saved.example:8123")
OnDriverLateInit()
T.eq(
  "late init without an address does not erase the existing programming variable",
  Variables["HA URL"],
  "saved.example:8123"
)
T.eq(
  "names missing configuration",
  Properties["Driver Status"],
  "Enter the Home Assistant hostname or IP address in HA Host."
)
T.eq("first-time setup shows the split connection fields", {
  visibility["HA Host"],
  visibility["HA Protocol"],
  visibility["HA Port"],
  visibility["HA URL"],
}, { 0, 0, 0, 1 })
T.eq(
  "removed visibility switch is absent from the native manifest",
  source:find("<name>Show advanced settings</name>", 1, true),
  nil
)
for _, name in ipairs({ "Driver Version", "Debug Print", "Log Level", "Log Mode", "Latency Diagnostics" }) do
  T.eq(name .. " visible without a separate action", visibility[name], 0)
end
T.eq("empty CA path waits for HTTPS", visibility["CA Certificate Path"], 1)
T.eq("unknown Home Assistant version is hidden", visibility["HA Version"], 1)
T.eq("saved logging comes on without raw HA dumps", {
  log:isPrintEnabled(),
  log:isC4LogEnabled(),
  Properties["Log Level"],
  DEBUG_RFN,
  DEBUG_URL,
  DEBUG_WEBSOCKET,
}, { true, true, "4 - Debug", false, false, false })
clock.run(2 * ONE_HOUR)
Properties["Log Mode"] = "Print"
OnPropertyChanged("Log Mode")
T.eq("live mode changes output immediately", { log:isPrintEnabled(), log:isC4LogEnabled() }, { true, false })
Properties["Log Level"] = "2 - Warning"
OnPropertyChanged("Log Level")
T.eq("live level changes the logger immediately", log:getLogLevel(), log.LogLevel.WARN)
Properties["Log Level"] = "6 - Ultra"
OnPropertyChanged("Log Level")
T.eq("a live Ultra value is clamped before enabling network dumps", {
  log:getLogLevel(),
  DEBUG_RFN,
  DEBUG_URL,
  DEBUG_WEBSOCKET,
}, { log.LogLevel.DEBUG, false, false, false })
clock.run(ONE_HOUR)
T.eq("the latest mode change replaces the previous expiry", Properties["Log Mode"], "Print")
clock.run(2 * ONE_HOUR)
T.eq("logging expires and resets the level as in the template", {
  Properties["Log Mode"],
  Properties["Log Level"],
  log:isEnabled(),
}, { "Off", "3 - Info", false })
Properties["HA URL"] = "https://ha.test"
OnPropertyChanged("HA URL")
clock.run(250)
T.eq("HTTPS offers custom trust without a separate action", visibility["CA Certificate Path"], 0)
T.eq(
  "saved full URL remains editable and hides the split host",
  { visibility["HA URL"], visibility["HA Host"] },
  { 0, 1 }
)
Properties["HA URL"] = "http://ha.test"
OnPropertyChanged("HA URL")
clock.run(250)
T.eq("HTTP omits unused CA field", visibility["CA Certificate Path"], 1)
Properties["CA Certificate Path"] = "previous-ca.pem"
OnPropertyChanged("CA Certificate Path")
clock.run(250)
T.eq("saved CA remains available to correct after scheme change", visibility["CA Certificate Path"], 0)
Properties["CA Certificate Path"] = ""
OnPropertyChanged("CA Certificate Path")
clock.run(250)
T.eq("clearing the saved CA restores HTTP visibility", visibility["CA Certificate Path"], 1)
EC.RetrySelected()
T.eq(
  "offline retry explains recovery",
  Properties["Last action"],
  "Connect to Home Assistant, then retry linked devices."
)
T.eq("retry feedback visible", visibility["Last action"], 0)
local tab = require("lib.ui.tab-properties")
for _, property in ipairs(tab:list()) do
  T.check("web tab excludes protected token", property.name ~= "HA Token")
end
T.eq("protected property debug suppressed", OPC.suppressDebug["HA Token"], true)

T.section("property dispatcher never logs token or rejected URL")
DEBUGPRINT = true
Properties["HA Token"] = "private-coordinator-token"
Properties["HA URL"] = "https://private-url-token@ha.test"
OnPropertyChanged("HA Token")
OnPropertyChanged("HA URL")
clock.run(250)
T.check("bad origin gets actionable status", Properties["Driver Status"]:find("without credentials", 1, true) ~= nil)
local setTimer = SetTimer
SetTimer = function()
  error("private-coordinator-token")
end
OnPropertyChanged("HA Token")
SetTimer = setTimer
T.eq(
  "timer failure gets a safe status",
  Properties["Driver Status"],
  "Connection setup could not start. Reload Home Assistant Connection."
)

T.section("destruction cancels pending configuration; unsupported OS never connects")
Properties["Log Mode"] = "Log"
OnPropertyChanged("Log Mode")
T.eq("logging timer is active before destruction", log:isC4LogEnabled(), true)
Properties["HA URL"] = "http://ha.test"
OnPropertyChanged("HA URL")
OnDriverDestroyed()
local count = 0
local createNetworkConnection = C4.CreateNetworkConnection
function C4:CreateNetworkConnection()
  count = count + 1
end
clock.run(3 * ONE_HOUR)
T.eq("no allocation after destroy", count, 0)
T.eq("destruction retires the logging timer and runtime output without changing the saved mode", {
  Timer["HA.LogMode"],
  log:isEnabled(),
  Properties["Log Mode"],
}, { nil, false, "Log" })
runtime = "3.2.4"
OnDriverInit()
OnDriverLateInit()
OnPropertyChanged("HA Token")
clock.run(120000)
T.eq("no allocation on unsupported runtime", count, 0)
T.check(
  "unsupported status retained",
  Properties["Driver Status"]:find("requires at least C4 OS 3.3.0", 1, true) ~= nil
)

T.section("legacy programming events follow authenticated transport transitions")
local declared, fired = {}, {}
for item in source:gmatch("<event>(.-)</event>") do
  declared[tonumber(XMLCapture(item, "id"))] = XMLCapture(item, "name")
end
T.eq("installed programming event IDs", declared, {
  [1] = "Home Assistant Connected",
  [2] = "Home Assistant Disconnected",
})
function C4:FireEventByID(event)
  assert(declared[event])
  fired[#fired + 1] = event
end

local WebSocket = require("drivers-common-public.module.websocket")
local function openSocket(delay)
  clock.run(delay)
  local _, socket = next(WebSocket.Sockets or {})
  assert(socket)
  OnConnectionStatusChanged(socket.netBinding, socket.port, "ONLINE")
  local accept = C4:Hash("SHA1", socket.key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", { return_encoding = "BASE64" })
  ReceivedFromNetwork(
    socket.netBinding,
    socket.port,
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
      .. accept
      .. "\r\n\r\n"
  )
  return socket
end
local function receive(socket, message)
  ReceivedFromNetwork(socket.netBinding, socket.port, string.char(0x81, #message) .. message)
end
local function authenticate(socket)
  receive(socket, '{"type":"auth_required"}')
  receive(socket, '{"type":"auth_ok"}')
end

C4.CreateNetworkConnection = createNetworkConnection
runtime = "3.3.0"
OnDriverInit()
OnDriverLateInit()
local socket = openSocket(1)
receive(socket, '{"type":"auth_required"}')
T.eq("authentication challenge has no programming event", fired, {})
receive(socket, '{"type":"auth_invalid"}')
T.eq("rejected first authentication reports no transition", fired, {})
OnPropertyChanged("HA Token")
socket = openSocket(3001)
authenticate(socket)
receive(socket, '{"type":"auth_ok"}')
T.eq("one connected event after authentication", fired, { 1 })
OnConnectionStatusChanged(socket.netBinding, socket.port, "OFFLINE")
OnConnectionStatusChanged(socket.netBinding, socket.port, "OFFLINE")
T.eq("one disconnected event after actual loss", fired, { 1, 2 })

socket = openSocket(4000)
clock.run(10000)
T.eq("retry handshake failure cannot disconnect an offline load again", fired, { 1, 2 })
socket = openSocket(5000)
authenticate(socket)
T.eq("fresh authentication after retry reconnects", fired, { 1, 2, 1 })
OnPropertyChanged("HA Token")
clock.run(250)
T.eq("changing connection settings retires the live session once", fired, { 1, 2, 1, 2 })
socket = openSocket(3001)
authenticate(socket)
T.eq("settings reauthentication connects once", fired, { 1, 2, 1, 2, 1 })
OnDriverDestroyed()
clock.run(3000)
OnDriverInit()
OnDriverLateInit()
socket = openSocket(1)
T.eq("driver teardown and reload create no transition", fired, { 1, 2, 1, 2, 1 })
authenticate(socket)
T.eq("reloaded driver reports its own first authentication", fired, { 1, 2, 1, 2, 1, 1 })

T.section("an in-place upgrade uses only the original address and token")
OnDriverDestroyed()
clock.run(3000)
Properties["Home Assistant URL"] = "secure.test:8123"
Properties["Long Lived Access Token"] = ""
Properties["Use SSL"] = "Yes"
Properties["Directory Start Path"] = "Driver"
Properties["Certificate Path"] = "client.crt"
Properties["Private Key Path"] = "client.key"
Properties["CA Certificate Path"] = "local-ca.pem"
Properties["HA URL"], Properties["HA Token"] = "", ""
OnDriverInit()
OnDriverLateInit()
T.eq(
  "empty legacy token remains unconfigured",
  Properties["Driver Status"],
  "Enter your Home Assistant address in Home Assistant URL and your access token in Long Lived Access Token."
)
T.eq(
  "only original connection controls visible",
  { visibility["Home Assistant URL"], visibility["HA Token"] },
  { 0, 1 }
)
T.eq("saved TLS client settings visible", visibility["Private Key Path"], 0)
Properties["Long Lived Access Token"] = "private-bp-saved-token"
OnPropertyChanged("Long Lived Access Token")
clock.run(251)
local _, secured = next(WebSocket.Sockets or {})
T.eq("original URL and transport", { secured.host, secured.protocol }, { "secure.test", "wss" })
T.eq("certificate identity preserved", {
  secured.wssOptions.CERTIFICATE,
  secured.wssOptions.PRIVATE_KEY,
  secured.wssOptions.CACERTFILE,
  secured.wssOptions.VERIFY_MODE,
}, { "./client.crt", "./client.key", "./local-ca.pem", "peer" })
Properties["Home Assistant URL"] = "https://secure.test:8123"
OnPropertyChanged("Home Assistant URL")
clock.run(250)
T.check(
  "old address error describes host-only input",
  Properties["Driver Status"]:find("Choose HTTPS using Use SSL", 1, true) ~= nil
)
T.eq("old token suppresses debug", OPC.suppressDebug["Long Lived Access Token"], true)
Properties["HA Token"] = "separate-connection-token"
OnPropertyChanged("HA Token")
clock.run(250)
T.check(
  "ambiguous credentials require an explicit choice",
  Properties["Driver Status"]:find("Two Home Assistant connections", 1, true) ~= nil
)
T.eq(
  "both controls available to resolve the conflict",
  { visibility["Long Lived Access Token"], visibility["HA Token"] },
  { 0, 0 }
)
Properties["HA Token"], Properties["Home Assistant URL"] = "", "secure.test:8123"
EC.WS_CONNECT()
socket = openSocket(3001)
receive(socket, '{"type":"auth_required"}')
receive(socket, '{"type":"auth_ok","ha_version":"2026.11.1"}')
T.eq(
  "saved status and negotiated version",
  { Properties.Status, Properties["HA Version"] },
  { "Connected", "2026.11.1" }
)
T.section("saved Composer service programming uses the active Home Assistant session")
local codec = require("ha.codec")
local sent = {}
local send = socket.Send
socket.Send = function(_, packet)
  sent[#sent + 1] = codec.decode(packet)
end
local vars = { [1001] = 'say "hello" \\ 100%', [1002] = "70", [1003] = "[0,2,3]" }
function C4:GetVariable(device, id)
  assert(device == 42)
  return vars[id]
end
ExecuteCommand("Call Service", {
  Service = "light.turn_on",
  ["Entity ID"] = "light.example",
  Data = [[{"message":"example ${VAR1}", "level":${VAR2}, "rgb_color":${VAR3}}]],
  ["${VAR1}"] = "42,1001",
  ["${VAR2}"] = "42,1002",
  ["${VAR3}"] = "42,1003",
})
T.eq("all three selected variables retain their JSON types", sent[1].service_data, {
  message = "example " .. vars[1001],
  level = 70,
  rgb_color = { 0, 2, 3 },
})
T.eq(
  "saved service, target and operation",
  { sent[1].domain, sent[1].service, sent[1].target.entity_id, sent[1].type },
  { "light", "turn_on", "light.example", "call_service" }
)
local function serviceResult(call, success)
  receive(socket, codec.encode({ type = "result", id = call.id, success = success }))
end
serviceResult(sent[1], true)
ExecuteCommand("Call_Service", { Service = "script.evening" })
T.check(
  "blank Data is an object and target can be omitted",
  codec.isObject(sent[2].service_data) and not sent[2].target
)
T.check("calls use distinct hub request IDs", sent[1].id ~= sent[2].id)
serviceResult(sent[2], false)
T.check("Home Assistant rejection is actionable", Properties["Last action"]:find("declined", 1, true))
for _, bad in ipairs({
  { Service = "light" },
  { Service = "script.run", Data = "private-json-service-value" },
  { Service = "light.turn_on", Data = "[]" },
  { Service = "light.turn_on", ["Entity ID"] = "invalid" },
  { Service = "light.turn_on", Data = [[{"level":${VAR1}}]], ["${VAR1}"] = "invalid" },
  { Service = "light.turn_on", Data = [[{"text":"${VAR1}"}]], ["${VAR1}"] = "42,1009" },
}) do
  ExecuteCommand("Call Service", bad)
end
T.eq("invalid saved commands send nothing", #sent, 2)
T.check("missing variable gives recovery", Properties["Last action"]:find("variables", 1, true))
ExecuteCommand("Call Service", { Service = "scene.turn_on", ["Entity ID"] = "all", Data = " " })
T.eq("target all preserved", sent[3].target.entity_id, "all")
clock.run(10001)
T.check("timeout asks user to verify outcome", Properties["Last action"]:find("Check the device", 1, true))
T.section("original Device Link commands enter the Coordinator via ReceivedFromProxy")
do
  local bindings, getDevices, getData, getProvider, getProperties =
    C4.GetBindingsByDevice, C4.GetDevices, C4.GetDeviceData, C4.GetBoundProviderDevice, GetDeviceProperties
  local owner = C4:GetDeviceID()
  local function peer(id, binding)
    return { deviceid = id, bindingid = binding, boundclasses = { "HA_DEVICE" } }
  end
  function C4:GetBindingsByDevice(id)
    if id == owner then
      return { bindings = { { bindingid = 1, provider = true, boundconsumers = { peer(39, 999) } } } }
    end
    return {
      bindings = {
        {
          bindingid = 999,
          provider = false,
          bindingclasses = { { class = "HA_DEVICE" } },
          boundprovider = { bound = peer(owner, 1) },
        },
      },
    }
  end
  function C4:GetDevices()
    return { [39] = { driverFileName = "HA.Light.c4z" } }
  end
  function C4:GetDeviceData(_, tag)
    return ({ model = "HA Light", version = "106", manufacturer = "BP" })[tag]
  end
  function C4:GetBoundProviderDevice(id, binding)
    return id == 39 and binding == 999 and owner or 0
  end
  function GetDeviceProperties()
    return { ["Entity ID"] = "light.entrance", ["Debug Mode"] = "Off" }
  end
  local packet = {
    domain = "light",
    service = "turn_on",
    target = { entity_id = "light.entrance" },
    service_data = {
      brightness = 128,
    },
  }
  ReceivedFromProxy(1, "HA_CALL_SERVICE", { JSON = codec.encode(packet) })
  T.eq(
    "installed BP wire produces scoped Home Assistant service",
    { sent[4].service, sent[4].target.entity_id, sent[4].service_data.brightness },
    { "turn_on", "light.entrance", 128 }
  )
  serviceResult(sent[4], true)
  packet.target.entity_id = "light.unselected"
  ReceivedFromProxy(1, "HA_CALL_SERVICE", { JSON = codec.encode(packet) })
  T.eq("legacy path rejects an unselected target", #sent, 4)
  ReceivedFromProxy(1, "HA_GET_STATE", { entity = "light.entrance" })
  T.eq("old refresh creates an exact state subscription", sent[5].trigger.entity_id, "light.entrance")
  T.eq("legacy command arguments suppressed at the native entry", RFP.suppressDebug[1].HA_CALL_SERVICE, true)
  C4.GetBindingsByDevice, C4.GetDevices, C4.GetDeviceData, C4.GetBoundProviderDevice, GetDeviceProperties =
    bindings, getDevices, getData, getProvider, getProperties
end
socket.Send = send
T.section("installed Coordinator diagnostic actions and private debug mode")
T.eq("original address programming variable", Variables["HA URL"], "secure.test:8123")
T.eq("original address variable leaves new URL property alone", Properties["HA URL"], "")
local before = #output
ExecuteCommand("LUA_ACTION", { ACTION = "PrintDiagnostics" })
local report = table.concat(output, "\n", before + 1)
T.check(
  "diagnostic action prints working connection and subscription counts",
  report:find("active_subscriptions", 1, true)
)
T.excludes("diagnostic action excludes host", report, "secure.test")
before = #output
ExecuteCommand("LUA_ACTION", { ACTION = "PRINT_ENTITY_TABLE" })
T.check("no linked IDs is clear", table.concat(output, "\n", before + 1):find("Linked Home Assistant IDs: 0", 1, true))
Properties["Debug Print"] = "On"
OnPropertyChanged("Debug Print")
T.eq("compatibility debug does not turn on raw WebSocket logging", DEBUG_WEBSOCKET, false)
local transitions = #fired
EC.WS_DISCONNECT()
EC.WS_DISCONNECT()
clock.run(60000)
T.eq("user disconnect stays offline and fires once", { Properties.Status, #fired }, { "Disconnected", transitions + 1 })
T.eq(
  "manual disconnect reports how it stopped",
  Properties["Driver Status"],
  "Disconnected from Home Assistant. Use Connect to Home Assistant in Actions to reconnect."
)
ExecuteCommand("Call Service", { Service = "script.evening" })
T.check("offline action explains recovery", Properties["Last action"]:find("Connect to Home Assistant", 1, true))
clock.run(36000000)
T.eq("original debug option switches off after ten hours", Properties["Debug Print"], "Off")
T.section("Director 3.4.3 restores the Yes/No TLS list as boolean text")
for _, case in ipairs({ { "False", "ws", 1 }, { "TRUE", "wss", 0 }, { "nO", "ws", 1 }, { "yes", "wss", 0 } }) do
  Properties["Use SSL"] = case[1]
  OnPropertyChanged("Use SSL")
  local upstream = openSocket(3001)
  T.eq(
    "restored " .. case[1] .. " selects the right transport and certificate visibility",
    { upstream.protocol, visibility["Certificate Path"] },
    { case[2], case[3] }
  )
  T.eq("restored TLS list preserves the original host variable", Variables["HA URL"], "secure.test:8123")
  EC.WS_DISCONNECT()
  clock.run(3000)
end
Properties["Home Assistant URL"] = "different.example:8123"
Properties["Use SSL"] = "unrecognized-fixture"
OnPropertyChanged("Home Assistant URL")
clock.run(250)
T.eq(
  "valid saved host stays available independently of an unrecognized TLS choice",
  Variables["HA URL"],
  "different.example:8123"
)
T.check("unknown TLS choice cannot authorize a connection", Properties.Status == "Disconnected")
T.eq(
  "unknown TLS choice names the setting to correct",
  Properties["Driver Status"],
  "In Properties, set Use SSL to Yes for HTTPS or No for HTTP."
)
Properties["Home Assistant URL"] = ""
OnPropertyChanged("Home Assistant URL")
clock.run(250)
T.eq("clearing the previously observed address clears the programming variable", Variables["HA URL"], "")

T.section("split settings discover a port and keep manual choices")
do
  local discovery = require("ha.port-discovery")
  local search, queries = discovery.search, {}
  discovery.search = function(origin, protocol, ca, done)
    local query = { origin = origin, protocol = protocol, ca = ca, done = done }
    queries[#queries + 1] = query
    return function()
      query.cancelled = true
    end
  end
  local function property(name, value)
    Properties[name] = value
    OnPropertyChanged(name)
    clock.run(250)
  end
  Properties["Long Lived Access Token"], Properties["HA URL"], Properties["HA Token"] = "", "", ""
  property("HA Host", "fresh.test")
  T.eq("blank port triggers detection before a token is entered", queries[1].origin, "http://fresh.test")
  queries[1].done(80, 1)
  T.eq("the unique detected port is saved", Properties["HA Port"], "80")
  T.eq(
    "the installer is prompted for a token",
    Properties["Driver Status"],
    "Enter your Home Assistant access token in HA Token."
  )
  property("HA Protocol", "HTTPS")
  T.eq("changing protocol clears the detected port", Properties["HA Port"], "")
  T.eq("invalidated automatic port clears the programming address", Variables["HA URL"], "")
  T.eq("only the newly selected protocol is checked", queries[2].origin, "https://fresh.test")
  queries[2].done(nil, 2)
  T.eq("ambiguous result leaves the property blank", Properties["HA Port"], "")
  T.check(
    "ambiguous result tells the installer what to do",
    Properties["Driver Status"]:find("More than one port", 1, true)
  )
  property("HA Protocol", "HTTP")
  T.eq("only the newly selected protocol is checked", queries[3].origin, "http://fresh.test")
  property("HA Port", "8444")
  queries[3].done(443, 1)
  T.eq("late discovery cannot overwrite the installer’s port", Properties["HA Port"], "8444")
  T.eq("a manual port publishes the normal programming address", Variables["HA URL"], "fresh.test:8444")
  property("HA Host", "other.test")
  T.eq("a manual port survives a host edit", Properties["HA Port"], "8444")
  property("HA Port", "")
  queries[4].done(nil, 0)
  T.eq("no match also leaves the property blank", Properties["HA Port"], "")
  T.eq("clearing the manual port clears the programming address", Variables["HA URL"], "")
  property("HA Host", "same-port.test")
  queries[5].done(80, 1)
  property("HA Port", "80")
  property("HA Protocol", "HTTPS")
  T.eq("explicitly saving the detected port makes it a manual port", Properties["HA Port"], "80")
  T.eq("the manual port publishes the configured address", Variables["HA URL"], "same-port.test:80")
  T.eq("a manual port prevents another discovery", #queries, 5)
  property("HA Port", "65536")
  T.eq("an invalid manual port clears the programming address", Variables["HA URL"], "")
  discovery.search = search
end
local text = table.concat(output, "\n")
T.excludes("saved service data is private", text, "private-json-service-value")
T.excludes("no secret in diagnostic output", text, "private-coordinator-token")
T.excludes("no old token in diagnostic output", text, "private-bp-saved-token")
T.excludes("no private URL in diagnostic output", text, "private-url-token")
T.eq("no timer errors", clock.errors, {})
OnDriverDestroyed()
clock.restore()
print = emit
T.finish()
