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

#### Scenario: Migrate several older switch drivers
- **WHEN** the installer opens Migrate switch drivers and confirms a backed-up selection
- **THEN** one operation prepares the replacements, moves supported connections, shows progress per switch and verifies the results

#### Scenario: A prototype switch uses button events
- **WHEN** the installer reviews a prototype Switch that uses button events
- **THEN** the review keeps its configuration intact and directs the installer to the documented manual migration
- **AND** both migration entry points require a verified direct mode before preparing an automatic migration and recheck it before transferring control

#### Scenario: One switch needs installer attention
- **WHEN** a switch has a reference the API cannot safely transfer
- **THEN** the preview shows references it found and confirms the project backup
- **AND** after staging the new driver, the wizard keeps the original in control and identifies the replacement, the Composer steps and how to continue

#### Scenario: Reopen after interruption
- **WHEN** the installer opens Migrate switch drivers with an unfinished operation
- **THEN** the wizard offers the saved operation and reports which switches can resume or recover without repeating completed steps

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

#### Scenario: Drivers share a name across rooms
- **WHEN** the installer selects drivers, moves programming, checks the result or reviews old drivers for removal
- **THEN** each named driver is paired with its Control4 room so the installer can find the correct driver in Composer

### Requirement: Reversible staged cutover
If automated cutover is offered, it SHALL require a restorable project backup, readiness verification, recorded old/new mappings and rollback steps. It MUST avoid duplicate active control, preserve unmapped originals, and MUST NOT delete originals or report completion while required references remain unresolved.

#### Scenario: A replacement cannot obtain HA readiness
- **WHEN** migration reaches its verification step
- **THEN** the existing working device remains authoritative and the failed replacement is not presented as a successful cutover

### Requirement: Idempotent optional deployment
Repeated optional migration runs SHALL reuse their recorded staged replacements and MUST NOT duplicate drivers or reapply destructive programming changes. Reports MUST identify applied, failed and pending operations without logging credentials or raw private programs.

#### Scenario: Resume after interruption
- **WHEN** a selected replacement was already added before the interruption
- **THEN** the migration tool recognizes that replacement instead of adding another instance in the same room

### Requirement: Family-specific replacement decisions
The designated temperature driver SHALL follow the same user-requested migration workflow once its source package and proxy are identified. Every remaining family SHALL have a documented and individually qualified upgrade path when implemented.

#### Scenario: A later family enters implementation
- **WHEN** its installed topology and public programming identities are inventoried
- **THEN** its first build includes a pre/post test of the proposed path and the installer guide identifies that exact family and source version
