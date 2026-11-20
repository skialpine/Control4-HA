## Purpose

Give every supported driver family a consistent, capability-driven setup experience that exposes useful endpoints without manual entity configuration for normal installations.

## ADDED Requirements

### Requirement: Consistent configuration surfaces
Every family SHALL offer searchable device selection, selected-device identity, relevant capabilities, understandable status and compact configuration. The picker SHALL filter its existing choices by name, room or exact entity ID. An ID outside the current list MUST NOT offer a selection action. Properties SHALL expose applicable settings directly, and Troubleshooting SHALL provide connection and preparation details and opt-in logging.

#### Scenario: Configure a lock after a light
- **WHEN** an installer opens the lock's setup
- **THEN** device selection and diagnostics follow the same interaction model as Light while presenting lock-specific capabilities and settings

### Requirement: Automatic Coordinator connection during initial setup
An unconfigured suite consumer SHALL connect during initialization when there is exactly one eligible Coordinator with the matching suite output. It MUST preserve an existing manual or retained original connection, and MUST leave the choice to the installer if more than one compatible Coordinator is present. A later restart MUST honor an intentional disconnection.

#### Scenario: Add a Switch to a project with a single Coordinator
- **WHEN** the new Switch starts with an empty Coordinator input and exactly one compatible Coordinator is installed
- **THEN** the Switch connects automatically and Device Setup can open the Home Assistant list

#### Scenario: Add a Switch to a project with two Coordinators
- **WHEN** the new Switch starts with an empty Coordinator input and two compatible Coordinators are installed
- **THEN** it leaves the input unbound and directs the installer to Composer Connections

### Requirement: Readable button Programming events
Light and Switch SHALL offer single, double and triple taps for buttons that report them, together with supported hold and release events. Higher tap counts MUST NOT appear as Programming events. On existing installations, keep IDs for supported events and reserve retired IDs to prevent any existing reference from selecting a different gesture.

#### Scenario: Find a triple tap on a multi-button switch
- **WHEN** the selected device reports five tap counts on each of several buttons
- **THEN** Composer shows the first three counts together under each button name, with no fourth or fifth tap entry

### Requirement: Appropriate and deduplicated choices
Selectors SHALL include usable native and companion loads for the family. The lighting picker SHALL include lights and compatible switches and toggle helpers. It SHALL exclude diagnostic, configuration and C4-exported entities. It SHALL present one most-capable choice for equivalent representations and keep independent loads selectable.

#### Scenario: Multiple functions share one device
- **WHEN** a device exposes an independent light, fan and sensor
- **THEN** each appears in its applicable selector rather than being lost by whole-device deduplication

#### Scenario: Relay and gesture representations are equivalent
- **WHEN** the selected family can use a prepared gesture representation of the same endpoint
- **THEN** the picker shows one most-capable choice, and the exact IDs of equivalent representations still find that row

### Requirement: Browsing is read-only
Opening, searching and closing setup SHALL NOT create C4 instances or HA controls, attach unused source listeners or modify hardware settings. Preparation MUST happen only after a user commits a choice.

#### Scenario: User abandons selection
- **WHEN** a user browses devices and closes the picker without selecting one
- **THEN** no persistent device or gesture control has been created

### Requirement: Prepared selection and sensible defaults
Committed selections SHALL resolve their endpoint, optional gestures and supported LEDs automatically when the companion is installed. Initial operating mode MUST reflect selected capabilities and established C4 bindings. Explicit user overrides MUST survive restart, and a broken explicit load link MUST NOT silently fall back to another load.

#### Scenario: Select a paddle already bound to a C4 light
- **WHEN** its selection is committed with no explicit mode override
- **THEN** the driver defaults to connected-C4 control and identifies the target light

### Requirement: Shared responsive discovery
Drivers SHALL share one Coordinator-owned selector dataset, verify its revision and avoid duplicate consumer caches. Ordinary setup SHALL work through scoped discovery without the optional companion. Selecting a current listed load SHALL use the verified revision without a separate Home Assistant confirmation.

#### Scenario: Open a second driver's picker
- **WHEN** the shared catalog revision has not changed
- **THEN** the picker reuses that dataset rather than downloading it again

#### Scenario: Commit a listed load
- **WHEN** the site confirms an eligible current choice
- **THEN** the normal subscription supplies live state, and a physical device receives only its required preparation

### Requirement: Honest setup and errors
An unconfigured driver SHALL say it is not configured rather than report an invalid entity. Missing integration, permission denial, unavailable endpoint, pending preparation and disconnected transport MUST have distinct explanations and recovery steps.

#### Scenario: Companion preparation is denied
- **WHEN** HA accepts the connection but rejects administrative preparation
- **THEN** setup identifies the permission problem without reporting HA as disconnected or claiming the device is ready

### Requirement: Optional selected-device commissioning
The Coordinator SHALL offer an explicit preview for adding selected devices, including proposed family, room, name and existing-match decisions. It MUST NOT automatically add every discovered entity, create duplicate instances on rerun or remove existing instances without explicit action.

#### Scenario: Repeat an interrupted commissioning pass
- **WHEN** commissioning is restarted for previously selected devices
- **THEN** it identifies completed additions and resumes without creating duplicates

### Requirement: Shared Quick Setup workflow
Drivers SHALL declare Properties before custom tabs and keep connection settings there. Quick Setup SHALL list Home Assistant devices on entry or type changes and retain room assignments and selections across filters. Quick Setup SHALL hide confirmed existing Control4 drivers by default and provide **Show all devices** to reveal them. A conflicting or unconfirmed match SHALL remain subject to project verification at review. Adding drivers SHALL require a summary and separate confirmation.

#### Scenario: Open an installed driver in Composer
- **WHEN** qualifying its landing screen
- **THEN** record which tab actually opens and the route to native proxy settings on that Composer version


#### Scenario: Choose devices in a constrained Composer pane
- **WHEN** the installer selects devices across rooms and changes the type or search
- **THEN** pending assignments survive, the next action stays accessible with one page scrollbar, and returning from review or cancelling makes no project changes

### Requirement: Built-in indicator configuration and native controls

Device Setup SHALL expose applicable indicator behavior, color and brightness for the selected physical Home Assistant device. It SHALL explain unavailable indicator metadata in the relevant device context. It MUST preserve native Light V2 authoring and distinguish Home Assistant indicator settings from linked Control4 keypad settings. Browsing SHALL leave configuration and hardware untouched.

#### Scenario: Change one indicator on a wall switch
- **WHEN** a prepared device reports several independent indicators and the user applies a supported color to one
- **THEN** only the selected channel receives that change, the page distinguishes command acceptance from reported state, and the other channels keep their settings
