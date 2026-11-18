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
Switch migration SHALL require a user request, read-only preview, confirmation and a rehearsed rollback. Supported staging and transfer MAY run inside that operation. Startup, discovery, binding changes and routine updates MUST NOT initiate a migration. The report SHALL identify every known manual step.

#### Scenario: Supported programming-write mechanism is unavailable
- **WHEN** the requested Switch migration reaches a programming reference it cannot transfer
- **THEN** it identifies the manual work and keeps the cutover pending verification

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
