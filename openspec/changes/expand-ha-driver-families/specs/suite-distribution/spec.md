# Spec Delta

## ADDED Requirements

### Requirement: Staged expansion of the suite
A release beyond the initial milestone SHALL list its qualified families, exact package identities and compatible versions. Each qualified family SHALL be separately installable with the Coordinator. The updater SHALL stage and verify the applicable installed packages before reload and update the Coordinator after those packages.

#### Scenario: Only some families are installed
- **WHEN** an installer updates a project containing Light and Fan from a release that also includes sensors
- **THEN** the update verifies the relevant installed drivers, updates the Coordinator last and leaves the project's set of installed families intact

#### Scenario: A staged wave is incomplete
- **WHEN** a required installed package fails release integrity or compatibility checks
- **THEN** installation does not start and the project retains its currently installed drivers

### Requirement: Coordinator-only Quick Setup installation
The Coordinator package SHALL carry the same archives distributed for each supported Quick Setup family. An explicitly confirmed Create action SHALL install a missing driver file before adding that device. It SHALL preserve existing driver files and keep project updates under the suite’s existing update controls.

#### Scenario: Only the Coordinator has been imported
- **WHEN** an installer confirms creating a Home Assistant device whose driver file is missing
- **THEN** the Coordinator installs that driver from its package and continues the confirmed add, binding and setup

#### Scenario: The driver file cannot be installed
- **WHEN** the confirmed Create action cannot install the required file
- **THEN** Quick Setup offers the installer a manual import path and preserves the selection for another review
