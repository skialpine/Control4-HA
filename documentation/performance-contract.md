# Latency measurement and qualification

Every common operation needs an instrumented boundary and repeated evidence
before the feedback handoff. A missing sample means unmeasured, not zero
latency. The operation matrix below is a release obligation alongside functional
tests; reserved metric names alone do not establish coverage.

## Linked toggle comparison on 2026111921

The pinned BP original, prototype and suite family archives each handled their
native linked-button `DO_CLICK` on the same simulated HA load. The Light used
the lab binary light and the Switch used the lab relay. All six cases used the
exact 2026111921 Coordinator, HA 2026.11.1 and the same Director shim with a 1
ms selector wait. The host monotonic clock measured dispatch, Coordinator
delivery of confirmed HA state and family consumption separately. Log Mode and
the legacy drivers' Debug Mode were off. Each case used four warmup clicks and
ten measured clicks per direction. Both loads returned to their starting state.

| Driver | Generation       | Coordinator median, off→on / on→off | Family feedback median, off→on / on→off | Slowest directional family p95 |
| ------ | ---------------- | ----------------------------------- | --------------------------------------- | ------------------------------ |
| Light  | BP 106           | 5.55 / 5.35 ms                      | 6.83 / 6.56 ms                          | 7.48 ms                        |
| Light  | Prototype 1      | 5.03 / 4.97 ms                      | 6.25 / 6.20 ms                          | 8.76 ms                        |
| Light  | Suite 2026111921 | 5.12 / 5.39 ms                      | 6.38 / 6.68 ms                          | 10.64 ms                       |
| Switch | BP 106           | 4.39 / 4.48 ms                      | 5.54 / 5.63 ms                          | 9.09 ms                        |
| Switch | Prototype 107    | 4.43 / 4.32 ms                      | 5.58 / 5.47 ms                          | 6.17 ms                        |
| Switch | Suite 2026111921 | 4.36 / 4.51 ms                      | 5.59 / 5.76 ms                          | 6.59 ms                        |

With ten samples per direction, the reported p95 is the largest observed sample
in that direction. The comparison covers the family drivers sharing one
Coordinator build. It includes the shim's process and network boundaries.

The installed 2026111921 suite was timed separately on the CORE 1 lab
controller. Native Light V2 Toggle reached the independent HA WebSocket state
push in a median 79 ms from Off and 75 ms from On. The corresponding p95 samples
were 84 and 86 ms. Native Switch Navigator Select took 35 ms from Off and 34 ms
from On, with p95 samples of 38 and 36 ms. There were ten measurements per
direction with Log Mode and Latency Diagnostics off and Log Level at Info. These
times start at the proxy command request and end at confirmed software feedback
from the simulated Home Assistant device.

## CORE 1 toggle timing by phase

To locate the delay in the native Light Toggle and Switch Select paths, a second
run on 2026111921 observed the Home Assistant service event and state push for
each command. It replayed the exact same service and parameters over a direct
Home Assistant WebSocket for comparison, alternating the order of the two
routes. Each route had ten measured commands per direction. The simulated dimmer
used its saved 57% On preset and the simulated switch used native Toggle. Their
initial state and brightness were restored.

| Boundary                                             | Light median across directions | Switch median across directions |
| ---------------------------------------------------- | ------------------------------ | ------------------------------- |
| Native proxy request to confirmed HA feedback        | 58.43–58.87 ms                 | 34.04–34.38 ms                  |
| Direct HA WebSocket request to confirmed HA feedback | 3.57–3.67 ms                   | 3.43–3.52 ms                    |
| Native HA service event to HA state update           | 0.21–0.24 ms                   | 0.18 ms                         |

The workstation measured request and receipt with its monotonic clock. The last
row uses the difference between timestamps from HA itself. In a separate
profiled run using `C4:GetTickCount`, the Light handler took a median 40 ms and
each of its binding validations took 13 ms. Each Switch binding validation took
2 ms. The Switch adapter's request-dispatch span took 5 ms. Switching the lab
command endpoint to asynchronous acknowledgment produced similar feedback times,
about 58–60 ms for Light and 35 ms for Switch. Neither run covers a physical
device or the Navigator interface.

Revision 2026111922 reuses the two fresh binding responses when validating a
retained legacy Light connection. The regression test verifies one read per
endpoint and checks that both legacy class declarations and the reciprocal peers
still have to match. All three candidate archives contain this same runtime
change.

| Native request to confirmed HA feedback | 2026111921 median off→on / on→off | 2026111922 median off→on / on→off |
| --------------------------------------- | --------------------------------- | --------------------------------- |
| Light Toggle                            | 58.87 / 58.43 ms                  | 55.31 / 53.94 ms                  |
| Switch Select                           | 34.04 / 34.38 ms                  | 34.86 / 34.45 ms                  |

The quiet runs used ten samples per direction with Log Mode and Latency
Diagnostics off. The maximum of the two observed directional p95s was
72.01→65.65 ms for Light and 36.91→46.15 ms for Switch. Each directional p95
represents the slowest sample at this sample count. The separate profiled runs
used Info and Log Mode Off. The median Light handler time moved from 40 to 37 ms
over 44 samples per revision. Its binding validation median moved from 13 to 11
ms over 176 samples per revision. The Switch request and binding medians stayed
at 5 and 2 ms. CORE 1 verified the upgrade across the suite and preserved
selections, bindings and programming. Both simulated loads and the diagnostics
settings returned to their initial values.

### Revision 2026111923 feedback recovery

The native CORE 1 toggle test used the same simulated dimmer and relay, with Log
Mode and Latency Diagnostics off. The workstation monotonic clock ran from the
native proxy request to the independent Home Assistant state push. Each
direction had ten samples.

| Native command | Median off→on / on→off | Directional p95 off→on / on→off |
| -------------- | ---------------------- | ------------------------------- |
| Light Toggle   | 55.42 / 53.55 ms       | 73.39 / 103.80 ms               |
| Switch Select  | 34.33 / 33.96 ms       | 41.42 / 40.19 ms                |

Each directional p95 is the slowest sample at this sample count. The relay
medians remain close to the previous 2026111922 run. The test restored both
loads and covers software feedback.

The paired recovery qualification withheld the expected HA state push from one
accepted command per family on each supported HA version. One exact read per
command restored confirmed feedback. Times use the test host's monotonic clock
from proxy dispatch through the packaged Coordinator and real isolated HA to the
family's confirmed state. Log Mode was Off.

| Home Assistant | Light, one sample | Switch, one sample |
| -------------- | ----------------- | ------------------ |
| 2026.11.1      | 3,181.59 ms       | 5,125.66 ms        |
| 2026.11.2      | 3,130.26 ms       | 5,220.99 ms        |

Each family has two recovery samples. These intervals include the confirmation
deadline, the harness and the state read.

### Revision 2026112009 packaged Light and Switch

The exact packages passed 1,466 Light and 727 Switch checks against Home
Assistant 2026.11.1. The driver processes used simulated Director IPC. Log Mode
was Off, Log Level was Info and Latency Diagnostics was enabled. Each row uses
ten samples and shows median / nearest-rank p95 in milliseconds. The workstation
monotonic clock starts at the proxy request and captures each receipt
separately. The family receipt includes harness scheduling and delivery to the
Lua driver.

| Operation                     | HA service acceptance | HA state push | Family consumed state |
| ----------------------------- | --------------------: | ------------: | --------------------: |
| Dimmer Toggle from Off        |         27.14 / 28.63 | 26.87 / 27.81 |         47.69 / 48.63 |
| Dimmer Toggle from On         |         27.08 / 28.61 | 26.74 / 28.36 |         47.86 / 49.78 |
| Dimmer scene activation       |         25.48 / 29.39 | 25.16 / 27.99 |         46.14 / 47.32 |
| Dimmer group level            |         25.36 / 27.85 | 25.06 / 26.76 |         46.44 / 46.73 |
| Switch linked Toggle from Off |         25.20 / 26.93 | 25.05 / 26.34 |         46.17 / 48.10 |
| Switch linked Toggle from On  |         25.60 / 27.70 | 25.48 / 27.07 |         46.44 / 48.84 |

The separate packaged picker run passed six checks per family. Both selected a
simulated wall control, then returned to the original Porch light through the
shipped HTML and verified the saved choice.

### Revision 2026112012 Office Light Group

The installer verified the linked Office switch tile on CORE 5 through Off and
On, then slider zero and On. The Light Group stayed in sync. The linked driver
reported the following timing samples with Log Mode Print, Level Debug and
Latency Diagnostics On. All samples used `C4:GetTickCount` and passed the clock
checks. These elapsed times measure the local send or feedback handler.

| Operation               | Samples | Median (ms) | p95 (ms) |
| ----------------------- | ------: | ----------: | -------: |
| Linked On send          |       6 |         101 |      120 |
| Linked Off send         |       7 |         123 |      170 |
| Linked ramp send        |      26 |          78 |      108 |
| Linked feedback handler |      58 |           7 |       27 |

The send timing includes synchronous Director work. It begins after the linked
target check and ends when the native send returns. The report does not measure
the time between the initial tap and visible light output.

### Revision 2026112013 Office bottom hold

The Office paddle sends press and release through its connected Control4 Light
Group. The group has a 4,000 ms hold-down rate. The Office Light has a 5,000 ms
hold-down rate for its own native control. The group uses brightness zero for
Off and has 0 ms command delay.

One CORE 5 capture recorded 24 Director samples on the host's monotonic clock.
The group started at 100% with 3,999 ms remaining toward 0%. At 2,999 ms
remaining, the group reported 74.92% and the three members reported 74.58% to
74.88%. This is about 25 percentage points per second of reported ramp time,
consistent with the group's rate. After release, every member and the Office
proxy held at 63% through the last sample, about 3.5 seconds after the first
settled group report. The installer saw the bulbs dim together. The sample
records Director feedback and the installer observation. It has no optical
measurement of brightness between the reports.

On CORE 1, a separate 70% hold test on the same group and suite revisions logged
the forwarded press and release. The group, fixture member and wall proxy all
settled at 42% after release and stayed there on a later read.

## Revision 2026112101 native reconnect

On the clean CORE 1 project, each of three runs disconnected the Coordinator,
confirmed all three drivers went offline, and issued the native Connect action.
The Director client timestamped the acknowledgment and the first connected
property readback per driver with its monotonic clock. Driver logging and
runtime profiling were Off. All three drivers were connected afterward, with the
Hallway wall dimmer and AC selections intact.

| Connect action to observation   | Median  | Range         |
| ------------------------------- | ------- | ------------- |
| Director command acknowledgment | 56 ms   | 55–56 ms      |
| Coordinator connected to HA     | 3.126 s | 3.110–3.133 s |
| Switch connected                | 3.276 s | 3.222–3.298 s |
| Light connected                 | 3.521 s | 3.470–3.542 s |

The child interval includes the delay to the first successful property poll.
This was an explicit reconnect on native Director with the companion loaded. The
packaged comparison below measures different boundaries, including
disrupted-socket and Coordinator lifecycle recovery.

An earlier native single run on 2026111813 timed a Coordinator-only reload. The
Director update operation took 6.968 s. The client first confirmed the Light
ready 1.359 s after that operation and the Switch ready after 1.425 s. The
client used its monotonic clock and sampled Director status. The receipt does
not record logging settings. This supplies a native reload sample, separate from
the current candidate's startup measurement.
[CORE 1 recovery receipt](../lab/installed-upgrade-recovery-readback.json)

## Revision 2026112101 paired startup and recovery

The same three packages ran against the same Home Assistant 2026.11.1 fixture
installation, first without HA Gesture Bridge and then with version 0.1.3. The
Light and Switch controlled the same direct HA loads in both conditions. Each
condition ran three fresh packaged Coordinator/Light/Switch process sets and
passed 30 checks. Package hashes matched the staged suite. The temporary HA
allocation was removed, and Edwards and its HA installation were unchanged.

| Measured interval                   | Companion absent, median (range) | Companion loaded, median (range) |
| ----------------------------------- | -------------------------------- | -------------------------------- |
| Package start to authenticated HA   | 2.160 s (2.158–2.181 s)          | 2.155 s (2.154–2.178 s)          |
| Socket loss to both consumers ready | 10.319 s (10.298–10.379 s)       | 10.295 s (10.279–10.310 s)       |
| Coordinator reload to both ready    | 7.044 s (7.038–7.060 s)          | 7.042 s (7.034–7.042 s)          |

The harness used Python monotonic time with driver logging Off and runtime
profiling disabled. Readiness required a fresh snapshot, exact subscription and
connected status for each child. These elapsed times include the Director shim,
inter-process communication and the harness's HA identity checks and forwarding.
They measure ordinary control with and without the integration loaded. Native
Director startup and recovery timing and companion-specific gesture timing are
separate measurements.

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

| Operation                                        | Required boundaries                                                                                                                 | Current qualification / remaining gate                                                                                                                          |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Binary Light/Switch On, Off, Toggle              | Request dispatch → HA result, separately → matching confirmed state; app/proxy processing separately                                | Packaged control and native CORE 1 Toggle sampled with simulated loads. Navigator and wall switch checks are grouped in OpenSpec.                               |
| Dimmer level while off/on                        | Request → result and exact brightness feedback; native slider/report cost separately                                                | Packaged adapter level changes timed against simulated HA dimmers. Physical dimmer timing remains open.                                                         |
| RGB/xy/CCT and transitions                       | Conversion/validation, service result, confirmed color/temperature/level; requested transition duration distinguished from overhead | Packaged adapters timed against HA Demo color modes and simulated transition feedback. Physical transitions remain open.                                        |
| Hold, ramp, release/stop                         | Input → first command, cadence/jitter, release → last future command; canceled/overridden outcome                                   | Template engine correctness proven; timing in actual adapter pending tasks 5.3–5.4                                                                              |
| Presets, scenes and groups                       | Native dispatch/program execution, target feedback; simultaneous group/scene work and forced synchronization                        | Packaged preset, scene and group dispatch timed. CORE 1 verified saved scenes and group membership with simulated targets. Repeated native timing remains open. |
| Connected-C4 On/level and paddle target          | Logical On/explicit level dispatch → target call/feedback; synchronous callback work separated                                      | CORE 1 verified On presets with an ordinary target and a Light Group. Repeated native timing remains open.                                                      |
| Single/multi-press, hold/release, extra buttons  | Decode, validation/programming, property/LED, forwarding and publication phases; HA-clock version-2 acknowledgment separately       | Existing companion protocol reused; new receiver wiring pending task 6.3                                                                                        |
| LED color/brightness/behavior                    | Validation/dispatch → result and actual indicator feedback, while preserving behavior                                               | Pending task 6.4; include restricted palette and unavailable/rejected controls                                                                                  |
| Cold picker, warm reopen, revision check, paging | User request → usable options; companion request, scoped metadata, projection and page costs separately                             | Runtime catalog spans wired; repeated UI wall-clock evidence required with task 4.3                                                                             |
| Selection commit and preparation                 | Choice → validated selection/confirmed state; preparation progress, result and input readiness separately                           | Preparation round-trip hook wired; setup UI and first-use/reuse scenarios pending task 4.4                                                                      |
| Startup and reconnect                            | Initialization → authenticated connection → fresh selected evidence; backoff, read/subscription costs distinct                      | Connect/auth/subscription/read hooks wired; native/physical and repeated recovery measurements pending                                                          |
| Release check/install                            | Check/download/verification/reload → usable restored state, interruption and rollback separately                                    | Pending update implementation and qualification                                                                                                                 |

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
