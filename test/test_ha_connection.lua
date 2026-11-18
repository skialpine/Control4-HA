-- Protocol/lifetime tests use the actual template WebSocket and virtual time.
local T = require("testlib")
local F = require("c4_fixtures")
local clock = F.virtualClock()
local captured, realPrint = {}, print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  captured[#captured + 1] = table.concat(parts, " ")
end
function C4:DebugLog(message)
  captured[#captured + 1] = tostring(message)
end
-- DriverWorks global for packing extended frame lengths, also used by the
-- upstream WebSocket tests. It is a native API, not part of the HA transport.
function tohex(s)
  return (s:gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end
local Connection = require("ha.connection")
local log = require("lib.logging")
log:setLogMode("Print and Log")
log:setLogLevel("6 - Ultra")
local token = "private-fixture-token-" .. string.rep("x", 160)
local function frame(text)
  assert(#text < 126)
  return string.char(0x81, #text) .. text
end
local function deliver(ws, text)
  ReceivedFromNetwork(ws.netBinding, ws.port, frame(text))
end
local function upgrade(ws, code, tail)
  OnConnectionStatusChanged(ws.netBinding, ws.port, "ONLINE")
  local accept = C4:Hash("SHA1", ws.key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", { return_encoding = "BASE64" })
  ReceivedFromNetwork(
    ws.netBinding,
    ws.port,
    "HTTP/1.1 "
      .. (code or "101 Switching Protocols")
      .. "\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: "
      .. accept
      .. "\r\n\r\n"
      .. (tail or "")
  )
end
local function sentText()
  local messages = {}
  for _, packet in ipairs(ShimSentFrames()) do
    local data = packet.data
    if data:byte(1) == 0x81 then
      local count, offset = bit.band(data:byte(2), 127), 3
      if count == 126 then
        count, offset = data:byte(3) * 256 + data:byte(4), 5
      end
      local mask, chars = { data:byte(offset, offset + 3) }, {}
      for i = 1, count do
        chars[i] = string.char(bit.bxor(data:byte(offset + 3 + i), mask[(i - 1) % 4 + 1]))
      end
      messages[#messages + 1] = JSON:decode(table.concat(chars))
    end
  end
  return messages
end
local function start(url, secret)
  local connection = Connection.new()
  connection:configure(url or "http://ha.test:8123", secret or token)
  clock.run(1)
  return connection, connection.socket
end
local function finish(connection)
  connection:destroy()
  clock.run(3000)
end

T.section("invalid configuration allocates no socket or authentication")
for _, url in ipairs({
  "https://user:secret@ha.test",
  "https://ha.test/?secret=bad",
  "https://ha.test/#frag",
  "https://ha.test/path",
  "https://ha.test:0",
  "https://ha.test:65536",
  "ws://ha.test",
  "https://ha.test\r\nHost: bad",
  "https://[::1]",
}) do
  local connection, ws = start(url)
  T.eq("invalid origin has no socket", ws, nil)
  T.eq("invalid origin is unconfigured", connection.state, "unconfigured")
  finish(connection)
end
T.eq("whitespace token rejected", Connection.validate("http://ha.test", "private\ntoken"), nil)
T.eq("empty token rejected", Connection.validate("http://ha.test", ""), nil)

T.section("authentication occurs only after valid upgrade and challenge")
do
  ShimResetSentFrames()
  local connection, ws = start("https://ha.test:8443")
  T.eq("TLS peer verification requested", ws.wssOptions.VERIFY_MODE, "peer")
  T.eq("no automatic network retries bypass the owner", ws.wssOptions.KEEP_CONNECTION, false)
  T.eq("no credentials before challenge", #sentText(), 0)
  upgrade(ws, nil, frame('{"type":"auth_required"}'))
  T.eq("auth frame emitted from coalesced first message", #sentText(), 1)
  T.eq("correct protocol", sentText()[1].type, "auth")
  T.eq("protected token reaches only auth payload", sentText()[1].access_token, token)
  T.eq("not ready before auth_ok", connection.state, "authenticating")
  deliver(ws, '{"type":"auth_ok"}')
  T.eq("ready after auth_ok", connection.state, "connected")
  clock.run(15000)
  T.eq("healthy authentication deadline was cancelled", connection.state, "connected")
  T.eq("no healthy state polling", #sentText(), 1)
  finish(connection)
end

T.section("rejected credentials stop retries and ignore private server errors")
do
  ShimResetSentFrames()
  local connection, ws = start()
  upgrade(ws, nil, frame('{"type":"auth_required"}'))
  deliver(ws, '{"type":"auth_invalid","message":"private-error-token"}')
  T.eq("explicit authentication failure", connection.state, "rejected")
  clock.run(120000)
  T.eq("no new socket after auth rejection", connection.socket, nil)
  T.eq("credentials sent only once", #sentText(), 1)
  connection:configure("http://ha.test:8123", "replacement-token")
  clock.run(1)
  T.check("explicit configuration retries", connection.socket ~= nil)
  finish(connection)
end

T.section("redirects neither authenticate nor change destination")
do
  ShimResetSentFrames()
  local connection, ws = start()
  upgrade(ws, "302 Found", frame('{"type":"auth_required"}'))
  T.eq("redirect never sends auth", #sentText(), 0)
  clock.run(10000)
  T.eq("redirect eventually reports failed upgrade", connection.state, "retrying")
  T.eq("old connection retired", connection.socket, nil)
  clock.run(3999)
  T.eq("waits for close and retry delay", connection.socket, nil)
  clock.run(1)
  T.eq("retry retains configured origin", connection.socket.host, "ha.test")
  T.eq("binding reused after cleanup", connection.socket.netBinding, ws.netBinding)
  finish(connection)
end

T.section("configuration changes and destruction invalidate stale callbacks")
do
  ShimResetSentFrames()
  local messages = {}
  local connection, ws = start()
  connection.onMessage = function(message)
    messages[#messages + 1] = message
  end
  upgrade(ws, nil, frame('{"type":"auth_required"}'))
  deliver(ws, '{"type":"auth_ok"}')
  deliver(ws, '{"type":"event","event":{"private":"private-state-value"}}')
  T.eq("authenticated message delivered", #messages, 1)
  local oldReceive, oldStatus = RFN[ws.netBinding], OCS[ws.netBinding]
  connection:configure("http://replacement.test:8123", "new-token")
  oldReceive(ws.netBinding, ws.port, frame('{"type":"event"}'))
  oldStatus(ws.netBinding, ws.port, "ONLINE")
  T.eq("stale message ignored", #messages, 1)
  T.eq("replacement waits for cleanup", connection.socket, nil)
  clock.run(3001)
  T.eq("replacement has correct destination", connection.socket.host, "replacement.test")
  local replacement = connection.socket
  finish(connection)
  oldReceive(ws.netBinding, ws.port, frame('{"type":"auth_required"}'))
  replacement.ProcessMessage(replacement, '{"type":"auth_required"}')
  clock.run(120000)
  T.eq("destroyed transport cannot reopen", connection.socket, nil)
  T.eq("destroyed configure refuses", connection:configure("http://ha.test", token), false)
  T.eq("stale callbacks cannot send auth", #sentText(), 1)
end

T.section("authentication deadline and bounded reconnect backoff")
do
  local connection, ws = start()
  upgrade(ws)
  clock.run(10000)
  T.eq("missing challenge times out", connection.state, "retrying")
  T.eq("first retry delay", connection.delay, 1000)
  for i = 1, 8 do
    clock.run(3000 + connection.delay)
    local current = connection.socket
    T.check("retry obtains a fresh socket", current ~= nil and current ~= ws)
    current.Offline(current)
    T.eq("retry delay is capped", connection.delay, math.min(1000 * 2 ^ i, 30000))
  end
  finish(connection)
end

T.section("raw input parse errors cannot escape to the logging dispatcher")
do
  local connection, ws = start()
  ws.ParsePacket = function()
    error("private-parser-token private-state-value")
  end
  ReceivedFromNetwork(ws.netBinding, ws.port, "private-state-value")
  T.eq("parser failure becomes a safe reconnect status", connection.state, "retrying")
  finish(connection)
end

T.section("ambiguous subscription recovery retires the old socket before retry")
do
  local connection, ws = start()
  upgrade(ws, nil, frame('{"type":"auth_required"}'))
  deliver(ws, '{"type":"auth_ok"}')
  T.truthy("active connection accepts explicit recovery", connection:recover())
  T.eq("recover immediately invalidates old transport", connection.state, "retrying")
  T.eq("recover retires the socket", connection.socket, nil)
  clock.run(3999)
  T.eq("recovery waits for close and backoff", connection.socket, nil)
  clock.run(1)
  T.check("recovery opens a different socket", connection.socket ~= nil and connection.socket ~= ws)
  finish(connection)
  T.eq("destroyed connection refuses recovery", connection:recover(), false)
end

T.section("credentials and private messages are absent at maximum logging")
local output = table.concat(captured, "\n")
T.excludes("token not logged", output, token)
T.excludes("server auth error not logged", output, "private-error-token")
T.excludes("private state not logged", output, "private-state-value")
T.excludes("parser error not logged", output, "private-parser-token")
T.eq("no swallowed timer failures", clock.errors, {})
clock.restore()
print = realPrint
T.finish()
