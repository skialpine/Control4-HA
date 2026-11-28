# Spec Delta

## Purpose

Expose supported Home Assistant climate controls through the native Control4 thermostat workflow.

## ADDED Requirements

### Requirement: Thermostat modes and setpoints
Thermostat SHALL reflect reported HVAC mode, current action, temperatures and supported setpoints. It SHALL distinguish single and dual setpoints, honor the qualified units and limits, and expose fan, preset and humidity settings only where their native use and HA support are verified.

#### Scenario: Dual setpoint with a different display unit
- **WHEN** an installer adjusts the heat and cool range on a supported endpoint configured for a different display unit
- **THEN** the qualified conversion preserves the intended bounds and Control4 reflects the confirmed Home Assistant range

### Requirement: Explicit thermostat auxiliary targets
Optional schedules, hold clearing and mode-selection mappings SHALL preserve the qualified predecessor workflow. Any auxiliary endpoint SHALL have a verified identity and role before it is used. Losing an auxiliary endpoint SHALL disable its dependent feature while keeping supported primary controls available.

#### Scenario: A saved mode-selection helper is unavailable
- **WHEN** the configured helper becomes unavailable and the climate entity still reports state
- **THEN** Control4 identifies the affected setting and continues to offer supported thermostat control
