-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("binary_sensor", require("ha.binary-sensor-adapter").new)
