local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
local http = require("lib.http")
local Connection = require("ha.connection")
local originalGet = http.get
local requests = {}
function http:get(url, headers, options)
  local promise = deferred.new()
  requests[#requests + 1] = { url = url, headers = headers, options = options, promise = promise }
  return promise
end
local function connection()
  local c = Connection.new()
  c.config = assert(Connection.validate("https://ha.test:8123", "private-snapshot-token", "/etc/ha-lab-ca.pem"))
  c.state = "connected"
  return c
end
local function read(c, entity)
  local result = {}
  c:readState(entity):next(function(state)
    result.state = state
  end, function(failure)
    result.failure = failure
  end)
  return result
end
local function answer(body)
  requests[#requests].promise:resolve({ body = body })
end

T.section("selected reads use one exact protected endpoint and preserve JSON types")
do
  local c = connection()
  local result = read(c, "light.lab")
  local request = requests[#requests]
  T.eq("one scoped path", request.url, "https://ha.test:8123/api/states/light.lab")
  T.eq("auth stays in header", request.headers, { Authorization = "Bearer private-snapshot-token" })
  T.eq(
    "raw private redirect-refusing request",
    { request.options.rawBody, request.options.privateRequest, request.options.rejectRedirects },
    { true, true, true }
  )
  T.eq(
    "TLS verification and explicit trust",
    { request.options.ssl_verify_host, request.options.ssl_verify_peer, request.options.ssl_cacerts },
    { true, true, { "/etc/ha-lab-ca.pem" } }
  )
  answer('{"entity_id":"light.lab","state":"off","attributes":{"optional":null,"modes":[],"metadata":{}}}')
  T.eq("null preserved", result.state.attributes.optional, codec.null)
  T.truthy("array preserved", codec.isArray(result.state.attributes.modes))
  T.truthy("object preserved", codec.isObject(result.state.attributes.metadata))
  T.eq("no extra read", #requests, 1)
end

T.section("legacy mutual TLS uses the same client identity on REST")
do
  local c = connection()
  c.config = assert(
    Connection.validate("https://secure.test", "token", "./ca.pem", { cert = "./client.crt", key = "./client.key" })
  )
  read(c, "light.lab")
  local options = requests[#requests].options
  T.eq(
    "REST verifies peer and hostname with saved credentials",
    { options.ssl_verify_host, options.ssl_verify_peer, options.ssl_cert, options.ssl_key, options.ssl_cabundle },
    { true, true, "./client.crt", "./client.key", "./ca.pem" }
  )
  answer('{"entity_id":"light.lab","state":"on","attributes":{}}')
end

T.section("malformed or foreign evidence cannot become a snapshot")
for _, body in ipairs({
  '{"entity_id":"light.foreign","state":"on","attributes":{}}',
  '{"entity_id":"light.lab","state":null,"attributes":{}}',
  '{"entity_id":"light.lab","state":"on","attributes":[]}',
  "[]",
  "null",
  "{invalid-private-payload",
}) do
  local result = read(connection(), "light.lab")
  answer(body)
  T.eq("invalid evidence rejected", result.failure, { kind = "invalid_state" })
  T.eq("invalid evidence not published", result.state, nil)
end

T.section("HTTP failures and retired lifetimes stay distinct")
for _, case in ipairs({
  { failure = { timedOut = true }, kind = "timeout" },
  { failure = { refused = true }, kind = "redirect_refused" },
  { failure = { code = 404, body = "private-response" }, kind = "not_found" },
  { failure = { code = 403, body = "private-response" }, kind = "permission_denied" },
}) do
  local result = read(connection(), "light.lab")
  requests[#requests].promise:reject(case.failure)
  T.eq("safe failure category", result.failure, { kind = case.kind })
end
do
  local c = connection()
  local result = read(c, "light.lab")
  c.generation = c.generation + 1
  answer('{"entity_id":"light.lab","state":"on","attributes":{}}')
  T.eq("old generation rejected", result.failure, { kind = "retired" })
  result = read(c, "light.lab")
  c:destroy()
  requests[#requests].promise:reject({ timedOut = true })
  T.eq("destroyed read is retired rather than timed out", result.failure, { kind = "retired" })
  local count = #requests
  result = read(c, "light.lab")
  T.eq("destroyed connection cannot read", #requests, count)
  T.eq("destroyed connection reports disconnected", result.failure, { kind = "disconnected" })
end

T.section("retired HTTP work has the same passive timing outcome")
do
  local metrics = require("ha.performance").shared
  metrics:reset()
  metrics:setEnabled(true)
  local c = connection()
  local result = read(c, "light.lab")
  c:destroy()
  requests[#requests].promise:reject({ timedOut = true })
  T.eq("caller sees retirement", result.failure, { kind = "retired" })
  T.eq("timing sees the same retirement", metrics:report().operations["snapshot.http"].outcomes, { retired = 1 })
  metrics:setEnabled(false)
  metrics:reset()
end

T.section("invalid identifiers never reach HTTP")
for _, entity in ipairs({ "light.lab/../../api/states", "light.lab?token=secret", "light.lab\n", "light.", "LIGHT.lab" }) do
  local count = #requests
  local result = read(connection(), entity)
  T.eq("invalid path rejected before request", #requests, count)
  T.eq("invalid entity identified", result.failure, { kind = "invalid_entity" })
end
T.section("native catalog shares private bounded HTTP policy and rejects broad/malformed responses")
do
  local originalPost, posted = http.post, nil
  function http:post(url, body, headers, options)
    posted = { url = url, body = body, headers = headers, options = options, promise = deferred.new() }
    return posted.promise
  end
  local c, result = connection(), {}
  c:readCatalog():next(function(rows)
    result.rows = rows
  end, function(failure)
    result.failure = failure.kind
  end)
  T.eq("read-only fixed template endpoint", posted.url, "https://ha.test:8123/api/template")
  T.eq("native projection is fixed shared source", posted.body.template, require("ha.native-catalog"))
  T.eq("same protected authentication", posted.headers.Authorization, "Bearer private-snapshot-token")
  T.eq(
    "bounded raw private redirect refusal",
    { posted.options.maxBytes, posted.options.rawBody, posted.options.privateRequest, posted.options.rejectRedirects },
    { 1048576, true, true, true }
  )
  posted.promise:resolve({ body = "[]" })
  T.truthy("successful empty native catalog retains array identity", codec.isArray(result.rows))
  c:readCatalog():next(nil, function(failure)
    result.failure = failure.kind
  end)
  posted.promise:resolve({ body = "{}" })
  T.eq("malformed native result fails without broad retry", result.failure, "invalid_filtered_catalog")
  c:readCatalog():next(nil, function(failure)
    result.failure = failure.kind
  end)
  posted.promise:reject({ code = 403 })
  T.eq("filtered permission failure retained", result.failure, "permission_denied")
  http.post = originalPost
end

T.section("an optional prototype catalog sensor supplies only exact device names and rooms")
do
  local c, sensor = connection(), "sensor.room_names"
  local function names(id)
    local outcome = {}
    c:readCatalogNames(id):next(function(value)
      outcome.names = value
    end, function(err)
      outcome.error = err.kind
    end)
    return outcome
  end
  local initial = #requests
  for _, invalid in ipairs({ "switch.fixture", "sensor.a/../private", "sensor.", "" }) do
    T.eq("invalid source is rejected", names(invalid).error, "invalid_entity")
  end
  T.eq("invalid sources generate no HTTP traffic", #requests, initial)
  local parsed = names(sensor)
  T.eq("only the exact sensor is requested", requests[#requests].url, "https://ha.test:8123/api/states/" .. sensor)
  local row =
    { entity_id = "switch.room", domain = "switch", friendly_name = "Lamp", area_name = "Den", extra = "private" }
  local attrs = {
    catalog_contract_version = "1.0",
    catalog_names_version = 1,
    catalog_names_revision = string.rep("a", 64),
    catalog_names_total = 1,
    catalog_names_pages = 1,
    catalog_names_page_001 = { row },
    private = "secret",
  }
  local function sensorBody()
    return codec.encode({ entity_id = sensor, state = tostring(attrs.catalog_names_total), attributes = attrs })
  end
  answer(sensorBody())
  T.eq(
    "private attributes never leave the connection",
    parsed.names,
    { ["switch.room"] = { name = "Lamp", area = "Den" } }
  )
  attrs.catalog_names_total, attrs.catalog_names_page_001 = 2, { row, row }
  parsed = names(sensor)
  answer(sensorBody())
  T.eq("duplicate identity invalidates optional names", parsed.error, "invalid_catalog")
  attrs.catalog_names_total, attrs.catalog_names_page_001 = 1, { row }
  parsed = names(sensor)
  c.generation = c.generation + 1
  answer(sensorBody())
  T.eq("retired sources cannot replace the names map", parsed.error, "retired")
end

http.get = originalGet
T.finish()
