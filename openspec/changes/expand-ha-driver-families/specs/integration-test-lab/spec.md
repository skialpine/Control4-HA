# Spec Delta

## ADDED Requirements

### Requirement: Reproducible simulation for every additional family
Qualification for all nine families SHALL use an isolated, resettable HA lab with the built-in Demo platforms and targeted simulators for cases Demo cannot reproduce. A simulator SHALL accept the relevant standard action where applicable and produce observable state changes or intentional faults.

#### Scenario: The tester has no physical garage door opener
- **WHEN** the tester starts qualification from the lab seed
- **THEN** a Demo or simulated garage cover supports selection and repeatable open/close behavior through standard HA APIs
- **AND** the tester can exercise movement, delayed feedback and loss of the final report without controlling physical equipment

### Requirement: Separate simulator and hardware evidence
Each family's qualification record SHALL distinguish shim-only tests, real Director or Composer with simulated HA devices, and tests with physical devices. Standard operation demonstrated with simulators SHALL be reported on that basis. Provider and hardware behavior MUST have corresponding evidence before it is represented as qualified.

#### Scenario: Native fan speeds work with a simulated fan
- **WHEN** the candidate passes native Control4 setup, commands and feedback against an HA simulation
- **THEN** the result identifies the simulator, HA version and Control4 surface
- **AND** it makes no claim about a physical fan's movement or response time

### Requirement: Reboot qualification on each side
After primary setup, command and feedback checks pass, the lab SHALL reboot Home Assistant and the Control4 controller in separate runs. Each run SHALL start with a connected mixed-family project, known endpoint states and recorded bindings. Recovery SHALL use the saved configuration. The lab SHALL record outage and recovery intervals separately.

#### Scenario: Home Assistant reboots while the controller stays up
- **WHEN** the lab restarts Home Assistant and waits for the API to recover
- **THEN** the Coordinator reconnects and the configured drivers publish fresh confirmed state
- **AND** the first post-reboot command succeeds without duplicate subscriptions, lost selections or a manual retry

#### Scenario: The controller reboots while Home Assistant stays up
- **WHEN** the lab reboots the controller and changes a lab fixture in Home Assistant while Director is down
- **THEN** the Coordinator and drivers restore their saved selections and bindings and sync the fixture's changed state
- **AND** initialization does not replay commands or transitions or create duplicate driver instances
