-- Evidence is local to one project operation and one authenticated HA session.
local codec = require("ha.codec")
local contract = require("ha.contract")
local deferred = require("deferred")
local http = require("lib.http")
local profile = require("ha.legacy-driver-profile")
local metrics = require("ha.performance").shared

local Scope = {}
Scope.__index = Scope
local LIMIT = 16 -- The migration and commissioning review limit.
local PROOF_PATH = "/api/ha_gesture_bridge/installation_proof/"

local function hex(value, length)
  return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function validProof(value, nonce)
  return codec.isObject(value)
    and value.version == 1
    and hex(value.nonce, 32)
    and (nonce == nil or value.nonce == nonce)
    and hex(value.proof, 64)
end

function Scope.new(hub)
  return setmetatable({ hub = hub }, Scope)
end

function Scope:origin()
  local connection = self.hub.connection
  return self.hub.online and connection.config and profile.canonicalOrigin(connection.config.origin) or nil
end

function Scope:relation(gateway, evidence, addresses)
  local current = self:origin()
  if not current then
    return
  end
  local legacy = profile.gatewayOrigin(gateway, addresses or profile.networkAddresses())
  if not legacy then
    return nil, legacy, current
  end
  if legacy == current then
    return "same", legacy, current
  end
  if evidence and evidence.origin == current and evidence.epoch == self.hub.epoch then
    return evidence.routes[legacy], legacy, current
  end
  return nil, legacy, current
end

function Scope:classify(devices, evidence)
  if evidence and evidence.origin then
    local addresses, relations = nil, {}
    for _, device in ipairs(devices) do
      if
        (device.legacy_gateway_profile or profile.contains(device.file)) and contract.integer(device.legacy_provider)
      then
        local gateway = device.legacy_provider
        if relations[gateway] == nil then
          addresses = addresses or profile.networkAddresses()
          relations[gateway] = self:relation(gateway, evidence, addresses) or false
        end
        local relation = relations[gateway]
        device.same_installation = relation == "same" or nil
        device.other_installation = relation == "separate" or nil
      end
    end
  end
  return devices
end

function Scope:prepare(devices, legacyGateway)
  local finished = deferred.new()
  local origin = self:origin()
  local evidence = { origin = origin, epoch = self.hub.epoch, routes = {} }
  if not origin then
    finished:resolve(evidence)
    return finished
  end
  local gateways = {}
  if contract.integer(legacyGateway) then
    gateways[legacyGateway] = true
  end
  for _, device in ipairs(devices) do
    if
      (device.legacy_gateway_profile or profile.contains(device.file)) and contract.integer(device.legacy_provider)
    then
      gateways[device.legacy_provider] = true
    end
  end
  if next(gateways) == nil then
    finished:resolve(evidence)
    return finished
  end
  local addresses, origins, seen = profile.networkAddresses(), {}, {}
  for gateway in pairs(gateways) do
    local route = profile.gatewayOrigin(gateway, addresses)
    if route and route ~= origin and not seen[route] then
      origins[#origins + 1], seen[route] = route, true
    end
  end
  if #origins == 0 then
    finished:resolve(evidence)
    return finished
  end
  evidence.requested = true
  table.sort(origins)
  local routes = {}
  for index = 1, math.min(LIMIT, #origins) do
    routes[index] = origins[index]
  end
  local function active()
    return evidence.epoch == self.hub.epoch and origin == self:origin()
  end
  local span = metrics:start("migration.installation")
  local function finish()
    metrics:finish(span, not active() and "retired" or next(evidence.routes) and "ok" or "rejected")
    finished:resolve(evidence)
  end
  -- Distinct hosts can resolve to the same reverse proxy or load balancer.
  self:proveRoutes(routes, active, function(proofs)
    evidence.routes = proofs
    finish()
  end)
  return finished
end

function Scope:proveRoutes(routes, active, done)
  local proofs = {}
  local function finish()
    done(active() and proofs or {})
  end
  self.hub:_request({ type = "ha_gesture_bridge/installation_proof" }, function(ok, challenge)
    if not (active() and ok and validProof(challenge)) then
      return finish()
    end
    local requests = {}
    local needAnchor = false
    local ca = self.hub.connection.config.ca
    for _, route in ipairs(routes) do
      local tls = route:sub(1, 8) == "https://"
      local sent, transfer = pcall(
        http.get,
        http,
        route .. PROOF_PATH .. challenge.nonce,
        { ["Cache-Control"] = "no-store" },
        {
          timeout = 5,
          connect_timeout = 5,
          maxBytes = 512,
          privateRequest = true,
          rejectRedirects = true,
          rawBody = true,
          cookies_enable = false,
          ssl_verify_host = true,
          ssl_verify_peer = true,
          ssl_cacerts = tls and ca and ca ~= "" and { ca } or nil,
        }
      )
      if sent then
        requests[#requests + 1] = transfer:next(function(response)
          local parsed, value = pcall(codec.decode, response.body)
          if active() and response.code == 200 and parsed and validProof(value, challenge.nonce) then
            if value.proof == challenge.proof then
              proofs[route] = "same"
            elseif tls then
              -- An unauthenticated HTTP mismatch cannot establish a separate owner.
              proofs[route] = "separate"
              needAnchor = true
            end
          end
          return true
        end, function()
          return true
        end)
      end
    end
    deferred.all(requests):next(function()
      if not active() or not needAnchor then
        return finish()
      end
      -- A restart between the two reads can change a proof on the same server.
      self.hub:_request(
        { type = "ha_gesture_bridge/installation_proof", nonce = challenge.nonce },
        function(read, anchor)
          if not (active() and read and validProof(anchor, challenge.nonce) and anchor.proof == challenge.proof) then
            proofs = {}
          end
          finish()
        end
      )
    end)
  end)
end

return Scope
