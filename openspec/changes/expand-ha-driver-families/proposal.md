# Proposal

## Why

Light and Switch have established a working pattern for Control4 setup, scoped Home Assistant communication and native feedback. The remaining BP drivers can bring more device types into the same suite while sharing that implementation and preserving useful tasks from the originals.

## What Changes

- Add Binary Sensor, Generic Sensor, Fan, Blinds, Garage Door, Thermostat, Lock, Alarm Panel and Media Player to the suite. Deliver them in waves so the first additions exercise both read-only feedback and native commands.
- Offer every released family in the Coordinator’s Quick Setup. Suggest the Control4 room from a unique HA area match, then create, bind and configure the driver after preview and confirmation. Use the shared Device Setup, diagnostics and package workflow from Light and Switch. Keep native proxy mappings and family-specific capabilities in adapters.
- Improve native Control4 controls, feedback and Programming for each family according to its reported capabilities. Use standard Home Assistant APIs for ordinary operation. Extend HA Gesture Bridge when a named user task needs provider-specific information or behavior that the standard APIs do not expose.
- Use pinned BP sources and package contracts as behavioral references. Establish redistribution terms for each upstream work before copying any of its code or assets.
- Verify which Light and Switch tasks carry over unchanged and which have a family-specific native equivalent. Include setup, native Programming, binding and feedback recovery, optional physical controls and indicators, and diagnostics in the family acceptance matrix.
- Give each family a documented and verified upgrade path that preserves supported selections, bindings and programming. Include the existing explicit migration requirement for BP Thermostat. Keep mixed projects working as families are introduced.
- Qualify each wave using the isolated HA lab, built-in Demo platforms and targeted simulators. Verify clean installs, retained projects, recovery, common-operation timings and native tasks. Plan any Bridge extension alongside its Control4 consumer, with a separate change in the Bridge repository and independent version compatibility.

## Capabilities

### New Capabilities

- `native-sensing` covers the Binary Sensor and Generic Sensor drivers.
- `native-airflow` covers the Fan driver and its speed capabilities.
- `native-covering` covers the Blinds and Garage Door drivers.
- `native-climate` covers the Thermostat and its optional Home Assistant controls.
- `native-security` covers the Lock and Alarm Panel, including credential handling.
- `native-media` covers the Media Player's transport, metadata and room integration.

### Modified Capabilities

- `ha-connectivity` extends scoped discovery, subscription and command validation to the new families.
- `device-setup` extends the shared selection and commissioning flows to new families and their applicable settings.
- `migration-assistance` adds family-by-family upgrade qualification and compatibility with mixed projects.
- `integration-test-lab` makes reproducible simulated qualification available for all nine families.
- `suite-distribution` extends the suite inventory and update contract to separately installable, qualified families beyond the initial milestone.

## Impact

The Control4 HA repository gains driver packages and adapters, shared family wiring in `src/ha`, catalog and setup support, package qualification and family manuals. The proposal builds on the existing suite and migration changes. Record each original BP in-place update that preserves the installed workflows. Use the existing Switch-style migration model when a retained identity cannot preserve them. Compare the separate legacy driver suite against the same installer and homeowner tasks and qualify equivalent or better replacements before recommending a move.
