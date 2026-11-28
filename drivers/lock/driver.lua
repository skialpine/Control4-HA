-- Independently authored suite entry point.
require("ha.device-driver").install("lock", require("ha.lock-adapter").new)
