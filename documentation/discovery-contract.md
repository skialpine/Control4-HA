# Shared discovery contract

`src/ha/catalog.lua` owns one runtime dataset per Coordinator. Its consumers
share the existing private transport, binding validation, lifetime/selection
correlation and template promises. Family drivers never persist their own copy.
Opening instances and reconnecting do not run discovery. An explicit picker
request registers an empty selection when unconfigured and requests operation
`catalog` with an empty arguments object. This is read-only browsing, never
legacy migration or device deployment.

Concurrent first-page requests share one operation. Later openings verify the
stored companion revision; unchanged responses reuse the same dataset rather
than download its rows again. New data publishes atomically only after every
page validates. A failed refresh retains the last complete dataset and returns
its actual error; it does not report old metadata as a successful refresh.
Reconnect invalidates verification and rejects prior-generation callbacks.

## Companion and native boundaries

The optional HA Gesture Bridge companion exposes the version 1
`ha_gesture_bridge.get_devices` service. Each response includes a SHA-256
revision, page, page count, total and unchanged flag. Subsequent pages must
retain the same revision, counts and eligibility version. Physical
`device_choice` IDs and native group entity IDs are picker metadata. Browsing
never prepares gestures or attaches inputs. The companion owns physical endpoint
relationships and their schema.

Only HA's `not_found` result for the requested companion service permits native
discovery. Permission rejection, an unsupported version, timeout, malformed data
or an inner service failure remains an actionable catalog error. HA
distinguishes these cases in its
[service WebSocket handler](https://github.com/home-assistant/core/blob/2026.11.1/homeassistant/components/websocket_api/commands.py).
No failure causes an all-state or full-registry download.

Native discovery uses the fixed `src/ha/native-catalog.lua` projection through
HA's
[read-only template endpoint](https://contributors.home-assistant.io/core/internals/rest-api/#post-apitemplate).
The projection enumerates only `light` and `switch`, returning identity,
name/area/device and allowlisted capability metadata. Caller strings never
become template code. Live levels, arbitrary attributes and event payloads are
omitted. It shares the connection's template HTTP helper, TLS/redirect policy,
private logging and generation checks. Both this endpoint and the companion
picker require their HA administrative permissions; authentication alone does
not establish catalog access.

The native metadata snapshot receives a content hash after stable entity-ID
ordering. HA's native endpoint offers no revision-only confirmation, so explicit
subsequent openings repeat this scoped projection, with concurrent reads still
coalesced. This does not poll during healthy control.

## Bounded consumer pages

Initial arguments may supply a known `revision`; cursor requests require that
revision and a following `cursor` greater than one. The Coordinator validates
arguments before any HA operation. A first-page request refreshes/verifies the
shared catalog. Following cursor requests read that verified snapshot without
another HA call. A changed revision rejects the cursor rather than mixing data.

The targeted correlated result has status `catalog` and a `catalog` object:
`source`, `revision`, `total`, `cursor`, `next_cursor` and `entities`.
`next_cursor` is explicit JSON null after the last page. Pages contain at most
50 records and a 16 KiB payload budget; records cannot be silently truncated.
Transfers are limited to 5,000 rows, 64 companion pages and 1 MiB of projected
records. Duplicate IDs, missing pages/records, inconsistent revisions, invalid
shapes and oversized rows fail. Data does not become load state or programming
occurrences, and it never authorizes a target by name.

## Qualification and remaining work

The shared Hub/Consumer tests cover two unconfigured consumers, coalescing,
revision-only reuse, changed revisions, paged reads, permission failures,
confirmed companion absence, filtered failures, duplicates, unsupported
versions, timeouts, release and transport invalidation. The native template was
also exercised against real HA 2026.11.1: its 11 scoped rows included all three
controlled lab loads without live brightness attributes.

The built Coordinator passed companion retrieval and revision confirmation
against that lab. The exact package hash and catalog summary are recorded in
`lab/transport-evidence.json`.

The packaged native setup run selected the controlled Light and Switch fixtures
by name and confirmed their initial states. The harness simulated only the
companion discovery service's `not_found` reply. The packaged POST template,
exact registry requests, subscriptions and selected REST reads used real HA. The
installed helper stayed in place and the runner sent no fixture commands. See
`lab/native-setup-evidence.json` for the package hash, timings and results.

Light and Switch share the same Device Setup tab. See the selection and recovery
steps in [Choose a device](device-setup.md).

## Eligibility and exact aliases

The version 1 helper eligibility projection advertises `eligibility_version: 1`
on every response, including revision confirmations. The helper excludes
disabled, hidden, configuration/diagnostic and C4-exported endpoints before
hashing its device list. The Coordinator validates descriptors and derives
family eligibility from their capabilities. An unchanged confirmation can reuse
the same pool and indices with one request.

For native discovery and companion responses with a missing or unknown
eligibility version, the shared `src/ha/choices.lua` policy reads registry
metadata only for catalog endpoints, in batches of at most 50 exact IDs. Missing
or foreign response IDs fail the scoped read. Device-less helpers stay on the
advanced manual path. Native groups remain independent supported endpoints. The
native projection checks integration and device ownership before returning its
small C4-export flag.

Light offers binary switches/lights, dimmers and remote choices. Switch offers
binary targets and remote choices; dimming-only endpoints remain in Light.
Multiple independent endpoints on one device and equally named entries remain
separate. Only a verified non-inverted switch-as-light registry link can
collapse native aliases, and it never collapses a group or an inverted
relationship. Physical choices from the companion retain their independently
identified source endpoints; a separately linked controlled load never proves
equivalence.

The Coordinator retains one record pool with small family index lists. With an
older helper, each explicit opening rechecks scoped eligibility even if the
descriptors are unchanged. With version 1 eligibility, a registry edit that
changes picker choices changes the upstream revision. The Coordinator keeps that
upstream revision separate from its public revision, which incorporates the
eligibility contract and the family projection. An eligibility version change
requests fresh descriptors even when the upstream hash matches. Browsing uses an
explicit request and creates no consumer cache, polling or preparation side
effects.

The pure policy suite passes 25 checks and its catalog integration passes 32.
The latter covers the versioned projection, unchanged confirmation, mixed
versions, unknown versions, the legacy registry path and the native fallback.
The previously packaged real-HA checks verified family eligibility through the
legacy registry path. The same packaged Coordinator was then tested on HA
2026.11.1 with helper 0.1.2 and 0.1.3. Ten warm opens needed ten registry
requests with 0.1.2 and zero with 0.1.3. Median request-to-list time was 6.87 ms
and 3.21 ms respectively with logging and instrumentation off. These are
DriverWorks shim measurements. See `lab/companion-catalog-evidence.json` for the
raw samples and package hash.
