-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("climate", require("ha.climate-adapter").new)
