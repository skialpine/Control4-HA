-- Exercise the real template HTTP wrapper. Only Director I/O and the authenticated HA reply are faked.
local T = require("testlib")
local codec = require("ha.codec")
local Scope = require("ha.installation-scope")

local legacySwitch = "chowmain_homeassistant_switch.c4z"
local nonce, sameProof, otherProof = string.rep("a", 32), string.rep("b", 64), string.rep("c", 64)
local challenge = codec.object({ version = 1, nonce = nonce, proof = sameProof })
local suffix = "/api/ha_gesture_bridge/installation_proof/" .. nonce
local addresses, properties, transfers, websocket
USER_AGENT = "test"

function C4:GetNetworkConnections()
  local rows = {}
  for gateway, host in pairs(addresses) do
    rows[#rows + 1] = { deviceid = gateway, bindingid = 6000, address = host }
  end
  return { IP = rows }
end

function GetDeviceProperties(device)
  return properties[device]
end

function C4:url()
  local transfer = {}
  function transfer:SetOptions(options)
    self.options = options
    return self
  end
  function transfer:OnHeaders(callback)
    self.receiveHeaders = callback
    return self
  end
  function transfer:OnBodyChunk(callback)
    self.receiveBody = callback
    return self
  end
  function transfer:OnDone(callback)
    self.done = callback
    return self
  end
  function transfer:Get(url, headers)
    self.url, self.headers = url, headers
    transfers[#transfers + 1] = self
    return self
  end
  return transfer
end

local function fixture()
  addresses, properties, transfers, websocket = {}, {}, {}, {}
  local hub = {
    online = true,
    epoch = 4,
    connection = {
      config = {
        origin = "http://HA.Internal:8123",
        token = "coordinator-fixture-token",
        ca = "/etc/private-ha-ca.pem",
        clientTLS = { cert = "/etc/private-ha-client.crt", key = "/etc/private-ha-client.key" },
      },
    },
  }
  function hub:_request(message, callback)
    websocket[#websocket + 1] = { message = message, callback = callback }
  end
  return Scope.new(hub), hub
end

local function legacy(id, host, port, tls)
  addresses[id] = host
  properties[id] = { Port = tostring(port), ["Use SSL"] = tls and "True" or "False" }
  return { file = legacySwitch, legacy_provider = id }
end

local function prepare(scope, devices, gateway)
  local outcome = {}
  scope:prepare(devices, gateway):next(function(evidence)
    outcome.evidence = evidence
  end)
  return outcome
end

local function answer(transfer, status, body, headers)
  local response = { code = status, headers = headers or {} }
  local stopped = transfer.receiveHeaders(transfer, response)
  if not stopped and body then
    stopped = transfer.receiveBody(transfer, response, body)
  end
  transfer.done(transfer, { response }, stopped and -1 or 0)
end

local function proof(digest, version, echoedNonce)
  return codec.encode(codec.object({ version = version or 1, nonce = echoedNonce or nonce, proof = digest }))
end

T.section("The exact configured route needs neither a challenge nor an HTTP request")
do
  local scope, hub = fixture()
  local exact = legacy(10, "HA.INTERNAL", 8123, false)
  local outcome = prepare(scope, { exact }, 10)
  T.eq("no requests on an exact route", { #websocket, #transfers }, { 0, 0 })
  T.eq("the normalized exact route is same-installation evidence", scope:relation(10, outcome.evidence), "same")
  hub.online = false
  T.eq("an offline Coordinator has no route evidence", scope:relation(10, outcome.evidence), nil)
end

T.section("Distinct origins require proof even when they can share a network address")
do
  local scope = fixture()
  local outcome = prepare(scope, { legacy(11, "shared-proxy.test", 8123, false) })
  T.eq("the same port still needs installation proof", #websocket, 1)
  websocket[1].callback(false)
  T.eq("an unverifiable alias leaves ownership unresolved", scope:relation(11, outcome.evidence), nil)
end

T.section("One bounded anonymous GET per distinct route compares an authenticated challenge")
do
  local scope = fixture()
  local devices = {
    legacy(10, "HA.INTERNAL", 8123, false),
    legacy(11, "ha-alias.test", 8123, false),
    legacy(12, "HA-ALIAS.test", 8123, false),
    legacy(13, "separate.test", 8443, true),
    legacy(14, "untrusted.test", 8123, false),
    legacy(15, "missing.test", 8123, false),
    legacy(16, "redirect.test", 8443, true),
    legacy(17, "large.test", 8443, true),
    legacy(18, "wrong-version.test", 8443, true),
    legacy(19, "timeout.test", 8443, true),
    legacy(20, "stale-proof.test", 8443, true),
  }
  local outcome = prepare(scope, devices, 12)
  T.eq("one fixed authenticated WS command", { #websocket, websocket[1].message }, {
    1,
    { type = "ha_gesture_bridge/installation_proof" },
  })
  T.eq("no request is sent before receiving the challenge", #transfers, 0)
  websocket[1].callback(true, challenge)
  T.eq("duplicate and exact origins are excluded", #transfers, 9)

  local byUrl = {}
  for _, transfer in ipairs(transfers) do
    byUrl[transfer.url] = transfer
    T.eq("bounded transport options", { transfer.options.connect_timeout, transfer.options.timeout }, { 5, 5 })
    T.eq("strict TLS with cookies and client credentials disabled", {
      transfer.options.ssl_verify_host,
      transfer.options.ssl_verify_peer,
      transfer.options.cookies_enable,
      transfer.options.ssl_cert,
      transfer.options.ssl_key,
    }, { true, true, false })
    T.eq("only anonymous request headers reach the alternative route", transfer.headers, {
      ["Cache-Control"] = "no-store",
      ["User-Agent"] = "test",
    })
  end
  local plain = byUrl["http://ha-alias.test:8123" .. suffix]
  local secure = byUrl["https://separate.test:8443" .. suffix]
  T.eq("borrow only the configured TLS trust roots on HTTPS", secure.options.ssl_cacerts, { "/etc/private-ha-ca.pem" })
  T.eq("plain HTTP does not borrow TLS configuration", plain.options.ssl_cacerts, nil)
  answer(plain, 200, proof(sameProof))
  answer(secure, 200, proof(otherProof))
  answer(byUrl["http://untrusted.test:8123" .. suffix], 200, proof(otherProof))
  answer(byUrl["http://missing.test:8123" .. suffix], 404)
  answer(byUrl["https://redirect.test:8443" .. suffix], 302, proof(otherProof), { Location = secure.url })
  answer(byUrl["https://large.test:8443" .. suffix], 200, proof(otherProof) .. string.rep(" ", 512))
  answer(byUrl["https://wrong-version.test:8443" .. suffix], 200, proof(otherProof, 2))
  answer(byUrl["https://stale-proof.test:8443" .. suffix], 200, proof(otherProof, 1, string.rep("d", 32)))
  local timedOut = byUrl["https://timeout.test:8443" .. suffix]
  timedOut.done(timedOut, {}, 28, "Timed out")
  T.eq("redirects produce no additional transfer", #transfers, 9)
  T.eq("a different TLS proof requires the original authenticated challenge again", {
    #websocket,
    websocket[2].message,
    outcome.evidence,
  }, { 2, { type = "ha_gesture_bridge/installation_proof", nonce = nonce } })
  websocket[2].callback(true, challenge)
  local evidence = outcome.evidence
  T.eq("only positive proof and verified HTTPS mismatch are conclusive", evidence.routes, {
    ["http://ha-alias.test:8123"] = "same",
    ["https://separate.test:8443"] = "separate",
  })
  scope:classify(devices, evidence)
  T.eq("only the independently verified legacy owner is scoped away", {
    devices[2].other_installation,
    devices[4].other_installation,
    devices[5].other_installation,
  }, { [2] = true })
end

T.section("An invalid challenge or retired connection cannot establish evidence")
do
  local scope, hub = fixture()
  local devices = { legacy(11, "ha-alias.test", 8123, false) }
  local malformed = prepare(scope, devices)
  websocket[1].callback(true, codec.object({ version = 1, nonce = nonce .. "-bad", proof = sameProof }))
  T.eq(
    "malformed challenges resolve without touching the alternative",
    { #transfers, malformed.evidence.routes },
    { 0, {} }
  )

  local retired = prepare(scope, devices)
  hub.epoch = hub.epoch + 1
  websocket[2].callback(true, challenge)
  T.eq("a challenge from the previous session is never sent", { #transfers, retired.evidence.routes }, { 0, {} })

  local request = prepare(scope, devices)
  websocket[3].callback(true, challenge)
  hub.epoch = hub.epoch + 1
  answer(transfers[1], 200, proof(sameProof))
  T.eq("an in-flight answer from the old session cannot attest scope", request.evidence.routes, {})
  T.eq("historical evidence expires when the session changes", scope:relation(11, request.evidence), nil)
end

T.section("A Home Assistant restart cannot make an alias appear to be a different installation")
do
  local scope = fixture()
  local outcome = prepare(scope, { legacy(11, "secure-alias.test", 8443, true) })
  websocket[1].callback(true, challenge)
  answer(transfers[1], 200, proof(otherProof))
  T.eq("the mismatch waits for the authenticated connection to recheck its proof", outcome.evidence, nil)
  websocket[2].callback(true, codec.object({ version = 1, nonce = nonce, proof = otherProof }))
  T.eq("a changed proof leaves the alternative route unresolved", outcome.evidence.routes, {})
end

T.section("An unavailable HTTP transport leaves the scope unresolved")
do
  local scope = fixture()
  local url = C4.url
  C4.url = function()
    error("unavailable")
  end
  local outcome = prepare(scope, { legacy(11, "secure-alias.test", 8443, true) })
  websocket[1].callback(true, challenge)
  C4.url = url
  T.eq("a synchronous transport error completes without scope evidence", outcome.evidence.routes, {})
end

if arg[1] == "--benchmark" then
  local samples = {}
  for index = 1, 96 do
    local scope = fixture()
    local devices = { legacy(11, "other.test", 8443, true) }
    local start = os.clock()
    local outcome = prepare(scope, devices)
    websocket[1].callback(true, challenge)
    answer(transfers[1], 200, proof(otherProof))
    websocket[2].callback(true, challenge)
    local elapsed = (os.clock() - start) * 1e6
    assert(outcome.evidence.routes["https://other.test:8443"] == "separate")
    if index > 32 then
      samples[#samples + 1] = elapsed
    end
  end
  table.sort(samples)
  print(
    ("Install scope local CPU time. %d samples, median %.0f us, p95 %.0f us, range %.0f–%.0f us"):format(
      #samples,
      samples[32],
      samples[math.ceil(#samples * 0.95)],
      samples[1],
      samples[#samples]
    )
  )
end

T.finish()
