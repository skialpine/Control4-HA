# Spec Delta

## Purpose

Give Control4 projects native blind and garage door controls with accurate movement and endpoint feedback.

## ADDED Requirements

### Requirement: Independent blind movement and tilt
Blinds SHALL expose supported movement, stop, position and tilt through the applicable native controls and Programming. It SHALL preserve qualified keypad connections and keep position and tilt feedback independent.

#### Scenario: A shade has position and tilt
- **WHEN** the user changes tilt on a shade that supports position and tilt
- **THEN** Control4 sends only the tilt command and updates the tilt reading from confirmed feedback

### Requirement: Verified garage door state and control
Garage Door SHALL map supported open and close actions and confirmed endpoint state to the native garage control surface. It SHALL preserve qualified relay and contact connections. Ambiguous movement or missing feedback MUST NOT be presented as confirmed open or closed.

#### Scenario: A door has no position reading
- **WHEN** the endpoint reports opening followed by unavailable without reporting an open endpoint
- **THEN** Control4 distinguishes movement and loss of feedback from a confirmed open state
- **AND** it does not infer a position or repeat the command

### Requirement: Legacy Cover control options
Blinds and Garage Door SHALL expose a native Cover control, a saved position mode and a step-by-step keypad binding. Blinds SHALL allow the installer to select lift or tilt for the native control. Garage Door SHALL keep the original relay and the separate Open, Close and Stop relays and both limit contacts. An override MUST NOT imply an end limit.

#### Scenario: The installer selects open and close mode
- **WHEN** the installer saves the open and close position mode for a position-capable cover and reopens its settings
- **THEN** the saved mode persists and the native control offers discrete movement without intermediate position requests

#### Scenario: A keypad stops a cover and reverses its direction
- **WHEN** a step click is received while a cover is moving and can stop
- **THEN** the driver requests Stop and waits for confirmed feedback
- **AND** a later click at a confirmed intermediate position moves opposite the last confirmed direction, when that direction is known
