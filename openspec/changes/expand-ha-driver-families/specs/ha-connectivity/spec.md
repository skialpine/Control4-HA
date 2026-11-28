# Spec Delta

## ADDED Requirements

### Requirement: Standard Home Assistant operation for additional families
Additional families SHALL use standard Home Assistant discovery, state and action APIs wherever those APIs supply the needed behavior. Basic family selection and control SHALL operate with the Bridge absent. The Coordinator SHALL limit requests to the configured endpoint, verified auxiliary targets and supported family operations.

#### Scenario: Fan operates without the Bridge
- **WHEN** the installer selects a compatible fan while the Bridge is absent
- **THEN** Control4 can select it, recover its state and call the applicable fan actions through standard Home Assistant APIs

### Requirement: Versioned optional Bridge enhancements
A feature that needs provider-specific evidence or behavior SHALL use a bounded, versioned Bridge capability only when established for the selected endpoint. An absent, incompatible or rejecting Bridge SHALL leave supported standard operation available and report the affected feature's status.

#### Scenario: A provider-specific keypad feature loses support
- **WHEN** the Bridge no longer offers the required capability for the selected device
- **THEN** Control4 leaves ordinary native commands and feedback available and prevents use of the unverified feature

### Requirement: Scoped catalog growth
Discovery for additional families SHALL request the applicable domains and project only the fields needed for current setup and selection. It SHALL reuse verified freshness evidence where available and preserve independent functions from the same device.

#### Scenario: A device owns an independent fan and temperature sensor
- **WHEN** the installer opens the Fan and Generic Sensor pickers
- **THEN** each includes its applicable endpoint and neither receives unrelated device classes

### Requirement: Reused connection and confirmed native Programming
Every additional family SHALL use the shared automatic Coordinator connection rules and retain manual bindings and intentional disconnections. Native controls and Programming SHALL expose supported commands, state conditions, variables and events. Fresh snapshots SHALL restore state without replaying commands, button presses or transition events.

#### Scenario: A configured driver restarts during a temporary outage
- **WHEN** its Coordinator reconnects and receives the selected device's current state
- **THEN** the driver recovers its binding and selection and updates available native state and Programming conditions
- **AND** the snapshot does not fire a new physical occurrence
