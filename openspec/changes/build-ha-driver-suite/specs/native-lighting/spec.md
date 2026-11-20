## Purpose

Expose supported HA lights and connected C4 lights through native Control4 lighting, including advanced features and accurate feedback without duplicated control ownership.

## ADDED Requirements

### Requirement: Capability-derived native lighting
Light SHALL expose On/Off, brightness, full color, white temperature and transition limits according to confirmed target capabilities. Binary HA switches selected as lights MUST receive power commands without brightness fields. Missing capability/state evidence MUST NOT be converted into guessed brightness or color.

#### Scenario: Select an on/off-only switch as a light
- **WHEN** Navigator requests a positive level or zero
- **THEN** the driver requests On or Off respectively and does not advertise a dimming slider or transmit brightness/transition parameters

#### Scenario: Select a color-temperature light
- **WHEN** valid CCT capability and current-state evidence arrive
- **THEN** Navigator exposes the supported temperature range and changes are confirmed through target feedback

#### Scenario: Choose a color while a direct Home Assistant light is off
- **WHEN** the user chooses a color without turning on the light
- **THEN** the light remains off and uses the chosen color the next time Control4 turns it on

### Requirement: Native advanced lighting features
Qualified lights SHALL support native presets, On modes, rates, Advanced Lighting Scenes, programming conditions and load groups where the target supports their behavior. Eligibility and settings MUST survive initialization, capability refresh and updates; unsupported features MUST NOT be advertised.

#### Scenario: Scene added to an existing light
- **WHEN** a light joins and executes an Advanced Lighting Scene and later receives capability feedback
- **THEN** it remains scene-eligible and retains its programmed scene and supported settings

### Requirement: Bounded dimming and cancellation
Holds, fades and scene execution SHALL honor supported timing and stop semantics. Selection changes, source failure, overriding commands and destruction MUST cancel owned scheduled work. A backend without verified hardware-stop behavior MUST NOT be described as supporting hardware fade cancellation.

#### Scenario: Release a software-driven dimming hold
- **WHEN** its release arrives or its source becomes unavailable
- **THEN** future dimming commands stop and no retired timer can resume them

### Requirement: Connected C4 app and paddle control
Connected-C4 mode SHALL mirror and control an ordinary C4 light or group through explicit bindings. App target selection MUST be visible and independent of individual paddle bindings. Logical On MUST preserve the target's current On preset, while an explicit level remains that exact request. Local app control MUST remain usable during HA loss.

#### Scenario: Target has a nighttime On preset
- **WHEN** the user selects On rather than an explicit slider percentage
- **THEN** the target applies its nighttime preset without a follow-up command forcing full brightness

### Requirement: Gesture occurrence integrity
Supported button taps, holds, releases and additional buttons SHALL be available to C4 programming. Only fresh, validated occurrences MUST fire actions. Historical, duplicate, foreign and malformed messages MUST NOT fire; identifiable owned malformed input MUST still clean up unsafe held output.

#### Scenario: Multi-button remote
- **WHEN** a remote with more than two buttons reports distinct supported actions
- **THEN** each button retains its identity and independently usable programming events

### Requirement: Supported indicator controls
LED configuration SHALL expose only discovered writable capabilities, including any palette or brightness limits. Color changes MUST preserve device LED behavior unless behavior was explicitly changed. Selection and startup MUST NOT write LED parameters merely to establish readiness.

#### Scenario: Change an indicator color
- **WHEN** the device is configured to illuminate only while its load is off
- **THEN** the color changes without changing that behavior to Always On

### Requirement: Single authoritative target feedback
The displayed load state SHALL derive from target evidence. The driver MUST NOT run competing scene, preset or ramp logic against another C4 light, or present a command request as physical confirmation. Explicit native synchronization MUST continue to resend supported state even when Composer display text is unchanged.

#### Scenario: Repeated target feedback
- **WHEN** identical target reports arrive during a native command
- **THEN** unchanged display properties are not rewritten, while changed native state and requested synchronization remain observable

### Requirement: Preserved Light behavior
Light SHALL preserve legacy device selection, all original operating modes, button and app links, standard and custom gesture programming, effects, indicators, target feedback and scene membership including connected targets and flashing.

#### Scenario: An existing configured Light is updated
- **WHEN** a saved program, scene or physical paddle controls the original target
- **THEN** the target and its indicators behave as configured and the same program and scene references work after reload
