-- Drive actual suite subscriptions and reads. Only Director bindings and the
-- authenticated HA server are simulated by the legacy family tests.
local Hub = require("ha.hub")
local Legacy = require("ha.legacy-coordinator")
local newTransport = require("ha_legacy_transport")
return function()
  local conn = newTransport()
  local hub = Hub.new(conn, function() end)
  local legacy = Legacy.new(hub)
  hub.legacy = legacy
  return conn, legacy
end
