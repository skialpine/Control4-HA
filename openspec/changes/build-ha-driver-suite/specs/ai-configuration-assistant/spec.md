## Purpose

Provide a distributable AI skill that helps users configure the supported HA integration and guides accurate installation and verification of the Control4 suite.

## ADDED Requirements

### Requirement: Portable versioned skill
The suite SHALL publish an installable skill with instructions, dependencies, reference mapping and compatibility information. It MUST use the release manuals as its installation source rather than maintain a conflicting second procedure, and MUST work with documented supported assistants/connectors.

#### Scenario: Install the skill from a release
- **WHEN** a supported assistant loads the published skill
- **THEN** it can find the matching manuals and connector requirements without local developer-only absolute paths

### Requirement: Inspect before configuring
The skill SHALL inspect the user's target HA instance, installed integration version, selected-device capabilities and intended C4 outcome before proposing configuration. It MUST distinguish optional companion preparation from ordinary native control and explain missing prerequisites.

#### Scenario: Configure a selected paddle
- **WHEN** the user wants it to control an existing C4 light
- **THEN** the skill identifies the supported HA inputs and the C4 binding/setup steps instead of assuming that commanding the HA relay is the intended behavior

### Requirement: Scoped authorized changes
The skill SHALL explain persistent changes, preserve existing configuration and honor the user's authorization scope. It MUST NOT silently alter unrelated automations, physical load mode, LED behavior, subscriptions or production/test instance selection. Credentials MUST use documented protected handling and MUST NOT be requested as pasted diagnostic output.

#### Scenario: Lab target does not match the user's requested instance
- **WHEN** the connected HA endpoint differs from the requested target
- **THEN** the skill stops before changing configuration and explains the mismatch

### Requirement: Honest Control4 assistance
The skill SHALL provide exact installer actions and expected verification for C4 installation, bindings, Navigator and programming. It MUST NOT claim to install or modify a Composer project without an available supported mechanism and authorized access. Ongoing automatic update instructions MUST remain usable by homeowners without Composer.

#### Scenario: No Composer access is available
- **WHEN** initial C4 package installation is required
- **THEN** the skill produces an installer handoff with the correct packages and settings rather than claiming installation succeeded

### Requirement: Verification and guided recovery
After authorized HA changes, the skill SHALL verify service results, entity readiness and required event/state evidence, then guide C4 checks separately. Failed or unsupported outcomes MUST be reported honestly with minimal diagnostics and recovery steps.

#### Scenario: Device preparation returns permission denied
- **WHEN** the assistant attempts an authorized preparation with insufficient HA permissions
- **THEN** it explains the permission requirement and does not replace the failure with a false disconnected diagnosis or a broad fetch

### Requirement: Skill scenario qualification
The skill SHALL be exercised against the isolated lab for fresh installation, existing configuration, missing companion, unsupported device, failure recovery and installer handoff. Test results MUST distinguish assistant-guidance validation from actual Composer or physical-device execution.

#### Scenario: Automated skill test lacks a real C4 controller
- **WHEN** its HA setup scenario succeeds
- **THEN** the result records HA success and leaves native C4 checks explicitly unverified
