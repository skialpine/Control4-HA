## Purpose

Keep every driver family connected to HA through a bounded, observable transport that protects selected-device ownership and remains safe across reconnects and updates.

## ADDED Requirements

### Requirement: Shared connection and exact subscriptions
All consumers of one Coordinator SHALL share its authenticated HA connection. State subscriptions and initialization reads MUST be limited to explicitly selected endpoints and required linked targets. Healthy control MUST use pushed feedback rather than repeated polling.

#### Scenario: Multiple drivers select the same endpoint
- **WHEN** several family drivers subscribe to one HA entity
- **THEN** the Coordinator shares the underlying subscription and retains it until its last consumer releases ownership

### Requirement: No broad discovery fallback
Queries SHALL request only relevant domains, attributes or exact entities. A failed filtered request MUST produce an actionable error and MUST NOT trigger an all-state or full-registry fetch. Optional companion absence MUST retain filtered native discovery.

#### Scenario: Filtered discovery fails
- **WHEN** HA rejects a scoped query or returns an invalid response
- **THEN** discovery reports that failure without attempting a broader read

### Requirement: Correlated command results
Service requests SHALL retain caller/selection correlation and expose rejection, timeout and transport failure distinctly. A queued or accepted command MUST NOT be presented as confirmed physical state. Delayed results from an old selection MUST NOT alter its replacement.

#### Scenario: HA rejects a thermostat command
- **WHEN** HA returns a validation error for a requested setpoint
- **THEN** the initiating thermostat reports failure and keeps its last confirmed feedback

### Requirement: Independent readiness and recovery
Consumers SHALL distinguish Coordinator binding, HA transport, selected entity availability, subscription readiness and optional companion preparation. Reconnection MUST acquire fresh selected-state evidence before live gestures become actionable; historical snapshots MUST NOT replay programming events.

#### Scenario: HA is connected but an event subscription is pending
- **WHEN** a gesture-capable driver has not received subscription confirmation and a fresh snapshot
- **THEN** it reports the pending boundary rather than claiming HA is disconnected or forwarding stored gestures

### Requirement: Lifetime isolation and cleanup
Selection changes, disconnects, destruction and reloads SHALL retire affected reads, subscriptions, callbacks and scheduled work. Old feedback MUST NOT operate a replacement target. Cleanup MUST release held logical outputs and remain effective when one resource's cleanup fails.

#### Scenario: Selection changes before its property callback
- **WHEN** a selected endpoint or mode has changed and an unrelated HA message arrives
- **THEN** old holds and stale target state are retired before any early routing rejection can defer cleanup

#### Scenario: Driver is updated with work outstanding
- **WHEN** a callback from the previous driver lifetime executes after destruction
- **THEN** it sends no commands or notifications and does not recreate resources

### Requirement: Credentials and payload privacy
Tokens SHALL be stored in password-protected configuration, excluded from routine logs and diagnostics, and withheld from redirected destinations. Diagnostic traces MUST be opt-in, bounded and independent of control decisions.

#### Scenario: Diagnostic collection after an authentication failure
- **WHEN** an installer exports diagnostics
- **THEN** the report identifies the failed authentication boundary without including the token or raw private device payloads

### Requirement: Upgraded Coordinator with existing children
An updated Coordinator SHALL serve existing BP and prototype children through the original provider and retain TLS settings, events, variables, scoped state, service, catalog and preparation behavior.

#### Scenario: Only the Coordinator has been updated
- **WHEN** an existing bound child requests state or controls its selected load
- **THEN** the child receives its original wire format through the retained binding and the load feedback confirms the command
