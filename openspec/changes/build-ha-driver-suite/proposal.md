# Proposal

## Why

The existing HA/C4 work has proved useful device selection, gestures, LEDs and lighting behavior, but remains a prototype with duplicated infrastructure and uneven native Control4 coverage. A fresh, template-based suite can offer consistent configuration, substantially richer C4 features across every device family, automatic updates and an installation path ordinary users can follow.

## What Changes

- Create a public, free `skialpine/Control4-HA` suite in this directory, using a pinned Finite Labs template and its applicable libraries, build tools and tests.
- Deliver Coordinator and Light as in-place upgrades of the original BP and prototype packages. Keep their installed device, proxy, programming and binding identities. Migrate older Control4 Switch drivers through one explicitly started Coordinator wizard while keeping the same hardware.
- Require a backed-up, reversible Switch migration rehearsal for the first demo. Identify manual programming work before cutover. Qualify compatible updates for the other families as they enter scope and track BP Home Assistant Thermostat as a migration exception for the later thermostat family.
- Deliver **Coordinator, Light and Switch first**, then stop for user feedback before implementing more families. Use the pinned BP `Control4-HA-*` repositories as functionality references across the suite. Keep Thermostat, Fan, Lock, Blinds, Garage Door, Alarm Panel, Media Player, Binary Sensor and Generic Sensor as the next-stage roadmap. Base is a reference for predecessor behavior.
- Require full working behavior from both predecessors for each initial family. Pin the original packages and all three prototype repositories, compare their contracts and qualify clean projects, coordinated whole-suite upgrades and completed migrations on one suite revision before the demo.
- Give every implemented driver the improved physical-device/endpoint picker, capability-driven configuration, understandable readiness/errors and compact/advanced diagnostics. Browse without creating unused devices; never fetch everything as a fallback.
- Provision an isolated project HA lab in a dedicated HA Container on the existing Portainer-managed Linux Docker VM on Proxmox, using a 2 GiB HA OS VM as the capacity-checked fallback. Use simulated lights/switches/gestures and fault scenarios; keep HA OS app/Marketplace qualification explicit where Container cannot exercise it. Investigate simulation coverage for later families; never use production HA as the development test environment.
- Delegate native lighting to the template Light V2 library, with HA and connected-C4 adapters, scenes, color/CCT, presets, groups, gesture programming and supported indicator LEDs.
- The installer extracts one release ZIP and selects all included suite packages together in Composer's Add or Update Driver dialog. This process also applies to later releases that introduce more driver families. The installer enables automatic updates once on the Coordinator. Later Production or Pre-release updates run without Composer or per-release approval. Apply the same release to every installed suite package in one operation and verify all installed instances before declaring success.
- Keep HA implementation in its separate repository. Retain native operation without the optional integration; version the richer catalog/preparation boundary explicitly.
- Deliver tested initial-family installation/migration guides and a portable AI setup skill, with complete manuals required before GA. Keep HA Marketplace acceptance and verified installation as GA gates, not blockers for the initial feedback milestone.
- Preserve credit and provenance for bphillips09/BP, Finite Labs, Control4 and other reused sources; resolve unclear source reuse terms before distribution.

## Capabilities

### New Capabilities

- `suite-distribution` covers template-based packages, family-specific upgrade identities, provenance and supported platforms.
- `ha-connectivity`: shared HA connection, scoped subscriptions, service calls and lifecycle isolation.
- `device-setup`: consistent selection, preparation, capabilities and diagnostics across families.
- `native-lighting`: native C4 lighting through the template library and verified adapters.
- `native-switching`: usable native general-purpose switch control and programming.
- `automatic-updates`: coordinated, Composer-free Production and Pre-release installation.
- `installation-guidance`: complete installation, migration, operation and troubleshooting manuals.
- `migration-assistance`: legacy inventory, migration mapping and qualified optional automation.
- `ai-configuration-assistant`: portable, documented HA configuration and C4 installation assistance.
- `integration-test-lab`: isolated project HA, simulated device coverage, fault injection and explicit hardware qualification limits.
- `release-readiness`: feature qualification, licensing and HA Marketplace gates before GA.

### Modified Capabilities

None. This is a new project with no existing specifications.

## Impact

The new repository owns C4 drivers, shared HA-facing code, packaging, manuals, skill, test-lab configuration and tests. The separate HA repository remains independently versioned. Existing light/switch preparation is the initial contract; all-family discovery and Marketplace publication are separate HA workstreams. The initial milestone ends with a user feedback handoff, not suite GA. C4 targets the verified template baseline; the HA companion retains its 2026.11.1 minimum.

### Feedback acceptance

The first feedback handoff requires demonstrated predecessor user tasks on the current packages, including the standard Light editor, built-in Home Assistant device LEDs, package-based picker and restored saved selections. Development builds remain available for isolated automated qualification.
