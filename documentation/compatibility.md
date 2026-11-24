# Platform and identity contract

The selected template is v0.9.117 at the full revision in
`provenance/template-lock.json`. Its example-driver baseline is Control4 OS
3.3.0. The suite checks the package's `minimum_os_version` using the template's
`CheckMinimumVersion` before starting control. A rejected platform gets an
explicit required/current OS message. LuaJIT, DriverWorks callbacks, persisted
values, `light_v2` and `uibutton` are required. Director checks on CORE 1 used
Control4 OS 3.4.3. The [first-demo record](first-demo-packages.md) distinguishes
completed Director checks from remaining Composer, Navigator and physical
observations. A separate Director rehearsal also verified the manufacturer label
update.

HA Gesture Bridge 0.1.3 is the optional companion exercised on Home Assistant
2026.11.1 and 2026.11.2. The isolated matrix exercised the built suite against
both versions with simulated Director IPC. Check the exact release and test
scope in the [first-demo record](first-demo-packages.md) before updating.

| Family      | Candidate package      | Intended first-demo path                                                                                                                            |
| ----------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Coordinator | HA.Coordinator.c4z     | Update HA.Coordinator.c4z on the existing BP or prototype instance. Preserve legacy children on provider 1 and their programming.                   |
| Light       | HA.Light.c4z           | Update HA.Light.c4z on the existing BP or prototype instance. Preserve the light_v2 proxy, saved inputs, target links, scenes and gesture programs. |
| Switch      | Control4.HA.Switch.c4z | Preview and explicitly request migration from the old Switch, verify the mappings and rehearse rollback.                                            |

The canonical candidates restore the original archive names and models. The old
side-by-side development archives used the Control4.HA prefix for Coordinator
and Light. Existing side-by-side instances have their own identities. Quick
Setup checks project devices before offering to add a Light.

Use the Coordinator's migration wizard for an installed BP Switch. The CORE 1
Replace Obsolete rehearsal kept the project name and device ID. Director created
no Experience Button proxy. After restart the Coordinator and relay connections
were gone and the replacement had no Home Assistant selection. The saved
programs still sent the original BP command names. Adding a fresh replacement
creates its native proxy and lets the wizard transfer supported settings and
connections. See the
[DriverWorks proxy lifecycle](https://snap-one.github.io/docs-driverworks-fundamentals/#driver-updates).

Native qualification still requires running saved programs and scenes and
checking their targets on the original Director device IDs. When the thermostat
family enters scope, BP `HA.Thermostat.c4z` revision 108 follows the
user-requested migration path. Its released archive declares the `thermostatV2`
proxy on binding 5001. Other families receive their own qualification when
implemented. See the [first-demo package comparison](first-demo-packages.md).

### Additional legacy HA source assessment

The read-only profiles cover the October 8, 2026 Light and Switch archives.
Director inventory confirmed their Light V2 and Experience Button proxy
topologies and separate HA gateway links. The assessment checks the archive
identity, proxy and declared binding interface before treating a source as
qualified. It reads automatic and manual entity selections separately and checks
for another owner of the same Home Assistant target. The staged replacement flow
covers Switches and explicitly configured Lights when the selected load supports
the reviewed settings. Quick Setup lists the original and replacement Light type
and any applied color format or white temperature limits. It reads the saved
settings back from the blank replacement before releasing the original. A
rejected write or incompatible Home Assistant feedback leaves the original
connected. Automatically detected legacy Light types and specialized keypad
links still require a verified mapping.

A working load hidden in Home Assistant can appear in Quick Setup when it is the
only usable entity for that load. A verified visible light that wraps a hidden
switch without reversing its behavior takes precedence. During migration, Quick
Setup shows that light as the replacement target and rechecks both entities and
their relationship before and after transferring control.

The Coordinator compares configured routes and checks the exact Home Assistant
entity registry entry before and after cutover. An exact match of the configured
scheme, host and port verifies the same route. For different endpoints,
installations with the current HA Gesture Bridge can establish identity with a
fresh proof. The bridge answers a fixed read-only request for a random challenge
without receiving the Coordinator's access token. Matching proofs allow one
installation to use more than one address or port. A verified different HTTPS
route keeps migration blocked for that source but allows ordinary Quick Setup to
use the same entity ID on the Coordinator's own installation. An unavailable
proof or a different proof over plain HTTP leaves the relationship unresolved.
For a target with no registry entry, Home Assistant must explicitly confirm the
absence and return the exact entity's current state.

Fixtures verify that external brightness, white temperature and hue keypad links
appear for review and keep a bound original in place.

The Coordinator discovers Advanced Lighting references from the DriverWorks
project snapshot. That snapshot can lag scene edits, so the Coordinator reads
the current scene directly from the Advanced Lighting agent with `GET_SCENE`
when verifying a transfer. On a lab controller, the direct read matched
authenticated Director before and after moving an Off scene's load and restoring
it. Both reads confirmed the saved Off level and fade. Verification compares the
complete saved membership, including sibling settings. When the saved snapshot
omits hue, saturation, or color temperature, the agent's readback can include
those values on a disabled color action. The comparison accepts those extra
numeric values only when both snapshots show that the color action and color
tracking are disabled. It still checks any explicitly saved color values and all
brightness, fade, and tracking settings. For direct scene memberships with one
saved action per load, Quick Setup can stage the replacement through the
Advanced Lighting agent's DriverWorks UI request. It verifies every staged scene
before removing the original members. If a saved setting differs, it removes
members added by the current attempt when it can verify their identity and
guides the remaining edits in Composer. It checks Composer scene edits against
the agent's current scene and recognized load group edits against the project
snapshot. Qualified relay bindings move through Director and are checked at both
ends. Incoming unconditional power actions can be verified by their original
event, command, count and positions in the script after the installer moves
them. The installer can also move a native Light On or Off script that starts or
stops one static Timer Agent timer. Quick Setup verifies the matching event, the
saved timer action and the absence of the old script. Unsupported references
identify their device and event and keep the original in place.
[DriverWorks programming readback](https://snap-one.github.io/docs-driverworks-api/#getallcodeitems)

Trace records the outcome of the saved-stage check, the scene edits and their
readback, the removal checkpoint, the Control4 and Home Assistant checks after
cutover, and the final naming and testing status. Scene diagnostics report
member counts and differing field paths. The simulator exercises these messages
from reopening a saved migration through **Test the new drivers** and checks
that the scene checks leave private settings and names out of the trace.

In a native rehearsal on revision 2026112301, migration paused for an Advanced
Lighting scene and an incoming Switch action. The scene move preserved the saved
level, rate and tracking. Composer saved the original Select action in its
existing position on the staged Switch. The Coordinator accepted Select as
equivalent to Toggle, then connected both replacements after recheck. Composer
moved keyboard focus to **Test the new drivers**. Activating the saved scene
turned on its Home Assistant load. The saved Light event ran the Switch action
and Home Assistant confirmed the switch toggled. The test restored the loads to
their starting states. A tunable-white fixture advertised its saved limits to
Director and clamped a Light V2 request above the allowed range before sending
it to Home Assistant.

After the backup restore, Director showed the original drivers reconnected and
the temporary replacements removed. The scene targeted the original Light with
its saved level, rate and tracking. The saved Light event referenced the
original Switch. Director reset unused color-tracking coordinates during
restore. The native proxy controls and Home Assistant feedback were verified. A
visual Navigator walkthrough remains pending.

The migration review was walked in a browser at 1000 × 550 and 320 × 300 with
both Light and Switch rows. The reviewer found the affected scene and exact
programming actions, reached the migration check by keyboard, and confirmed that
successful recheck focuses the test heading. In the smaller pane the action
scrolls into view when focused. The Advanced settings review covered the Light
type, color format and white temperature controls. Native Composer and Navigator
verification is tracked in the native migration rehearsal.

The test results now list the exact programs and lighting scenes to run. The
independent browser review confirmed the test steps, keyboard access and Back
navigation at both pane sizes. **Confirm testing** opens a checklist before
**Check old drivers** reads removal eligibility. When a separate manual test is
pending, **Confirm tests for ready drivers** identifies the batch action. An
independent browser check at 1000 × 550 and 320 × 300 confirmed that completed
drivers still show their required tests alongside unresolved connections.
Keyboard focus reaches confirmation and the resulting removal review includes
only the eligible drivers. Reopening Quick Setup reads the saved migration
status. **Retry driver setup** reruns a blocked transfer after the installer
checks the affected device. The affected row distinguishes a missing or
unavailable Home Assistant device from a timed-out, disconnected, or denied
state read and explains what to check. **Check Composer changes** and **Check
connections** identify the checks that follow manual edits. In both browser
panes a failed retry kept focus on the retry button, a successful retry focused
the test heading, and **Review more drivers** opened the list without starting
another migration.

Three migrated lab Switches passed live On and Off tests through their native
Control4 buttons. Director feedback agreed with Home Assistant on all six
transitions. The replacements retained their intended loads and the migrated
relay connection. The original drivers had no remaining bindings or programming
references. The test restored all three starting states. The explicit Light
settings preview and retry paths passed the same two pane sizes in a browser.
Driver-entry-point fixtures cover persistence failures, readback, selection
followed by Home Assistant feedback, and a retry without detaching the original.
Native Composer verification of this new preview is still pending. The route
notices passed keyboard and layout review at both sizes. Separate rehearsals
against two pinned Home Assistant instances verified the companion proof
responses. Control4 fixtures verified matching aliases, distinct installations,
and changes before configuration and before migration naming. The authenticated
Home Assistant proof matched the anonymous responses over both HTTP and
certificate-verified HTTPS in the lab. Live Director verification found the
gateway address in the network connections API. The Coordinator now uses that
API because the project XML available to a running driver can omit addresses
that appear in a project backup.
[DriverWorks network connections reference](https://control4.github.io/docs-driverworks-api/#getnetworkconnections)
The companion continued to serve its existing catalog after the update. Composer
verification on the packaged candidate is pending. The separate **Light
compatibility** section passed keyboard review at 756 × 605 and 320 × 300. The
reviewer saved a range, corrected an invalid input, and confirmed that each
device shows only the settings it supports.

## Existing BP children on the updated Coordinator

The original Device Link connects Coordinator provider 1 to child input 999. The
candidate uses the actual reciprocal connections, installed model, filename,
manufacturer, version and saved selections to scope legacy traffic. The shared
Hub subscribes to the selected Home Assistant entities and reads their current
state after authentication. An enabled BP Thermostat mode selector also owns its
configured auxiliary select entity.

The original protocol sends state to everyone on provider 1. The candidate
includes only the state and attributes used by the original consumers of that
entity. Each original receiver filters by its configured entity. Debug Mode must
be Off for every original recipient because BP Base prints a packet before the
family checks its target. A current suite Light or Switch can share the provider
after its connection and its capability to ignore legacy packets without logging
are verified. An unknown receiver blocks legacy broadcasts. Signed, external and
unverified media artwork paths are omitted. A project that depends on signed
album artwork still needs a replacement for that part of the media experience.

For service commands, the original packet names the Home Assistant target and
carries no originating Control4 device ID. The Coordinator accepts only an
operation and parameters emitted by an identified original family for a target
currently selected by a compatible, bound driver. Two Lights can therefore both
turn on their own selected targets. A stale packet for a target outside the
verified project is dropped. When two drivers share a target, the original
protocol cannot identify which one sent a particular command. The account token,
service payload and alarm or lock codes are excluded from Coordinator diagnostic
output.
[DriverWorks ReceivedFromProxy and SendToProxy reference](https://snap-one.github.io/docs-driverworks-api/#receivedfromproxy)

The offline family qualification loads the original command sources and exact
Base revisions from the prototype Coordinator at revision
`9102878246e6fe670367d6efc3ed82db2bcc7b5c`. It covers Alarm Panel 102, Binary
Sensor 102, Blinds 102, Fan 104, Garage Door 101, Generic Sensor 110, Light 106,
Lock 102, Media Player 102, Switch 106 and Thermostat 108. It also runs two
separately configured Lights on one provider, including checks for cross-device
feedback, and the Thermostat’s auxiliary selector. The source versions for Fan
104 and Alarm Panel 102 need separate package qualification.

The runner loads the packaged Coordinator with its own bundled dependencies. The
original children send commands through the Coordinator’s Director entry points.
A simulated Home Assistant connection records requests and returns responses,
including after reconnection. A saved Composer Call Service action resolves a
Control4 variable and sends its typed value to the selected light.

### Existing prototype direct loads

Coordinator revision 2026111838 recognizes the pinned Prototype Light 1 and
Switch 107 on their retained Device Links. A prototype request identifies its
consumer and active entities. For a direct load, the Coordinator verifies that
the single requested entity is the bound driver's saved selection. It retains
the HA timestamp needed by the prototype's state parser and retires released
selections even during a disconnect. Verified readers of the same entity share
one subscription until the last reader releases it. Prototype load commands use
the same HA service-parameter checks as the suite. The shared wire establishes
project scope from verified packages and selections. It carries no independent
sender credential for a legacy service packet.

The prototype qualification used the two pinned reference archives in
[the baseline inventory](../provenance/first-demo-baselines.json).

The mixed-project run qualifies initial state, power commands, live feedback and
reconnect for those direct loads with simulated Director and HA transport.
Prototype gesture and linked-load state, scoped discovery, preparation, and the
native mixed-project update rehearsal remain open.

Optional template modules selected: `light ui`. Dependency discovery bundles
only actually required Lua modules per package. XML, deferred and version
helpers are included only where a dependency requires them. Expression, OAuth,
crypto, telemetry and DriverCentral licensing modules must not enter runtime
packages. `python3 tools/check_packages.py` verifies each build.
