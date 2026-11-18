# Latency measurement and qualification

Every common operation needs an instrumented boundary and repeated evidence
before the feedback handoff. A missing sample means unmeasured, not zero
latency. The operation matrix below is a release obligation alongside functional
tests; reserved metric names alone do not establish coverage.

## Prior work across all three repositories

The Light prototype is `light/` inside Control4-HA-Switch. Its history includes
quiet sampling/routing (`427f3f3`), passive phase timing (`97c179d`), the shared
codec upgrade (`4b5fb10`), measured JSON results (`75bd021`), and avoiding
repeated property publications (`cb9295f`, qualified with `7f75c95`). The
Coordinator's paired work includes entity hints (`c39f6da`), single projected
reads (`c9c5c58`), shared revision checks (`0b1d9e1`), codec work (`671e493`)
and the Unicode correction (`9102878`). HA Gesture Bridge adds bounded
acknowledgments (`16ec8b2`), receiver-neutral version 2 (`b617159`) and
quiet-sampling guidance (`c4f1648`).

Retain the useful boundaries from those commits: decode/routing,
validation/native programming, property/LED work, linked-target forwarding
including synchronous feedback, and final publication/status. HA's own monotonic
publish-to-acknowledgment measurement is a separate round trip. It includes
outbound delivery, C4 work and return handling; subtracting processing does not
isolate pure network time, and dividing the remainder by two does not prove
one-way latency. Physical gesture classification and visible output are outside
both measurements unless independently instrumented.

The suite retains targeted deliveries rather than broad state broadcasts. Its
existing template `UpdateProperty` helper already skips unchanged text; use it
instead of adding a second display cache, while preserving forced native
synchronization. The single existing Finite Labs/Friedl JSON codec now also
retains the prototype's bounded ASCII spans and permissive four-byte escape fix.
No parallel parser was added. Strict UTF-8/escape/tail and typed-container tests
qualify that adaptation.

## Passive runtime collector

`src/ha/performance.lua` is shared by all drivers. **Latency Diagnostics** is
Off by default and independent of Log Mode/Level. Enabling it collects local
spans without per-sample logs, timers, HTTP/HA acknowledgment traffic or control
ordering changes. Disabled spans do not read the clock. Only fixed operation
names and outcome enums are accepted; payloads, targets and household IDs are
never retained.

**Print timing summary to Lua** updates the **Latency Report** variable and
prints one `HA Timing |` JSON line. **Reset Timing Samples** clears statistics
and retires old spans without canceling actual commands. Turning collection Off
preserves completed statistics; already-started local spans may finish.
Statistics reset on driver initialization and are not persisted per event.

Each observed operation reports lifetime count/mean/min/max and outcomes, plus
p50/p95 over the most recent 64 samples. Window count and logging contexts are
explicit. Mixed logging or a logging change during a span is flagged; reset and
repeat with stable settings for comparisons. Backward/invalid clock samples are
excluded and counted. Long/high-tail valid intervals remain visible.

Prefer `C4:GetTickCount` when supplied by the controller; otherwise report the
`C4:GetTime` wall-clock fallback explicitly. Cross-host UTC values are for
correlation, never for deciding whether a gesture or command is valid. Clock
resolution can produce a local zero-duration sample; it does not prove zero
latency. In the Director shim, local clock values test
instrumentation/correlation only and are not native CPU or wall-clock
performance evidence.

## Common operation matrix

| Operation                                        | Required boundaries                                                                                                                 | Current qualification / remaining gate                                                                 |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Binary Light/Switch On, Off, Toggle              | Request dispatch → HA result, separately → matching confirmed state; app/proxy processing separately                                | Repeated built-package/real-HA transport samples; native family UI/control pending                     |
| Dimmer level while off/on                        | Request → result and exact brightness feedback; native slider/report cost separately                                                | Repeated real-HA 64/192 level scenarios; actual Light adapter pending                                  |
| RGB/xy/CCT and transitions                       | Conversion/validation, service result, confirmed color/temperature/level; requested transition duration distinguished from overhead | Request categories registered; feature/scenario qualification pending task 5.2                         |
| Hold, ramp, release/stop                         | Input → first command, cadence/jitter, release → last future command; canceled/overridden outcome                                   | Template engine correctness proven; timing in actual adapter pending tasks 5.3–5.4                     |
| Presets, scenes and groups                       | Native dispatch/program execution, target feedback; simultaneous group/scene work and forced synchronization                        | Pending native adapter qualification                                                                   |
| Connected-C4 On/level and paddle target          | Logical On/explicit level dispatch → target call/feedback; synchronous callback work separated                                      | Pending tasks 6.1–6.2; include ordinary target and group                                               |
| Single/multi-press, hold/release, extra buttons  | Decode, validation/programming, property/LED, forwarding and publication phases; HA-clock version-2 acknowledgment separately       | Existing companion protocol reused; new receiver wiring pending task 6.3                               |
| LED color/brightness/behavior                    | Validation/dispatch → result and actual indicator feedback, while preserving behavior                                               | Pending task 6.4; include restricted palette and unavailable/rejected controls                         |
| Cold picker, warm reopen, revision check, paging | User request → usable options; companion request, scoped metadata, projection and page costs separately                             | Runtime catalog spans wired; repeated UI wall-clock evidence required with task 4.3                    |
| Selection commit and preparation                 | Choice → validated selection/confirmed state; preparation progress, result and input readiness separately                           | Preparation round-trip hook wired; setup UI and first-use/reuse scenarios pending task 4.4             |
| Startup and reconnect                            | Initialization → authenticated connection → fresh selected evidence; backoff, read/subscription costs distinct                      | Connect/auth/subscription/read hooks wired; native/physical and repeated recovery measurements pending |
| Release check/install                            | Check/download/verification/reload → usable restored state, interruption and rollback separately                                    | Pending update implementation and qualification                                                        |

Exercise both normal and failure paths: rejection, timeout, unavailable target,
retired selection and recovery. A diagnostic failure cannot suppress a command,
keep a hold alive or authorize stale input. HA acknowledgment remains disabled
normally; only fresh accepted gestures advertising exact acknowledgment version
2 may participate. Snapshots, duplicates and rejected events are not gesture
latency samples. HA Gesture Bridge keeps its own bounded, anonymous export;
there is no new HA latency protocol to maintain here.

## Repeatable lab and CPU commands

```sh
# Quiet external baseline: runtime instrumentation remains Off.
.venv/bin/python lab/verify_transport.py --timings --samples 10

# Separate run with local phase collection enabled; retain a separate report.
.venv/bin/python lab/verify_transport.py --timings --runtime-profile --samples 10 --output .cache/profiled-transport.json

# Read-only native setup and candidate verification against the same HA lab.
.venv/bin/python lab/verify_transport.py --native-setup --timings --runtime-profile --samples 10 --output .cache/native-setup.json

# Offline codec CPU comparison, using the reviewed pinned template baseline.
.venv/bin/python lab/benchmark_codec.py
```

The transport runner repeats each currently implemented fixture scenario, keeps
HA acceptance separate from matching pushed state, and records per-operation
count/min/median/p95/max/mean using Python's monotonic clock. Raw samples retain
fixture role and parameter class. Record exact package/HA versions, logging and
runtime-profiling settings. Each report describes its IPC/package/shim/HA
boundary; do not compare it directly to native C4 or physical measurements.
Setup/reconnect observations separately list harness HTTP identity checks and
state forwarding. These safety/forwarding calls serialize in Python and are not
the native Director HTTP scheduler. Native setup reports candidate verification
separately for a working fixture and a missing fixture. Each sample measures an
exact state read through the packaged Coordinator while the existing selection
stays active. Reconnect also includes the template's three-second
socket-retirement barrier and the configured retry backoff; neither is wire
transit time. Do not subtract shim-local zero-duration spans from these
wall-clock intervals to infer a network delay.

Native qualification must use the exact packages and representative controls,
including concurrent consumers and idle counters. Keep outliers and distinguish
cold/warm paths; never claim an improvement from one overlapping small run.

`lab/codec-benchmark.json` records three alternating before/after CPU rounds of
2,000 decodes per workload, with source hashes and runtime version. Its
synthetic service result, gesture metadata and catalog page contain no household
data. These workstation CPU numbers justify the narrow string-span change but do
not replace native Director or physical latency measurements.

### Scene dispatch CPU benchmark

Run `HA_SCENE_BENCHMARK=1 test/run_test.sh test_ha_light_adapter.lua` to repeat
64 pushes, activations and deactivations with a delayed brightness step in the
Lua Director shim. One arm64 LuaJIT 2.1.1794214635 run used `os.clock` for
process CPU in milliseconds, virtual scene timers, and Log Mode Off at level 0.
Collection was enabled with no excluded clock samples. The most recent 64
samples determine each percentile.

| Boundary                        | Samples | Min (ms) | p50 (ms) | p95 (ms) | Max (ms) | Mean (ms) |
| ------------------------------- | ------: | -------: | -------: | -------: | -------: | --------: |
| Native scene command dispatch   |     192 |    0.022 |    0.133 |    1.276 |    1.760 |     0.456 |
| Deferred scene callback         |     192 |    0.021 |    0.034 |    0.162 |    0.280 |     0.055 |
| Local HA level request dispatch |     128 |    0.003 |    0.007 |    0.012 |    0.030 |     0.008 |

The deferred series includes callbacks that arm the next delay, send a step, or
finish the scene. The bench uses a local service stub. Native scene routing,
connected target confirmation, HA acceptance and physical response require
separate measurement.

On CORE 1, Light 52 revision 2026111804 returned its full set of 32 native
driver properties on ten consecutive GET_PROPERTIES_SYNC requests. Elapsed time
measured with the client’s Python monotonic clock was 51.83 ms minimum, 53.74 ms
median, and 61.50 ms nearest-rank p95 and maximum. The driver used Info, logging
off and latency diagnostics off. This measures the MCP/Director request and
reply through the LAN; Composer rendering is outside this interval.
