## Purpose

Keep installed suite drivers current through automatic, coordinated release installation that does not require homeowners to have Composer.

## ADDED Requirements

### Requirement: Automatic release channels
The HA Coordinator SHALL offer Production and Pre-release channels. Child drivers MUST NOT expose independent upgrade settings or actions. Production MUST be the default and exclude prereleases; Pre-release MUST include eligible prereleases. Updates from the selected channel MUST install automatically when enabled, without a Composer action or per-release user approval.

#### Scenario: New Production release
- **WHEN** a newer eligible production release is available and automatic updates are enabled
- **THEN** the installed suite downloads and applies it without requiring the homeowner to use Composer

### Requirement: Suite-level update settings and ownership
The HA Coordinator SHALL own the update setting and status for all installed suite packages on the controller. One operation MUST apply a single compatible release to the installed family, including installed packages without a current HA binding. Multiple Coordinator instances MUST NOT run competing operations against the same installed package files. The settings MUST survive reset/restart. Uninstalled families MUST NOT be added merely because their assets exist in a release.

#### Scenario: An installer enables updates once
- **WHEN** the installer enables automatic updates on the Coordinator
- **THEN** installed Light and Switch packages follow the Coordinator's channel and release without separate settings on either child

#### Scenario: Many lights share a Coordinator
- **WHEN** their scheduled update check becomes due
- **THEN** one suite operation checks and updates the installed packages rather than every light independently performing installation

### Requirement: Qualified release selection
An update SHALL use versioned release assets matching the exact installed package identities. Missing, malformed, incomplete or incompatible release assets MUST produce a visible failure without replacing the working installation. A manifest MUST identify the selected versions and artifact integrity evidence.

#### Scenario: Release is missing Switch
- **WHEN** the installed suite includes Switch but its required release asset is absent
- **THEN** the update reports the incomplete release before installing any of that operation's packages

### Requirement: Ordered and observable installation
All required assets SHALL be fetched and validated before installation begins. Package reloads MUST be sequenced with Director acknowledgment and the coordinating driver reloaded last. Partial failure MUST be visible, preserve a recoverable path and MUST NOT be reported as a fully successful update.

#### Scenario: A child update fails
- **WHEN** Director rejects a child package during the update sequence
- **THEN** the suite reports which package failed and retains enough version information to retry or restore the prior qualified release

### Requirement: Release and lifecycle recovery
Update execution SHALL retire old owned callbacks, subscriptions, timers and held outputs without duplicate control. After reload, consumers MUST recover their selections/settings and reacquire fresh state. An interrupted update MUST NOT cause an uncontrolled repeated reload loop.

#### Scenario: Coordinator reloads last
- **WHEN** its own package is installed after child packages
- **THEN** the old update lifetime cannot continue sending commands and the replacement reconnects using saved configuration

### Requirement: Diagnostic independence
Automatic update operation SHALL expose concise current/available version, channel, outcome and actionable error information. It MUST NOT require verbose logging or include HA credentials in update requests or reports.

#### Scenario: GitHub is temporarily unreachable
- **WHEN** a scheduled release check fails
- **THEN** existing device control continues and the update status identifies the temporary failure without a reload
