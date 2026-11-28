# Design

## Context

See [proposal.md](proposal.md) for the scope. The current suite has one Coordinator,
one Light adapter and one Switch adapter. `device-driver.lua`, `setup.lua`,
`selection.lua` and the catalog/commissioning paths already share lifecycle and
selection behavior, with several Light/Switch-specific branches. The Coordinator
owns endpoint subscriptions, exact reads, correlation and reconnect. The
installed-suite and release checks currently enumerate the three initial packages.

The project has pinned BP source revisions, cached predecessor XML and mixed
project protocol tests. The tests record state and action envelopes for all nine
families, but do not qualify new native surfaces or upgrades. The recorded
source baselines are Binary Sensor 102, Generic Sensor 110, Fan 104 including
the alternate nine-speed package identity, Blinds 102, Garage Door 101,
Thermostat 108, Lock 102, Alarm Panel 102 and Media Player 102. Exact package
comparisons remain necessary, especially where the recorded Fan and Alarm Panel
evidence used source. BP licensing evidence for these families is unresolved in
the pinned inventory. [Predecessor contracts](../../../documentation/compatibility.md#existing-bp-children-on-the-updated-coordinator) · [Source inventory](../../../provenance/sources.json)

The template is pinned to Finite Labs v0.9.119 with `light` and `ui` enabled.
Its general example supplies lifecycle and packaging patterns. Example Light
shows how a template library owns the native surface while the adapter supplies
device facts. The pin contains no equivalent dedicated library for the new native
families. [Template reuse](../../../documentation/template-reuse.md)

## Goals / Non-Goals

**Goals**

- Teach existing shared modules about new families where two or more families
  have the same need. Keep device-specific interpretation and native proxy
  commands in small adapters.
- Preserve selection identity, confirmed feedback, stable Control4 programming
  surfaces and familiar setup. Improve the native experience using capabilities
  each endpoint actually reports.
- Support ordinary setup and operation across Home Assistant providers through
  standard APIs. Make targeted Bridge enhancements independently versioned.

**Non-Goals**

- Provide a new installable Base driver, a second transport stack or a universal
  native proxy engine.
- Require the Bridge for the nine families' standard behavior, implement vendor
  quirks without an identified user task, or expand the Bridge into an arbitrary
  service proxy.
- Change the existing suite's Control4 platform baseline, publish the HA
  integration to Marketplace or deploy new drivers to production in this change.

## Decisions

### 1. Extend the existing driver pattern

Start each new driver from the closest pinned template example and wire it
through the current shared lifecycle. Prefer the template's helpers for
bindings, events, values, persistence, logging, timers, Composer UI and package
assembly. Keep per-family differences in small descriptors and adapters in
`src/ha`. Use the first read-only and command-capable adapters to identify useful
shared seams, and move existing Light/Switch logic only where the same behavior
applies. Keep the Light library as the owner of Light's native behavior and
retain the existing adapters' public contracts.

Keep known package identity and family selection metadata together using the
existing identity and selection modules. Extend the shared catalog, Device Setup,
Quick Setup, owner validation and runtime inspection from that inventory where
practical. Keep explicit versioned manifests and package allowlists. Validate
that release tools and the Coordinator agree on shipped families and installed
bindings. An unverified file name does not authorize project writes.

The Coordinator carries the standalone archives for the families Quick Setup
can create. An approved Create action installs a missing file from the
Coordinator package before asking Director to add the device. Existing archives
and project devices stay on the established suite update path. Package
verification compares each bundled archive with the corresponding standalone
file.

Every released family enters through the same Coordinator Quick Setup. Extend
the existing selection and commissioning paths so a type change refreshes
eligible endpoints and preserves prior edits. Reuse the Light/Switch room
default: a single case-insensitive, trimmed match between HA area and Control4
room name. Leave missing and ambiguous matches for the installer. Verify the
preview and revalidate the approved room and endpoint before adding. Use the
existing saved progress records to verify room, Coordinator binding and
selection and recover after an interrupted add. Reusing a configured instance
keeps its existing room, settings and bindings.

Separate repositories would repeat lifecycle and release code. A new base class
or generic proxy engine would force unlike native protocols through a larger
abstraction and risk regressions in Light/Switch.

### 2. Use standard Home Assistant capabilities first

Extend the existing exact-target state and service paths with typed family
operations and bounded attribute projections. Begin with the supported
Home Assistant state, entity/registry metadata and domain actions. Use advertised
features, reported state and integration behavior to decide what to show.
Request filtered domains through the existing native discovery path and keep
breadth, paging and freshness checks at the Coordinator. Browsing never enrolls
a provider or invokes a device action. Keep separate identities for independent
functions on one physical device, and preserve explicit selections across
refreshes and reconnects.

Do not introduce a parallel set of service calls for ordinary controls. HA
service acceptance, reported device state and physical verification remain
separate. Bound service payloads, validate the selected target and parameters,
and preserve the suite's unavailable and reconnect behavior. Transition examples
include a cover still moving, a lock jam and temperature feedback that arrives
after the service result. [Home Assistant WebSocket API](https://contributors.home-assistant.io/core/internals/websocket-api/)

### 3. Improve native Control4 behavior by family

The opportunity column identifies concrete installer or homeowner tasks to
qualify. A task enters the shipped feature matrix when the required HA feature,
the native C4 surface and its feedback have been demonstrated.

| Family | Existing reference and standard HA route | Control4 opportunity |
| --- | --- | --- |
| Binary Sensor 102 | Contact connection and binary state. Use standard state and device class. | Give contact, occupancy and other tested roles clear labels and useful state-change Programming. Preserve polarity and separate signal loss from clear/closed. |
| Generic Sensor 110 | Value, units, sensor type and temperature/humidity value connections. Use standard state, unit and device class. | Discover sensible sensor type defaults, publish typed values and make temperature/humidity routable to supported native consumers. Preserve explicit unit fallback. |
| Fan 104 | Native fan and button links, plus original speed variants. Use power, percentage and reported speed steps. | Present binary and stepped controls honestly. Preserve keypad control and qualify optional direction, oscillation and presets where the C4 surface supports them. |
| Blinds 102 | Blind and keypad connections. Standard cover features support movement, stop, position and tilt. | Separate lift and tilt, retain keypad support and allow native setting of positions where both ends support it. |
| Garage Door 101 | Existing relay, open/closed contacts and keypad roles. Standard cover state and explicit open/close. | Show moving, confirmed endpoint and lost feedback separately. Verify which native connections can share the selected HA endpoint and preserve required relay behavior. |
| Thermostat 108 | ThermostatV2, native room selection, optional mode selection and a clear-hold target. Use standard HVAC modes, actions, setpoints, fan modes, presets and humidity features. | Qualify single and dual setpoints, meaningful active HVAC state and native schedule/hold workflows. Prefer standard climate features for a preset and use a selected helper only when that behavior is genuinely separate. |
| Lock 102 | Native Lock proxy and original code setting. Use lock actions and the standard reported states. | Preserve native lock controls and expose reported transition/jam and verified low-battery feedback only when available. Keep local controls and HA credential handling tied to the selected lock. |
| Alarm Panel 102 | Security panel and partition proxies with room selection. Use standard supported arm/disarm modes and code policy. | Use the existing native keypad/partition workflow and accurately show reported arming, armed and triggered states. Qualify code entry and supported modes without exposing codes. |
| Media Player 102 | MediaService, AV outputs and room endpoint. Use reported media transport, metadata and volume capabilities. | Verify native room routing, now-playing feedback and transport. Add supported source selection or browse where the native path maps cleanly. Use a verified artwork path. |

Standard state and feature details are covered by the contributor references.
[Binary Sensor](https://contributors.home-assistant.io/core/entities/binary-sensor/) · [Sensor](https://contributors.home-assistant.io/core/entities/sensor/) · [Fan](https://contributors.home-assistant.io/core/entities/fan/) · [Cover](https://contributors.home-assistant.io/core/entities/cover/) · [Climate](https://contributors.home-assistant.io/core/entities/climate/) · [Lock](https://contributors.home-assistant.io/core/entities/lock/) · [Alarm Panel](https://contributors.home-assistant.io/core/entities/alarm-control-panel/) · [Media Player](https://contributors.home-assistant.io/core/entities/media-player/)

### 4. Carry forward Light and Switch product behavior

Use the Light and Switch specs and setup manual as the common task baseline.
Record each task as a shared requirement, a qualified family equivalent or
inapplicable with the reason. Apply this alongside the predecessor task matrix.

| Existing task | Requirement for additional families |
| --- | --- |
| Open the driver and choose an HA endpoint | Properties appears first. Device Setup shows the selected device, controlled target and current status. Quick Setup handles first-time creation from the Coordinator for every released type. |
| Configure the driver with minimal input | Use proven HA capabilities and valid C4 bindings to choose defaults. Retain manual bindings and overrides. Ask for a room or an optional secondary endpoint only when inference is uncertain. |
| Find an action or state in Control4 Programming | Provide the family's supported native commands, events, conditions and typed variables. Verify readback, rollback and restart without replaying old presses or state transitions. |
| Use a native binding or a supported physical keypad | Qualify family-specific links, relays, sensors or room endpoints, with a named control target and separate input/feedback where relevant. Review applicable buttons, gestures and indicator behavior through existing contracts. |
| Recover from a failed connection, stale list or setup denial | Use shared status, actionable recovery, Log Mode/Level and opt-in timing. Preserve selections and drafts through recovery. |
| Use an advanced native feature | Check for a useful family equivalent and verify it on the actual native surface. Examples include fan speed levels, independent blind lift and tilt, dual thermostat setpoints and media routing. |

[Light and Switch Device Setup](../../../documentation/device-setup.md) ·
[Shared Quick Setup requirements](../build-ha-driver-suite/specs/device-setup/spec.md)

### 5. Extend the Bridge only for demonstrated gaps

The Bridge already provides revisioned picker responses, explicit preparation,
device-bound gesture discovery and supported provider LED handling. Use standard
HA APIs for on/off, motion, setpoints, sensing and basic media, regardless of
Bridge presence. Evaluate these extensions in order of benefit and cost:

| Candidate | Evidence that would justify Bridge work | Behavior without it |
| --- | --- | --- |
| Physical controls and indicators for Fan or covers | The selected hardware has a real keypad input or indicator that standard state/actions cannot express. The existing gesture and indicator contracts can represent it with a bounded adapter and stable registry identity. | Native load control, keypad bindings supported directly by C4, and state feedback. |
| Discovery of auxiliary thermostat or security endpoints | Standard capabilities and registry data cannot reliably prove an associated helper, battery or contact role, but a known provider exposes that role unambiguously and the user gains a simpler setup or richer feedback. | Select a supported auxiliary endpoint explicitly when enabling its feature. Ordinary control uses the primary endpoint. |
| Media artwork delivered to the native renderer | Standard authorized HA media retrieval cannot be rendered safely by C4, and an authenticated bounded path can deliver meaningful artwork without passing HA tokens or provider URLs into Navigator. | Continue transport and metadata. Safe artwork through the standard path when available. |

For any accepted extension, record the user task, standard API evidence, provider
scope, benefit, fallback and native qualification. Use a narrow capability on
the selected endpoint, permission checks where needed, version support checks and
a producer/consumer fixture. Reuse the Bridge's existing registry identity and
dispatch code. Keep ordinary commands on the standard path. Avoid adding a new
generic Bridge command service for security or making browse create hardware
configuration. Plan Bridge code in its own OpenSpec change and qualify the
Control4 suite with the Bridge absent, at the existing supported version and at
the new compatible version. Release ordering must preserve independently
updatable installations.

### 6. Deliver in waves and qualify the installed experience

Start with Binary Sensor, Generic Sensor and Fan to prove common read-only
feedback and native control. Follow with Blinds, Garage Door and Thermostat to
exercise richer Control4 surfaces and the known replacement case. Finish with
Lock, Alarm Panel and Media Player, where native routing, credentials and media
retrieval need their own proof. A wave can qualify and release once its own
requirements pass. The initial milestone's remaining stable promotion and
handoff evidence stays in the existing change.

For every family, compare the old and new installer/homeowner tasks. Exercise
packaged drivers with scoped HA on the controller and independently review the actual
available screens, settings readbacks, normal and constrained panes and
keyboard use. Installer verification covers Composer and Navigator surfaces the
lab automation cannot operate. Collect bounded timings for discovery, selection,
commissioning, startup, recovery and the native operations each family adds.
Record sample counts, distributions, clock and logging mode. Repeat the
existing Light/Switch checks on each wave and measure a mix of eligible families
at the current large-catalog baseline.

### 7. Use HA Demo and targeted simulators for qualification

The isolated lab already seeds the HA Demo integration. The pinned HA
2026.11.1 source includes binary sensor, sensor, fan, cover, climate, lock,
alarm control panel and media player demo implementations. It includes separate
garage/tilt cover examples, fan speed variants and a climate temperature range.
Start by verifying the real picker and action path on Demo. Add a small
project-owned simulated entity or controlled fault only for missing behavior.
Fixtures must work through ordinary HA discovery, action calls and state
events. Use response stubs for fast driver tests of specific boundaries.
[Home Assistant Demo](https://www.home-assistant.io/integrations/demo/)

| Family | Demo or standard lab starting point | Targeted coverage to add if needed |
| --- | --- | --- |
| Binary Sensor, Generic Sensor | Binary signals and typed readings with units. | Repeatable contact and occupancy transitions, numeric zero, a unit change, stale or unavailable feedback. |
| Fan | Power, supported speed steps and presets. | On/off versus discrete steps including nine speeds, an accepted command with delayed or different state, and a missing optional control. |
| Blinds, Garage Door | Cover motion, separate tilt and a garage-class endpoint. | Held movement, delayed end state, unavailable feedback and simulated C4 contact/relay consumers. |
| Thermostat | Climate examples with supported target ranges. | Unit and step boundary pairs, delayed feedback and verified synthetic select or button helpers for optional modes and hold clearing. |
| Lock, Alarm Panel | Demo lock and alarm targets. | Repeatable jam, missing-code rejection, delayed transitions and a restricted set of alarm modes using synthetic credentials. |
| Media Player | Demo playback, metadata, volume and browse-capable examples. | Predictable track and room-routing cases and artwork permitted, unavailable or denied through a private fixture origin. |

Pin the lab HA version and fixtures, use synthetic names and credentials, and
provide seed/reset instructions. Exercise the real Control4 native surfaces on
The controller or through installer-operated Composer and Navigator with HA simulated.
Record the package version, HA version, fixture and evidence level per task.
Standard behavior can qualify against those fixtures. Physical motion,
provider radio behavior and hardware indicators need corresponding evidence
before they are listed as hardware-qualified.

## Risks / Trade-offs

- **Shared refactoring can break working drivers.** Add coverage to the existing
  entry points before extracting logic, and run equivalent packaged cases after
  the change.
- **Provider capability differs across devices.** Gate UI and programming by
  reported support and prove real behavior with varied fixtures. Expose
  unavailable state instead of interpreting it as a supported off/closed mode.
- **Security, movement and media actions have different consequences.** Reject
  unverified targets and credentials, keep live security and motion tests
  explicit, and avoid replay after an ambiguous result. Redact before logging
  and keep media access on verified origins.
- **More domains increase catalog cost.** Project only the needed selectors at
  HA where available, keep stable bound checks, and benchmark both cold and warm
  mixed-family views.
- **Compatibility declarations are weaker than native proof.** A declared
  proxy, event or binding does not prove existing programming still runs.
  Keep unresolved behavior visible in the per-family evidence.

## Migration Plan

1. Pin each baseline and verify its package, proxies, connections, variables,
   conditions, events and task behavior. Include existing compatible BP children
   and mixed projects in the regression suite.
2. Qualify clean setup first. Use in-place upgrades only after installed
   identity, version ordering, native programming and connection behavior pass.
   Extend the existing explicit migration workflow for Thermostat. For any
   other family requiring replacement, preview changes and require explicit
   approval before staging.
3. Verify the replacement's selection, confirmed feedback, settings,
   connections and required programming before removal is considered. Use the
   existing journal and backups to recover a partially applied operation.
   Demonstrate restoring the previous package or project and the original route.
4. Package the qualified families per wave and verify update order and
   recovery with partial installed-family sets. Record which package and
   companion combinations were exercised before publishing a prerelease.
