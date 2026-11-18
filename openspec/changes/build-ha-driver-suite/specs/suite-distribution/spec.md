## Purpose

Provide a coherent, freely distributed Control4 driver suite with family-specific installation identities, traceable sources and reproducible release packages.

## ADDED Requirements

### Requirement: Initial feedback distribution
The initial milestone SHALL distribute Coordinator, Light and Switch packages and stop for user feedback before adding further families. Other upstream families MUST remain explicitly identified as roadmap items. The suite MUST NOT require an installable Base driver or the legacy Base submodule.

#### Scenario: Install one device family
- **WHEN** an installer installs the Coordinator and a selected family package
- **THEN** that family operates without installing or initializing a legacy Base package

### Requirement: Installed family identities
Coordinator and Light SHALL update the original and prototype instances in place under HA.Coordinator.c4z and HA.Light.c4z respectively. Updates SHALL retain the protocol/proxy IDs, names, rooms, settings, bindings and working programming. Switch SHALL use its new identity through requested migration.

#### Scenario: A configured original or prototype instance is updated
- **WHEN** the installer applies the candidate to its existing Coordinator or Light
- **THEN** the same instance controls its saved selection and its previous programming and connections work after reload

### Requirement: Coherent release artifacts
A release SHALL include separately installable packages for all families it declares implemented and an inventory recording versions and hashes. Rebuilding identical release inputs MUST yield identical runtime package contents and MUST exclude lab credentials, development fixtures and unused optional modules.

#### Scenario: Rebuild a release
- **WHEN** two builds use the same pinned sources, configuration and release version
- **THEN** their runtime package contents and inventory hashes match

### Requirement: Traceable attribution and reuse
Distributed source and packages SHALL identify bphillips09/BP's upstream work, Finite Labs and other reused components, preserve required notices, and record source revisions and applicable reuse terms. Distribution MUST be blocked for copied material whose reuse permission remains unresolved.

#### Scenario: A source repository has no established reuse grant
- **WHEN** a release contains copied material from that repository
- **THEN** release qualification fails until permission is documented or the material is replaced with an independently authored implementation

### Requirement: Explicit platform compatibility
The suite SHALL publish a tested Control4 platform/API baseline derived from its selected template version. The separate HA companion SHALL retain a minimum of HA 2026.11.1 unless a separately approved change modifies it. Unsupported platforms MUST receive an actionable incompatibility message.

#### Scenario: Unsupported Control4 runtime
- **WHEN** a driver starts on a runtime below its qualified API baseline
- **THEN** it explains the incompatibility and does not start partially functional control
