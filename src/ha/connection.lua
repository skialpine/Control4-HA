-- HA authentication and connection lifetime over the template WebSocket helper.
-- Independently authored; AGPL-3.0.
local WebSocket = require("drivers-common-public.module.websocket")
local codec = require("ha.codec")
local contract = require("ha.contract")
local deferred = require("deferred")
local http = require("lib.http")
local log = require("lib.logging")
local metrics = require("ha.performance").shared
local nativeCatalog = require("ha.native-catalog")

local Connection = {}
Connection.__index = Connection
local serial = 0

-- This helper's URL parser supports DNS names and IPv4, not IPv6 literals.
-- Accept an origin only: redirects, embedded credentials and proxy paths must
-- never silently move authentication to another destination.
function Connection.authority(url)
  local scheme, authority
  if type(url) == "string" then
    scheme, authority = url:match("^(https?)://([^/]+)/*$")
  end
  if not scheme or authority:find("[^%w%.:%-]") then
    return nil,
      "Check HA URL. Enter an address such as http://homeassistant.local:8123 without credentials or a page path."
  end
  local host, port = authority:match("^([%w%.%-]+):(%d+)$")
  if not host then
    host = authority:match("^[%w%.%-]+$")
  end
  if not host or (port and (tonumber(port) < 1 or tonumber(port) > 65535)) then
    return nil, "Check the host and port in HA URL. For IPv6, enter the host name."
  end
  return authority, scheme
end

local function validateOrigin(url, ca, clientTLS)
  local authority, scheme = Connection.authority(url)
  if not authority then
    return nil, scheme
  end
  if ca ~= nil and (type(ca) ~= "string" or ca:find("[%c]")) then
    return nil, "Check CA Certificate Path in Properties."
  end
  if clientTLS then
    if scheme ~= "https" then
      return nil, "Check Use SSL before connecting with a client certificate."
    end
    for _, path in pairs(clientTLS) do
      if type(path) ~= "string" or path:find("[%c]") then
        return nil, "Check the certificate and key paths in Properties."
      end
    end
  end
  return {
    clientTLS = clientTLS,
    origin = scheme .. "://" .. authority,
    url = (scheme == "https" and "wss" or "ws") .. "://" .. authority .. "/api/websocket",
    ca = ca,
  }
end

function Connection.validate(url, token, ca, clientTLS)
  if type(url) ~= "string" or url == "" or type(token) ~= "string" or token == "" then
    return nil, "Enter your Home Assistant address in HA URL and your access token in HA Token."
  end
  local config, err = validateOrigin(url, ca, clientTLS)
  if not config then
    return nil, err
  end
  if token:find("[%c%s]") then
    return nil, "Paste the access token into HA Token again. Remove any spaces or line breaks."
  end
  config.token = token
  return config
end

function Connection.new(onState, onMessage)
  serial = serial + 1
  return setmetatable({
    prefix = "HA.Connection." .. serial .. ".",
    generation = 0,
    attempts = 0,
    state = "unconfigured",
    onState = onState,
    onMessage = onMessage,
  }, Connection)
end

function Connection:_state(state, detail)
  self.state = state
  if state == "connected" then
    metrics:finish(self.connectTiming, "ok")
    metrics:finish(self.authTiming, "ok")
  end
  -- Only fixed local status text goes to logs. No URLs, server error messages,
  -- payloads or credential tables reach the diagnostic boundary.
  log:info("HA transport: %s", detail)
  if self.onState then
    self.onState(state, detail)
  end
end

function Connection:_cancel()
  pcall(CancelTimer, self.prefix .. "Retry")
  pcall(CancelTimer, self.prefix .. "Handshake")
end

function Connection:_resume()
  if self.destroyed or self.socket or self.closing or not self.wantConnect then
    return
  end
  local generation = self.generation
  SetTimer(self.prefix .. "Retry", self.delay or 1, function()
    if not self.destroyed and self.generation == generation and self.wantConnect then
      self:_open()
    end
  end)
end

function Connection:_retire(onRetired)
  local ws = self.socket
  self.socket = nil
  if not ws then
    self:_resume()
    if onRetired then
      onRetired()
    end
    return
  end
  self.closing = ws
  ws:delete(function()
    if self.closing == ws then
      self.closing = nil
      self:_resume()
    end
    if onRetired then
      onRetired()
    end
  end)
end

function Connection:_stop(state, detail)
  if self.destroyed then
    return
  end
  local outcome = state == "verified" and "ok" or state == "disconnected" and "retired" or "failed"
  metrics:finish(self.connectTiming, outcome)
  metrics:finish(self.authTiming, outcome)
  self.connectTiming, self.authTiming = nil, nil
  self.generation = self.generation + 1
  self:_cancel()
  self.wantConnect = state == "retrying"
  if self.wantConnect then
    self.attempts = math.min(self.attempts + 1, 6)
    self.delay = math.min(1000 * 2 ^ (self.attempts - 1), 30000)
  end
  if self.config and self.config.probe then
    local generation = self.generation
    self:_retire(function()
      if self.generation == generation then
        self:_state(state, detail)
      end
    end)
  else
    self:_state(state, detail)
    self:_retire()
  end
end

function Connection:_fail(detail, retry)
  self:_stop(retry and not (self.config and self.config.probe) and "retrying" or "rejected", detail)
end

function Connection:_configure(config, err)
  if self.destroyed then
    return false
  end
  metrics:finish(self.connectTiming, "retired")
  metrics:finish(self.authTiming, "retired")
  self.connectTiming, self.authTiming = nil, nil
  self.generation = self.generation + 1
  self:_cancel()
  self.config = config
  self.wantConnect = config ~= nil
  self.attempts, self.delay = 0, 1
  self:_state(config and "connecting" or "unconfigured", config and "Connecting to HA" or err)
  self:_retire()
  return config ~= nil
end

function Connection:configure(url, token, ca, clientTLS)
  return self:_configure(self.validate(url, token, ca, clientTLS))
end

function Connection:probe(url, ca)
  local config, err = validateOrigin(url, ca)
  if config then
    config.probe = true
  end
  return self:_configure(config, err)
end

function Connection:disconnect()
  self:_stop("disconnected", "Disconnected from Home Assistant. Use Connect to Home Assistant in Actions to reconnect.")
end

function Connection:_open()
  if self.destroyed or self.socket or self.closing or not self.wantConnect then
    return
  end
  local config, generation = self.config, self.generation
  local cached = WebSocket.Sockets and WebSocket.Sockets[config.url]
  if cached and cached.deleteAfterClosing then
    cached:delete(function()
      if self.generation == generation then
        self:_resume()
      end
    end)
    return
  end
  self.connectTiming = metrics:start(config.probe and "transport.port_probe" or "transport.connect")
  -- Raw template traces include auth frames and private incoming state. Routine
  -- suite logging never enables those global debug switches.
  DEBUG_WEBSOCKET, DEBUG_RFN = false, false
  local options = { VERIFY_MODE = "peer", AUTO_CONNECT = false, KEEP_CONNECTION = false, MONITOR_CONNECTION = false }
  if config.ca and config.ca ~= "" then
    options.CACERTFILE = config.ca
  end
  if config.clientTLS then
    options.CERTIFICATE = config.clientTLS.cert
    options.PRIVATE_KEY = config.clientTLS.key
  end
  local ok, ws = pcall(WebSocket.new, WebSocket, config.url, nil, options)
  if not ok or not ws then
    self:_fail("Cannot open HA connection; check controller networking and available bindings", true)
    return
  end
  self.socket = ws
  local phase = "upgrade"
  local function active()
    return not self.destroyed and self.socket == ws and self.generation == generation
  end
  local function deadline(detail)
    SetTimer(self.prefix .. "Handshake", config.probe and 3500 or 10000, function()
      if active() then
        self:_fail(detail, true)
      end
    end)
  end
  ws:SetEstablishedFunction(function()
    if active() then
      if not config.probe then
        self.authTiming = metrics:start("transport.authenticate")
      end
      phase = "required"
      self:_state("authenticating", "Waiting for HA authentication challenge")
      deadline("HA authentication timed out; check the endpoint and proxy WebSocket support")
    end
  end)
  ws:SetProcessMessageFunction(function(_, raw)
    if not active() then
      return
    end
    local timing = metrics:start("transport.decode")
    local decoded, message = pcall(codec.decode, raw)
    metrics:finish(timing, decoded and "ok" or "failed")
    if not decoded or not codec.isObject(message) or type(message.type) ~= "string" then
      self:_fail("Invalid HA protocol message", true)
      return
    end
    if phase == "required" and message.type == "auth_required" then
      if config.probe then
        self:_stop("verified", "Home Assistant authentication prompt detected")
        return
      end
      phase = "auth"
      DEBUG_WEBSOCKET = false
      ws:Send(codec.encode({ type = "auth", access_token = config.token }))
      self:_state("authenticating", "Authenticating with HA")
    elseif phase == "auth" and message.type == "auth_ok" then
      phase = "ready"
      self.attempts = 0
      CancelTimer(self.prefix .. "Handshake")
      local version = message.ha_version
      self.haVersion = type(version) == "string" and #version <= 64 and version:match("^[%w%.%+%-]+$") or nil
      self:_state("connected", "HA transport authenticated")
    elseif phase == "auth" and message.type == "auth_invalid" then
      self:_fail("HA rejected the access token; replace it in the protected property", false)
    elseif phase == "ready" then
      if self.onMessage then
        self.onMessage(message)
      end
    else
      self:_fail("Unexpected HA authentication response", true)
    end
  end)
  local function offline()
    if active() then
      self:_fail("HA connection lost; reconnecting", true)
    end
  end
  ws:SetOfflineFunction(offline)
  ws:SetClosedByRemoteFunction(offline)

  -- The template dispatcher prints raw network input if a handler throws.
  -- Catch failures before that boundary and discard their private error text.
  local receive, status = RFN[ws.netBinding], OCS[ws.netBinding]
  local function guarded(callback, ...)
    if active() then
      DEBUG_WEBSOCKET, DEBUG_RFN = false, false
      if not pcall(callback, ...) then
        self:_fail("HA network handler failed; reconnecting", true)
      end
    end
  end
  RFN[ws.netBinding] = function(...)
    guarded(receive, ...)
  end
  OCS[ws.netBinding] = function(...)
    guarded(status, ...)
  end
  deadline(
    "HA WebSocket upgrade timed out; use the final URL and check DNS, TLS trust and proxy support (redirects are refused)"
  )
  if not pcall(ws.Start, ws) then
    self:_fail("Cannot start HA connection; check controller networking", true)
  end
end

function Connection:send(message)
  if self.destroyed or self.state ~= "connected" or not self.socket then
    return false
  end
  DEBUG_WEBSOCKET = false
  local ok, raw = pcall(codec.encode, message)
  if not ok then
    return false
  end
  if not pcall(self.socket.Send, self.socket, raw) then
    self:_fail("HA send failed; reconnecting", true)
    return false
  end
  return true
end

-- An expired subscription has an ambiguous server-side lifetime. Retiring the
-- socket releases all old HA subscriptions before the Hub's bounded recovery.
function Connection:recover()
  if self.destroyed or self.state ~= "connected" then
    return false
  end
  self:_fail("HA subscription confirmation timed out; reconnecting", true)
  return true
end

-- Both exact state reads and scoped discovery share the template HTTP policy.
function Connection:_privateRead(path, body, maxBytes, operation)
  local result = deferred.new()
  local timing = metrics:start(operation)
  if self.destroyed or self.state ~= "connected" or not self.config then
    metrics:finish(timing, "disconnected")
    result:reject({ kind = "disconnected" })
    return result
  end
  local generation, config = self.generation, self.config
  local options = {
    timeout = 10,
    connect_timeout = 10,
    maxBytes = maxBytes,
    privateRequest = true,
    rejectRedirects = true,
    rawBody = true,
    cookies_enable = false,
    ssl_verify_host = true,
    ssl_verify_peer = true,
  }
  if config.ca and config.ca ~= "" then
    if config.clientTLS then
      options.ssl_cabundle = config.ca
    else
      options.ssl_cacerts = { config.ca }
    end
  end
  if config.clientTLS then
    options.ssl_cert = config.clientTLS.cert
    options.ssl_key = config.clientTLS.key
  end
  local headers = { Authorization = "Bearer " .. config.token }
  local toHeaders, transferBody
  if timing and operation == "snapshot.http" then
    toHeaders = metrics:start("snapshot.headers", timing)
    options.onHeaders = function(code)
      if not self.destroyed and self.generation == generation and toHeaders then
        metrics:finish(toHeaders, code >= 200 and code < 300 and "ok" or "rejected")
        toHeaders = nil
        transferBody = metrics:start("snapshot.body", timing)
      end
    end
  end
  local function finish(outcome)
    metrics:finish(timing, outcome)
    metrics:finish(transferBody, outcome)
    toHeaders = nil
  end
  local work = body and http:post(config.origin .. path, body, headers, options)
    or http:get(config.origin .. path, headers, options)
  work:next(function(response)
    if self.destroyed or self.generation ~= generation then
      finish("retired")
      result:reject({ kind = "retired" })
    else
      finish("ok")
      result:resolve(response.body)
    end
  end, function(failure)
    local kind = (self.destroyed or self.generation ~= generation) and "retired"
      or failure.timedOut and "timeout"
      or failure.refused and "redirect_refused"
      or failure.code == 404 and "not_found"
      or (failure.code == 401 or failure.code == 403) and "permission_denied"
      or "read_failed"
    finish((kind == "retired" or kind == "timeout") and kind or "failed")
    result:reject({ kind = kind })
  end)
  return result, timing
end

function Connection:readCatalogNames(sensor)
  local names = require("ha.catalog-names")
  local result = deferred.new()
  if not names.sensor(sensor) then
    result:reject({ kind = "invalid_entity" })
    return result
  end
  self:_privateRead("/api/states/" .. sensor, nil, 2097152, "catalog.names_http"):next(function(raw)
    local ok, parsed = pcall(codec.decode, raw)
    local map = ok and names.parse(parsed, sensor)
    if map then
      result:resolve(map)
    else
      result:reject({ kind = "invalid_catalog" })
    end
  end, function(err)
    result:reject(err)
  end)
  return result
end

function Connection:readState(entity)
  local result = deferred.new()
  if type(entity) ~= "string" or not entity:match("^[a-z][a-z0-9_]*%.[a-z0-9_]+$") then
    result:reject({ kind = "invalid_entity" })
    return result
  end
  local work, httpTiming = self:_privateRead("/api/states/" .. entity, nil, 262144, "snapshot.http")
  work:next(function(raw)
    local timing = httpTiming and metrics:start("snapshot.decode", httpTiming)
    local ok, state = pcall(codec.decode, raw)
    local valid = ok and contract.state(state, entity)
    metrics:finish(timing, valid and "ok" or "rejected")
    if valid then
      result:resolve(state)
    else
      result:reject({ kind = "invalid_state" })
    end
  end, function(failure)
    result:reject(failure)
  end)
  return result
end

function Connection:readCatalog()
  local result = deferred.new()
  local total, revision, rows, ids = nil, nil, codec.array({}), nil
  local offset, generation = 0, self.generation
  local function reject()
    result:reject({ kind = "invalid_filtered_catalog" })
  end
  local function read(page)
    self
      :_privateRead(
        "/api/template",
        { template = nativeCatalog.template(page, offset) },
        262144,
        "catalog.native_projection"
      )
      :next(function(raw)
        local ok, response = pcall(codec.decode, raw)
        if not ok or generation ~= self.generation then
          return reject()
        end
        if not page then
          if
            not codec.isObject(response)
            or not codec.isArray(response.ids)
            or type(response.total) ~= "number"
            or response.total % 1 ~= 0
            or response.total < offset
            or response.total > nativeCatalog.maxCandidates
            or (response.total > nativeCatalog.indexSize and (type(response.revision) ~= "string" or #response.revision ~= 64 or not response.revision:match(
              "^[a-f0-9]+$"
            ) or (revision and revision ~= response.revision)))
            or (total and total ~= response.total)
            or #response.ids ~= math.min(nativeCatalog.indexSize, response.total - offset)
          then
            return reject()
          end
          local previous = #rows > 0 and rows[#rows].entity_id or ""
          for _, id in ipairs(response.ids) do
            if not nativeCatalog.entity(id) or id <= previous then
              return reject()
            end
            previous = id
          end
          total, revision, ids, response = response.total, response.revision, response.ids, response.rows
        end
        local size = math.min(nativeCatalog.pageSize, #ids - (#rows - offset))
        if not codec.isArray(response) or #response > size or (size > 0 and #response == 0) then
          return reject()
        end
        for _, row in ipairs(response) do
          if not contract.catalogRow(row) or row.entity_id ~= ids[#rows - offset + 1] then
            return reject()
          end
          rows[#rows + 1] = row
        end
        if #rows == total then
          result:resolve(rows)
        elseif #rows - offset == #ids then
          offset = #rows
          read()
        else
          local nextPage = codec.array({})
          local current = #rows - offset
          for index = current + 1, math.min(#ids, current + nativeCatalog.pageSize) do
            nextPage[#nextPage + 1] = ids[index]
          end
          read(nextPage)
        end
      end, function(failure)
        result:reject(failure)
      end)
  end
  read()
  return result
end

function Connection:destroy()
  if self.destroyed then
    return
  end
  metrics:finish(self.connectTiming, "retired")
  metrics:finish(self.authTiming, "retired")
  self.destroyed = true
  self.generation = self.generation + 1
  self.wantConnect, self.config = false, nil
  self:_cancel()
  self:_retire()
end

return Connection
