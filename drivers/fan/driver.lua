-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("fan", require("ha.fan-adapter").new)
