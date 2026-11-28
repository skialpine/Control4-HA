-- Verify the retained package from its normal lifecycle with a simulated Director project.
local T = require("testlib")
require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local ids = require("ha.identities")
local contract = require("ha.contract")
local persist = require("lib.persist")
local values = require("lib.values")
local drivers = (arg[0]:match("^(.*[/])") or "") .. "../drivers/"
local sensor, coordinator = 21, 10
local target = "binary_sensor.lab_entry"
local model, file = "HA Binary Sensor", "HA.Binary.Sensor.c4z"
local input, bindingClass = 999, ids.legacyCoordinatorClass
local chosen, lastMessage = {}, nil

function C4:GetDeviceID()
  return sensor
end
function C4:GetDeviceData(device, key)
  return key == "model" and (device == sensor and model or ids.packages.coordinator.model)
    or key == "name" and "Lab sensor"
end
function C4:GetDevices()
  return {
    [sensor] = { driverFileName = file },
    [coordinator] = { driverFileName = "HA.Coordinator.c4z" },
  }
end
function C4:GetVersionInfo()
  return { version = "3.4.3" }
end
function C4:GetDriverConfigInfo(key)
  return ({ minimum_os_version = ids.minimumOS, version = "20261124", config = "<config/>" })[key]
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:GetBoundProviderDevice(device, binding)
  return device == sensor and binding == input and coordinator or 0
end
function C4:GetBindingsByDevice(device)
  if device == sensor then
    return {
      bindings = {
        {
          bindingid = input,
          provider = false,
          bindingclasses = input == 999
              and { { class = ids.legacyCoordinatorClass }, { class = ids.coordinatorClass } }
            or { { class = ids.coordinatorClass } },
          boundprovider = {
            bound = { deviceid = coordinator, bindingid = 1, boundclasses = { bindingClass } },
          },
        },
        model == "HA Binary Sensor"
            and { bindingid = 1, provider = true, bindingclasses = { { class = "CONTACT_SENSOR" } } }
          or model == "HA Generic Sensor" and {
            bindingid = 500,
            provider = true,
            bindingclasses = { { class = "TEMPERATURE_VALUE" } },
          }
          or nil,
      },
    }
  end
  return {
    bindings = {
      {
        bindingid = 1,
        provider = true,
        bindingclasses = { { class = ids.legacyCoordinatorClass }, { class = ids.coordinatorClass } },
        boundconsumers = {
          { deviceid = sensor, bindingid = input, boundclasses = { bindingClass } },
        },
      },
    },
  }
end
function SendSecretToDevice(device, command, params)
  local message = codec.decode(params.PAYLOAD)
  lastMessage = message
  if message.op == "select" then
    chosen[#chosen + 1] = { device = device, command = command, entities = message.entities }
  end
end

local function deliver(message, kind, data)
  EC.HA_SUITE_V1({
    PAYLOAD = codec.encode(codec.object({
      version = ids.api,
      kind = kind,
      coordinator = coordinator,
      boot = 1,
      epoch = 1,
      session = message.session,
      selection = message.selection,
      data = codec.object(data),
    })),
  })
end

local function restart()
  OnDriverDestroyed()
  ShimPersistLand()
  OnDriverInit()
  OnDriverLateInit()
end

T.section("An exact retained package keeps its input, selected entity and legacy variable")
Properties = {
  ["Entity ID"] = target,
  ["Manual entity ID"] = "",
  ["Log Mode"] = "Off",
  ["Driver Version"] = "",
  ["Driver Status"] = "",
  ["Next step"] = "",
  ["Selected Device"] = "",
  Controls = "",
}
local _, first = C4:AddVariable("ENTITY_ID", target, "STRING")
assert(loadfile(drivers .. "binary-sensor/driver.lua"))()
OnDriverInit()
OnDriverLateInit()
T.eq("the retained native edge stays on binding 999", { contract.consumerBinding(sensor) }, { 999, coordinator })
T.eq("the upgraded variable keeps its first native ID", values:getValue("ENTITY_ID").id, first)
T.eq(
  "the old Programming variable and saved selection agree",
  { Variables.ENTITY_ID, Variables["Selected Endpoint"] },
  { target, target }
)
T.eq(
  "only the saved exact target subscribes",
  chosen[#chosen],
  { device = coordinator, command = "HA_SUITE_V1", entities = { target } }
)
T.eq("legacy packets are ignored", UIR.HA_LEGACY_WIRE(), "<legacy_wire>ignore-v1</legacy_wire>")
restart()
T.eq("reopening keeps the saved selection", chosen[#chosen].entities, { target })

T.section("Explicitly clearing a retained selection keeps it clear after reload")
Properties["Manual entity ID"] = ""
OnPropertyChanged("Manual entity ID")
T.eq("cleared selection releases the target", chosen[#chosen].entities, {})
T.eq("the legacy variable clears with it", Variables.ENTITY_ID, "")
restart()
T.eq("the old property cannot reselect after explicit clear", chosen[#chosen].entities, {})
OnDriverDestroyed()

T.section("Generic Sensor retains exact legacy Programming variables across an update and a cold restart")
ShimRestartDirector()
persist:delete("Values")
persist:delete("HA.DeviceSelection")
model, file, target = "HA Generic Sensor", "HA.Generic.Sensor.c4z", "sensor.lab_temperature"
Properties["Entity ID"], Properties["Manual entity ID"] = target, ""
Properties["Sensor Type"], Properties["Unit Fallback"], Properties["Poll Timer"] = "Temperature", "Celsius", "On"
local oldVariables = {
  { "SENSOR_STATE", "STRING", "12.5" },
  { "SENSOR_STATE_INT", "INT", "13" },
  { "SENSOR_STATE_FLOAT", "FLOAT", "12.5" },
  { "SENSOR_LAST_UPDATED", "STRING", "2026-11-21 00:00:00" },
  { "ENTITY_ID", "STRING", target },
}
local original = {}
for _, variable in ipairs(oldVariables) do
  local name, kind, previous = unpack(variable)
  local _, id = C4:AddVariable(name, previous, kind)
  original[#original + 1] = { id = id, kind = kind, previous = previous, writable = true }
end
ShimUpdateDriver()
assert(loadfile(drivers .. "sensor/driver.lua"))()
OnDriverInit()
OnDriverLateInit()
local function readVariables()
  local actual = {}
  for _, variable in ipairs(oldVariables) do
    local record = values:getValue(variable[1])
    actual[#actual + 1] = {
      id = record.id,
      kind = record.varType,
      previous = tostring(record.value),
      writable = record.writable,
    }
  end
  return actual
end
T.eq(
  "Generic Sensor uses the exact legacy Coordinator route",
  { contract.consumerBinding(sensor) },
  { 999, coordinator }
)
T.eq("old variable IDs, types, access and values are retained", readVariables(), original)
T.eq("exact saved sensor subscribes", chosen[#chosen].entities, { target })
T.eq(
  "saved overrides remain readable",
  { Properties["Sensor Type"], Properties["Unit Fallback"], Properties["Poll Timer"] },
  { "Temperature", "Celsius", "On" }
)
OnDriverDestroyed()
ShimRestartDirector()
OnDriverInit()
OnDriverLateInit()
T.eq("legacy variable IDs remain stable after a cold restart", readVariables(), original)
T.eq("the same saved sensor subscribes after a cold restart", chosen[#chosen].entities, { target })
OnDriverDestroyed()

T.section("A Fan add reserves no target before explicit selection and restores the saved target after reload")
ShimRestartDirector()
persist:delete("Values")
persist:delete("HA.DeviceSelection")
model, file, target = ids.packages.fan.model, ids.packages.fan.file, "fan.lab_ceiling"
input, bindingClass = 1, ids.coordinatorClass
Properties["Entity ID"], Properties["Manual entity ID"] = nil, ""
chosen = {}
assert(loadfile(drivers .. "fan/driver.lua"))()
OnDriverInit()
OnDriverLateInit()
T.eq("Fan uses the suite connection", { contract.consumerBinding(sensor) }, { 1, coordinator })
T.eq("the fresh Fan leaves its selection empty", Variables["Selected Endpoint"], "")
T.falsy("a native power command before feedback is refused", ReceivedFromProxy(5001, "ON"))
deliver(lastMessage, "selected", {})
Properties["Manual entity ID"] = target
OnPropertyChanged("Manual entity ID")
T.eq("manual setup verifies the exact requested fan before saving", { lastMessage.operation, lastMessage.entity_id }, {
  "verify_target",
  target,
})
T.eq("selection remains empty while verification is pending", Variables["Selected Endpoint"], "")
deliver(lastMessage, "result", {
  request_id = lastMessage.request_id,
  entity_id = target,
  operation = "verify_target",
  status = "verified",
})
T.eq("the selected Fan is persisted", Variables["Selected Endpoint"], target)
T.eq("only the requested Fan subscribes", chosen[#chosen].entities, { target })
local beforeReload = lastMessage
restart()
T.eq("the same target is offered after reload", chosen[#chosen].entities, { target })
local snapshot = { entity_id = target, state = "off", attributes = codec.object({ supported_features = 48 }) }
deliver(beforeReload, "snapshot", snapshot)
T.falsy("reload waits for a new snapshot before permitting power", ReceivedFromProxy(5001, "ON"))
deliver(lastMessage, "selected", {})
deliver(lastMessage, "readiness", {
  entity_id = target,
  transport = true,
  subscription = true,
  snapshot = false,
  available = false,
})
deliver(lastMessage, "snapshot", snapshot)
T.truthy("a command works after fresh feedback", ReceivedFromProxy(5001, "ON"))
T.eq("power is sent to the restored exact target", { lastMessage.operation, lastMessage.entity_id }, {
  "service",
  target,
})
OnDriverDestroyed()
T.finish()
