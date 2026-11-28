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

The installed 2026111921 suite was timed separately on the the controller lab
controller. Native Light V2 Toggle reached the independent HA WebSocket state
push in a median 79 ms from Off and 75 ms from On. The corresponding p95 samples
were 84 and 86 ms. Native Switch Navigator Select took 35 ms from Off and 34 ms
from On, with p95 samples of 38 and 36 ms. There were ten measurements per
direction with Log Mode and Latency Diagnostics off and Log Level at Info. These
times start at the proxy command request and end at confirmed software feedback
from the simulated Home Assistant device.

## Controller toggle timing by phase

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
at 5 and 2 ms. The controller verified the upgrade across the suite and preserved
selections, bindings and programming. Both simulated loads and the diagnostics
settings returned to their initial values.

### Revision 2026111923 feedback recovery

The native toggle test used the same simulated dimmer and relay, with Log
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
simulated wall control, then returned to the original binary light through the
shipped HTML and verified the saved choice.

### Revision 2026112012 linked Light Group

The installer verified Off and On from a linked switch tile, followed by slider
zero and On. The Light Group stayed in sync. The linked driver reported the
following timing samples with Log Mode Print, Level Debug and Latency
Diagnostics On. All samples used `C4:GetTickCount` and passed the clock checks.
These elapsed times measure the local send or feedback handler.

| Operation               | Samples | Median (ms) | p95 (ms) |
| ----------------------- | ------: | ----------: | -------: |
| Linked On send          |       6 |         101 |      120 |
| Linked Off send         |       7 |         123 |      170 |
| Linked ramp send        |      26 |          78 |      108 |
| Linked feedback handler |      58 |           7 |       27 |

The send timing includes synchronous Director work. It begins after the linked
target check and ends when the native send returns. The report does not measure
the time between the initial tap and visible light output.

### Revision 2026112013 linked bottom hold

The paddle sent press and release through its connected Control4 Light Group.
The linked group used its own configured hold rate and reported intermediate
brightness until release.

A capture recorded 24 Director samples on the host's monotonic clock. Group
brightness changed by about 25 percentage points per second during the ramp.
After release, the group, its members and the linked proxy held their last
reported level through the end of the capture, about 3.5 seconds after the first
settled report. The installer observed the bulbs dimming together. Optical
brightness between readings was unmeasured.

A separate lab hold with the same group and suite revisions verified the
forwarded press and release. The group, fixture member and wall proxy settled at
the same level after release and held it on a later read.

## Revision 2026112101 native reconnect

On the clean project, each of three runs disconnected the Coordinator,
confirmed all three drivers went offline, and issued the native Connect action.
The Director client timestamped the acknowledgment and the first connected
property readback per driver with its monotonic clock. Driver logging and
runtime profiling were Off. All three drivers were connected afterward, with the
saved Light and Switch selections intact.

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

## Revision 2026112101 paired startup and recovery

The same three packages ran against the same Home Assistant 2026.11.1 fixture
installation, first without HA Gesture Bridge and then with version 0.1.3. The
Light and Switch controlled the same direct HA loads in both conditions. Each
condition ran three fresh packaged Coordinator/Light/Switch process sets and
passed 30 checks. Package hashes matched the staged suite. The temporary HA
allocation was removed after the checks.

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

## Legacy Light and Switch migration

Revision 2026112301 recorded opt-in Coordinator spans on the controller with
`C4:GetTickCount`, Log Mode Off and Log Level Info. The collector retained up to
64 samples per operation and excluded no clock samples. One migration batch
first staged two replacements and stopped on their dependencies. Both
replacements passed when the installer rechecked the same batch.

| Operation               | Samples | Outcomes               |     Median / p95 |
| ----------------------- | ------: | ---------------------- | ---------------: |
| Assessment              |       4 | 4 passed               | 1,130 / 1,190 ms |
| Initial staging         |       2 | 2 passed               | 5,806 / 6,338 ms |
| Dependency verification |       4 | 2 blocked, 2 passed    |     203 / 212 ms |
| Cutover attempts        |       4 | 2 blocked, 2 passed    |   627 / 5,787 ms |
| Recovery                |       0 | Unmeasured in this run |                  |

The collector uses nearest-rank percentiles. The Cutover row includes the two
attempts that stopped before transferring control. Successful completion
includes the Coordinator waiting for confirmed replacement feedback. The
measurements describe driver and controller behavior using lab Home Assistant
loads.

`migration.scene_move` times the Coordinator's direct scene member transfer and
readback. One successful DriverWorks qualification through the private test
client took 853 ms from request submission to verified response. That wall clock
sample includes the client, transport, and Director readbacks. It does not
measure physical light response. Diagnostics were disabled for the probe, and
one sample does not establish a distribution.

The scene-removal checkpoint regression used simulated Director storage. One
successful run confirmed the removal intent on the first read, with no timer
wait, while Director returned an earlier copy of the full batch. One delayed run
waited for the fixture to land the write and verified that both original members
were still present before that point. The intent is written once and read up to
17 times at 125 ms intervals. The existing `migration.scene_move` span includes
this step. On the controller, one two-scene migration confirmed the checkpoint
and both original-member removals on their first reads with Trace logging
enabled. The replacement selection then timed out after 45 s.

The cutover span includes waiting for a replacement claim. In three virtual
clock runs with one dropped message per run, the replacement claimed the
selection at the first 250 ms retry. The original gateway stayed connected until
that claim, and each replacement applied the selection once. The three runs
covered the registration, selection reply and offer. Native timing for the
targeted reoffer is pending.

The subsequent hardening was checked with the real driver handlers on a virtual
clock. In one run a blank replacement recovered a dropped registration update at
2 s. In another, the Coordinator recovered a missing acknowledgment from the
exact durable selection, and the replacement then confirmed its Home Assistant
state after a simulated 6 s delay. Both runs applied the selection once. The
two-scene fixture also kept the original members when feedback disappeared at
the removal checkpoint. These simulated durations exclude real Director and Home
Assistant latency. Native repeat-migration timing remains open.

The scene verification fixture also counts native reads across migration phases.
Reference comparison and staging validation of the same snapshot consume one
native reply per relevant scene. At authorization boundaries, a Light migration
reads each known scene once so an outdated membership projection cannot hide a
new reference. A separate feedback fixture ran four retries and a final
successful check. It recorded one full installed-version scan, after feedback
was ready. Both are offline call counts. Controller latency for the inventory
and native scene reads remains unmeasured. An inventory fixture read each of two
consumer inputs once and read their shared Coordinator output once. A second
inventory fetched fresh binding evidence.

On cutover when scenes already point to the replacement and no connections need
transferring, the fixture recorded two affected-scene checks and one full scene
check, down from four affected-scene checks and one full check in the previous
path. It recorded two ownership scans, down from three. A separate naming retry
read the scenes again and rejected a changed setting. In a two-consumer binding
fixture, one Coordinator output read served both announcements. A new binding
callback read the changed projection again.

The Coordinator report separates affected-scene and full-scene verification
(`migration.scene_verify`, `migration.scene_verify_all`), individual native
scene reads (`migration.scene_read`), complete ownership checks and their
individual peer requests (`migration.ownership`, `migration.ownership_read`),
and binding callbacks and provider reads (`binding.reconcile`,
`binding.output_read`). Use the sample counts alongside the elapsed times. Scene
reads include parsing. Provider reads count the native output query served by
the shared contract, including uses outside binding reconciliation.

Readiness samples start when the replacement selection is accepted. The
Coordinator measures the first poll that verifies the saved selection
(`migration.selection_readback`), the time from that observation to reported
feedback (`migration.feedback_after_selection`), and the total readiness wait
through the installed release check (`migration.feedback`). The first two
samples describe the existing poll observations. They do not measure when
Director wrote the selection or when the physical device changed.

In 64 runs with virtual Director timers, Log Mode Off and Log Level Info, the
fixture exposed persistence at the 500 ms poll and feedback at the 1,000 ms
poll. Median and p95 were both 500 ms for each of the two readiness intervals
and 1,000 ms for the total. There were no excluded samples. These results
qualify the measurement boundaries and confirm that collection does not add
polls. Native timings for the new boundaries remain open.

```sh
LUA_PATH='test/?.lua;src/?.lua;src/?/init.lua;vendor/?.lua;vendor/?/init.lua;;' \
  luajit -l c4_shim test/test_ha_additional_migration.lua --benchmark-readiness
```

The explicit Light settings path uses the same cutover span. Its fixture runs
the driver and commissioning handshake on a virtual clock and verifies that the
new driver waits for Director persistence readback before acknowledging. The 100
ms timer allows for the roughly 50 ms persistence delay observed in the
template's Director shim qualification. Registry and state reads run
concurrently before cutover. The native timing table above predates this path.

The Coordinator's latency report records `migration.preflight_state`,
`migration.preflight_registry`, and `migration.preflight_installation`
separately. The installation span includes collecting legacy gateways and
checking their Home Assistant routes. Reusing already collected evidence adds no
installation sample. A retried state read creates its own sample. The
counterparts after feedback are `migration.post_cutover_registry` and
`migration.post_cutover_installation`. Concurrent spans overlap, so their
durations should be read individually. Each span ends when the Coordinator
receives the result and includes local scheduling and processing time.

`migration.feedback_poll_interval` measures the time from scheduling an existing
500 ms readiness poll to the start of its callback. Two virtual polls measured
500 ms each. With an injected millisecond clock and Log Mode Off at Info, the
evidence fixture recorded one sample per operation. Both p50 and p95 were 35 ms
for preflight state, 10 ms for preflight registry, 30 ms for preflight
installation, 35 ms for post-cutover registry, and 15 ms for post-cutover
installation. These configured fixture delays verify the measurement boundaries.

One native two-driver run with `C4:GetTickCount` and Print/Trace collected two
samples per operation and excluded no clock samples. Preflight state took
150–181 ms, registry 147–173 ms, and installation 654–681 ms. After feedback,
registry took 289–292 ms and installation 1,386–1,988 ms. The two scheduled 500
ms polls started after 500 ms and 873 ms. Both scene moves stopped at the
durable checkpoint and verified rollback, so these cutover results describe the
failure path.

The opt-in `migration.installation` span covers the companion round trip,
bounded parallel alternate-route reads, and the authenticated recheck when an
HTTPS route returns a different proof. Exact routes produce no network calls for
this check. The offline template transport fixture timed the distinct-route path
after 32 warmups on arm64 macOS with LuaJIT 2.1 and logging off. Across 64
samples the process CPU median was 76 µs, p95 was 149 µs, and the range was
70–223 µs. This measures local parsing and routing with simulated I/O. It
excludes actual network and Director wait time.

```sh
LUA_PATH='test/?.lua;src/?.lua;src/?/init.lua;vendor/?.lua;vendor/?/init.lua;;' \
  luajit -l c4_shim test/test_ha_installation_scope.lua --benchmark
```

The recovery fixture ran the production rollback function with Director bindings
simulated. After 32 warmups, all 64 measured calls verified restored authority.
On arm64 macOS with LuaJIT 2.1, the process CPU clock recorded a median of 4 µs,
p95 of 5 µs and a range of 3–7 µs. Log Mode was Off and Log Level was Info. The
fixture checks the recorded binding arguments outside the timed interval and
compares control calls, readiness polling and the feedback gate with diagnostics
on and off. Its recovery timing covers local rollback logic. The lab backup
restore separately verified the original bindings and project references. A
native automatic rollback duration remains unmeasured. A rerun after hardening
the checkpoint and rollback passed all 64 samples, with a 3 µs median, 4 µs p95
and a range of 2–4 µs with the same clock and logging settings.

```sh
LUA_PATH='test/?.lua;src/?.lua;src/?/init.lua;vendor/?.lua;vendor/?/init.lua;;' \
  luajit -l c4_shim test/test_ha_additional_migration.lua --benchmark-recovery
```

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

### Exact state reads

`snapshot.http` measures the complete Home Assistant state request.
`snapshot.headers` measures from submission to the response headers callback.
`snapshot.body` covers that callback through HTTP settlement, including body
delivery and the HTTP library's local handling. Reads that end before the
headers callback contribute only to the whole-request timing. The header
interval includes any controller queueing, connection setup and remote work.
DriverWorks reports these callback boundaries without separate timestamps for
those earlier phases.
[DriverWorks OnHeaders and OnDone](https://control4.github.io/docs-driverworks-api/#onheaders)

`snapshot.decode` measures parsing and validating the returned state.
`snapshot.publish` measures the Coordinator's local dispatch and readiness
updates for a subscribed state read. The optional catalog names sensor uses
`catalog.names_http` to keep its retrieval out of the state-read measurements.

`snapshot.queue` measures the interval from queue entry to HTTP submission or
discard. `snapshot.ready` measures from queue entry through processing the
result or settling the queued work. A valid state event can satisfy a queued
read before it is sent. Retired work is recorded as such. These spans cover
background snapshots for confirmed subscriptions. Explicit one-shot reads and
Home Assistant service commands keep their existing dispatch paths.

On a Control4 controller lab controller running 2026112416, the first reconnect after install
and a later explicit reconnect each yielded four successful snapshots with
`C4:GetTickCount`. Both runs used Latency Diagnostics. The table gives median
and p95 in milliseconds. With four samples, p95 is the observed maximum.

| Boundary                     | Logging Off, p50 / p95 | Print at Trace, p50 / p95 |
| ---------------------------- | ---------------------: | ------------------------: |
| Whole HTTP read              |               57 / 137 |                   74 / 89 |
| Time to headers              |               56 / 136 |                   73 / 88 |
| Headers to HTTP settlement   |                  1 / 1 |                     1 / 1 |
| Decode and validate          |                  0 / 1 |                     0 / 0 |
| Publish and report readiness |                12 / 57 |                  22 / 118 |
| Subscription acceptance      |              207 / 208 |                 232 / 232 |

These runs verify that each phase reports a native sample. Compare longer runs
under the same logging setting when evaluating performance differences.

#### Controller snapshot burst

Revision 2026112418 was tested through the private buddy driver. Each run sent
38 read-only requests for the same synthetic state through the production
authenticated HTTP path, timed with `C4:GetTickCount`. Latency Diagnostics was
On throughout. Burst elapsed time begins when the Coordinator starts the run.
Each range covers the listed repetitions and is expressed in milliseconds. All
requests in this table succeeded.

| Log Mode / Level | Reads in flight | Runs | First result | HTTP p95 | Queue p95 | Queue through result p95 | Whole burst |
| ---------------- | --------------: | ---: | -----------: | -------: | --------: | -----------------------: | ----------: |
| Off / Info       |              38 |    2 |        23–24 |  109–124 |         0 |                  110–125 |     118–132 |
| Off / Info       |               8 |    2 |        10–11 |  108–124 |    89–104 |                  109–126 |     114–130 |
| Off / Info       |               4 |    2 |         9–11 |    15–21 |   108–136 |                  118–148 |     123–154 |
| Off / Info       |               1 |    2 |            8 |      6–7 |   165–166 |                  169–170 |     175–176 |
| Print / Trace    |              38 |    1 |           53 |      147 |         0 |                      147 |         166 |
| Print / Trace    |               8 |    2 |        18–19 |  152–165 |   124–135 |                  152–166 |     162–175 |
| Print / Trace    |               4 |    2 |           13 |    21–26 |   147–153 |                  160–167 |     169–176 |
| Print / Trace    |               1 |    2 |         9–11 |        8 |   189–214 |                  194–218 |     201–226 |

The Coordinator dispatches four background snapshots at a time. Four gave
earlier feedback and a lower HTTP tail than simultaneous submission in this
test. Queue-inclusive p95 and last completion stayed in the same range or
increased. A separate native reconnect with logging Off produced four successful
subscription confirmations and snapshots. Queue p95 was 0 ms, HTTP p50/p95 was
52/164 ms, and queue through readiness was 79/181 ms. The regression test
confirms that fresh pushed feedback skips a queued read, failed reads release a
slot, and reconnect retires the previous queue. The multi-second production HTTP
timing still needs a same-project comparison of time to first and last
readiness.

The lab runner is stored in `lab/snapshot_benchmark.lua`. In a disposable build
checkout, place it in `src/ha/snapshot-benchmark-lab.lua` and append
`require("ha.snapshot-benchmark-lab").install(function() return hub end)` to the
Coordinator's entry point. Install that lab variant only in the dedicated test
project. The normal suite build omits the runner.

#### Controller switch commands with delayed replies

The relay fixture sent real Home Assistant state reports. A lab-only Coordinator
adapter delayed the first service reply by 2,500 ms. If a second request reached
the simulated device before that reply, the adapter replaced the first reply
with a superseded error. The MCP test sent Off after reading the relay's On
state, while the On service reply was still outstanding.

One run per revision used `C4:GetTickCount`, Latency Diagnostics On, Log Mode
Off and Log Level Info. Times are milliseconds.

| the controller revision       | On service outcome / time | Off queue wait | Off service outcome / time |
| --------------------- | ------------------------- | -------------: | -------------------------- |
| 2026112419, baseline  | Rejected / 705            |              0 | Accepted / 33              |
| 2026112420, sequenced | Accepted / 2526           |           1828 | Accepted / 25              |

In a separate run on 2026112420, the fixture switched Off and the adapter
dropped the service reply. The queued On expired after 4,000 ms. The Off request
timed out at 10,000 ms even though the fixture had reported Off. A fresh On and
Off both succeeded and the fixture returned to its initial state.

The Coordinator queues suite commands to the same switch until the outstanding
Home Assistant service reply arrives. Different switches have independent
queues. The queue holds up to four waiting commands, expires unsent work after
four seconds and discards queued work when the preceding command times out or
disconnects. It does not replay commands. State reports keep their existing path
and can arrive during the wait. `service.switch_queue` measures this wait
separately from service acceptance.

The lab adapter in `lab/switch_overlap.lua` belongs only in the disposable
Director build. Place it in `src/ha/switch-overlap-lab.lua` and append
`require("ha.switch-overlap-lab").install(function() return hub end)` to the
Coordinator entry point. Send `LabSwitchOverlap` with `SCENARIO` set to
`supersede` or `drop` on the lab Coordinator. The fault expires on its own and
affects only the dedicated simulated switch.

## Common operation matrix

| Operation                                        | Required boundaries                                                                                                                 | Current qualification / remaining gate                                                                                                                          |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Binary Light/Switch On, Off, Toggle              | Request dispatch → HA result, separately → matching confirmed state; app/proxy processing separately                                | Packaged control and native Toggle sampled with simulated loads. Navigator and wall switch checks are grouped in OpenSpec.                               |
| Dimmer level while off/on                        | Request → result and exact brightness feedback; native slider/report cost separately                                                | Packaged adapter level changes timed against simulated HA dimmers. Physical dimmer timing remains open.                                                         |
| RGB/xy/CCT and transitions                       | Conversion/validation, service result, confirmed color/temperature/level; requested transition duration distinguished from overhead | Packaged adapters timed against HA Demo color modes and simulated transition feedback. Physical transitions remain open.                                        |
| Hold, ramp, release/stop                         | Input → first command, cadence/jitter, release → last future command; canceled/overridden outcome                                   | Template engine correctness proven; timing in actual adapter pending tasks 5.3–5.4                                                                              |
| Presets, scenes and groups                       | Native dispatch/program execution, target feedback; simultaneous group/scene work and forced synchronization                        | Packaged preset, scene and group dispatch timed. The controller verified saved scenes and group membership with simulated targets. Repeated native timing remains open. |
| Connected-C4 On/level and paddle target          | Logical On/explicit level dispatch → target call/feedback; synchronous callback work separated                                      | the controller verified On presets with an ordinary target and a Light Group. Repeated native timing remains open.                                                      |
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

## Lab timing method

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

The codec benchmark records three alternating before/after CPU rounds of 2,000
decodes per workload, with source hashes and runtime version. Its synthetic
service result, gesture metadata and catalog page contain no household data.
These workstation CPU numbers justify the narrow string-span change but do not
replace native Director or physical latency measurements.

### Quick Setup scale benchmark

Run the Coordinator's catalog, project matching, preview, confirmed apply and
migration ownership code with synthetic Home Assistant replies and the Director
shim. The fixture uses equal numbers of dimmable lights and switches. Existing
Control4 peers are linked switches, and apply adds new ones. The three arguments
are catalog rows, existing linked peers and new selections. An optional fourth
argument adds characters to each device name. Use batch size zero for just the
catalog limit probe.

```sh
LUA_PATH='test/?.lua;src/?.lua;src/?/init.lua;vendor/?.lua;vendor/?/init.lua;;' \
  luajit -l c4_shim tools/benchmark_ha_setup.lua 1000 100 16
```

Ten fresh processes per row used arm64 LuaJIT 2.1.1794214635 and measured
process CPU with `os.clock`, with logging and diagnostic collection off. The
table gives p50 / nearest-rank p95 in milliseconds. Registry calls and native
adds use immediate fixtures. The timer is virtual. These results exclude Home
Assistant rendering, network trips, Director IPC and browser rendering.

| HA rows | Existing linked drivers |   Catalog CPU | All picker pages CPU |     Apply CPU | Registry replies in apply |
| ------: | ----------------------: | ------------: | -------------------: | ------------: | ------------------------: |
|      50 |                       6 |     3.0 / 3.2 |            0.5 / 0.5 |     103 / 106 |                        32 |
|     250 |                      25 |   13.7 / 14.2 |            3.1 / 3.6 |     479 / 512 |                       160 |
|   1,000 |                     100 |   56.4 / 61.5 |          10.2 / 12.2 | 2,002 / 2,094 |                       640 |
|   2,500 |                     250 | 156.3 / 167.6 |          34.5 / 41.4 | 5,413 / 5,599 |                     1,600 |

Each 16-device apply made 32 full catalog reads and 32 project inventories, plus
one of each for its preview. At 1,000 rows, applying one and four devices took
125 and 496 ms median CPU with two and eight full reads. Registry batches run in
series, up to 50 entries per reply. The template's five-second pacing after each
successful add adds 80 seconds to a successful 16-device batch, independent of
the measured CPU. The picker requested 23 and 56 pages at 1,000 and 2,500 rows.
It did one project inventory as it read all the pages. Migration ownership read
each peer's saved identity once across 16 checks. The checks still visited the
peer list for each candidate. The benchmark did not include migration scene and
programming assessment.

The native fallback accepted 3,000 short-name rows. At 3,100, the raw projection
fit but the enriched catalog exceeded its 1 MiB limit. With names 100 characters
longer, 2,500 rows already exceeded the enriched limit. At 3,500 short-name
rows, the synthetic response itself crossed the separate 1 MiB HTTP cap. These
counts depend on metadata size. A companion connection still runs the native
supplement during a forced refresh in the current Coordinator.

For context, a separate, previously captured the controller sample on revision
2026112420 reported 20 binding validations at 2 / 3 ms p50 / p95 with logging
Off at Info and the controller tick clock. That run covered normal switch
traffic. The larger-project results still need native scale qualification.

#### Freshness check and scoped projection

Repeat the same synthetic apply with a prevalidated companion and stable Home
Assistant metadata by adding `0 companion` to the command. The fixture uses
immediate responses to the freshness checks. Ten fresh processes per size
measured these warm apply results:

| HA rows | Existing linked drivers | CPU p50 / p95 (ms) | Freshness checks | Native projection pages | Registry requests |
| ------: | ----------------------: | -----------------: | ---------------: | ----------------------: | ----------------: |
|   1,000 |                     100 |            31 / 33 |               32 |                       0 |                 0 |
|   2,500 |                     250 |            93 / 96 |               32 |                       0 |                 0 |

Apply still made 32 fresh project inventories. Each inventory indexes the
Coordinator's reciprocal bindings once. The HA response confirms both catalog
revisions without sending rows. If metadata changes, the Coordinator checks the
revision on both sides of a fresh read. With no compatible companion, 1,000 rows
and 100 linked drivers still required 640 registry replies during the batch. In
that fixture the median apply CPU was 1,987 ms.

The fallback accepted 5,000 synthetic loads with 100 extra characters per name.
Its 2.01 MB unpaged projection was read in 40 bounded template replies.
Separately, Home Assistant 2026.11.1 rendered the actual templates against 5,000
synthetic loads with 120 accented characters per name. The count and all exact
IDs matched across 59 replies. The largest reply was 110,684 bytes, and
workstation render time across the replies was 662 ms. This was a local HA
runtime measurement, excluding transport, registry and Composer time.

The optional `tools/core1_catalog_benchmark.lua` runner can be included in a
lab-only Coordinator to measure forced refreshes from the native tick clock.
Copy it into the isolated build's `src/ha/core1-catalog-benchmark.lua` and wire
it to the Coordinator's live Hub at the end of the entry point. Use the private
lab MCP to send `LabCatalogBenchmark` with a count from 1 to 10 and a
32-character hexadecimal nonce, then read the matching `Latency Report`. The
timed request is read-only against Home Assistant.

The initial test and rollback archives omitted the lab Coordinator's
archive-relative CA file. The Coordinator entered reconnect retry after each
reload. The lab HA and its TLS proxy accepted authenticated WebSocket
connections with the lab CA. Adding the public CA to the private test archive
restored the the controller connection with the same saved endpoint and credentials.
Check for the trust resource in each lab test and rollback archive before
reloading the driver.

On the controller, the same Coordinator ran ten forced catalog refreshes against each
companion version over the verified TLS lab connection. The larger fixture added
1,000 synthetic lights and switches to the lab's 17 eligible entities. Timings
use `C4:GetTickCount`, Latency Diagnostics On and Log Mode Off at Info. Each row
has one cold sample and nine warm samples. The warm p95 is the nearest-rank
result. These timings cover catalog refresh through verified publication. They
exclude adding drivers and Composer rendering.

| Eligible entities | HA freshness support | Cold (ms) | Warm p50 / p95 (ms) | Registry requests per warm refresh |
| ----------------: | -------------------- | --------: | ------------------: | ---------------------------------: |
|                17 | Older companion      |        90 |             52 / 63 |                                  1 |
|                17 | Updated companion    |        92 |               3 / 5 |                                  0 |
|             1,017 | Older companion      |     1,695 |       1,324 / 1,416 |                                 21 |
|             1,017 | Updated companion    |     1,478 |              5 / 17 |                                  0 |

Every warm refresh with the updated companion sent one freshness request and
reused the verified native projection. Both companions still required the native
projection and exact registry reads on a cold refresh.

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

On a lab the controller, Light revision 2026111804 returned its full set of 32 native
driver properties on ten consecutive GET_PROPERTIES_SYNC requests. Elapsed time
measured with the client’s Python monotonic clock was 51.83 ms minimum, 53.74 ms
median, and 61.50 ms nearest-rank p95 and maximum. The driver used Info, logging
off and latency diagnostics off. This measures the Director request and reply
through the LAN; Composer rendering is outside this interval.
