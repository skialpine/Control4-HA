-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("switch", require("ha.switch-adapter").new)
