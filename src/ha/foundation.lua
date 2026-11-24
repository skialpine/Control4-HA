-- Independently authored suite lifecycle foundation; AGPL-3.0.
require("lib.utils")
local log = require("lib.logging")
local identities = require("ha.identities")
local bindings = require("lib.bindings")
local values = require("lib.values")
local codec = require("ha.codec")
local metrics = require("ha.performance").shared

local M = {}
local LOG_TIMER = "HA.LogMode"
local loggingActive = false
local DIAGNOSTIC_LIMIT = 25
local diagnosticLines = {}

local function applyLogMode(mode)
  CancelTimer(LOG_TIMER)
  log:setLogMode(mode)
  if not log:isEnabled() then
    diagnosticLines = {}
  else
    SetTimer(LOG_TIMER, 3 * ONE_HOUR, function()
      if loggingActive then
        UpdateProperty("Log Mode", "Off", true)
      end
    end)
  end
end

function M.canLogDiagnostic(label)
  return log:isEnabled()
    and log:getLogLevel() >= log.LogLevel.DEBUG
    and (diagnosticLines[label] or 0) < DIAGNOSTIC_LIMIT
end

function M.logDiagnostic(label, message)
  if M.canLogDiagnostic(label) then
    local count = (diagnosticLines[label] or 0) + 1
    diagnosticLines[label] = count
    local suffix = count == DIAGNOSTIC_LIMIT
        and " | Limit reached. Turn Log Mode off and back on, then set Log Level to 4 - Debug."
      or ""
    pcall(log.debug, log, "%s | %s%s", label, message, suffix)
  end
end

OPC.Log_Mode = function(mode)
  if loggingActive then
    applyLogMode(mode)
    if mode == "Off" and Properties["Log Level"] ~= nil then
      UpdateProperty("Log Level", "3 - Info", true)
    end
  end
end

OPC.Log_Level = function(level)
  if loggingActive then
    log:setLogLevel(level)
  end
end

OPC.Latency_Diagnostics = function()
  metrics:setEnabled(Properties["Latency Diagnostics"] == "On")
end
EC.PrintTiming = function()
  local report = codec.encode(metrics:report())
  values:update("Latency Report", report, "STRING")
  print("HA Timing | " .. report)
end
EC.ResetTiming = function()
  metrics:reset()
  values:update("Latency Report", "", "STRING")
end

function M.publishAddress(address)
  -- The suite also has a same-named configuration property containing the
  -- full URL. Original programming reads the host[:port] from the variable.
  values:update("HA URL", address or "", "STRING", true, nil, { property = false })
end

function M.init(family, address)
  C4:AllowExecute(true)
  loggingActive = false
  log:setLogMode("Off")
  diagnosticLines = {}
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  -- Trace describes Coordinator operations. Ultra with Print enables raw
  -- DriverWorks dumps, including HA traffic.
  log:setMaxLogLevel(family == "coordinator" and log.LogLevel.TRACE or log.LogLevel.DEBUG)
  loggingActive = true
  log:setLogLevel(Properties["Log Level"])
  applyLogMode(Properties["Log Mode"])
  metrics:reset()
  metrics:setEnabled(Properties["Latency Diagnostics"] == "On")
  bindings:restoreBindings()
  if family == "light" then
    for _, name in ipairs({
      "Entity ID",
      "Operation Mode",
      "Device Setup",
      "Mode Description",
      "Connected Light",
      "Status",
      "Selected Capabilities",
      "Button Capabilities",
      "LED Status",
    }) do
      if Properties[name] ~= nil then
        SetPropertyVisible(name, false)
      end
    end
    if Variables.ENTITY_ID ~= nil and not values:getValue("ENTITY_ID") then
      -- BP Light registered this name first. Record it before restoring the
      -- other variables so older Director versions keep allocating it first.
      values:update("ENTITY_ID", Variables.ENTITY_ID, "STRING", true)
    end
  end
  if
    family == "coordinator"
    and not values:getValue("HA URL")
    and (Variables["HA URL"] ~= nil or not next(values:getValues()))
  then
    -- The original Coordinator added this variable first. Let existing suite
    -- layouts without it restore their own slots before appending it.
    M.publishAddress(address)
  end
  values:restoreValues()
  if family == "coordinator" and (address ~= nil or not values:getValue("HA URL")) then
    M.publishAddress(address)
  end
  for _, variable in ipairs(identities.variables) do
    values:update(variable.name, variable.initial, variable.kind)
  end
end

function M.lateInit()
  if not CheckMinimumVersion("Driver Status") then
    return false
  end
  -- Director can retain removed property rows across in-place updates.
  C4:SetPropertyAttribs("Show advanced settings", 1)
  UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
  UpdateProperty("Driver Status", "Not configured")
  return true
end

function M.destroy()
  loggingActive = false
  pcall(CancelTimer, LOG_TIMER)
  log:setLogMode("Off")
end

return M
