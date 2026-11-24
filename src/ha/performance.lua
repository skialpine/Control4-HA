-- Passive, bounded local timing. No timers, payloads, IDs, network calls or
-- per-sample logs. Timing results never decide whether control is permitted.
local Metrics = {}
Metrics.__index = Metrics
local WINDOW = 64
local OPERATIONS = {}
for _, name in ipairs({
  "transport.connect",
  "transport.port_probe",
  "transport.authenticate",
  "transport.decode",
  "subscription.confirm",
  "subscription.release",
  "snapshot.http",
  "snapshot.headers",
  "snapshot.body",
  "snapshot.decode",
  "snapshot.publish",
  "snapshot.queue",
  "snapshot.ready",
  "service.round_trip",
  "request.light.on",
  "request.light.off",
  "request.light.toggle",
  "request.light.level",
  "request.light.color",
  "request.light.cct",
  "request.light.effect",
  "request.switch.on",
  "request.switch.off",
  "request.switch.toggle",
  "request.input_boolean.on",
  "request.input_boolean.off",
  "request.input_boolean.toggle",
  "service.dispatch",
  "service.switch_queue",
  "preparation.round_trip",
  "catalog.cold",
  "catalog.refresh",
  "catalog.page",
  "catalog.registry",
  "catalog.names_http",
  "catalog.native_projection",
  "consumer.decode",
  "binding.validation",
  "binding.output_read",
  "binding.reconcile",
  "consumer.dispatch",
  "consumer.handler",
  "selection.commit",
  "selection.verify",
  "commissioning.catalog_matches",
  "commissioning.preview",
  "commissioning.execute",
  "commissioning.add",
  "commissioning.bind",
  "migration.availability",
  "migration.status",
  "migration.assess",
  "migration.stage",
  "migration.dependencies",
  "migration.scene_move",
  "migration.scene_verify",
  "migration.scene_verify_all",
  "migration.scene_read",
  "migration.installation",
  "migration.preflight_state",
  "migration.preflight_registry",
  "migration.preflight_installation",
  "migration.post_cutover_registry",
  "migration.post_cutover_installation",
  "migration.cutover",
  "migration.ownership",
  "migration.ownership_read",
  "migration.selection_readback",
  "migration.feedback",
  "migration.feedback_after_selection",
  "migration.feedback_poll_interval",
  "migration.restore",
  "startup.ready",
  "recovery.ready",
  "light.on",
  "light.off",
  "light.toggle",
  "light.level",
  "light.color",
  "light.cct",
  "light.effect",
  "light.ramp",
  "light.stop",
  "light.preset",
  "light.scene",
  "light.scene_step",
  "light.group",
  "switch.on",
  "switch.off",
  "switch.toggle",
  "switch.feedback",
  "led.programming",
  "led.follow",
  "led.color",
  "led.brightness",
  "led.behavior",
  "gesture.decode",
  "gesture.validate_program",
  "gesture.properties_leds",
  "gesture.forward",
  "gesture.publish",
  "connected.on",
  "connected.off",
  "connected.toggle",
  "connected.level",
  "connected.ramp",
  "connected.color",
  "connected.stop",
  "connected.paddle",
  "connected.feedback",
  "update.check",
  "update.install",
}) do
  OPERATIONS[name] = true
end
local OUTCOMES =
  { ok = true, accepted = true, rejected = true, timeout = true, disconnected = true, retired = true, failed = true }
local LOG_MODES = { Off = true, Print = true, Log = true, ["Print and Log"] = true }
local function context()
  local properties = Properties or {}
  local mode, level = properties["Log Mode"], properties["Log Level"]
  mode = LOG_MODES[mode] and mode or "Unknown"
  level = type(level) == "string" and level:match("^([0-6]) %- ") or "Unknown"
  return mode .. "/" .. level
end
local function finite(value)
  return type(value) == "number" and value == value and value >= 0 and value < math.huge
end
function Metrics.new(options)
  options = options or {}
  local clock, name = options.clock, options.clock_name
  if not clock then
    if C4 and type(C4.GetTickCount) == "function" then
      clock = function()
        return C4:GetTickCount()
      end
      name = "C4:GetTickCount"
    else
      clock = function()
        return C4:GetTime()
      end
      name = "C4:GetTime (wall clock)"
    end
  end
  return setmetatable(
    { clock = clock, clockName = name or "injected clock", enabled = false, generation = 0, records = {}, invalid = 0 },
    Metrics
  )
end
function Metrics:setEnabled(value)
  self.enabled = value == true
end
function Metrics:reset()
  self.generation = self.generation + 1
  self.records, self.invalid = {}, 0
end
function Metrics:start(operation, parent)
  if
    not self.enabled
    or not OPERATIONS[operation]
    or parent and (parent.owner ~= self or parent.generation ~= self.generation)
  then
    return nil
  end
  local ok, stamp = pcall(self.clock)
  if not ok or not finite(stamp) then
    self.invalid = self.invalid + 1
    return nil
  end
  return { owner = self, generation = self.generation, operation = operation, stamp = stamp, context = context() }
end
function Metrics:finish(span, outcome)
  if not span or span.owner ~= self or span.done or span.generation ~= self.generation then
    return
  end
  span.done = true
  local ok, stamp = pcall(self.clock)
  local elapsed = ok and finite(stamp) and stamp - span.stamp
  if not elapsed or elapsed < 0 then
    self.invalid = self.invalid + 1
    return
  end
  local record = self.records[span.operation]
  if not record then
    record = {
      count = 0,
      total = 0,
      min = elapsed,
      max = elapsed,
      window = {},
      outcomes = {},
      logging = {},
      context_changed = 0,
    }
    self.records[span.operation] = record
  end
  record.count, record.total = record.count + 1, record.total + elapsed
  record.min, record.max = math.min(record.min, elapsed), math.max(record.max, elapsed)
  record.window[(record.count - 1) % WINDOW + 1] = elapsed
  outcome = OUTCOMES[outcome] and outcome or "failed"
  record.outcomes[outcome] = (record.outcomes[outcome] or 0) + 1
  record.logging[span.context] = (record.logging[span.context] or 0) + 1
  if span.context ~= context() then
    record.context_changed = record.context_changed + 1
  end
end
function Metrics:report()
  local report = {
    version = 1,
    enabled = self.enabled,
    clock = self.clockName,
    boundary = "local processing/round-trip intervals; not physical response",
    window_limit = WINDOW,
    excluded_clock_samples = self.invalid,
    logging_at_export = context(),
    operations = {},
  }
  for operation, record in pairs(self.records) do
    local sorted = {}
    for i, value in ipairs(record.window) do
      sorted[i] = value
    end
    table.sort(sorted)
    local contexts, outcomes, contextCount = {}, {}, 0
    for name, count in pairs(record.logging) do
      contexts[name] = count
      contextCount = contextCount + 1
    end
    for name, count in pairs(record.outcomes) do
      outcomes[name] = count
    end
    report.operations[operation] = {
      count = record.count,
      min_ms = record.min,
      max_ms = record.max,
      mean_ms = record.total / record.count,
      window_count = #sorted,
      p50_ms = sorted[math.ceil(#sorted * 0.5)],
      p95_ms = sorted[math.ceil(#sorted * 0.95)],
      outcomes = outcomes,
      logging = contexts,
      mixed_logging = contextCount > 1 or record.context_changed > 0,
      logging_changed_during_operation = record.context_changed,
    }
  end
  return report
end
return { new = Metrics.new, shared = Metrics.new() }
