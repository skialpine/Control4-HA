-- Native HA families use independent catalog scopes and existing suite wiring.
local M = {}
M.order =
  { "binary_sensor", "sensor", "fan", "blinds", "garage", "climate", "lock", "alarm_control_panel", "media_player" }
local entries = {
  binary_sensor = { "Binary sensors", "binary_sensor", "BinarySensor" },
  sensor = { "Sensors", "sensor", "Sensor" },
  fan = { "Fans", "fan", "Fan", "fan" },
  blinds = { "Blinds", "cover", "Blinds", "blind" },
  garage = { "Garage doors", "cover", "GarageDoor", "blind" },
  climate = { "Thermostats", "climate", "Thermostat", "thermostatV2" },
  lock = { "Locks", "lock", "Lock", "lock" },
  alarm_control_panel = { "Alarm panels", "alarm_control_panel", "AlarmPanel", "securitypanel", "security" },
  media_player = { "Media players", "media_player", "MediaPlayer", "media_service" },
}
M.domains = {}
for _, family in ipairs(M.order) do
  local name, domain, suffix, proxy, extraProxy = unpack(entries[family])
  local model = "Control4.HA." .. suffix
  M[family] = {
    name = name,
    domain = domain,
    model = model,
    file = model .. ".c4z",
    proxies = { ["5001"] = proxy, ["5002"] = extraProxy },
  }
  M.domains[domain] = true
end
M.binary_sensor.file = "HA.Binary.Sensor.c4z"
M.binary_sensor.model = "HA Binary Sensor"
M.binary_sensor.retainsLegacyInput = true
M.binary_sensor.predecessorVersion = 102
M.sensor.file = "HA.Generic.Sensor.c4z"
M.sensor.model = "HA Generic Sensor"
M.sensor.retainsLegacyInput = true
M.sensor.predecessorVersion = 110
function M.eligible(family, domain, attributes)
  local definition = entries[family]
  if not definition or definition[2] ~= domain then
    return false
  end
  if domain == "cover" then
    local class = attributes.device_class
    local door = class == "garage"
    return (family == "garage") == door
  end
  return true
end
return M
