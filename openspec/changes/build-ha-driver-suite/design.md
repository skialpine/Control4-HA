# Design

## Context

See proposal.md for motivation and the eleven capability specifications for behavior. This is a new C4 project; the previous repositories remain reference implementations, not a framework to carry forward. The initial delivery is deliberately Coordinator, Light and Switch, followed by a user feedback pause. It is not GA of the full family roadmap.

Discovery inspected the Finite Labs template tree `5efdae849b32d8739d23e4750c0b6e4d60f754c9`, the upstream `bphillips09/Control4-HA-*` repositories, and the qualified prototype: Switch/Light `86441f1`, Coordinator `9102878`, separate HA source `c4f1648`. The original family inventory contains thirteen repositories: Coordinator, eleven device families and Base. Only Coordinator had a repository license file in that inventory; its Apache-2.0 license cannot be assumed to cover the others. The template carries AGPL-3.0 and additional per-file vendor notices.

The prototype has useful ownership, lifecycle, filtered-discovery and gesture/LED tests. It also demonstrated why normal feedback, native scene eligibility and Director updates need native qualification: local tests cannot prove those behaviors. Its current companion already supports light/switch/gesture choices; broader HA catalog work is unnecessary for the first milestone.

Use a dedicated HA Container on a Linux Docker host, with a dedicated HA OS VM as a fallback. Home Assistant's [Demo integration](https://www.home-assistant.io/integrations/demo/) covers all roadmap domains. Inspection of HA 2026.11.1's demo Light, Cover and Climate implementations confirmed service handlers and device-registry information; this does not establish complete transition, failure or hardware emulation.

## Goals / Non-Goals

**Goals:**

- Make the first three drivers usable in the new model early enough for feedback, with shared setup, richer native behavior and an isolated repeatable lab.
- Use the template as maintained infrastructure, and keep HA-specific decisions small and explicit.
- Retain installed Coordinator and Light identities while implementing their behavior with the template and shared suite modules. Existing users keep their project references through an update.
- Establish release, manuals, skill and Marketplace workstreams without waiting for unrelated families or optional migration automation.

**Non-Goals for this change's feedback milestone:**

- Porting Base and adding new device families are outside the first demo.
- Implement the other nine device families before Light/Switch feedback.
- Promise arbitrary Composer programming transfer, physical device conformance from simulation, or GA before its external publication gates.
- Move production HA code into the C4 repository or use production HA as a test target.

## Decisions

### 1. One C4 source project, separate HA integration

Proposed implementation layout:

```text
Control4-HA/
  drivers/coordinator/
  drivers/light/
  drivers/switch/
  src/ha/                  HA transport/contracts/selection/gestures/LED adapters
  src/lib/                 Template-owned libraries
  vendor/                  Selected template/vendor dependencies
  documentation/           Canonical manuals and feature matrices
  skills/control4-ha-setup/ Portable product setup skill and references
  lab/                     Isolated test environment seed data
  test/                    Template tests, adapter tests and contract fixtures
  tools/                   Template build tools and small project-specific tools
  openspec/
  dist/                    Generated release artifacts
```

Use one Copier project, pin the selected template revision and retain its update metadata. Template updates remain separately reviewable changes. Reference the inspected revision initially; qualify the chosen pin's APIs, teardown and adapter behavior before adopting it. Do not assume a moving `main` or the latest unexamined tag is equivalent.

Ship HA.Coordinator.c4z (HA Coordinator) and HA.Light.c4z (HA Light) under their predecessor identities. The Switch uses Control4.HA.Switch.c4z and its new proxy. Keep interim suite packages identifiable during development. Match existing endpoints without silently adopting, duplicating or converting a device. Preserve legacy Control4 variable, binding, proxy and event IDs as well as their meanings. Qualify version ordering against each starting version before publishing.

The separate HA repository keeps `custom_components/ha_gesture_bridge` and its existing stable HA identities. This change owns the C4 side of that versioned contract plus its manuals and fixtures. Any required HA runtime change or Marketplace submission must use a separately scoped change in that repository, not an incidental edit outside this project's OpenSpec root.

Alternative rejected: twelve independent template repositories or a copied Base loader. Both duplicate maintenance without giving the user a coherent suite release.

### 2. Reuse template ownership instead of layering a second framework

Use applicable template modules for lifecycle/dispatch, timers, persistence, logs/redaction, bindings, events, values, HTTP/WebSocket infrastructure, UI property helpers, companion deployment and GitHub updates. Select `light` and `ui`; include XML/deferred/version dependencies as required by their actual uses. Do not include expression, crypto, OAuth, cloud telemetry or commercial licensing layers merely because they exist. The public free build must not require DriverCentral licensing or remote telemetry.

The template's `src/lib/light` owns the native Light V2 surface: capability publication, presets/On modes, scenes, fades, colors, groups and native Button Links. HA-specific adapters supply transport facts, requests and actual reports. The old custom scene engine and native-light publisher are not ported. Shared prototype tests are translated into boundary expectations rather than used as a reason to keep old implementation structure.

Use `values`/`events` persistence conventions so a new release does not change programming identities after installation. Restore variables at the lifecycle stage required by the template. Teardown must retire transport work and adapter callbacks as well as library-owned timers; verify the pinned library's actual reset/lost/destruction contract and supply a reviewed template correction if needed. A reset that starts another refresh is not destruction.

### 3. Coordinator owns HA transport and shared discovery

```text
HA test or user instance
       |
       | authenticated WebSocket; scoped REST only where needed
       v
Coordinator -- validated targeted state/results --> Light / Switch
       ^                                         |
       +--------- exact subscriptions/services ---+

Light connected-C4 adapter <--> selected native C4 target
```

One Coordinator group owns one authenticated connection, selected-entity subscription membership, read coalescing and one revision-checked catalog. Consumers register their exact selections and linked endpoints; release one consumer without disrupting others. Correlate commands, snapshots and preparation with both consumer selection and Coordinator lifetime. Validate the consumer's binding/ownership rather than trusting an arbitrary requested device ID.

Use the suite protocol across the upgraded suite. Qualify Coordinator and Light upgrades and the explicit Switch migration from both predecessor projects through one suite cutover. Preserve the installed project identities and settings described below, including the Coordinator's retained Device Link and saved programming. A partly updated suite is an installation or recovery state. Test its recovery to a single revision before normal operation resumes.

HA service acceptance is request progress, not physical confirmation. Results and failures return to the initiating consumer; states update from HA evidence. Separate transport, subscription, selected entity and companion status. Avoid the prototype's misleading global "HA disconnected" diagnosis when only preparation or a subscription is unready.

Never retrieve all states or full registries because a scoped request failed. Missing companion permits filtered native discovery; a present but failing companion yields its real error. No healthy-state polling loop. Limited initial/recovery reads use exact IDs and are canceled on identity/lifetime changes.

### 4. Common setup with family-specific facts

Keep the existing useful flow: search physical devices/endpoints, commit a choice, prepare optional gestures/LEDs on demand, subscribe to resolved identities, and verify fresh state. No entities/listeners/parameters are created by browsing. Reuse one Coordinator catalog across instances, with revision checks rather than independent short-lived caches.

Basic configuration presents Device Setup, Selected Device, status, capabilities and meaningful operating settings. The picker offers manual device entry. Native Properties shows all applicable settings directly. Detailed readiness, binding identities and logging also have a troubleshooting route. Use the template UI helpers and standard property conventions; retain a usable classic Properties surface and protect credentials. Skip unchanged read-only display writes without deferring native feedback.

Physical device equivalence is not whole-device equivalence. Collapse a proven relay/gesture/wrapper alias of one endpoint, but preserve independent endpoints and different functions. Exclude C4-exported devices, configuration/diagnostic entities and inappropriate helpers from normal lists. An explicit manual entity path in the picker remains available for supported exceptional targets.

Initial mode selection uses actual capabilities and C4 bindings; explicit user choices then win across restart. Keep direct HA, HA load plus buttons, gesture-only and connected-C4 uses understandable without requiring the user to choose an internal gesture entity.

### 5. Initial native feature contracts

| Driver | Initial feature work and qualification |
| --- | --- |
| Coordinator | Shared scoped push connection, result correlation, coherent readiness, shared picker, selected commissioning, diagnostics and coordinated updates |
| Light | Binary/dimmable/full-color/CCT HA loads; native scenes/groups/presets/On modes/rates; app and programming feedback; connected ordinary C4 lights/groups; declared gesture identities; supported independent LED controls |
| Switch | General-purpose relay and usable Navigator on/off presentation; native state commands/events/conditions/variables and relay/Button Links; optional gestures/LEDs without claiming dimming |

Light uses the template's profile/device/report/adapter contract. Native HA color/CCT is new relative to the prototype's direct-load limitations: map supported HA color modes and Kelvin/xy/RGB conversions explicitly, including color while off and transition capability. Advertise only verified behavior. Use the library's tested stepping mechanism where an HA endpoint lacks native transition semantics; do not invent a second fade/stop engine.

Connected-C4 mode is another adapter, with watched target feedback and explicit App Control Link. Logical On must remain distinguishable from an explicit numeric level so target nighttime presets survive. Before porting, prove the template adapter contract carries that distinction; if it does not, add a narrow, tested upstream-compatible intent field rather than guess from matching numbers. Preserve Color Agent versus device-local preset ownership. Native target app control remains independent of HA gesture transport health.

Switch needs an actual Navigator surface: an invisible `other` relay alone does not satisfy it. Use the documented UI Button/experience surface with explicit confirmed On/Off/Unavailable presentation alongside relay/control bindings; validate SELECT, state icons and programming behavior in native C4. A switch used for lighting instead belongs in Light's binary mode. Avoid installing a duplicate Light instance merely to expose a fireplace switch.

Baseline the shipped BP Coordinator, original BP Light project and BP Switch, plus the Coordinator, Switch/Light and HA helper prototype revisions. Inventory public XML, Lua dispatch, persistence, companion requests and actual behavior. Track source version, test and evidence for each capability. All supported behavior from either baseline is required for the first demo. Escalate conflicting observable behaviors for a decision and cover each supported starting configuration. A package rename or a green proxy shim cannot establish native upgrade parity.

### 6. Testing and isolated Home Assistant

Use a dedicated HA Container for initial real-service testing. Verify host capacity and assign a unique container, config volume and reachable endpoint. Keep the lab isolated from production configuration, credentials, host networking and devices. If the host cannot support a container, check available compute, storage and network resources before assigning a dedicated HA OS VM.

Container testing does not qualify the HA OS app/Supervisor experience. Use an isolated MQTT container only if required by simulation. Record OS/app-specific installation and Marketplace checks as unverified until a suitable HA OS lab is available; do not narrow the GA publication gate or report those checks complete based on Container evidence.

Record HA OS image, HA Core, separate integration and simulator versions. Support a seed/reset and backup/restore path. Use unique endpoint, HA identity and credentials; no production backup restore, radio passthrough, production MQTT, real-device pairing or automatic production HA discovery setup. Test runners require an explicit allowlisted lab identity, not a default URL/token. Ensure the C4 test controller can reach the lab endpoint; localhost-only containers do not satisfy that path.

Layer tests by what they prove:

| Layer | Mechanism | Evidence and limits |
| --- | --- | --- |
| Fast logic | Template and project Lua/LuaJIT tests, fake clocks | Validation, selection, scenes/On modes, cancellation, bounds; no physical timing |
| Packaged C4 contracts | Actual built drivers with only C4 boundaries faked | Native command/notification sequences, lifecycle and package dependencies |
| Real HA integration | Dedicated VM, real services/subscriptions, separate companion | Command/result/state round trips and actual entity/device registry behavior |
| Controlled simulation | Demo entities first; MQTT discovery plus simulator for missing behaviors | Binary/dim/RGB/CCT, delay/out-of-order, unavailability, gestures, LED metadata/palette; not radio conformance |
| Native C4 | Test project/controller and explicit smoke checklist | Navigator, Composer programming/ALS, variable IDs, binding roles and Director update/restart stability |
| Physical subset | Available representative devices only | Device classification, radio LED parameters, real fades and physical latency |

Do not build a wholesale HA emulator. Demo platforms have real service handlers, but some do not implement actual timed fades, failures or all metadata combinations. Supplement only those gaps with controlled test-owned entities or an isolated MQTT simulator; merely setting HA states is insufficient proof that a service works. Test fixtures live under the lab/test tree and never ship as the production companion or C4 package payload.

Initial scenarios include direct binary/dimmer/RGB/CCT, switch-as-light, general-purpose relay, connected-C4 target presets, scene membership/execution, multiple buttons, LED behavior/color independence, two consumers, restarts, stale replies, lost subscription, denied preparation, invalid owned/foreign messages and update interruption. Extend the source/readiness tests already proven by the prototype. Test the HA minimum and supported current version; do not infer compatibility from `dev` source alone.

Prefer a separate C4 test controller where available. Do not represent another project on a live Director as complete controller isolation. Any production C4 installation/update test requires a separately approved backup and test window. No HA lab credentials or raw household project/programming dumps are committed.

### 7. Automatic updates and deployment

The installer initially loads the suite packages from one release in the same Composer session using Add or Update Driver, verifies that all installed instances run that revision, and enables automatic updates once on the Coordinator. Use the template OSS GitHub updater's supported capabilities and shared Production/Pre-release settings. Production is the default. Both channels install eligible updates automatically after enablement. The Coordinator owns the only update setting, channel and status. Update the exact suite package files installed on the controller, including unbound instances, from one release. Elect one owner when multiple suite Coordinators exist because installed files are controller-wide. Keep the free release independent of commercial licensing and cloud services.

Publish all suite packages with a coherent manifest. One operation stages and verifies the complete required set before the first installation write, then applies that set under a single controller-wide owner. Director may acknowledge reloads in sequence inside that operation, with Coordinator last if the installer needs it to maintain the operation. Persist the target and recovery record across its reload. Verify the running revision of every affected instance after reload. Close an interruption by finishing the same qualified release or restoring the previous working set. A failure must not create a rapid reload loop or report success while revisions differ.

Use Finite Labs’ pinned OSS archive writer and Director reload transport.
The Coordinator supplies the exact verified archive bytes, elects its owner
from the installed instances and saves the archive hashes and original files
in the owner's sandbox before its first replacement. The template transport
uses file access and a Director operation outside the published DriverWorks
file and update contracts. Qualify its permissions, staged archive survival
and running-version readback on the supported controller OS before handoff.
Keep automatic updates off by default. If an update is incomplete after a
restart, check the saved files first. The installer can retry the same batch
with **Check for driver updates** while automatic updates are enabled. A
Coordinator configured to use certificate files stored in its own package
requires an installer-managed update that preserves those files.
[Finite Labs template updater](https://github.com/finitelabs/control4-driver-template/blob/v0.9.117/template/src/lib/github-updater.lua)

Use Group Lighting's committed YYYYMMDDRR revision for every package and release tag, with the template's numeric version comparison. Qualify channel changes, prerelease promotion and same-day version behavior; do not silently downgrade a newer prerelease when Production is selected. Only installed drivers update. User-initiated selective commissioning uses the template companion deployment library for room/name/binding work and rerun handling; device creation is not an unattended startup or upgrade side effect.

### 8. In-place updates and requested migration

Rehearse same-instance Coordinator and Light updates from each baseline as part of the same suite cutover that verifies Switch migration. Snapshot nondefault properties, rooms, names, selections, secure credential presence, bound peers, agents, scenes, program references and variable/event IDs. Verify lookups, actual control and rollback on the original instance after reload. Treat manufacturer-only evidence as a separate test.

Start migration from the expanded **Migrate switch drivers** section at the top of the Coordinator's Quick Setup page. It appears only when this Coordinator has older switch drivers to review or saved migration or removal work. The wizard identifies each older driver by name, room and Home Assistant device. Give blocked rows a specific reason and next step. Provide a single review with the selected rows, planned changes and backup confirmation. Put detailed connection and programming information behind a disclosure. Keep the Home Assistant device list and any in-progress selections available below the migration section.

Before creating a replacement, ask the installer to acknowledge where to return if Composer selects the new driver. For migrations that need programming edits, verify the original and replacement identities and give them their final display names before showing the worklist. Name the old driver that still controls the load and give the exact command and room for the replacement. Persist intent before either rename so an interruption can resume without transferring control or repeating the add.

After **Start migration**, use the existing template-based deployment path to add or reuse one replacement in each original room. Prepare its saved Home Assistant selection and verify its Coordinator and installed release. Check all conditions needed for single-owner cutover before changing the original. Transfer supported bindings by semantic role and verify them on both ends. Preserve the original settings and a recovery checkpoint. Show progress per switch with a specific manual step only where an API cannot safely complete it. Verify affected programming and scene references before retiring the original. A blocked row keeps its existing control while other eligible rows proceed.

Migration starts only when the user requests it. Preview, confirm, stage, verify and cut over with one active owner. Support cancellation, interrupted resume and rollback from a restorable backup. Complete and verify required manual mappings with the installer before reporting success. Rehearse the cutover and rollback from each pinned Switch baseline. All suite destinations must run the selected release at successful cutover. Use a user-requested migration for BP Home Assistant Thermostat when that family enters scope. The verified source is `HA.Thermostat.c4z` revision 108 from release v1.0.8, model `HA Thermostat`, with a `thermostatV2` proxy on binding 5001. Qualify any additional source revisions individually. Default the remaining families to an in-place design and prove each independently when scheduled.

### 9. Manuals, AI skill and public release gates

Keep canonical manuals in the C4 repository, with versioned links to the separate HA integration's own installation/release docs. Provide pilot quick start, homeowner/installer roles, property/binding reference, direct/connected examples, migration, diagnostics, updates and rollback. Explain custom integration versus HA OS app/add-on, and use the current HA 2026.11 Marketplace path rather than instructions to install old HACS first.

The portable product skill lives separately from generated development/OpenSpec skills. It references those manuals, declares supported assistant/HA connector setup and inspects the target before acting. It can configure supported HA components within authorization and guide exact C4 steps; it cannot claim to perform a Composer task without a supported connected mechanism. Test its fresh/existing/failure/installer-handoff scenarios in the lab.

Marketplace acceptance is a later GA gate, not a prerequisite for the initial feedback prerelease. The separate HA workstream must pass current validation, publish its qualified release, submit for catalog inclusion, obtain acceptance and verify fresh listing-based installation/update in the lab. A repository link or pending submission is not an accepted listing. External review timing cannot be guaranteed. Record the actual release compatibility pair and deliver complete manuals before GA.

### 10. Follow-up family roadmap after feedback

Use the corresponding BP `Control4-HA-*` repository and its released driver to identify installer and homeowner tasks for each follow-up family. The [provenance inventory](../../../provenance/sources.json) pins all 13 BP repositories, including the initial Coordinator, Light and Switch and the shared Base reference. Apply the same common setup and feature-matrix standards to the nine follow-up families after feedback on the initial drivers. Check reuse terms before taking any source code.

| Family | Native C4 expansion to assess against supported HA behavior |
| --- | --- |
| Thermostat | HVAC action/modes, single/dual setpoints, units/precision, fan/swing/presets, holds/schedules and remote sensor bindings |
| Fan | Discrete/percentage speeds and thresholds, presets, direction/oscillation, programming and Button Links |
| Lock | Native lock state/presentation, code handling, supported open/jammed states and events/conditions |
| Blinds | Open/close/stop, position/tilt, direction and movement/availability feedback |
| Garage Door | Door/relay/contact presentation, bindings, movement and supported stop behavior |
| Alarm Panel | Modes/codes, pending/triggered/delay feedback, partitions and explicit sensor-zone associations |
| Media Player | Transport, volume/mute, metadata/artwork/progress, source/app launching, mini-apps, queues and AV routing |
| Binary Sensor | Device-class bindings, native companions, breach/reset programming and optional notifications without startup replay |
| Generic Sensor | Typed values/units, native sensor bindings, availability and thresholds without unknown-to-zero conversion |

Chowmain's published [feature announcements](https://www.c4forums.com/forums/topic/44955-chowmain-home-assistant-driver/) inform feature selection, not source reuse or a claim of parity. Selective commissioning, configurable fans, sensor notifications, apps and alarm detail belong in the appropriate implementation/roadmap scope. Do not introduce all-family registry scans to make a future feature easier.

## Risks / Trade-offs

- **Template API/lifecycle gaps** -> Prove adapter intent, destruction and proxy conformance against the selected pin before porting; use narrow audited template corrections rather than layering a second engine.
- **Director update crashes** -> Test actual teardown/reload and child/self update ordering, preserve recovery artifacts, and require real Director evidence before GA; simulated TCP success is insufficient.
- **Demo coverage mistaken for hardware coverage** -> Maintain explicit evidence tiers and supplement only identified simulator gaps. Lack of physical devices does not justify false conformance claims.
- **Production contamination** -> Verify distinct HA identity/credentials, reject unintended test targets and require explicit separate C4 test authorization.
- **Existing project references** → Compare saved identity and behavior before and after each upgrade and after restoring the backup.
- **Unclear upstream reuse rights** -> Inventory provenance, obtain permission or independently author replacements before public copied-code distribution; retain all required notices.
- **Two repository releases and external catalog timing** -> Version contracts, qualify the exact pair, track separate HA deliverables and keep Marketplace acceptance as a visible GA gate.
- **Scope expansion before feedback** -> Stop after the three initial drivers and lab/handoff; put other families and unproven migration automation in follow-up changes.

## Migration Plan

1. Build and qualify the new packages against the isolated HA lab; leave existing production configuration untouched.
2. Publish a clearly labeled initial feedback candidate with hashes, compatibility and the manual/assessment. Public source distribution first satisfies provenance checks.
3. On the backed-up isolated project, update each existing Coordinator and Light in place. Separately run the requested Switch migration, including cancellation and recovery. Exercise original children, partially updated projects and a clean install.
4. Verify native UI/programming/scenes/gestures and record the actual evidence tier. Keep originals available for rollback until verification is complete.
5. Offer the three-driver feedback candidate only after the section 0 and 11.4 gates pass. Further driver families and GA publication have separate scope. A migration cutover always requires an explicit user action.

## Deferrable Configuration Inputs

Use a Docker host designated for the isolated lab. Obtain Docker endpoint/container/volume/port identity and capacity before Container provisioning, or storage/network/VM identity before the 2 GiB HA OS fallback, plus an approved native C4 test controller/window before native tests. Final display branding can be chosen before package identity freeze. No infrastructure, controller or public release was changed while authoring this proposal.

## Reference Sources

- [Finite Labs template](https://github.com/finitelabs/control4-driver-template), particularly Light `types.lua`, companion deployment, GitHub updater and Copier build/release files.
- [Original family repositories](https://github.com/bphillips09?tab=repositories), credited individually in the eventual provenance inventory.
- [HA Demo](https://www.home-assistant.io/integrations/demo/) and the `2026.11.1` Demo source for service/registry behavior.
- [HA OS VM/Container installation](https://www.home-assistant.io/installation/alternative/).
- [Marketplace integration publishing](https://contributors.home-assistant.io/marketplace/guides/integrations/) and its current catalog inclusion/validation references.
- [Native UI Button protocol](https://snap-one.github.io/docs-driverworks-proxyprotocol-uibutton/) and [DriverWorks APIs](https://snap-one.github.io/docs-driverworks-api/) for native presentation, deployment/bindings and read-only programming inspection.

### Qualifying the current packages before feedback

Keep the Light V2 native editor available for brightness behavior, keypad presets, transition and click/hold rates. Device Setup configures the LEDs on the selected Home Assistant wall device through verified companion capabilities. Show applicable native Properties directly. The optional manual identity lives in the device picker. Troubleshooting contains diagnostic details. Let the installed Composer version determine the placement of its native proxy editor and record the observed route.

Test the complete path from the shipped HTML request through packaged Lua, Coordinator, Home Assistant and the correlated reply. Exercise reload using Director storage types on existing device identities. Run read-only Director checks on the installed candidate and independent end-user task walkthroughs before asking for a narrowly defined native observation. Tie evidence to exact archive hashes, versions, fixture capabilities and outcomes. An advertised command or visible field alone cannot establish that an installer can edit and use it.
