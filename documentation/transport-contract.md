# Coordinator/consumer contract

The shared implementation is `src/ha/hub.lua`, `consumer.lua`, `contract.lua`
and `codec.lua`. Family adapters use these modules rather than implementing
their own transport, binding inspection or JSON decoder. Template utilities own
targeted private sends, binding inspection, timers, promises and persistence.
This is a developer contract; the Light/Switch foundation entry points are not
yet wired to selections or load control.

## Version 1 selection boundary

`HA_SUITE_V1` carries a JSON `PAYLOAD`. A consumer sends:

```json
{
  "version": 1,
  "op": "select",
  "consumer": 54,
  "session": 1,
  "selection": 1,
  "entities": ["switch.lab"]
}
```

`consumer` is the protocol device ID. Both sides check the recorded endpoints
and connection class. Coordinator uses provider 1. Light uses input 999, and
Switch and the interim Light use input 1. The usual connection class is
`SKIALPINE_HA_SUITE_V1`. An upgraded Coordinator and Light can also use their
existing `HA_DEVICE` connection after both current drivers and their reciprocal
endpoints pass validation.

The consumer lifetime `session` is a monotonically increasing integer saved with
the template persistence helper. Each committed selection increments
`selection`. The Coordinator retains the highest pair for each consumer,
including after release, to reject delayed registrations from older lifetimes or
selections. Resetting or restoring persistent state requires coordinated
reload/re-registration; these counters are routing safeguards, not credentials.

Selections contain at most 16 unique exact entity IDs in the currently supported
`light`, `switch`, `event`, `select` and `number` domains. Duplicate, malformed,
unsupported-domain and non-array selections are rejected without replacing the
working selection. JSON null, object and array identities remain distinct.

`release` uses the same consumer/session/selection fields without `entities`. It
affects only that current owner. Changing a selection diffs memberships so
unchanged entities retain their shared resources.

## Shared evidence

Each selected entity has one scoped HA state-trigger subscription. Its
successful acknowledgment starts one coalesced exact REST read at
`/api/states/<entity>`. Additional consumers reuse both resources and their
confirmed snapshot. The read uses template HTTP with TLS verification, private
request logging, a body limit, a deadline and explicit redirect refusal. No
all-state fallback or healthy state polling occurs. Trigger subscription
permissions follow HA's documented
[WebSocket API](https://contributors.home-assistant.io/core/internals/websocket-api/#subscribe-to-a-trigger);
subscription refusal remains a separate failure from authentication.

The configured CA file must remain readable after a Coordinator reload. If its
path points inside the driver archive, the replacement and rollback archives
must both carry that trust resource. A missing file can cause the WebSocket to
retry while Home Assistant remains healthy. Check this dependency before
replacing a package in a project that uses a custom CA.

The Coordinator targets bound consumers with `version`, `coordinator`,
`session`, `selection`, `boot`, `epoch`, `kind` and `data`. The initial kinds
are:

| Kind        | Meaning                                                                         |
| ----------- | ------------------------------------------------------------------------------- |
| `snapshot`  | Selected state evidence for initialization; never a physical gesture occurrence |
| `state`     | Validated pushed state for the selected entity                                  |
| `readiness` | Separate transport, subscription, snapshot and entity-availability booleans     |
| `failure`   | A bounded local boundary/category, without raw HA errors                        |

Consumers check current binding, lifetime, selection, payload entity and payload
shape before delivery to their family adapter. A newer push wins over a REST
read already in flight. Transport changes invalidate old reads. Releasing one
consumer leaves other owners intact; the last release unsubscribes. A
subscription acknowledged after its final owner released is immediately
unsubscribed.

## Correlated operations

Consumers use the same shared contract for `service` and `prepare` requests.
Each request has a monotonically increasing request ID in addition to its
consumer lifetime and selection. Only selected entities may be targeted.
Supported load requests are exact Light/Switch power calls and validated Light
parameters; arbitrary services and target overrides are rejected. Preparation
calls the separately versioned companion's `prepare_device` service.

Service deadlines are ten seconds at the Coordinator and fifteen at the
consumer. Preparation has thirty/thirty-five-second deadlines because its
existing HA contract can await enrollment. A bounded targeted result reports
acceptance, rejection, timeout or transport failure. Acceptance never updates
confirmed state. Selection/lifetime changes retire outstanding requests; delayed
replies cannot affect their replacements. Replayed request IDs cannot execute
twice. Preparation replies must match their device, source registry/selected
entity and supported contract version before being delivered. Prepared input
readiness remains separate from confirmed load state.

## Readiness and bounded recovery

The shared readiness model keeps binding, authenticated transport, subscription,
fresh snapshot/entity availability and optional preparation separate.
Preparation can be denied while ordinary selected-load feedback remains healthy.
A removed entity invalidates its snapshot without calling HA disconnected.

Scoped subscription/read failures get at most three attempts, with one- and
two-second retry delays. Permission denial is not retried; a missing entity
waits for pushed evidence. An ambiguous subscription timeout retires the socket
so an unknown server-side subscription cannot leak into its replacement. Its
failure budget survives that reconnect, preventing a reconnect loop. Healthy
push cancels pending read recovery; no all-state/registry fallback exists. An
explicit selection or **Retry Selected Devices** action can retry failed scopes.
The first evidence after startup/reconnect/removal is a `snapshot`, including
when it arrives as a push before the HTTP read, so it cannot itself be
interpreted as a historical gesture occurrence.

The current state-trigger subscription path requires the HA user's documented
trigger-subscription permission (administrator). Authentication success alone
does not establish that permission. A refusal remains a subscription error.

## Reload and cleanup

The Coordinator's persisted `boot` counter identifies its driver lifetime; each
transport change increments `epoch`. A `selected` acknowledgement establishes
both before evidence is accepted. Older acknowledgements cannot move an epoch
backward. A targeted `reset` announcement on reload or binding change asks valid
bound consumers to re-register their existing selection; it never discovers,
adds or migrates drivers. If startup or an offline transport loses the
registration, the consumer tries the same exact registration at 2 seconds, then
after 5 and 10 more seconds. A live Coordinator can return cached evidence to
that one consumer without creating a subscription or read. Receiving online
readiness cancels the retry. A replacement Coordinator rebuilds only the
selected subscriptions.

Consumers check their current property/mode intent before inspecting incoming
routing data. Their family adapters supply cleanup callbacks for held outputs,
template Light work and watches. Cleanup runs every callback independently and
blocks reentrant selection/request creation while retiring. Failed timer
cancellation cannot restore authority: callback guards also check lifetime,
selection and current resource ownership. Final subscription release waits for
acknowledgement; ambiguous unsubscription retires the socket. The template
WebSocket cleanup tolerates a failed close send/timer operation and cannot clear
a replacement socket's binding callbacks.

Legacy project migration is a separate, explicitly requested user action.
Startup, discovery, rebinding and routine driver updates must never initiate it.

## Qualification

`test_ha_hub.lua` exercises the actual shared modules, wire codec, template
timers, promises and persistence with only Director/HA boundaries faked: 220
checks pass, including correlation, bounded recovery, independent readiness,
reloads, fresh baselines and failed cleanup of actual template Light work.
`test_ha_snapshot.lua` adds 47 selected-read/catalog HTTP checks; the template
HTTP policy tests pass 114 checks, and the connection and configuration tests
pass 77 and 16 checks respectively. The three packages build and pass package
inspection. The unit results use local protocol/Director shims. The built
Coordinator also passed real-HA service and catalog checks; native suite
bindings remain unqualified. The WebSocket suite passes 40 checks, including
close failure and obsolete-owner cleanup. Family-specific cleanup wiring will
also be exercised as those adapters are implemented.

## Built-package lab runner

The lab runner verifies the allowlisted environment and its Home Assistant
version. It uses dedicated lab credentials and resets only the test integration.
It runs `driver.lua` extracted from the exact Coordinator `.c4z` and excludes
the source runtime from the module path. The harness supplies Director
properties, bindings and network boundaries. Actual template WebSocket framing,
authentication, selected HTTP reads, Hub subscriptions and service correlation
execute from the package against real HA. The HTTP boundary forwards exact
fixture reads. The native setup rehearsal also forwards the fixed discovery
template. Each call verifies the lab identity.

The lab report records the package hash, HA version, logging configuration,
check names, service results and independently confirmed state observations. The
runner keeps credentials in memory and confirms changes with matching pushed
state.

Optional timings begin when Python writes a consumer request to the Lua process
and end when Python receives the packaged Coordinator's targeted result or
matching pushed-state delivery. They include local process scheduling/IPC,
shared Lua/template transport and real HA processing. They exclude physical
button and load latency. They do not qualify native Director behavior. The
report records sample count and the package's actual logging mode/level; logging
is not changed by enabling timing collection.

The quiet run passed 323 checks on HA 2026.11.1 with 152 service samples and
logging Off / 3 - Info. The report identifies the exact package. The native
setup rehearsal simulates only the missing helper service and uses real HA for
scoped discovery, registry lookup and selected state. The helper comparison
measures the same package before and after upgrading the helper. Selection and
reuse were measured separately.
