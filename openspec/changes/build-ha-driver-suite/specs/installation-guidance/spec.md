## Purpose

Let homeowners and installers install, migrate, operate and troubleshoot the initial suite without relying on knowledge from the prototype conversation.

## ADDED Requirements

### Requirement: Complete role-based installation
The initial release SHALL include homeowner and Composer-installer guides covering prerequisites, downloads, HA connection credentials, optional companion installation, C4 package installation/binding, selection and verification. Each step MUST state its expected result and identify who can perform it.

#### Scenario: Homeowner has no Composer
- **WHEN** the homeowner follows first-install instructions
- **THEN** the installer extracts the release ZIP, selects all included driver packages together in Composer's Add or Update Driver dialog, and enables automatic updates once on the Coordinator
- **AND** after that handoff, the homeowner can operate the suite and receive eligible automatic updates without Composer access

### Requirement: Accurate HA component instructions
Documentation SHALL distinguish the custom integration from HA OS apps/add-ons and identify optional dependencies. It MUST cover the current Marketplace installation/setup path, pilot repository-link installation where required, and manual recovery without claiming unapproved catalog publication.

#### Scenario: Install the pilot companion
- **WHEN** the integration is not yet listed in the Marketplace catalog
- **THEN** the guide explicitly identifies the temporary repository-link path and does not describe it as an accepted catalog listing

### Requirement: Family-specific setup and feature reference
Light and Switch SHALL each have worked examples and a reference for properties, native controls, programming, bindings and limitations. Examples MUST include a direct HA light, a binary switch used as a light, a general-purpose relay, connected C4 lighting, gestures and supported LEDs.

#### Scenario: Configure a switch controlling a C4 group
- **WHEN** the installer follows that example
- **THEN** the guide identifies the correct physical selection, operating mode, app target and Controller Link roles without creating a redundant HA-exported C4 group

### Requirement: Migration and recovery
The Switch migration guide SHALL direct the installer to the open **Migrate switch drivers** section at the top of the Coordinator's Quick Setup page while migration or removal work remains. It SHALL explain how migration moves control to new drivers for the same hardware, how to confirm the project backup, how to resolve any specific programming or scene work reported by the wizard and how to restore the original project.

#### Scenario: Pilot driver fails during migration
- **WHEN** the installer rolls back using the guide
- **THEN** the previous packages/project can be restored without depending on automatic conversion of new instances

### Requirement: Troubleshooting by boundary
Manuals SHALL distinguish network/authentication, filtered discovery, companion preparation, HA entity availability, subscription, C4 binding, proxy feedback and update failures. Each path MUST identify the minimal diagnostic evidence to collect without exposing credentials or enabling indefinite verbose logging.

#### Scenario: HA is connected but gestures do not work
- **WHEN** a user follows the troubleshooting flow
- **THEN** it checks preparation, subscription, snapshots and bindings rather than repeatedly reinstalling or broadening discovery

### Requirement: Versioned and tested manuals
Release manuals SHALL identify their compatible C4/HA versions and contain tested initial-install and upgrade results. New-family instructions MUST remain marked as roadmap until implemented. GA MUST include validated Marketplace installation and developer/build/maintenance documentation.

#### Scenario: Follow a release's instructions on a clean lab
- **WHEN** an operator uses only the published manual and release assets
- **THEN** the initial supported setup completes and deviations are corrected before that release is qualified

### Requirement: Instructions for each existing installation
The guide SHALL identify the correct same-instance Coordinator and Light update, user-requested Switch migration and backup and recovery steps for the exact qualified packages.

#### Scenario: An installer starts with a mixed project
- **WHEN** they select instructions for their installed packages
- **THEN** they can apply one suite release to all affected drivers, confirm the migration, verify that the destinations run the same revision and restore the original project if cutover fails
