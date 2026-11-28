# Spec Delta

## Purpose

Bring verified Home Assistant lock and alarm behavior into native Control4 security surfaces.

## ADDED Requirements

### Requirement: Confirmed lock and alarm state
Lock and Alarm Panel SHALL expose supported native controls, modes and Programming. Their feedback SHALL distinguish confirmed state from a pending or rejected action, loss of connectivity and any reported jam, transition or alarm trigger.

#### Scenario: Lock accepts a request and later reports a jam
- **WHEN** Home Assistant accepts a lock request and subsequently reports a jam
- **THEN** Control4 shows the jam without reporting a successful lock transition

#### Scenario: A panel advertises a subset of arm modes
- **WHEN** an alarm panel supports only home and away arming
- **THEN** Control4 offers the supported arm modes and the applicable disarm workflow

### Requirement: Security action credentials
Security actions SHALL use the selected endpoint and its supported credential policy. PINs and codes MUST be excluded from catalog results, user-facing errors, routine logs and exported diagnostics. Discovery and verification MUST NOT originate a physical security action.

#### Scenario: An alarm action needs a code
- **WHEN** the endpoint requires a code and a qualified credential flow has not supplied one
- **THEN** the action remains incomplete with actionable status and the system does not guess, queue or replay the code
