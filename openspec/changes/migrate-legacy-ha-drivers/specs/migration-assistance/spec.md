# Spec Delta

## ADDED Requirements

### Requirement: Review eligible legacy HA Lights and Switches

Quick Setup SHALL offer an explicit migration review for qualified legacy HA Light and Switch sources. The review SHALL preserve the source room and show the project name, effective HA target, relevant settings, and discovered project references. Assessment SHALL be read-only and indicate any missing or ambiguous evidence.

#### Scenario: Source metadata is incomplete or unrecognized

- **WHEN** the driver type, interface, or saved selection cannot be verified
- **THEN** the review explains which check is outstanding and leaves the original in control

#### Scenario: The source was installed as a Light for an on/off load

- **WHEN** a legacy Light controls a verified HA switch entity
- **THEN** the review proposes a binary Light and preserves its lighting and scene role

#### Scenario: Home Assistant hides a working load

- **WHEN** an enabled load with a verified registry identity is hidden in Home Assistant
- **THEN** the installer can select it if it is the only usable representation of that load
- **AND** a legacy driver using a hidden switch is offered a compatible visible light when its non-inverted wrapper relationship is verified
- **AND** the review shows the proposed target and migration verifies both identities and the relationship before and after cutover
- **AND** disabled, unavailable, diagnostic, and Control4-exported hidden entities remain ineligible

#### Scenario: Another driver already controls the selected target

- **WHEN** an existing Control4 driver controls the same effective Home Assistant load
- **THEN** the review identifies the existing device and withholds automatic cutover until ownership is resolved
- **AND** ordinary Quick Setup identifies a known legacy owner before adding or configuring a second driver for the same load

#### Scenario: An installed device appears under a different discovery choice

- **WHEN** Quick Setup can verify that a choice has the same registry load as a saved physical selection, or that it is the only eligible load of a saved button source
- **THEN** the add list excludes the installed device and keeps independent loads available

#### Scenario: Two Home Assistant installations have the same entity ID

- **WHEN** a legacy source and the Coordinator report the same entity ID
- **THEN** migration verifies that the reviewed source and destination identify the same installation and load before transferring control
- **AND** an unverifiable or changed installation or load leaves the original in control

#### Scenario: The legacy driver and Coordinator use the same configured route

- **WHEN** the legacy driver and Coordinator use the same canonical scheme, host and port
- **THEN** Quick Setup uses that configured route as installation evidence
- **AND** Quick Setup rechecks the configured route before transferring control

#### Scenario: Different network endpoints reach the same Home Assistant installation

- **WHEN** the legacy driver and Coordinator use different configured routes, even if those routes share an address
- **THEN** fresh proof from both routes can establish a shared installation without sending Coordinator credentials to the legacy route
- **AND** Quick Setup rechecks the evidence before transferring control

#### Scenario: A verified separate installation uses the same entity ID

- **WHEN** ordinary Quick Setup finds a matching legacy entity ID on an independently verified separate installation
- **THEN** that legacy driver does not count as an owner of the selected load
- **AND** uncertain evidence leaves any potential ownership conflict in review

### Requirement: Preserve legacy HA project references

The migration SHALL account for the legacy driver and its proxy, including incoming and owned programming, relay and keypad bindings, load group membership, and Advanced Lighting Scene membership. It SHALL verify that transferred references preserve their original behavior and settings, including scene levels, rates, tracking, and other configured scene options.

#### Scenario: One Light belongs to several scenes

- **WHEN** the installer reviews a Light with direct or group-based scene participation
- **THEN** the review shows the affected scenes and groups and distinguishes the references that can be moved or checked in Composer
- **AND** after transfer the migration verifies membership and saved settings for each affected scene or group before offering removal
- **AND** changes to unrelated members in an affected scene or group block approval
- **AND** before releasing a Light's original Home Assistant connection or approving removal, the migration checks the native membership of every scene in the current Director scene inventory, including scenes whose project snapshots show no relevant members

#### Scenario: Direct lighting scene assignments can be moved automatically

- **WHEN** the installer approves a migration involving direct scene loads with one saved action each
- **THEN** Quick Setup can stage the corresponding replacement members through the Advanced Lighting agent
- **AND** it verifies the complete saved settings and sibling membership in every affected scene before removing the original members
- **AND** it confirms the approved scene plan and the removal intent in Director storage before issuing the first original-member removal
- **AND** a mismatch before removing original members keeps the migration in review with the affected scene identified
- **AND** when color tracking and the scene color action are disabled, Director may initialize unused color coordinates. For a single non-flashing replacement Off action, the disabled color fade may equal the level fade or use zero to represent that same level fade. All active settings and original and sibling scene members must still match.
- **AND** preview approval, staging, recovery, and removal use the same comparison for original, replacement, and sibling members. Unused tracking coordinates may differ only when tracking and every color action on that member are explicitly disabled.
- **AND** opt-in Coordinator logging records the failed check and the names of differing scene fields.

#### Scenario: An automatic scene transfer is interrupted after removal begins

- **WHEN** Quick Setup has saved its recovery checkpoint and an original scene member may have been removed without completing cutover
- **THEN** Quick Setup requires restoring the project backup and withholds further migration and removal approval
- **AND** the recovery instruction remains visible after reopening Quick Setup

#### Scenario: Scenes moved but the replacement selection timed out

- **WHEN** the original gateway connection is verified and a saved migration check confirms all scene references have moved correctly
- **THEN** Quick Setup offers Continue migration after refreshing or reopening the page
- **AND** the original gateway stays bound until the replacement claims the verified selection offer for that migration

#### Scenario: An agent action targets the old device

- **WHEN** a Timer Agent or another device contains programming that targets the legacy driver or its proxy
- **THEN** the review identifies the source event and the required action change
- **AND** an unresolved action keeps the affected row pending

#### Scenario: The old driver owns an event or an action cannot be verified

- **WHEN** a programming reference has no verifiable transfer
- **THEN** Quick Setup identifies the limitation before staging or supports a verified transfer of that reference

#### Scenario: A native Light event starts or stops a timer

- **WHEN** a native Light V2 On or Off event has one enabled Timer Agent command with a static timer ID
- **THEN** Quick Setup lists that event and any incoming commands that target the light
- **AND** cutover verifies that the same timer command and argument are on the matching replacement event and that the original event has been cleared
- **AND** an unsupported script identifies its device and event before staging

#### Scenario: A legacy keypad link has no verified equivalent

- **WHEN** a used link applies a brightness, temperature, or hue action whose equivalent cannot be verified
- **THEN** the review shows the linked keypad and required behavior and leaves the original usable until the reference is resolved

### Requirement: Verify replacement settings before cutover

The migration SHALL require a project backup and explicit approval of the reviewed plan. It SHALL preserve verified settings and require review of any setting that cannot be read or mapped. It SHALL verify target feedback and recheck references and ownership before cutover. A changed plan or failed verification SHALL keep the affected original usable or require backup recovery.

#### Scenario: An installation has a compatibility override

- **WHEN** a legacy Light uses a nondefault supported light type, color format, or temperature range
- **THEN** the review displays the original and proposed settings and verifies the replacement settings before cutover

#### Scenario: Supported transfer cannot preserve a reference

- **WHEN** a reference requires an installer change
- **THEN** Quick Setup shows the exact Composer location and expected result and rechecks the reference after the installer continues

#### Scenario: Progress is interrupted after staging

- **WHEN** the installer reopens Quick Setup
- **THEN** it finds the recorded replacement, rechecks affected state, and offers the next safe step without duplicating the device or changing an unreviewed reference
- **AND** automatic driver installation waits while a staged migration still has work to do

#### Scenario: An explicit suite update happens while a replacement is staged

- **WHEN** the original still owns the connection, the replacement is blank, and the saved plan and project identities can be verified
- **THEN** one explicit Continue revalidates the stage on the new release and resumes using the saved plan
- **AND** an interrupted transfer follows the recovery path, while an unverifiable stage before cutover remains available to check

#### Scenario: An older release stored a generic backup warning for an intact stage

- **WHEN** an installer opens a saved migration that was blocked by the generic release warning
- **THEN** Quick Setup offers a check of the original driver, blank replacement and applicable scene members
- **AND** a successful check reopens the stage for a separate explicit continuation
- **AND** an inconclusive check leaves the project unchanged and explains what to check

#### Scenario: The replacement passes testing

- **WHEN** the replacement has verified feedback and references and the installer completes the listed functional checks
- **THEN** the replacement keeps the original name and room and the wizard offers a separate review of the clearly named retired driver
- **AND** the review identifies the backup or verified recovery path and leaves removal to the installer

#### Scenario: A mixed batch has completed drivers and outstanding connection checks

- **WHEN** Quick Setup offers confirmation for a completed driver in a mixed batch
- **THEN** it shows that driver's pending scene and programming tests before accepting confirmation
