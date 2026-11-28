# Tasks

## 1. Capture the baseline and extract the shared driver pattern

- [x] 1.1 Use the pinned BP inventory, exact available packages and source command harness to record a task and identity matrix for all nine families. Include package file/model/version, proxies, bindings, settings, events, conditions and Programming. Record Fan's package variants and distinguish exact archive evidence from source-only evidence. Verify the provenance and evidence columns before claiming parity.
- [x] 1.2 Review the pinned Finite Labs examples and library APIs. Reuse the current shared lifecycle, values, events, selection, bindings and diagnostics for a read-only and a command-capable adapter. Introduce only the family metadata and hooks they need. Verify Light and Switch from their normal driver entry points through initialization, setup, commands, feedback, saved settings and reload. Record reuse and any template gaps.
- [x] 1.3 Extend the shared endpoint contract, request validation and scoped discovery for the first wave. Verify mixed-domain picker filtering, freshness reuse, an older or absent Bridge, exact endpoint identity, invalid inputs and recovery. Record baseline cold and warm timings from the existing suite before expanding the catalog.
- [ ] 1.4 Extend the shared Device Setup and Quick Setup with family-specific labels, capability visibility, packaging identity and existing-match rules. Demonstrate read-only browsing, per-type draft retention and creation after preview and confirmation. Test unique, missing and duplicate area-to-room matches and manual room overrides. Verify room, Coordinator binding, saved endpoint and safe reruns. Include native Properties order, actionable recovery and independent setup review.

- [x] 1.5 Establish a resettable isolated fixture set using HA Demo for all eight domains and add only the targeted simulated cases in the design. Verify that resetting the seed reproduces eligible endpoints, ordinary actions and state events using synthetic data. Record the supported HA versions, fixture commands and missing hardware coverage.

## 2. Wave one — Binary Sensor, Generic Sensor and Fan

- [x] 2.1 Implement Binary Sensor through the shared read-only path. Qualify contact and native Programming transitions for representative device classes, loss of signal and reconnect without a duplicate event. Document device classes, supported outputs and the applicable upgrade path.
- [x] 2.2 Implement Generic Sensor typed states, units, applicable temperature/humidity connections and explicitly saved fallbacks. Verify valid zero, unit rendering, unavailable values, downstream readback and the compatible predecessor workflows. Document connection and unit choices.
- [x] 2.3 Implement Fan power, confirmed speed and native keypad/Programming behavior. Verify a binary fan and discrete speeds including the original nine-speed variant. Qualify each optional preset, direction or oscillation feature before exposing it. Document the supported controls and upgrade handling.
- [ ] 2.4 Qualify the wave against the predecessor task matrix and on the controller using the isolated HA Demo and simulator lab. Demonstrate an exact package update or explicitly requested replacement for each qualified predecessor, mixed-project operation and recovery. Verify that unqualified options are labeled and that related Light/Switch workflows still work.

## 3. Wave two — Blinds, Garage Door and Thermostat

- [ ] 3.1 Extend the scoped contract for cover and climate states, native actions and proven auxiliary roles. Verify feature filtering, two independent functions on one device, exact target validation and refusal to use ambiguous helpers. Document the supported standard HA capability mappings.
- [x] 3.2 Implement Blinds movement, stop, position and tilt on their supported native surfaces. Exercise a simple shade, a position-capable shade and a tilt-capable shade. Verify separate lift/tilt commands and feedback, a qualified keypad workflow and saved settings on reopen. The keypad and tilt paths were verified in the simulator, and native position control and retained settings were verified on the controller with HA Demo.
- [x] 3.3 Implement Garage Door open/close, available endpoint feedback and the qualified relay, contact and keypad behavior. Verify motion and missing-feedback states with simulated endpoints. Qualify physical motion or contact behavior only with an approved hardware fixture, and document supported connections. The controller native control used HA Demo. Relay, contact and keypad signal behavior was verified in the simulator.
- [ ] 3.4 Implement ThermostatV2 mode, current action, setpoints and applicable fan, preset and humidity controls. Verify heating/cooling setpoints, dual range, unit conversion and delayed feedback. Verify separately selected helper/hold/schedule behavior and that losing a helper leaves supported primary functions available.
- [ ] 3.5 Qualify the explicit BP Thermostat replacement. Demonstrate a read-only preview, retained original route before cutover, secondary selection and Programming review, confirmed replacement feedback, and rollback. Verify the Blinds and Garage Door upgrade paths against their native tasks and record observed results and known limits.

## 4. Wave three — Lock, Alarm Panel and Media Player

- [x] 4.1 Add scoped security and media capability projections and allowlisted actions. Verify malformed inputs, explicit target ownership, rejected credentials, timeouts and stale callbacks. Demonstrate that logs, UI errors and exported diagnostics contain no credentials or signed URLs.
- [ ] 4.2 Implement native Lock and Alarm Panel behavior with their own adapters. Qualify Lock feedback including jam where supported, native alarm room/partition selection, supported arm/disarm modes and the available credential flow. Exercise missing-code, rejection and disconnected cases with simulated targets. Document the confirmed native controls and package upgrade path for each driver.
- [ ] 4.3 Implement native Media Player transport, room routing and now-playing feedback. Verify active and idle players, source or browse behavior where supported, and a missing or unqualified artwork URL. Qualify the safe artwork path separately from transport and document supported media tasks and package upgrade handling.

## 5. Decide on optional Bridge extensions with evidence

- [x] 5.1 For each wave, evaluate the named enhancement candidates in the design during family qualification. Record which user task is already covered by standard HA APIs, what remains unavailable to an ordinary client, native Control4 proof and whether an extension is worth its cost. An unsupported candidate remains optional in the feature matrix.
- [x] 5.2 For each accepted gap, create a coordinated OpenSpec change in the Bridge repository before extending the HA runtime. Verify the design scopes capabilities and permission checks to a selected endpoint, names the compatible versions and defines an ordinary standard-API fallback. Record the owner and release order in the cross-repo compatibility notes. The evaluation accepted no Bridge extensions for this wave.
- [x] 5.3 Implement the Control4 side of any accepted capability through existing Bridge discovery and preparation paths. Verify against a real HA producer fixture and test standard operation with the Bridge absent, at the previously supported version and at the new version, including a failed or stale response. No new Bridge capability entered this wave.

## 6. Verify each release wave

- [x] 6.1 Update the package inventory, manifest and updater rules for each qualified wave. Verify deterministic builds, exact packaged identity, Coordinator-last order, installed-subset updates, channel rules, blocked incomplete releases and interrupted update recovery.
- [ ] 6.2 Run the driver suites, packaged verification and provenance checks on each candidate. For every family in the wave, exercise Quick Setup from the Coordinator with HA Demo or a simulator and show correct room placement, automatic configuration, settings readback and re-open or resume without duplicates. Demonstrate the prerequisite Light/Switch carry-over matrix and the original-to-new family task matrix for native controls, Programming, verified migration and rollback. Record the independent UI review and the installer-observed Composer and Navigator checks. Identify the fixture and evidence level for each family and separate any physical hardware claims.
- [x] 6.3 Record the controller cold/warm discovery at the mixed-family scale baseline and bounded timing distributions for discovery, selection, commissioning, startup, recovery and added native operations. Include Logging Mode/Level, sample count and clock. Keep transport acceptance, confirmed state and any measured physical response distinct. The lab report records the non-reboot recovery and live Demo command samples.
- [x] 6.4 Review branch changes using the repository's audit workflow before any commit. Verify each qualified release bundle has matching driver inventory, documented supported capabilities, baseline references, privacy-safe evidence and matching installed package versions. The suite audit and the controller running readback cover a later build.
- [ ] 6.5 Run reboot qualification last, after the other lab checks. Reboot lab Home Assistant and the controller in separate runs. Confirm automatic reconnect, snapshot convergence, saved selections and bindings, the first post-reboot command and no duplicate subscriptions, drivers or transition events. Measure outage and recovery intervals separately and record results before qualifying the wave.
- [x] 6.6 Adopt template v0.9.119 and bundle each supported Quick Setup archive in the Coordinator. Verify archive equality, confirmed-only installation, existing-file preservation, and manual recovery in the package and simulator checks.
- [x] 6.7 After the suite regression checks pass and the controller confirms Coordinator-only setup with the chosen child archive absent from its driver store, submit the archive-name fix to Finite Labs. Keep the existing folder-name validator. Add a template fixture where a companion folder and its dotted archive name differ, and verify the embedded and standalone bytes match in both template distributions. The controller verified an absent dotted Fan fixture, its installed checksum and reuse on a second preview. [Finite Labs PR 250](https://github.com/finitelabs/control4-driver-template/pull/250)
- [ ] 6.8 Upgrade to Finite Labs template v0.9.123 as soon as the the controller Binary Sensor and Generic Sensor predecessor rehearsal and baseline regression tests pass. Merge the WebSocket v18 update with the suite's authentication and reconnect cleanup fixes. Retain dotted companion filename support and add the 3.5 MiB archive limit to `suite-verify`. Review the upstream Example Light diff, update the template pin and provenance, and rerun the suite and upstream WebSocket tests, package verification, and the controller authentication, reconnect and companion installation checks before reboot qualification (6.5).

## Workflow follow-up

- [x] 7.1 Match the separate legacy driver suite against the native and
  Programming task matrix. Keep read-only detection distinct from a qualified
  replacement. Include legacy-only Event, Select, Humidifier, notifications and
  TV remote and app-launching tasks before claiming equivalent coverage.
- [ ] 7.2 Qualify retained update candidates against exact installed BP
  archives. For each other supported predecessor, demonstrate a Switch-style
  preview, migration, feedback verification and rollback. Preserve legacy
  devices that have unresolved settings, Programming or manual connections.
- [x] 7.3 Use “legacy drivers” in all public instructions and installer-facing
  copy. Show the affected feature and recovery steps in every blocked preview.

- Archive the foundation before this change if its in-flight capability specs are
  still pending. The added requirements here use those same capability paths.
