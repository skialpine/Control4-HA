local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
local metrics = require("ha.performance").shared
local values = require("lib.values")
local clock = require("c4_fixtures").virtualClock()
local pending, report = {}, nil
local connection = { state = "connected" }
function connection:readState(entity)
  T.eq("only the synthetic fixture is read", entity, "light.ha_lab_binary_light")
  local work = deferred.new()
  pending[#pending + 1] = work
  return work
end
function values:update(name, raw)
  T.eq("benchmark uses existing timing report", name, "Latency Report")
  report = codec.decode(raw)
end
local owner = { online = true, connection = connection }
dofile("lab/snapshot_benchmark.lua").install(function()
  return owner
end)
local run = UIR.HA_LAB_SNAPSHOT_BURST
local params = { COUNT = "3", CONCURRENCY = "2", NONCE = string.rep("a", 32) }
T.eq("benchmark needs opt-in timing", run(params), "unavailable")
metrics:setEnabled(true)
T.eq("benchmark launches a bounded wave", run(params), "scheduled")
T.eq("only two requests start together", #pending, 2)
T.eq("running benchmark cannot be replaced", run(params), "unavailable")
clock.run(100)
pending[1]:resolve({})
T.eq("first completion dispatches the last read", #pending, 3)
pending[2]:reject({})
T.eq("results are withheld until all reads complete", report, nil)
clock.run(100)
pending[3]:resolve({})
T.eq("report correlates the completed burst without a target name", report.lab_burst, {
  nonce = params.NONCE,
  count = 3,
  concurrency = 2,
  failures = 1,
  first_ok_ms = 100,
  elapsed_ms = 200,
})
T.eq("queue records time before dispatch", report.operations["snapshot.queue"].max_ms, 100)
T.eq("ready includes dispatch wait", report.operations["snapshot.ready"].max_ms, 200)
T.finish()
