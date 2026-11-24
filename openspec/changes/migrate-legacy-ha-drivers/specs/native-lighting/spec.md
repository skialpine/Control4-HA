# Spec Delta

## ADDED Requirements

### Requirement: Advanced light compatibility overrides

Light SHALL use automatic capability detection by default. In Advanced settings it SHALL allow explicit light type, outbound color format (HS, RGB, or XY), and white temperature limit overrides where applicable. Overrides SHALL persist for the selected target and MUST NOT fabricate confirmed capabilities or state.

#### Scenario: An installer chooses a different color format

- **WHEN** an installer selects a supported color format for a compatible color Light
- **THEN** subsequent color requests use that format and the displayed state continues to follow Home Assistant feedback
- **AND** the selection persists after reopening the driver

#### Scenario: An installer sets temperature limits

- **WHEN** a Light supports white temperature and the installer saves a valid minimum and maximum
- **THEN** the driver exposes the effective range and respects it for temperature requests
- **AND** an invalid or incompatible range leaves the prior settings in place and shows an actionable validation message
- **AND** the displayed state follows valid Home Assistant temperature feedback outside the configured command limits

#### Scenario: A light needs manual capability configuration

- **WHEN** automatic detection yields incomplete capabilities and the installer chooses a supported light type
- **THEN** the driver uses that type for the selected target and confirms control through feedback
- **AND** choosing a different target requires a fresh check before any saved override applies to it
- **AND** saving settings for one target preserves the explicit settings of another target, including when the original target is selected again

#### Scenario: An installer restores automatic detection

- **WHEN** the installer clears a saved override
- **THEN** subsequent commands use the detected capability, color format, or temperature limits for that setting

### Requirement: Light unavailable programming event

Light SHALL expose a dedicated Control4 programming event when a previously available selected load becomes unavailable. It MUST NOT report a transient request failure or an unverified startup state as a confirmed loss of availability.

#### Scenario: A working light goes offline

- **WHEN** feedback confirms that a previously available selected load became unavailable
- **THEN** Control4 emits the unavailable event once for that loss
- **AND** duplicate unavailable updates do not emit another event before availability recovers
