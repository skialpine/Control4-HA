# Spec Delta

## Purpose

Expose Home Assistant binary and generic readings as reliable Control4 feedback, connections and programming inputs.

## ADDED Requirements

### Requirement: Binary sensor feedback and connections
Binary Sensor SHALL expose the configured binary entity through Control4 contact feedback and corresponding programming transitions. The setup SHALL use a recognized device class to describe the signal and preserve any qualified installer-selected interpretation.

#### Scenario: Door feedback and loss of signal
- **WHEN** a configured door sensor changes from closed to open and later becomes unavailable
- **THEN** Control4 reports the transition and distinguishes loss of feedback from a closed contact
- **AND** reconnecting restores the current state without replaying stale transitions

### Requirement: Typed generic sensor readings
Generic Sensor SHALL display the confirmed value and applicable unit. It SHALL use reported metadata for compatible temperature and humidity connections, preserve qualified fallback settings, and expose typed values to Programming.

#### Scenario: Valid zero and a later unknown reading
- **WHEN** a compatible sensor reports a numeric zero followed by an unknown state
- **THEN** Control4 publishes zero with its applicable unit, then marks the reading unavailable without publishing a substitute measurement
