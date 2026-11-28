# Additional driver lab checks

The independent browser review used the generated setup pages at 480 × 530 and
960 × 720. A Fan used the matching room automatically. A Sensor retained its
edited name and room across device types. Mixed review sent separate catalog
revisions. After a hidden device type changed, the page opened that type and
allowed clearing its changed entries while keeping other choices. Keyboard
confirmation sent one simulated Add. Lock browsing and radio selection did not
commit a change. The generated driver definitions place Properties before Device
Setup. Actual tab order and native controls still require the installer’s
Composer and Navigator checks.

The first new-family run on the controller used a development build. Director acknowledged all 12 package
updates. Live readback confirmed the Coordinator and all four configured Light
and Switch instances connected. All nine new driver fixtures reported confirmed
state after the update.

The controller created three test fixtures. Binary Sensor and Generic Sensor
confirmed live Demo state through their retained bindings. A second eligible
Coordinator meant the directly added Fan needed an explicit provider. After
binding and selection, a Fan Programming command returned an accepted result and
Control4 reported confirmed power and speed. A separate HA read verified the
power change. The second command restored the original Demo power state and the
independent state read verified it.

Blinds, Garage Door, Thermostat, Lock, Alarm Panel and Media Player also read
confirmed Demo state after direct installation, explicit Coordinator binding and
selection on the controller. Director kept the package name for the relay/contact Garage
Door. A native rename and project readback verified the intended name on that
fixture. An independent browser review of a later build tested a custom
name and room, keyboard confirmation and reopening at both pane sizes. The
simulator confirmed that a later Quick Setup run keeps the renamed driver. An
add that times out before the rename needs the installer to rename the added
driver before resuming. The automatic fallback awaits an installer run through
Composer.

The first reload failed during the WebSocket handshake because the lab
Coordinator's archive-relative CA was missing. Restoring the public trust
certificate in the Coordinator archive recovered the same saved connection and
the existing children. The public build does not include trust files.

The dedicated Home Assistant 2026.11.1 lab reported Demo entities across all
eight required domains. The
[read-only scope runner](../../lab/verify_endpoint_scopes.py) sent five
authenticated first-page requests for each type. It used `perf_counter_ns` on
the caller with no driver logging active. Timings are HTTP round trips through
the lab connection, including HA template rendering. They do not measure
Coordinator cache latency or hardware response. For five samples, nearest-rank
p95 equals the maximum.

| Type          | Matching Demo rows | Median, ms | p95, ms |
| ------------- | -----------------: | ---------: | ------: |
| Binary sensor |                  3 |     2012.6 |  2057.5 |
| Sensor        |                 12 |     2018.3 |  2040.9 |
| Fan           |                  5 |     2012.8 |  2042.3 |
| Blinds        |                  4 |     2014.9 |  2042.7 |
| Garage door   |                  1 |     2012.1 |  2047.5 |
| Thermostat    |                  3 |     2014.2 |  2034.6 |
| Lock          |                  4 |     2013.7 |  2037.0 |
| Alarm panel   |                  1 |     2012.3 |  2077.5 |
| Media player  |                  8 |     2013.6 |  2036.1 |

One Demo fan power command took 2014.8 ms to receive an HTTP service reply. A
separate state read confirmed the requested state. The run restored and verified
the original state.

A later repeat confirmed the same row counts for eight scopes, with five round
trips per scope and medians of 4013–4018 ms. The repeat ended before Media
Player. These timings were measured by the lab client and do not establish a
change in Coordinator or the controller performance.

The Lua fixtures verify warm-cache reuse, exact registry identity and a stale
mixed-type preview. One mixed commissioning run confirmed all eleven endpoint
families, including Light and Switch. It checked each destination package, room,
Coordinator binding and saved endpoint. Reopening Quick Setup and confirming
the same choices added no drivers and repeated no configuration. Native
commissioning and installed predecessor upgrades remain open on the controller.
[Existing suite latency baseline](../performance-contract.md#quick-setup-scale-benchmark)

## Demo seed reset

The [local reset runner](../../lab/verify_demo_reset.py) started Home Assistant
2026.11.1 and 2026.11.2 twice each from empty configuration directories using
the same seed. Each version reproduced the same eligible IDs across all eight
domains and the same starting readings for the tested endpoints. Both passes on
each version exercised eleven paths. Separate state events and REST reads
confirmed a contact edge, a zero temperature reading, fan power, blind position,
garage motion to the opposite end, thermostat mode, unlocking, alarm arming and
media pause. A separate comfort-mode select and clear-hold button each confirmed
their effect while the primary thermostat's mode stayed the same. The starting
fixtures were restored by recreating the disposable
container. These checks exercise Home Assistant. The delayed feedback,
unavailable state, and native Control4 contact and relay behavior are covered by
the Lua fixtures.

## Controller functional checks

On a later build, the Fan power, Blinds position, Thermostat preset, Lock
and Media Player commands all received Home Assistant acceptance. Separate state
reads verified the changes and restored the five fixtures. The Demo blind
reported 60% after a 55% request, and Control4 published the confirmed 60%. A
binary source change and numeric sensor update reached their Control4 drivers,
then the test restored the original values. Trying to arm the Demo Alarm Panel
without a required code left it disarmed and prompted for a code in Control4.

Composer showed a malformed-driver warning for the original Garage Door fixture.
A clean install of a later build displayed Driver Information and the
native Cover editor with type Door in Composer. The native proxy opened the Demo
cover. A Programming command closed it again, and separate Home Assistant reads
verified both states. A later build added the garage icon and Director
readback verified its paths. The simulator verifies Open, Close and Stop relay
outputs and both limit contacts, including partial positions and lost feedback.
The revised icon and absence of the original hover warning still need a Composer
visual check.

A later build removed the three duplicate Garage Door keypad connections.
Director reported one each of the native Open, Closed and Toggle links, plus the
separate Step-by-Step link. The same fixture retained its Coordinator binding
and both limit contacts and all four relay outputs. The native Open target
opened the Demo cover, and the native Toggle command closed it again.
Independent Home Assistant reads confirmed both results. A physical keypad and
the stock Control4 Garage Door controller pairing still need qualification.

Director acknowledged the 12 package updates for a later build. Readback
found all 12 package types, and all nine added-family fixtures returned
available state. Independent reads confirmed that all nine selected Home
Assistant endpoints came from Demo and matched their Control4 state, including
the moisture label, sensor unit and thermostat mode display. The Coordinator
and the four configured Light and Switch instances reported connected.
The native Garage Door proxy opened the Demo cover and then closed it to
restore its starting state. Separate HA reads confirmed both commands.

The Coordinator timing report collected after the package update used
`C4:GetTickCount`, Latency Diagnostics On, Log Mode Off and Log Level Info.
All 13 subscription confirmations and all 13 snapshots succeeded. These are
driver processing and Home Assistant round trips.

| Operation                 | Samples | p50, ms | p95, ms |
| ------------------------- | ------: | ------: | ------: |
| Subscription confirmation |      13 |     444 |     455 |
| Snapshot HTTP             |      13 |     224 |    1056 |
| Snapshot through ready    |      13 |     384 |    1431 |

The same report measured one transport connection at 269 ms and authentication
at 167 ms.

### Controller Quick Setup browse

The Coordinator build ran the normal Quick Setup
browse handler against the lab. Each scope started with an empty scoped catalog.
The five warm samples reused the returned revision and repeated the project
match check. The clock was `C4:GetTickCount`, with Latency Diagnostics On, Log
Mode Off and Log Level Info. The nearest-rank p95 is the maximum of five samples.

| Type          | Choices | Cold, ms | Warm p50, ms | Warm p95, ms |
| ------------- | ------: | -------: | -----------: | -----------: |
| Lighting      |      17 |      409 |          361 |          372 |
| Binary sensor |       2 |      385 |          346 |          361 |
| Sensor        |      16 |      451 |          343 |          358 |
| Fan           |       5 |      373 |          351 |          367 |
| Blinds        |       4 |      382 |          359 |          383 |
| Garage door   |       1 |      360 |          360 |          364 |
| Thermostat    |       3 |      356 |          341 |          365 |
| Lock          |       4 |      385 |          349 |          371 |
| Alarm panel   |       1 |      363 |          363 |          367 |
| Media player  |       8 |      370 |          371 |          408 |

These samples cover Director browse and project matching at the lab's mixed
catalog size. They exclude browser rendering.

### Scale and confirmed setup

A second run added 250 owned synthetic Home Assistant states across six
scopes and used the same Coordinator driver paths and clock. Fan already had
a cached catalog from the commissioning rehearsal, so its first sample is a
forced refresh. The warm statistics cover the first page only.

| Type       | Total choices | First page | First, ms | Warm p50, ms | Warm p95, ms |
| ---------- | ------------: | ---------: | --------: | -----------: | -----------: |
| Lighting   |            59 |         37 |       472 |          348 |          383 |
| Fan        |            47 |         47 |       446 |          362 |          556 |
| Sensor     |            58 |         50 |       511 |          353 |          365 |
| Blinds     |            46 |         46 |       450 |          378 |          396 |
| Garage door |           42 |         42 |       410 |          348 |          353 |
| Thermostat |            44 |         44 |       459 |          352 |          358 |

On a later build, an alias of the standalone Fan package was
absent from the controller's driver store. The normal Quick Setup preview kept the
project unchanged. Confirmation installed the embedded archive and verified
its checksum. Director added the visible device to the approved room and
retained the correct Coordinator link and saved Demo selection. The next
preview found the same device. Its first Fan command changed the independent
HA state and a reverse command restored the starting state. The temporary
driver instance was removed.

Two commissioning previews measured 653 ms median and 700 ms nearest-rank
p95. The confirmed run took 7375 ms, including Director add at 459 ms,
binding at 434 ms, package install at 3 ms and selection verification at
388 ms. The total includes the template's wait after a successful add.
The companion archive fix also passed standalone-versus-embedded byte checks
in both template distributions. [Finite Labs PR 250](https://github.com/finitelabs/control4-driver-template/pull/250)

An independent browser reviewer compared blocked legacy Garage Door and
Thermostat previews at 480 × 530 and 960 × 720 in 16 runs. The preview named
the connections or settings needing review, kept Apply disabled and kept Back
to edit visible. Keyboard activation returned focus to the blocked device's
checkbox. Unchecking that item preserved another device's edited name and
room and allowed that device to proceed. These checks used simulated
Coordinator replies. The same flow in Composer remains open.

An additional independent browser check verified exact lookup by a native
entity ID and by the alias of a lighting choice without showing the raw
identifier in the result. Duplicate room and name recovery preserved both
drafts and allowed correction by keyboard. The manual Cover recovery text
fit in Troubleshooting at both pane sizes. Composer Properties still needs
installer verification.

## Optional Bridge work

The standard Home Assistant API covers the tested actions on all three waves.
The following extensions need a demonstrated device or rendering requirement
before they enter the release scope.

| Candidate                                  | Current evidence and decision                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fan and cover keypad inputs and indicators | Director and Demo confirmed fan power and speed, blind position, and the garage cover's open and toggle paths. Control4 exposes local keypad links. A Bridge extension needs a specific compatible HA keypad or LED and a physical evidence run.                                                                                                |
| Thermostat and security auxiliary devices  | the controller confirmed a thermostat preset, lock control and an alarm code requirement using the primary HA device. Use reported capabilities and authorized state. A paired mode selector, hold helper or battery endpoint needs a proven role or an explicit selection before use. The present evidence supports that work through standard HA APIs. |
| Authenticated media artwork                | the controller confirmed Media Player commands and returned state. A signed URL is filtered from the simulated Control4 metadata path. Qualify a trusted artwork transport in the native renderer before deciding whether it needs Bridge support. Track text and ordinary control remain available.                                                     |

## Running candidate and non-reboot recovery

Director acknowledged all 12 package updates for a later build. Live
readback found that revision on the Coordinator and all 15 children. The
Coordinator and all 13 configured children reported connected. Two children
without a saved selection reported unconfigured. The Coordinator
archive adds the trust certificates to the standard package.

Disconnecting the Coordinator's WebSocket made the Demo Fan report unavailable.
After reconnecting the WebSocket, all nine new-family fixtures reported available
with saved selections, and the suite returned to its former connected count.
All 13 subscription confirmations and snapshots succeeded. Both systems stayed
up throughout the run.

| Operation                 | Samples | p50, ms | p95, ms |
| ------------------------- | ------: | ------: | ------: |
| Transport connection      |       1 |     185 |     185 |
| HA authentication         |       1 |     167 |     167 |
| Subscription confirmation |      13 |     492 |     505 |
| Snapshot HTTP             |      13 |     233 |     317 |
| Snapshot through ready    |      13 |     571 |     735 |

The Coordinator used `C4:GetTickCount`, Latency Diagnostics On, Log Mode Off
and Log Level Info. The stages can overlap across endpoints. The snapshot
interval starts at queueing and ends after publishing confirmed state.

Seven command and restore pairs ran through Director on the same candidate.
Independent Home Assistant reads confirmed each change and restore, including
the blind's reported position, thermostat preset, and the Demo alarm's armed
and disarmed states. The nine Control4 fixtures also reported their restored
states after the transitions settled.

| Operation                         | Samples | Acceptance p50, ms | Acceptance p95, ms |
| --------------------------------- | ------: | -----------------: | -----------------: |
| Fan on and off                    |       2 |                 28 |                 31 |
| Blind position                    |       2 |                 34 |                 36 |
| Garage open and close             |       2 |                 31 |                 32 |
| Thermostat preset                 |       2 |                 20 |                 22 |
| Lock and unlock                   |       2 |               2021 |               2021 |
| Alarm arm home and disarm         |       2 |                 23 |                 26 |
| Media pause and play              |       2 |                 26 |                 26 |

Each reported percentile uses the nearest rank. The timing window covers
the Coordinator's HA service request and result. The independent state reads
establish confirmed feedback. The Demo fixtures exercise software responses.
Director also reported the alarm partition connected to two room security
inputs. The native partition accepted the Demo code. Navigator's presentation
of the applicable arm modes and the room selection workflow await the
installer's visual check.

## Installer and disposable project checks

1. On the running candidate, open a new driver and verify that Properties is
   the first tab. Use the Coordinator to preview one Demo device in a chosen
   room. Verify the displayed room, the saved selection and the same instance
   on reopening. Use a non-destructive preview if the fixture already exists.
1. Open the Garage Door Driver Information and Connections in Composer. Check
   the icon, hover warning and keypad connection labels. For stock relay and
   contact wiring, use a simulated door and check that each direction and both
   limits reach the intended binding.
1. In a lab room, verify Navigator shows the Demo alarm and the applicable arm
   modes and code prompt. Select an isolated room's Demo media player and
   verify the active source, volume path and Now Playing in Navigator. The
   Director readback found the media AV and room bindings available to connect.
1. In a disposable project, install the released Binary Sensor and
   Generic Sensor archives using their original names. Save representative
   settings, connections and Programming and record the initial state. Apply
   the candidate, verify retained IDs and behavior, then repeat with a
   supported explicit replacement and rollback. Use the exact identities in
   the [predecessor matrix](additional-driver-predecessors.md).

### Released sensor baseline on a disposable project

The first add after clearing the project used Director's previously loaded
sensor definitions. The package checksum confirmed the uploaded bytes, while
the running driver reported the newer version. After a verified package update,
fresh instances loaded the exact released Binary Sensor 102 and Generic Sensor
110. Their Coordinator links and original variable IDs were read directly from
Director. The Generic Sensor retained its configured temperature and unit
settings and read the Demo temperature independently confirmed in Home
Assistant.

The fresh Coordinator initially authenticated its WebSocket while its HTTPS
state reads failed before a transfer. A later build uses the explicitly
configured CA bundle for those reads. With the same endpoint, token and CA,
both subscriptions and both state snapshots passed. The required installer
Programming and post-upgrade regression checks are pending.
[DriverWorks URL options](https://control4.github.io/docs-driverworks-api/#setoption)

## Reboot qualification

Run the two reboots separately after setup, control and feedback work on the
same installed candidate. Before each run, record the connected drivers,
confirmed state, saved endpoints and bindings in the lab.

1. Restart lab Home Assistant while the controller stays up. Record the time from API
   availability to the Coordinator reconnecting and all selected endpoints
   syncing. Confirm that each fixture's state comes from fresh HA feedback. Send
   a normal command and verify its independent feedback.
1. Reboot the controller while Home Assistant stays up. Record the time from Director
   availability to connection and state sync. Change a lab fixture in HA while
   Director is down and verify that Control4 reports the new state after
   startup. Reopen setup to check the retained selections and room assignments.
   Confirm the first command and check for duplicate subscriptions, drivers or
   transition events.

Both runs must recover automatically on the controller. Record the outage, the time to
reconnect and the time until all selected endpoints report confirmed state. For
the first command, record service acceptance and confirmed feedback separately.
Include the clock and logging settings, then restore the lab fixture states
before signing off the wave.
