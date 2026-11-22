## Purpose

Support same-instance upgrades and user-requested migrations with explicit evidence for each starting family.

## ADDED Requirements

### Requirement: Read-only legacy assessment
The initial milestone SHALL include a supported legacy Light/Switch assessment identifying source versions/identities, rooms, names, recoverable selections, bindings and discoverable programming references. Assessment MUST NOT change the project and MUST label inaccessible or unrecognized data as unresolved.

#### Scenario: Assess an original Light driver
- **WHEN** the installer requests its migration assessment
- **THEN** the report identifies the source, its same-instance upgrade path and any unresolved references without deploying or rewiring anything

### Requirement: Semantic migration mappings
Mappings SHALL distinguish device/protocol/proxy identities, connection roles, event IDs, commands, parameters and variables. Programming owned by the legacy device and references from other devices/agents MUST be considered separately. Ambiguous or incompatible references MUST NOT be replaced by numeric or name heuristics.

#### Scenario: Another device's program targets the legacy light
- **WHEN** that reference is discovered
- **THEN** it is included in the migration report rather than assuming only programs attached to the legacy device need attention

### Requirement: Explicit migration action
The Coordinator SHALL offer **Migrate switch drivers** in Quick Setup for both pinned Switch versions. It SHALL list older switch drivers by project name and room, indicate eligibility with specific reasons, and show a review of selected changes. A project backup and a single explicit **Start migration** confirmation SHALL precede any mutation. Startup, discovery, binding changes and routine updates MUST NOT initiate migration.

#### Scenario: Quick Setup shows migration when it is useful
- **WHEN** the Coordinator has older switch drivers to review or an operation awaiting migration, naming or removal review
- **THEN** the expanded **Migrate switch drivers** section appears above the Home Assistant device list and shows the current drivers or saved progress
- **AND** the list explains that the new driver type requires migration and tells the installer to test replacements before returning to review the originals for removal
- **AND** when no such work remains, Quick Setup hides the section

#### Scenario: The initial migration check fails
- **WHEN** the Coordinator cannot report whether migration work exists
- **THEN** Quick Setup shows a retry for the migration check
- **AND** a successful retry shows the work or hides the section when there is none

#### Scenario: An installer opens a replacement's Device Setup
- **WHEN** a Light or Switch has yet to be configured
- **THEN** Device Setup offers **Review an older driver**
- **AND** for a configured driver, the entry is hidden except when a Switch has an unfinished or unreadable saved migration
- **AND** an installer who closes a completed review returns to Device Setup with focus on **Change device** when that action is available

#### Scenario: Migrate several older switch drivers
- **WHEN** the installer opens Migrate switch drivers and confirms a backed-up selection
- **THEN** the review identifies the selected HA device and the connected endpoints by name, room, role and verification status
- **AND** before creating a replacement, the wizard requires the installer to acknowledge that Composer may select the replacement and tells them how to return to the Coordinator’s Quick Setup
- **AND** one operation prepares the replacements, moves verified connections, shows progress per switch and verifies the results
- **AND** if a peer also needs migration, the review identifies it and keeps the original connection pending while the installer resolves that dependency

#### Scenario: A prototype switch uses button events
- **WHEN** the installer reviews a prototype Switch that uses button events
- **THEN** Quick Setup offers to create an unconfigured replacement in the original room after the installer reviews the change and confirms a backup
- **AND** Quick Setup leaves the original connected, connects the blank replacement to the Coordinator and copies the supported Button behavior and LED Behavior properties
- **AND** the initial review presents the exact Home Assistant load when the verified catalog uniquely associates the original’s button event with a physical choice, and Start migration approves that displayed load
- **AND** Quick Setup checks the physical and event identities, and transfers the prepared default load automatically when it agrees with the reviewed endpoint and registry identity
- **AND** Quick Setup asks a separate load question only when it can propose a load that the installer has not already approved
- **AND** the load confirmation shows the exact entity and its Home Assistant name and area when available, describes the verified button-event match and the checks before transferring control, and presents confirmation before the manual fallback in visual and keyboard order
- **AND** when the selection, ownership and connected peers are verified and any necessary programming review is complete, Quick Setup transfers the selection, waits for feedback and moves the verified relay and button links
- **AND** an inconclusive match leaves the original connected and names the remaining Composer step
- **AND** the wizard applies any remaining name changes after verified automatic cutover and asks the installer to test the replacement
- **AND** if cutover is completed manually, the wizard verifies the new selection, original disconnection and installer testing before removal review
- **AND** the old driver remains available for a separate removal review that requires installer testing
- **AND** the individual replacement action requires verified direct mode, and Quick Setup rechecks the selection and intended mode before transferring control and after a retry

#### Scenario: One switch needs installer attention
- **WHEN** a switch has a reference the API cannot safely transfer
- **THEN** the preview shows references it found and confirms the project backup
- **AND** after staging the new driver, the wizard keeps the original in control and identifies the replacement, the Composer steps and how to continue
- **AND** it gives the replacement the original project name when it can verify both driver names, then shows which old-named driver still controls the switch and the specific Composer commands to move

#### Scenario: Reopen after interruption
- **WHEN** the installer opens Migrate switch drivers with an unfinished operation
- **THEN** the wizard offers the saved operation and reports which switches can resume or recover without repeating completed steps

#### Scenario: The suite is updated while waiting for load confirmation
- **WHEN** the installer explicitly rechecks a staged migration after all suite drivers have been updated together
- **THEN** Quick Setup shows the saved load for approval and can reuse the replacement if it is still blank and the original selection, programming and connections can be verified
- **AND** it repeats selection, ownership and connection verification before any transfer

#### Scenario: The installer verifies the replacement
- **WHEN** the replacement runs the same revision as the rest of the suite and required controls and references have been exercised
- **THEN** the migration records a verified cutover with one active owner and a restorable project backup

#### Scenario: Supported programming-write mechanism is unavailable
- **WHEN** the requested Switch migration reaches a programming reference it cannot transfer
- **THEN** it identifies the manual work and keeps the cutover pending until the installer completes it and verifies that the replacement receives the expected control and feedback

### Requirement: Preserve switch names and review old driver removal
After verifying the cutover, the wizard SHALL give the new driver the original project name and give the disconnected old driver a distinct name. The wizard SHALL preserve the room and verify the new name used by the replacement proxy. The wizard MUST offer a separate removal review after the installer confirms testing and checks programming.

#### Scenario: Review retired drivers after testing
- **WHEN** the installer confirms that the replacement drivers were tested and their programming reviewed
- **THEN** the wizard identifies the exact retired drivers whose replacements, names, connections and programming qualify them for removal in Composer
- **AND** the confirmation states which switches were tested, what constitutes a passing test, and that deletion is performed separately in Composer
- **AND** Quick Setup retains the previous testing confirmation for that replacement and checks its current selection, mode, feedback and transferred connections before offering removal

#### Scenario: Drivers share a name across rooms
- **WHEN** the installer selects drivers, moves programming, checks the result or reviews old drivers for removal
- **THEN** each named driver is paired with its Control4 room so the installer can find the correct driver in Composer

### Requirement: Reversible staged cutover
If automated cutover is offered, it SHALL require a restorable project backup, readiness verification, recorded old/new mappings and rollback steps. It MUST avoid duplicate active control, preserve unmapped originals, and MUST NOT delete originals or report completion while required references remain unresolved.

#### Scenario: A replacement cannot obtain HA readiness
- **WHEN** migration reaches its verification step
- **THEN** the existing working device remains authoritative and the failed replacement is not presented as a successful cutover

#### Scenario: Another Control4 driver could share control
- **WHEN** a bound driver may already control the replacement’s load or report its button events
- **THEN** Quick Setup compares the functions that would transfer, checks effective identities across Coordinators and pauses when another owner cannot be ruled out

#### Scenario: The connections change during transfer or restoration
- **WHEN** a replacement has connections outside the reviewed plan or a required original destination port cannot be verified
- **THEN** Quick Setup stops before enabling the unreviewed replacement or detaching the working connection from an unavailable restoration destination
- **AND** if any row requires restoring the project backup, every row in the batch is paused until recovery

### Requirement: Idempotent optional deployment
Repeated optional migration runs SHALL reuse their recorded staged replacements and MUST NOT duplicate drivers or reapply destructive programming changes. Reports MUST identify applied, failed and pending operations without logging credentials or raw private programs.

#### Scenario: Resume after interruption
- **WHEN** a selected replacement was already added before the interruption
- **THEN** the migration tool recognizes that replacement instead of adding another instance in the same room

### Requirement: Family-specific replacement decisions
BP Home Assistant Thermostat SHALL follow the user-requested migration workflow when the thermostat family enters implementation. The verified source is `HA.Thermostat.c4z` revision 108 (release v1.0.8), model `HA Thermostat`, with a `thermostatV2` proxy on binding 5001. Every remaining family SHALL have a documented and individually qualified upgrade path when implemented.

#### Scenario: A later family enters implementation
- **WHEN** its installed topology and public programming identities are inventoried
- **THEN** its first build includes a pre/post test of the proposed path and the installer guide identifies that exact family and source version
