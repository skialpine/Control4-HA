## Purpose

Qualify the suite against an isolated project HA environment and reproducible simulations without depending on ownership of every physical device or using production HA for development tests.

## ADDED Requirements

### Requirement: Dedicated Home Assistant environment
The project SHALL provision a dedicated HA Container on an available Linux Docker host, subject to host capacity and a unique container/volume/LAN port. Configuration, credentials and backups MUST be separate from production. The lab MUST NOT copy production credentials or pair production devices. A dedicated HA OS VM is the fallback after confirming available host resources.

#### Scenario: Start the development lab
- **WHEN** its instance starts from the documented lab configuration
- **THEN** it has a distinct identity and endpoint and cannot control production devices using imported credentials or radio attachments

### Requirement: Installation-type evidence boundaries
Container evidence MUST NOT be claimed as HA OS app/Supervisor or OS-specific Marketplace qualification. Those checks SHALL remain explicit prerequisites where applicable.

#### Scenario: Container services pass
- **WHEN** real HA service and subscription tests pass in the initial Container lab
- **THEN** their results qualify Container behavior and leave HA OS app and OS-specific Marketplace checks unverified

### Requirement: Explicit test-target verification
Automated service, restart, deployment and fault tests SHALL require a positively identified lab target and dedicated credentials. Missing, mismatched or production targets MUST fail closed. Native C4 tests MUST identify their controller/project and MUST NOT update production Director without separate authorization.

#### Scenario: A test is given the production HA endpoint
- **WHEN** the runner verifies the target
- **THEN** it refuses before issuing service calls or changing configuration

### Requirement: Functional simulated initial devices
Initial lab coverage SHALL include binary lights, dimmers, RGB/CCT lights, general-purpose switches and gesture/LED scenarios. Simulated devices MUST accept actual HA services and produce resulting feedback; merely writing desired values into HA's state API MUST NOT count as end-to-end control verification.

#### Scenario: C4 commands a simulated dimmer
- **WHEN** a level request passes through the actual driver and Coordinator into HA
- **THEN** the simulator records the service request, updates its state and returns feedback that the driver presents through its native proxy

### Requirement: Simulation coverage and gaps
The test strategy SHALL evaluate built-in Demo entities first and add controlled simulation only for missing cases. It MUST record coverage/gaps for every roadmap family and distinguish generic HA behavior from device-specific Z-Wave, Zigbee or physical timing qualification.

#### Scenario: A Zooz LED profile passes simulation
- **WHEN** its service/metadata tests pass without physical hardware
- **THEN** the report marks the contract/profile behavior verified and leaves actual radio/device parameter execution explicitly unverified

### Requirement: Layered fault and lifecycle tests
Qualification SHALL combine pure/adapter tests, actual packaged-driver transport tests, real lab HA service round trips and native C4 checks. Fault scenarios MUST include auth/service rejection, disconnect/reconnect, delayed/stale feedback, subscription failure, selection changes, malformed input and destruction/reload.

#### Scenario: HA disconnects during a hold
- **WHEN** the lab drops the live connection and later reconnects
- **THEN** held output is cleaned up and no gesture resumes until fresh readiness evidence arrives

### Requirement: Reproducible lab reset and compatibility runs
Lab state SHALL be resettable from project-owned seed configuration and backups, with pinned HA/companion/simulator versions recorded. Tests MUST cover HA 2026.11.1 and the supported current release, while optional CI containers MUST remain disposable and isolated from the persistent lab.

#### Scenario: Repeat a failed service test
- **WHEN** the lab is restored to its seed state and the recorded versions are used
- **THEN** another operator can reproduce the request/feedback scenario without production data

### Requirement: Honest native and performance evidence
Results SHALL distinguish simulated HA, fake C4 proxy, real Director and real hardware coverage. Latency reports MUST state measured boundaries and logging settings, include sample counts/ranges, and MUST NOT present HA acknowledgment round trip as physical tap-to-light or pure network latency.

#### Scenario: CI proxy conformance passes
- **WHEN** no real Director was involved
- **THEN** the release report does not claim Composer scene eligibility, update stability or physical behavior was verified

### Requirement: Packaged setup and installed-driver verification

The suite SHALL exercise UIRequest browsing on the packaged Light and Switch through their packaged Coordinator against the isolated Home Assistant lab and verify a correlated response. The suite SHALL also check installed-driver identity, selection and status after a cold in-place reload through supported, scoped Controller APIs.

#### Scenario: An installed Lua dependency is missing
- **WHEN** the device picker cannot start its local catalog request
- **THEN** the package test fails and the page reports a driver-side failure without implying Home Assistant is down

#### Scenario: A saved selection returns as a native table
- **WHEN** an existing driver reloads and Director returns its saved selection in table form
- **THEN** the validated device and its control route recover without reselection and an explicit clear continues to prevent adoption of stale properties
