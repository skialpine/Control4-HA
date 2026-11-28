# Spec Delta

## ADDED Requirements

### Requirement: Consistent setup for additional families
Every released family SHALL appear in the Coordinator's Quick Setup Device type list and provide the shared Device Setup flow. Quick Setup SHALL load compatible HA choices on entry and type changes. Its preview SHALL identify the selected device, driver type, name, room and whether the operation creates, resumes or keeps an instance.

#### Scenario: Multiple functions are available on one device
- **WHEN** an installer switches between Fan and Generic Sensor in Quick Setup
- **THEN** choices match the selected driver type and the prior draft remains available on return
- **AND** browsing neither adds a driver nor changes an existing selection

### Requirement: Search and existing-driver visibility
Quick Setup SHALL support selection by name, HA area or exact entity ID. It SHALL hide confirmed configured instances by default and offer Show all devices to reveal them. An ambiguous existing match SHALL be reviewed before any change.

#### Scenario: An installed fan appears in the full list
- **WHEN** the installer chooses Show all devices and finds an already configured fan
- **THEN** Quick Setup identifies that instance and preserves its confirmed room, settings and selection without offering a duplicate add

### Requirement: Capability-dependent configuration
For every family, setup SHALL derive the exact HA endpoint, supported capabilities and safe settings from verified HA metadata and existing bindings. It SHALL preserve explicit overrides and ask only for required information that cannot be resolved reliably. Optional selections SHALL be requested only when the installer enables the feature.

#### Scenario: A thermostat has no proven mode helper
- **WHEN** the installer selects the thermostat and asks to add an optional mode mapping
- **THEN** the setup asks for the needed helper while leaving ordinary climate operation available

### Requirement: Verified Control4 room placement
Quick Setup SHALL suggest the unique Control4 room matching the HA area's name and allow an override. It SHALL ask for a room when there is no unique match. Confirmation SHALL create the selected driver in the approved room, bind it to the Coordinator, save its HA selection and verify the saved configuration. A retry SHALL resume or keep the verified instance without duplicating or moving it.

#### Scenario: An installer adds a driver with an unambiguous area
- **WHEN** the selected device's HA area matches one Control4 room and the installer confirms the preview
- **THEN** the correct family driver is created in the approved room, bound and configured
- **AND** reopening setup shows the saved selection and relevant settings

#### Scenario: Two Control4 rooms match the HA area
- **WHEN** Quick Setup cannot infer one destination
- **THEN** it asks the installer to choose the room before confirmation and retains that choice across filters and type changes

### Requirement: Consistent setup status and recovery
Every family SHALL keep native Properties first and expose the selected endpoint, actual control target where applicable, readiness and next useful action. It SHALL use shared advanced diagnostics and distinguish unconfigured, unavailable, disconnected and denied states. A retry SHALL preserve the confirmed room, target and overrides.

#### Scenario: Home Assistant denies setup
- **WHEN** preparation or discovery fails due to permissions
- **THEN** Quick Setup or Device Setup identifies the permission issue and offers the appropriate retry while preserving the draft

### Requirement: Proven targets, inputs and indicators
Where a family supports linked targets, buttons or indicators, setup SHALL distinguish the endpoint being controlled from the input and feedback sources. It SHALL offer only supported modes and settings and retain existing choices on reopen. Browsing, restart and reconnect MUST NOT write indicator settings.

#### Scenario: A compatible keypad serves a cover
- **WHEN** the installer selects a verified keypad association for the cover
- **THEN** setup identifies which device moves and which supplies presses
- **AND** optional indicator controls appear only for supported settings
