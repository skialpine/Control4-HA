-- Independently authored suite entry point; AGPL-3.0.
local foundation = require("ha.foundation")
local Connection = require("ha.connection")
local Hub = require("ha.hub")
local Legacy = require("ha.legacy-coordinator")
local log = require("lib.logging")
local codec = require("ha.codec")
local Commissioning = require("ha.commissioning")
local commissionPage = require("ha.commission-page")
local connection
local hub
local legacy
commissionPage.install(function()
  return hub
end)
local ready = false
local resetReleaseCheck = require("ha.release-check").installActions(function()
  return ready
end)
local observedAddress = false
local APPLY_TIMER = "HA.Coordinator.Configure"
local DEBUG_TIMER_NAME = "HA.Coordinator.DebugPrint"
local CONNECTED_EVENT, DISCONNECTED_EVENT = 1, 2
local connectionStatus = {
  connecting = "Connecting to Home Assistant…",
  authenticating = "Signing in to Home Assistant…",
  connected = "Connected to Home Assistant. Open Quick Setup to add devices.",
  rejected = "Home Assistant rejected the access token. Replace HA Token in Properties.",
  retrying = "Reconnecting to Home Assistant. If this continues, check HA URL and the controller’s network connection.",
}

-- Choose one complete credential namespace. Never pair a token from one
-- configuration with the address from another.
local function legacySettings()
  return (Properties["Home Assistant URL"] or "") ~= "" or (Properties["Long Lived Access Token"] or "") ~= ""
end

local function conflictingSettings()
  return legacySettings() and ((Properties["HA URL"] or "") ~= "" or (Properties["HA Token"] or "") ~= "")
end

local function legacyTLS()
  local value = Properties["Use SSL"]
  if type(value) == "string" then
    -- Director 3.4.3 can expose the saved Yes/No list as True/False.
    local mode = value:lower()
    if mode == "yes" or mode == "true" then
      return true
    elseif mode == "no" or mode == "false" then
      return false
    end
  end
end

local function connectionSettings()
  if not legacySettings() then
    return Properties["HA URL"], Properties["HA Token"], Properties["CA Certificate Path"]
  end
  local host = Properties["Home Assistant URL"] or ""
  local tls = legacyTLS()
  local url = host ~= "" and ((tls and "https://" or "http://") .. host) or ""
  local token = Properties["Long Lived Access Token"]
  if tls == nil then
    return nil, nil
  end
  if not tls then
    return url, token
  end
  local prefix = Properties["Directory Start Path"] == "Driver" and "./" or "../../../../"
  local function path(name)
    local file = Properties[name]
    return file and file ~= "" and prefix .. file or nil
  end
  return url, token, path("CA Certificate Path"), { cert = path("Certificate Path"), key = path("Private Key Path") }
end

local function programmingAddress()
  if conflictingSettings() then
    return nil
  end
  local host = Properties["Home Assistant URL"]
  -- BP publishes host[:port]. Address ownership is independent of the TLS
  -- control and token, which may arrive later during an in-place upgrade.
  local url = host and host ~= "" and ("http://" .. host) or Properties["HA URL"]
  local authority = Connection.authority(url)
  return authority
end

local function publishConfiguredAddress()
  local address = programmingAddress()
  if address then
    foundation.publishAddress(address)
    observedAddress = true
  elseif observedAddress and (Properties["Home Assistant URL"] or "") == "" and (Properties["HA URL"] or "") == "" then
    -- An address that was present on this load has been cleared. At startup
    -- missing properties are not evidence that a saved variable was cleared.
    foundation.publishAddress("")
    observedAddress = false
  end
end

local legacyStatus = {
  connecting = "Connecting...",
  authenticating = "Waiting for Auth...",
  connected = "Connected",
  retrying = "Waiting to retry connection...",
  rejected = "Disconnected",
  disconnected = "Disconnected",
  unconfigured = "Disconnected",
}

local function updatePropertyVisibility()
  local legacy = legacySettings()
  local legacySecure = legacy and legacyTLS() == true
  local _, scheme = Connection.authority(Properties["HA URL"])
  SetPropertyVisible("Status", false)
  SetPropertyVisible("HA Version", (Properties["HA Version"] or "") ~= "")
  for _, name in ipairs({ "HA URL", "HA Token" }) do
    SetPropertyVisible(name, not legacy or conflictingSettings())
  end
  for _, name in ipairs({ "Home Assistant URL", "Long Lived Access Token", "Use SSL" }) do
    SetPropertyVisible(name, legacy)
  end
  for _, name in ipairs({ "Directory Start Path", "Certificate Path", "Private Key Path" }) do
    SetPropertyVisible(name, legacySecure)
  end
  -- A previously entered CA path is still validated in the suite configuration.
  -- Keep it accessible for correction even after a change to the address.
  SetPropertyVisible(
    "CA Certificate Path",
    legacySecure or not legacy and (scheme == "https" or (Properties["CA Certificate Path"] or "") ~= "")
  )
  for _, name in ipairs({ "Driver Version", "Debug Print", "Log Level", "Log Mode", "Latency Diagnostics" }) do
    SetPropertyVisible(name, true)
  end
end

local function apply()
  if ready and connection then
    updatePropertyVisibility()
    local ok = pcall(function()
      publishConfiguredAddress()
      if conflictingSettings() then
        connection:configure(nil, nil)
        UpdateProperty(
          "Driver Status",
          "Two Home Assistant connections are saved. Clear the address and token for the connection you no longer use."
        )
      elseif legacySettings() and (Properties["Long Lived Access Token"] or "") ~= "" and legacyTLS() == nil then
        connection:configure(nil, nil)
        UpdateProperty("Driver Status", "In Properties, set Use SSL to Yes for HTTPS or No for HTTP.")
      else
        connection:configure(connectionSettings())
      end
    end)
    if not ok then
      -- Never let the generic property dispatcher print the property value on
      -- failure. The token exists only in Composer's protected property and the
      -- active connection; it is not copied into values or diagnostics.
      connection:destroy()
      UpdateProperty("Driver Status", "Connection setup failed. Reload Home Assistant Connection.")
    end
  end
end

local function configureSoon()
  if ready then
    SetTimer(APPLY_TIMER, 250, apply)
  end
end

for _, name in ipairs({
  "HA URL",
  "HA Token",
  "CA Certificate Path",
  "Home Assistant URL",
  "Long Lived Access Token",
  "Use SSL",
  "Directory Start Path",
  "Certificate Path",
  "Private Key Path",
}) do
  OPC.suppressDebug[name] = true
  OPC[name:gsub("%W+", "_")] = function()
    -- Generic handler errors include the original value. Keep that boundary
    -- protected even when timer creation fails on Director.
    if not pcall(configureSoon) then
      UpdateProperty("Driver Status", "Connection setup could not start. Reload Home Assistant Connection.")
    end
  end
end

EC.suppressDebug.HA_SUITE_V1 = true
EC.HA_SUITE_V1 = function(params)
  if ready and hub then
    -- C4's generic error handler includes incoming parameters. Contain private
    -- state/request payloads at this boundary, including malformed JSON errors.
    pcall(function()
      local message = codec.decode(params.PAYLOAD)
      hub:receive(message)
    end)
  end
end
RFP.suppressDebug[1] = RFP.suppressDebug[1] or {}
RFP.suppressDebug[1].HA_GET_STATE = true
RFP.HA_GET_STATE = function(binding, _, params)
  if ready and legacy then
    pcall(legacy.request, legacy, binding, params)
  end
end
RFP.suppressDebug[1].HA_CALL_SERVICE = true
RFP.HA_CALL_SERVICE = function(binding, _, params)
  if ready and legacy then
    pcall(legacy.service, legacy, binding, params)
  end
end

EC.PrintDiagnostics = function()
  if ready and hub then
    print("Home Assistant connection | " .. codec.encode(hub:diagnostics()))
  end
end

EC.PRINT_ENTITY_TABLE = function()
  if ready and hub then
    local list = hub:linkedEntityIds(legacy:linkedEntities())
    print("Linked Home Assistant IDs: " .. #list)
    for _, entity in ipairs(list) do
      print(entity)
    end
  end
end

OPC.Debug_Print = function()
  CancelTimer(DEBUG_TIMER_NAME)
  if ready and Properties["Debug Print"] == "On" then
    EC.PrintDiagnostics()
    -- Keep the original ten-hour limit. Generic handler and WebSocket
    -- dumps can contain credentials or private state and remain separate.
    SetTimer(DEBUG_TIMER_NAME, 36000000, function()
      UpdateProperty("Debug Print", "Off")
    end)
  end
end

EC.suppressDebug["Call Service"] = true
EC.suppressDebug.Call_Service = true
EC.Call_Service = function(params)
  if ready and hub then
    local current = hub
    local function report(ok, problem)
      if not ok and ready and current == hub then
        UpdateProperty("Last action", problem)
        SetPropertyVisible("Last action", true)
      end
    end
    if not pcall(current.programmedService, current, params, report) then
      report(false, "Check the saved Home Assistant action and its selected variables.")
    end
  end
end
EC.WS_CONNECT = function()
  if ready then
    CancelTimer(APPLY_TIMER)
    apply()
  end
end
EC.WS_DISCONNECT = function()
  if ready and connection then
    CancelTimer(APPLY_TIMER)
    connection:disconnect()
  end
end
EC.RetrySelected = function()
  if ready and hub then
    local result
    if not hub.online then
      result = "Connect to Home Assistant, then retry linked devices."
    elseif not next(hub.entities) then
      result = "There are no linked devices to retry."
    else
      hub:retry()
      result = "Requested a connection check for linked devices. Open Device Setup on a device to see its status."
    end
    UpdateProperty("Last action", result)
    SetPropertyVisible("Last action", true)
  end
end
OBC[1] = function()
  if legacy then
    legacy:bindingChanged()
    pcall(legacy.refresh, legacy)
  end
  if hub then
    hub:prune()
    hub:announce()
  end
end

function OnDriverInit()
  ready = false
  resetReleaseCheck()
  if legacy then
    legacy:destroy()
    legacy = nil
  end
  pcall(CancelTimer, APPLY_TIMER)
  pcall(CancelTimer, DEBUG_TIMER_NAME)
  if connection then
    if hub then
      if hub.commissioning then
        hub.commissioning:destroy()
      end
      hub:destroy()
    else
      connection:destroy()
    end
    hub = nil
    connection = nil
  end
  local address = programmingAddress()
  observedAddress = address ~= nil
  if not address and type(Variables["HA URL"]) == "string" then
    address = Connection.authority("http://" .. Variables["HA URL"])
  end
  foundation.init("coordinator", address)
end

function OnDriverLateInit()
  if foundation.lateInit() then
    if legacy then
      legacy:destroy()
    end
    if connection then
      if hub then
        if hub.commissioning then
          hub.commissioning:destroy()
        end
        hub:destroy()
      else
        connection:destroy()
      end
    end
    ready = true
    UpdateProperty("Last action", "")
    SetPropertyVisible("Last action", false)
    connection = Connection.new()
    hub = Hub.new(connection, function(device, message)
      SendSecretToDevice(device, "HA_SUITE_V1", { PAYLOAD = codec.encode(message) })
    end)
    legacy = Legacy.new(hub)
    hub.legacy = legacy
    local currentHub, updateHub = hub, connection.onState
    local reportedOnline = false
    connection.onState = function(state, detail)
      local status = connectionStatus[state] or detail
      if legacySettings() then
        if status:find("Check HA URL.", 1, true) then
          status =
            "Enter the host and port in Home Assistant URL, for example homeassistant.local:8123. Choose HTTPS using Use SSL."
        else
          status = status:gsub("HA URL", "Home Assistant URL"):gsub("HA Token", "Long Lived Access Token")
        end
      end
      UpdateProperty("Driver Status", status)
      UpdateProperty("Status", legacyStatus[state] or "Disconnected")
      if state == "connected" then
        UpdateProperty("HA Version", connection.haVersion or "")
        SetPropertyVisible("HA Version", (connection.haVersion or "") ~= "")
      end
      updateHub(state, detail)
      if legacy then
        if state == "connected" then
          -- Director can publish bindings or consumer receivers after startup.
          -- Retry the boot announcement on HA connection only for missing consumers.
          currentHub:announce(true)
          pcall(legacy.refresh, legacy)
        else
          legacy:bindingChanged()
        end
      end
      if ready and hub == currentHub and Properties["Debug Print"] == "On" then
        print("Home Assistant connection | " .. state)
      end
      -- Use the Hub's state after it handles the transport transition. The
      -- load can retire or lose the socket while handling that transition.
      if ready and hub == currentHub and currentHub.online ~= reportedOnline then
        reportedOnline = currentHub.online
        local event = reportedOnline and CONNECTED_EVENT or DISCONNECTED_EVENT
        if not pcall(C4.FireEventByID, C4, event) then
          log:warn("Could not publish Home Assistant connection event %d", event)
        end
      end
    end
    hub.commissioning = Commissioning.new(hub.catalog, function(device, query)
      return hub.transfer:start(device, query)
    end)
    hub:announce()
    OPC.Debug_Print()
    apply()
  end
end

function OnDriverDestroyed()
  foundation.destroy()
  ready = false
  resetReleaseCheck()
  if legacy then
    legacy:destroy()
    legacy = nil
  end
  pcall(CancelTimer, APPLY_TIMER)
  pcall(CancelTimer, DEBUG_TIMER_NAME)
  if connection then
    if hub then
      if hub.commissioning then
        hub.commissioning:destroy()
      end
      hub:destroy()
    else
      connection:destroy()
    end
    hub = nil
    connection = nil
  end
end
