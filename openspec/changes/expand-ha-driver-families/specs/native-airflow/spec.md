# Spec Delta

## Purpose

Give Control4 users native fan power and speed control that matches their Home Assistant device.

## ADDED Requirements

### Requirement: Fan speeds reflect device capabilities
Fan SHALL support native power, confirmed speed, and qualified keypad connections and Programming. Speed controls SHALL reflect the device's available steps. Additional controls such as oscillation or presets SHALL appear only when both the endpoint and the Control4 surface support them.

#### Scenario: Binary and multi-speed fans share a project
- **WHEN** a project has an on/off fan and a discrete-speed fan
- **THEN** the on/off fan shows power controls and the discrete-speed fan exposes its supported speed levels
- **AND** a command followed by a different device-reported speed displays the confirmed speed
