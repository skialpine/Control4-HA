-- Independently authored suite entry point; AGPL-3.0.
require("ha.device-driver").install("blinds", require("ha.blinds-adapter").new)
