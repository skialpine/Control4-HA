local T = require("testlib")
local Performance = require("ha.performance")
local codec = require("ha.codec")
require("lib.utils")
local at, calls = 0, 0
local metrics = Performance.new({
  clock = function()
    calls = calls + 1
    return at
  end,
  clock_name = "fixture monotonic ms",
})
Properties = Properties or {}
Properties["Log Mode"], Properties["Log Level"] = "Off", "3 - Info"
T.section("disabled diagnostics do no clock work or dynamic operation allocation")
T.eq("disabled by default", metrics:start("service.round_trip"), nil)
T.eq("disabled path never reads clock", calls, 0)
metrics:setEnabled(true)
T.eq("private or dynamic operation names rejected", metrics:start("private-household-token"), nil)
T.eq("unknown operation does no clock work", calls, 0)
T.section("bounded distributions distinguish lifetime aggregates from recent sample window")
for i = 1, 75 do
  local span = metrics:start("service.round_trip")
  at = at + i
  metrics:finish(span, "accepted")
  metrics:finish(span, "failed")
end
local report = metrics:report()
local row = report.operations["service.round_trip"]
T.eq("one outcome per completed operation", row.count, 75)
T.eq("minimum preserves full history", row.min_ms, 1)
T.eq("maximum preserves full history", row.max_ms, 75)
T.eq("mean preserves full history", row.mean_ms, 38)
T.eq("only sixty-four recent samples retained", row.window_count, 64)
T.eq("recent median is explicitly windowed", row.p50_ms, 43)
T.eq("recent p95 retains high tail", row.p95_ms, 72)
T.eq("outcomes counted separately", row.outcomes, { accepted = 75 })
T.eq("quiet logging context recorded", row.logging, { ["Off/3"] = 75 })
T.eq("clock domain named", report.clock, "fixture monotonic ms")
row.outcomes.accepted = 0
T.eq(
  "export does not expose mutable internal counters",
  metrics:report().operations["service.round_trip"].outcomes.accepted,
  75
)
T.section("logging changes and disabling capture preserve honest existing samples")
local span = metrics:start("consumer.handler")
Properties["Log Mode"], Properties["Log Level"] = "Print", "6 - Ultra"
at = at + 20
metrics:setEnabled(false)
metrics:finish(span, "ok")
row = metrics:report().operations["consumer.handler"]
T.eq("in-flight local sample can finish after capture is disabled", row.count, 1)
T.eq("logging change is flagged", row.mixed_logging, true)
T.eq("changed context count visible", row.logging_changed_during_operation, 1)
T.eq("disabled capture retains previous aggregates", metrics:report().operations["service.round_trip"].count, 75)
T.eq("disabling prevents new samples", metrics:start("consumer.handler"), nil)
T.section("clock failures and reset cannot alter control or revive retired samples")
metrics:setEnabled(true)
span = metrics:start("consumer.handler")
at = at - 1
metrics:finish(span, "ok")
T.eq("backward clock excluded", metrics:report().excluded_clock_samples, 1)
T.eq("invalid interval not counted as a fast operation", metrics:report().operations["consumer.handler"].count, 1)
span = metrics:start("consumer.handler")
metrics:reset()
at = at + 10
metrics:finish(span, "ok")
T.eq("reset retires earlier spans", metrics:report().operations, {})
T.eq("reset preserves enabled state", metrics:report().enabled, true)
T.section("Quick Setup reports the Control4 work after fetching a catalog page")
span = metrics:start("commissioning.catalog_matches")
at = at + 18
metrics:finish(span, "ok")
row = metrics:report().operations["commissioning.catalog_matches"]
T.eq("catalog matching records its own elapsed time", row and row.p50_ms, 18)
span = metrics:start("transport.port_probe")
at = at + 25
metrics:finish(span, "ok")
row = metrics:report().operations["transport.port_probe"]
T.eq("port discovery exports elapsed time", row and row.p50_ms, 25)
local broken = Performance.new({
  clock = function()
    error("private-clock-detail")
  end,
})
broken:setEnabled(true)
local ok, _, output = T.capture(function()
  T.eq("failed clock produces no span", broken:start("light.on"), nil)
end)
T.truthy("clock exception remains contained", ok)
T.excludes("clock error body is not logged", output, "private-clock-detail")
T.excludes("report contains no unknown operation/payload", codec.encode(metrics:report()), "private-household-token")
T.finish()
