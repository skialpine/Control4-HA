-- Independently authored suite entry point; AGPL-3.0.
local adapter = require("ha.light-adapter")
require("ha.device-driver").install("light", adapter.new)
