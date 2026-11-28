-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("garage", require("ha.garage-adapter").new)
