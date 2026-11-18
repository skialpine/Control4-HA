## Purpose

Provide general-purpose HA switch loads with useful native Control4 presentation, bindings and programming without treating every relay as a dimmable light.

## ADDED Requirements

### Requirement: Native switch experience
Switch SHALL expose On/Off/Toggle, confirmed relay feedback, a usable Navigator control and applicable relay/Button Link integration. A non-light load MUST work without adding a dimmer or advertising brightness. A switch intended for lighting SHALL also be selectable through Light's binary-light behavior.

#### Scenario: Configure a fireplace relay
- **WHEN** the installer selects its HA switch in Switch
- **THEN** Navigator offers an on/off control and relay/programming connections without brightness controls

### Requirement: Expanded programming coverage
Switch SHALL expose native state commands, events, conditions and useful variables, plus declared physical gestures where available. Startup and refreshed snapshots MUST initialize state without replaying occurrence-based programming.

#### Scenario: Switch starts in the On state
- **WHEN** its initial snapshot arrives
- **THEN** state conditions reflect On without firing a new physical press or turn-on occurrence

### Requirement: Explicit load and gesture ownership
App and relay commands SHALL operate only the selected resolved HA load. Explicit linked-load overrides MUST take precedence until changed or cleared. Gesture-only mode MUST NOT command a load, and unsupported connected-C4 lighting use MUST direct the installer to Light rather than silently selecting another mode.

#### Scenario: Linked load disappears
- **WHEN** a configured explicit linked load is unavailable or removed
- **THEN** load commands are blocked with an explanation rather than falling back to the physical relay

### Requirement: Capability and feedback honesty
Command acceptance SHALL remain distinct from confirmed switch state. Service failures and unavailable/unknown states MUST be visible; stale responses and pending selection changes MUST NOT preserve old relay authority or fabricate successful operation.

#### Scenario: A selection changes before its callback
- **WHEN** an unrelated HA delivery arrives before the property callback
- **THEN** old relay feedback is invalidated and cannot authorize the replacement endpoint

### Requirement: Supported buttons and indicators
Switch SHALL expose declared button identities and supported LED configuration without a two-button-only assumption. Unsupported colors or behaviors MUST NOT appear as applicable controls, and a color change MUST NOT alter the configured LED behavior.

#### Scenario: Indicator has a restricted palette
- **WHEN** the installer opens LED configuration
- **THEN** the available choices reflect that palette and selecting a color preserves behavior

### Requirement: Legacy Switch functionality
The new Switch SHALL provide equivalent manual helper control, button packets, multi-press events, indicator programming and useful diagnostics. The migration plan SHALL map every supported prior control and flag manual references.

#### Scenario: A configured Switch is migrated
- **WHEN** the user verifies a pre-existing automation or keypad operation
- **THEN** the selected device responds once and the expected feedback and indicator state return
