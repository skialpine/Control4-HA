-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("sensor", require("ha.sensor-adapter").new)
