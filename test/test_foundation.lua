local T = require("testlib")
local H = require("values_harness")
local foundation = require("ha.foundation")
local ids = require("ha.identities")
Properties["Driver Status"] = ""
Properties["Driver Version"] = ""

local runtime = "3.2.4"
function C4:GetVersionInfo()
  return { version = runtime }
end
function C4:GetDriverConfigInfo(key)
  return ({ minimum_os_version = ids.minimumOS, model = "HA Light", version = "20261116" })[key]
end
function C4:UpdateProperty(key, value)
  Properties[key] = value
end

T.section("unsupported runtime refuses initialization with an upgrade instruction")
foundation.init("light")
T.eq("late init refused", foundation.lateInit(), false)
T.check("names required OS", Properties["Driver Status"]:find("requires at least C4 OS 3.3.0", 1, true) ~= nil)
T.check("names installed OS", Properties["Driver Status"]:find("3.2.4", 1, true) ~= nil)

T.section("minimum supported runtime initializes without claiming control readiness")
runtime = "3.3.0"
T.eq("late init accepted", foundation.lateInit(), true)
T.eq("still unconfigured", Properties["Driver Status"], "Not configured")

T.section("initial variable IDs survive reload and state is invalidated")
local before = H.visible()
T.eq("stable first variable", before["Selected Endpoint"], 1001)
T.eq("stable state variable", before.State, 1002)
T.eq("stable availability variable", before.Available, 1003)
T.eq("stable result variable", before["Last Command Result"], 1004)
local values = require("lib.values")
values:update("State", "On", "STRING")
values:update("Available", true, "BOOL")
ShimPersistLand()
ShimUpdateDriver()
foundation.init("light")
T.eq("same IDs", H.visible(), before)
T.eq("old feedback is not current feedback", Variables.State, "Unknown")
T.eq("unavailable pending fresh evidence", Variables.Available, "0")
T.eq("a suite instance keeps its existing layout", Variables.ENTITY_ID, nil)
local _, extra = C4:AddVariable("ENTITY_ID", "light.extra", "STRING")
ShimUpdateDriver()
foundation.init("light")
local after = H.visible()
T.eq("a known suite layout keeps an existing compatibility variable at its live slot", after.ENTITY_ID, extra)
after.ENTITY_ID = nil
T.eq("learning the compatibility variable does not renumber the suite", after, before)

for _, rename in ipairs({ false, true }) do
  T.section("BP Light programming variable survives an update and restart with variable rename " .. tostring(rename))
  H.wipe()
  T.unload("^lib%.persist$", "^lib%.values$", "^ha%.foundation$")
  ShimVariableRename(rename)
  C4:AddVariable("ENTITY_ID", "light.original", "STRING")
  ShimUpdateDriver()
  foundation = require("ha.foundation")
  foundation.init("light")
  T.eq("updated Light keeps the programming variable in its old slot", H.visible().ENTITY_ID, 1001)
  T.eq("existing value is preserved on update", Variables.ENTITY_ID, "light.original")
  T.eq("the original variable is still writable", C4:GetDeviceVariables(C4:GetDeviceID())["1001"].readonly, "False")
  T.eq("new suite variables start after the existing variable", H.visible()["Selected Endpoint"], 1002)
  require("lib.values"):update("Connected", true, "BOOL")
  local connectedId = H.visible().Connected
  T.truthy("the template Light has a programming slot for Connected", connectedId)
  ShimPersistLand()
  ShimRestartDirector()
  T.unload("^lib%.persist$", "^lib%.values$", "^ha%.foundation$")
  foundation = require("ha.foundation")
  foundation.init("light")
  T.eq("restarted Light keeps the programming variable in its old slot", H.visible().ENTITY_ID, 1001)
  T.eq("the existing variable's text survives a restart", Variables.ENTITY_ID, "light.original")
  T.eq("the original variable stays writable", C4:GetDeviceVariables(C4:GetDeviceID())["1001"].readonly, "False")
  T.eq("suite variables retain their slots", H.visible()["Selected Endpoint"], 1002)
  T.eq("Connected is restored at its original ID during OnDriverInit", H.visible().Connected, connectedId)
end
for _, rename in ipairs({ false, true }) do
  T.section("Coordinator variable upgrade and restart with variable rename " .. tostring(rename))
  H.wipe()
  T.unload("^lib%.persist$", "^lib%.values$", "^ha%.foundation$")
  ShimVariableRename(rename)
  Properties["HA URL"] = "https://example.test"
  C4:AddVariable("HA URL", "example.test", "STRING")
  ShimUpdateDriver()
  foundation = require("ha.foundation")
  foundation.init("coordinator", "example.test")
  T.eq("Coordinator original programming slot", H.visible()["HA URL"], 1001)
  T.eq("new suite variables follow the old Coordinator variable", H.visible()["Selected Endpoint"], 1002)
  T.eq("programming address omits scheme", Variables["HA URL"], "example.test")
  T.eq(
    "publishing the variable leaves the distinct configuration URL intact",
    Properties["HA URL"],
    "https://example.test"
  )
  T.eq("retains original programming writability", C4:GetDeviceVariables(C4:GetDeviceID())["1001"].readonly, "False")
  local beforeRestart = H.visible()
  ShimPersistLand()
  ShimRestartDirector()
  T.unload("^lib%.persist$", "^lib%.values$", "^ha%.foundation$")
  foundation = require("ha.foundation")
  foundation.init("coordinator", "example.test")
  T.eq("original and new IDs survive a restart", H.visible(), beforeRestart)
  H.wipe()
  T.unload("^lib%.persist$", "^lib%.values$", "^ha%.foundation$")
  foundation = require("ha.foundation")
  foundation.init()
  local interim = H.visible()
  ShimPersistLand()
  ShimUpdateDriver()
  foundation.init("coordinator", "example.test")
  local upgraded = H.visible()
  T.eq("an interim installation appends the variable", upgraded["HA URL"], 1006)
  upgraded["HA URL"] = nil
  T.eq("interim IDs survive", upgraded, interim)
end
T.finish()
