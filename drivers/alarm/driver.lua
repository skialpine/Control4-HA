-- Independently authored suite entry point.
require("ha.device-driver").install("alarm_control_panel", require("ha.alarm-adapter").new)
