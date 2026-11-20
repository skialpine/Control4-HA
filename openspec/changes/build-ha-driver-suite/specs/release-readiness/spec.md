## Purpose

Make pilot and GA readiness explicit through scoped feature evidence, independently versioned HA dependencies, honest publication status and a deliberate user-feedback milestone.

## ADDED Requirements

### Requirement: Initial working-driver feedback milestone
This change SHALL end with Coordinator, Light and Switch packages at one revision, verified whole-suite update and recovery, verified Switch migration from both starting versions, lab/proxy test evidence, setup instructions and a user feedback handoff. Further device families are deferred. Legacy migration MUST start only from an explicit user action.

#### Scenario: Initial three drivers are ready
- **WHEN** the current release candidate passes the documented release, upgrade, installation and predecessor task checks
- **THEN** the user receives the qualified artifacts, evidence and scope, and work pauses for feedback before additional families

### Requirement: Qualified native feature matrix
Implemented families SHALL maintain traceable requirements, backend support, automated scenarios and native C4 verification status for their advertised features. A feature MUST NOT be marked physically verified because only a simulator or proxy shim passed.

#### Scenario: Scene engine passes local conformance tests
- **WHEN** no real Director/Composer test has been performed
- **THEN** scene behavior is marked locally verified and native scene eligibility/update stability remain explicitly pending

### Requirement: Coordinated independent HA compatibility
Each C4 release SHALL identify compatible separate HA integration versions and supported protocol contracts. Companion absence or incompatible versions MUST produce accurate behavior/status without silently broadening queries. HA code MUST remain in its own repository and release process.

#### Scenario: Companion version is incompatible
- **WHEN** the Coordinator negotiates an unsupported preparation/catalog contract
- **THEN** it reports that incompatibility and does not claim successful enhanced setup

### Requirement: Marketplace publication before GA
Suite GA SHALL be blocked until the separate HA integration has an accepted Marketplace catalog listing, a qualified published release and a verified clean installation through that listing. Submission alone or repository-link installation MUST NOT satisfy the gate.

#### Scenario: Marketplace review is still pending
- **WHEN** the C4 packages otherwise qualify
- **THEN** they can be supplied as clearly labeled feedback/prerelease builds but MUST NOT be declared suite GA

### Requirement: Marketplace validation and documentation
The HA publication gate SHALL include passing current catalog/HA validation, valid release metadata and branding, complete user documentation, and install/update verification on the isolated lab. The submitted package MUST be the same qualified version referenced by the C4 release.

#### Scenario: Listing is accepted but installs an untested version
- **WHEN** the final installation check identifies that version mismatch
- **THEN** GA remains blocked until the published version is qualified or corrected

### Requirement: Audit and update qualification
Release candidates SHALL undergo source/test audits, fixes and a post-fix re-audit. GA MUST include native Director evidence for initial installation, restart/reconnect, scene persistence and Composer-free update/recovery, with no unresolved Critical/High/Medium findings in the release scope.

#### Scenario: Update tests only cover a fake TCP endpoint
- **WHEN** the candidate is reviewed for GA
- **THEN** its real Director update stability remains unqualified and cannot be inferred from transport tests

### Requirement: Roadmap and provenance honesty
Published releases SHALL identify implemented families separately from future roadmap features, credit upstream sources and satisfy established reuse terms. GA MUST NOT imply official HA/Control4 endorsement or describe copied material with unresolved reuse terms as cleared for distribution.

#### Scenario: A roadmap family has not been implemented
- **WHEN** the initial release is published
- **THEN** documentation labels that family as planned rather than offering it as an available driver

### Requirement: First demo functional parity
The first demo SHALL pass each applicable baseline behavior on clean, updated and migrated configurations. Each inventory row SHALL name the baseline, inputs, expected effect, test and evidence tier. Missing and unverified behavior block handoff.

#### Scenario: A previous implementation supports a feature
- **WHEN** the candidate is qualified for the demo
- **THEN** the team verifies the functional outcome and retained project references and records operation latency separately

### Requirement: Measured common operations
The demo SHALL verify the measurement boundaries in documentation/performance-contract.md on recorded inputs, including helper and native setup, commands, confirmed feedback, scene flash, effects, linked controls, LEDs, startup and recovery. Record counts, distributions, clocks and logging settings. Separate local processing, service acceptance, confirmed state and HA-clock acknowledgment. Instrumentation MUST be opt-in and bounded.

#### Scenario: A test records only a successful service call
- **WHEN** the release matrix is reviewed
- **THEN** load feedback and any physical observation are separately verified and timed where measurable

### Requirement: Independent usability review
An independent UI reviewer SHALL check rendered changes at normal and constrained sizes, keyboard access, common vocabulary and next actions. The user SHALL verify the actual Properties landing and native controls in Composer.

#### Scenario: A shared setup control changes
- **WHEN** the team checks the change for handoff
- **THEN** the reviewer exercises each affected family and records the result and any remaining native checks

### Requirement: Task-based release evidence

The team SHALL qualify predecessor tasks before feedback handoff. The report SHALL identify the archive digests, baseline version, fixture capability, user task, result and evidence boundary. Each independent usability review SHALL exercise the full task from its normal entry point. Unavailable essential tasks MUST block handoff until restored or explicitly accepted by the user.

#### Scenario: A redesign hides the native Light editor
- **WHEN** the new Device Setup page passes rendered checks but a dimmer user cannot create and reopen a brightness preset in Composer
- **THEN** native authoring parity remains failed and the package stays in development qualification
