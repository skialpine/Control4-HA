# Selected-device commissioning

**Properties** contains the Home Assistant connection settings. **Quick Setup**
lists devices from Home Assistant and lets you choose a Control4 room for each.
A device type change immediately displays the matching list. The initial
**Lights and switches** view shows eligible devices once, with their suggested
driver type. Checking several devices also lets you fill their empty rooms
together while keeping any rooms already chosen. A unique matching Home
Assistant area suggests the room. Missing or ambiguous matches require a room
choice.

The device list scrolls with the page. **Review devices** opens the read-only
summary after the selected devices have valid names and rooms. The separate
confirmation button applies the reviewed changes.

The Coordinator previews only the choices selected by the user. Each row shows
the driver family, destination room, proposed name and whether the action will
add a driver, keep a compatible match, finish an earlier addition or require
review. Keeping a match preserves its existing name, room, settings and
connections. A same-name instance by itself cannot establish a match.

The preview reads the current HA catalog and Control4 project inventory. It
creates no HA controls, Control4 devices, bindings or receipts. The user must
confirm the preview before the Coordinator can add anything.

The Coordinator checks the catalog revision and affected project devices again
on confirmation. It works one item at a time. After a Director callback it
checks that the endpoint is still eligible and the returned instance still
matches the approved file, model, room and name. It links only the exact
instance to the shared Coordinator connection and verifies both ends. Then it
requests setup through that linked driver and verifies its selected endpoint. An
unsuccessful item stops the batch. Earlier additions stay in the project.

## Recover an interrupted setup

Open a new preview with the same endpoint and room. A confirmed addition can be
reused after a lost binding or setup reply. A changed name, room, selection or
Coordinator link may require review. Commissioning never removes a device,
rewires an existing connection or renames an existing driver.

Director acknowledges an add asynchronously. The Coordinator records the request
before sending it and keeps an uncertain result when Director stops answering. A
return value of zero from the callback is a definite rejection. On timeout, or a
malformed reply, the Coordinator never resends that add. A late callback records
the instance ID for the next preview. If the callback is lost during restart,
one matching unconfigured instance can be shown as a recovery candidate. Confirm
its identity before approving that preview. If the candidate is missing or
ambiguous, the preview asks for review.

## Implementation and evidence

`src/ha/commissioning.lua` owns previews and the encrypted per-endpoint receipt
record. Its supported actions use the template's companion library for Director
callbacks, room placement, exact binding and Navigator updates. The shared
provider connection can have several consumers. The library's original
one-companion-per-binding method remains available to its older callers.

The DriverWorks AddDevice API supplies a file, optional room, optional name and
callback. It provides no caller-defined idempotency key or initial driver
settings. Bind returns no confirmation. The suite uses project read-back,
explicit confirmation on ambiguous recovery and a separate setup acknowledgment.
These interfaces are available on the suite's minimum OS version. The
[DriverWorks API reference](https://snap-one.github.io/docs-driverworks-api/#adddevice)
documents the add callback and binding arguments.

The Lua test suite covers two devices sharing the provider, explicit preview and
execution, uncertain/malformed and late replies, failed bind and setup, stale
revisions, existing matches and idempotent resume. Opt-in timing captures
preview, batch execution, native add callbacks and binding checks. Native
Director commissioning and its latency samples still need qualification.
