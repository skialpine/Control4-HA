-- Installed identities are an append-only contract; AGPL-3.0.
return {
  api = 1,
  packages = {
    coordinator = { file = "HA.Coordinator.c4z", model = "HA Coordinator" },
    light = { file = "HA.Light.c4z", model = "HA Light" },
    interimLight = { file = "Control4.HA.Light.c4z", model = "Control4.HA.Light" },
    switch = { file = "Control4.HA.Switch.c4z", model = "Control4.HA.Switch" },
  },
  legacyPrototypes = {
    ["HA.Light.c4z"] = { model = "HA Light", family = "light", version = "1" },
    ["HA.Switch.c4z"] = { model = "HA Switch", family = "switch", version = "107" },
  },
  minimumOS = "3.3.0",
  coordinatorClass = "SKIALPINE_HA_SUITE_V1",
  legacyCoordinatorClass = "HA_DEVICE",
  coordinatorBinding = 1,
  lightCoordinatorBinding = 999,
  proxy = 5001,
  relay = 2,
  targetLinks = { app = 310, top = 203, bottom = 204, toggle = 205 },
  lightLinks = { top = 200, bottom = 201, toggle = 202 },
  links = { top = 300, toggle = 301, bottom = 302 },
  events = { stateOn = 1000, stateOff = 1001, unavailable = 1002 },
  lightUnavailableEvent = 1099,
  conditions = { on = 1000, off = 1001, available = 1002 },
  -- Values allocates these in this order on first install and restores their IDs.
  variables = {
    { name = "Selected Endpoint", kind = "STRING", initial = "" },
    { name = "State", kind = "STRING", initial = "Unknown" },
    { name = "Available", kind = "BOOL", initial = false },
    { name = "Last Command Result", kind = "STRING", initial = "" },
    { name = "Latency Report", kind = "STRING", initial = "" },
  },
}
