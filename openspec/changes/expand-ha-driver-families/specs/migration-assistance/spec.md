# Spec Delta

## ADDED Requirements

### Requirement: Qualified upgrade path per additional family
Each family SHALL publish a verified install and upgrade path that records the supported predecessor revisions and preserves qualified user tasks and identities. In-place treatment requires proof that retained proxy, settings, connections and Programming still work. Where replacements are needed, migration SHALL begin only after an installer request.

#### Scenario: An original BP package can keep its installed interfaces
- **WHEN** the installer updates a verified predecessor in place
- **THEN** the instance retains its room, saved Home Assistant target, native connections and Programming
- **AND** the installer can resume operation after the new driver confirms feedback

#### Scenario: A legacy driver needs a replacement
- **WHEN** the installer requests migration of a qualified legacy driver
- **THEN** the preview identifies its destination, retained settings, connections and Programming requiring attention
- **AND** the original remains available until a confirmed cutover with recovery comparable to the Switch workflow
- **AND** the public migration instructions refer to the predecessor as a legacy driver

#### Scenario: A legacy task has no qualified equivalent
- **WHEN** an installer or homeowner relies on a feature whose replacement has not passed the same task
- **THEN** assessment identifies the unqualified feature and leaves the original in place

#### Scenario: BP Thermostat is present when the suite updates
- **WHEN** the suite is updated before the installer requests thermostat migration
- **THEN** the original thermostat keeps its selection and working connection
- **AND** the proposed replacement is handled through the explicit workflow

#### Scenario: A legacy use depends on an unmapped Programming action
- **WHEN** assessment cannot verify an equivalent action on the new driver
- **THEN** the installer sees the manual review required and the original driver is kept available until the path is verified

### Requirement: Mixed projects remain operable
Introducing a family SHALL preserve verified operation of existing suite drivers and compatible original drivers. An incomplete or failed replacement SHALL preserve or restore the verified original route and report the recovery outcome.

#### Scenario: A project has an original Garage Door and a new Fan
- **WHEN** the new Fan is added to the existing Coordinator
- **THEN** the fan and garage door retain separate scoped commands and confirmed feedback
