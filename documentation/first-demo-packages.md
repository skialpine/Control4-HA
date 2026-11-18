# First-demo package comparison

Run the offline archive check after building the three candidate packages. It
uses the exact archive names, version and SHA-256 hashes in the build inventory
and verifies the inventory's own digest. Unlisted archives are ignored. The
normal development build and verification targets remain available.

```sh
make suite-verify-first-demo
```

The target checks the committed VERSION by default. Set DRIVER_VERSION
explicitly when inspecting an older build. The script writes a JSON report. Exit
status 0 means the archive checks passed. Status 1 means the report contains
blockers. Status 2 means an input is missing, malformed or different from its
pinned digest. An archive pass still requires the runtime and native evidence in
the first-demo plan.

To compare files outside the development build, supply all three paths. The
comparator reports the SHA-256 of each explicitly selected file. Pass
`--version` to require a particular version for all three.

```sh
python3 tools/check_first_demo.py --version 2026111801 \
  --coordinator /path/to/HA.Coordinator.c4z \
  --light /path/to/HA.Light.c4z \
  --switch /path/to/Control4.HA.Switch.c4z
```

## Reference archives

The six reference assets remain private. Their exact filenames, SHA-256 hashes,
source pins, archive versions and expected local locations are in
[first-demo-baselines.json](../provenance/first-demo-baselines.json). The
original BP Light and Switch inputs are the untouched v1.0.6 release assets. The
Coordinator 113 input is the stock build from the v1.1.3 source tag. The
prototype inputs are the pinned local Coordinator 114, Light 1 and Switch 107
builds. The prototype Light comes from the `light/` project in the Switch
repository and has the same install name as the original BP Light. The separate
HA Gesture Bridge source pin in the same manifest is revision
`c4f16485776afe2cca3eef914b1c88bc03060163` at version 0.1.2.

To keep archives outside the expected checkout and cache locations, put them
under these exact relative paths in a private directory.

| Reference directory     | Archive              | Driver version |
| ----------------------- | -------------------- | -------------- |
| `bp-coordinator`        | `HA.Coordinator.c4z` | 113            |
| `prototype-coordinator` | `HA.Coordinator.c4z` | 114            |
| `bp-light`              | `HA.Light.c4z`       | 106            |
| `prototype-light`       | `HA.Light.c4z`       | 1              |
| `bp-switch`             | `HA.Switch.c4z`      | 106            |
| `prototype-switch`      | `HA.Switch.c4z`      | 107            |

Pass `FIRST_DEMO_BASELINES=/path/to/references` to Make, or
`--baseline-dir /path/to/references` to the script. A hash mismatch stops the
check. Rebuilding a reference from the correct source can still change its ZIP
bytes. Use the pinned asset when reporting results.

## Reading the report

- Coordinator and Light are checked for in-place updates against both
  predecessors. The report checks package and model identity, version ordering,
  the legacy and suite binding classes, proxy IDs, programming commands and
  parameters, Actions, events, conditions and static variables. It checks the
  presence and types of legacy properties and their retained options. It
  requires the retained Coordinator token field and any additional suite token
  field to be password-protected with blank defaults. An additive suite binding
  may use a distinct ID while retaining each legacy binding. Package defaults
  are reported by presence only.
- Switch is checked as the new native migration target. The report records
  differences from both starting points as mappings to exercise during
  migration. It checks the new filename and model, `uibutton` proxy, relay and
  Coordinator bindings.
- Differences in branding, OS floor, connection labels, Action labels and
  default presence are flagged for native review. Installed device IDs, actual
  settings and secure credential presence, dynamic variable and event IDs,
  persisted state, programming references, runtime protocols, companion behavior
  and rollback need separate evidence in the restored lab project.

The candidates now build as HA.Coordinator.c4z and HA.Light.c4z under their
original model names. The early build comparison below identified compatibility
gaps. A matching filename and model allow an in-place rehearsal once the runtime
and binding prerequisites are ready. The new Switch archive requires a separate
migration rehearsal from both starting versions.

For build 20261117 (inventory SHA-256
`877fc0fb9edcdaf2a28cab133ea51ef71b172e185a76492056771e1705724a66`), the pinned
comparison reports the following archive gaps. Native-review items are tracked
separately in the checker output.

| In-place candidate | Original BP gaps | Prototype gaps |
| ------------------ | ---------------: | -------------: |
| Coordinator        |                3 |              4 |
| Light              |                3 |             35 |

Light retains input 999 and its original connection class. The original BP input
also requested automatic binding. That behavior still needs reconciliation with
selection of the intended Coordinator during setup. The isolated Home Assistant
fixture run passed 1,064 checks using these packaged drivers and a simulated
Director binding graph. It did not exercise a saved CORE 1 project or establish
full baseline parity.

### CORE 1 rehearsal baseline

The verified lab backup contains 58 project items, 20 binding edges and three
saved event scripts. None references original Light 52 or its proxy 53. The
project has Coordinator 42 version 114, original Light 52 and Switch 51 version
106, and a distinct development Coordinator 59. The original drivers connect to
provider 42/1 from input 999. The saved Light proxy is 53/5001. Record the
fingerprint with `python3 lab/compare_saved_project.py BEFORE.c4p` before the
update. Run
`python3 lab/compare_saved_project.py BEFORE.c4p AFTER.c4p --before-sha256 FINGERPRINT`
to compare existing item identities, room assignments, bindings and saved
scripts locally. The tool omits script arguments and credentials from its
output.

For the authorized Docker rehearsal, Coordinator 42 was pointed to the isolated
lab. Light 52 was set to the binary test light and Switch 51 to the switch
paddle. The private development tool's native listener on 52/1001 observed the
change after its initial notification, and proxy 53 operated the test light in
both directions. Confirmed state came from the isolated Home Assistant instance.
A listener verifies a live variable identity. A saved Composer event script
requires separate qualification.

On the first native Coordinator update, Director retained protocol 42 and the
development helper acknowledged the new package. A separate read of driver
metadata confirmed version 20261118. The original Light and Switch stayed
installed. The saved legacy endpoint matched the lab, its token was present, and
the new credential fields were empty. The connection did not recover on this
build. The TLS setting was not recognized, and the original HA URL variable was
still present at 1001 but empty. This run exposed a regression after the local
upgrade tests passed.

On revision 2026111802, Director reported the new version on both existing items
42 and 52. Coordinator 42 reconnected using the saved legacy Docker endpoint and
token and repopulated HA URL at slot 1001. Before and after updating Light 52,
its existing proxy 53 changed the binary fixture and restored its starting
state, verified in Home Assistant. Light retained the configured entity across
the update. The same native listener on 52/1001 observed two selection changes
before the update and two after, advancing from count 1 to 5. The post-update
changes used both the new manual property and the original Entity ID property.
Original Switch 51 remained at version 106. The update helper timed out waiting
for inventory on both updates, but a later independent inventory read confirmed
both installed versions. The saved graph comparison is recorded below.

The recovered pre-update backup matched the recorded SHA-256
6a1604088dd6070a308d55ee8d2b43f13651628b53b35ea6daf4e72e3e7039f8. Both backup
archives passed integrity checks. Their complete saved graphs matched across all
58 item IDs, names, parent rooms or devices and package filenames, all 20
binding edges and all three saved scripts. The embedded Coordinator advanced
from 114 to 2026111802 and Light from 106 to 2026111802. Switch remained at 106.
None of the three scripts references Light 52 or proxy 53. The native listener
test above covers the Light variable callback separately.

### Revision 2026111803

The built packages passed the archive comparison against all six pinned
references. This closes the 19 prototype Light archive differences previously
classified as gaps. The remaining differences require native review or explicit
Switch migration mapping. The Docker fixture rehearsal passed 744 Light and 365
Switch checks using this exact package inventory (SHA-256
`8106a49985be2a5411ae56cfd3593422ebbef83660612b013836fd1bd5e3f64c`). This run
uses simulated Director/proxy IPC and real Home Assistant services.

Director confirmed revision 2026111803 for Coordinator 42 and Light 52 through a
native metadata read. An explicit Light refresh preserved its saved selection,
and proxy 53 controlled and restored the isolated binary light. The suite Switch
54 updated separately; original Switch 51 remained at 106. Composer Driver
Information independently confirmed Light 52, proxy 53, and version 2026111803.
Its Advanced Properties pane showed only Properties and Lua. The standard setup
page and Actions were missing in the user’s screenshot. Revision 2026111804
corrects a duplicated top-level capabilities element in the Light archive. After
reconnecting, Composer showed the driver pages and native property rows on
revision 2026111804. The recheck combined a package change with a reconnect, so
it does not isolate which refreshed the screen.

Director confirmed Light 52 was updated in place to 2026111804. Its existing
proxy still operated the isolated binary light and restored its original state.
A GET_PROPERTIES_SYNC read from the protocol driver returned all 32 properties.
Three had visibility attributes set to zero: Driver Status (“Device connected”),
Next step (“Home Assistant is reporting its state.”) and Show advanced settings
(“No”). The protocol response rules out missing runtime values for those three
fields. The standard light controls in the upper pane are a separate proxy
surface. The test fixture is on/off only. The user’s 2026111804 screenshots show
these exact three rows in the inner Properties tab, all eight native Actions,
and the Device Setup page. The outer Light Properties tab still shows the native
keypad LED editor for the binary fixture.

### Development qualification after the Composer picker timeout

On revision 2026111809 the installed Light's picker raised a Lua require error
before it contacted the Coordinator. The same failure reproduced against both
archived consumer packages. Revision 2026111810 includes the missing dependency.
The package verifier now opens Device Setup through UIRequest, exercises the
bound consumer and checks the reply. This complements the six-source
compatibility comparison. It also covers errors starting the request and
formatting a reply.

Revision 10 is installed on CORE 1 with Coordinator 42, Light 52 (proxy 53) and
suite Switch 54. Original Switch 51 remains at 106. The read-only MCP verified
the restored wall-dimmer selection and the reported on/off, brightness, button
and indicator capabilities. The verification does not establish native preset
editing, a complete Switch migration or physical indicator behavior. See the
[native readback](../lab/installed-setup-readback.json) and the
[task-based audit](audits/device-settings-2026-11-18.md).

The development workflow uses the current OpenSpec section 0 tasks. Record the
package SHA-256 before rehearsal and link evidence to the individual task. A
development build that passed its archive tests can still have outstanding
controller, browser, or hardware qualification. The feedback gate is task 11.4.

### Revision 2026111817 qualification

This build adopts template v0.9.112. The archive comparison passed against all
six predecessors, and the packaged Light tests preserved brightness presets,
click and hold rates, and configured keypad colors across reload.

CORE 1 updated the three packages in place. Both Light and Switch recovered
their selected Home Assistant devices with the same proxy IDs and Coordinator
bindings. Director retained the Switch's saved **Bottom - 2 taps → Turn off HA
Light** program. A synthetic double tap delivered one gesture and turned off the
fixture light. Its original state was restored, and the Switch load stayed
unchanged. [CORE 1 readback](../lab/installed-revision-17-readback.json) ·
[Saved gesture readback](../lab/gesture-program-readback.json)

Connected Light keypad and group routing have automated coverage. A physical
keypad and a Navigator group still need a native acceptance check.

Director readback confirmed that logging changes apply immediately and **Log
Mode → Off** returns **Log Level** to **Info** on all three drivers. The
three-hour timeout was exercised with a virtual clock.

Home Assistant 2026.11.1 and 2026.11.2 each passed 1,131 family, 12 browser
setup and eight shared-Coordinator checks with the same packages as CORE 1. The
runtime and browser runs used isolated Home Assistant containers with simulated
Director and proxy behavior.
[Revision 2026111817 matrix](../lab/recovery-evidence.json)

### Revision 2026111816 qualification

Revision 2026111816 passed the six predecessor archive comparisons. CORE 1 kept
the existing Light and Switch selections, proxy IDs and bindings during
child-first updates, followed by a Coordinator update. Both devices returned to
**Device connected**.
[CORE 1 readback](../lab/installed-revision-16-readback.json)

The operator later saved **Bottom - 2 taps → Turn off HA Light** in Composer.
Director reported one attached action on the Switch. A synthetic bottom double
tap produced one gesture and Home Assistant confirmed the Light changed from on
to off. The Light's original state was restored and the Switch load stayed
unchanged. [Saved gesture readback](../lab/gesture-program-readback.json)

Home Assistant 2026.11.1 and 2026.11.2 each passed 1,131 family assertions, 12
browser setup assertions and eight shared-Coordinator assertions using this
package set. The paired check ran the packaged Light and Switch in separate Lua
processes against the same packaged Coordinator. It changed the Light selection,
confirmed the Switch subscription remained intact, interrupted the shared
socket, and exercised Coordinator destroy and init callbacks. Both children
recovered their exact subscriptions and confirmed control after reload. These
are isolated HA and simulated Director/proxy results.
[Revision 2026111816 matrix](../.cache/version-runs/2026111816/recovery-evidence.json)

```sh
receipts=.cache/version-runs/2026111816
python3 tools/check_first_demo.py --version 2026111816 --match-evidence \
  --controller-receipt lab/installed-revision-16-readback.json \
  --docker-receipt "$receipts/2026.11.1-family.json" \
  --docker-receipt "$receipts/2026.11.1-picker.json" \
  --docker-receipt "$receipts/2026.11.2-family.json" \
  --docker-receipt "$receipts/2026.11.2-picker.json"
```

### Revision 2026111815 qualification

Revision 2026111815 passed the archive comparison against all six predecessor
packages. CORE 1 loaded the Coordinator and both current child packages at that
revision. The existing Light and suite Switch returned to their saved Home
Assistant selections after the Coordinator reloaded. Their bindings were
preserved. [CORE 1 readback](../lab/installed-release-check-readback.json)

The [gesture check](../lab/gesture-program-readback.json) used the isolated
Switch fixture. Four taps delivered no Programming event. The following three
taps delivered one, with the load state unchanged. The lab's installed Light and
Switch had no saved gesture programs to retest. Composer display, saved
programming and physical response still require separate qualification.

Home Assistant 2026.11.1 passed 1,113 family assertions and 12 browser setup
assertions. Home Assistant 2026.11.2 passed 1,122 family assertions and 12
browser setup assertions. Both ran in restored Docker lab volumes with the same
package bytes and HA Gesture Bridge 0.1.3. Director and the Composer browser
connection used shims in these runs. The revision 2026111816 section has the
retained per-version receipts and verification command.

The connected status establishes that Director loaded the refreshed packages.
The receipt associates the locally deployed archive hashes with the reported
revisions. The archive checks do not substitute for the project migration and
first-demo handoff checks.

### Revision 2026111810 qualification

Run `python3 tools/check_first_demo.py --version 2026111810 --match-evidence` to
match built archive hashes with the Docker run and deployment record, and match
all three revisions with CORE 1 readback. Director reports the installed
versions. The hashes come from the deployment record. The open behavioral and
operator checks below still govern handoff.

| OpenSpec task                               | Evidence on this candidate                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Remaining qualification                                                                                                                                                                                                                                                                               |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0.3, mixed original drivers                 | The packaged Coordinator passed 123 checks with eleven original BP child sources, including fresh state after reconnect, two independently targeted Lights and a saved Call Service action with a numeric argument. [Reproduction](compatibility.md#platform-and-identity-contract)                                                                                                                                                                                                         | Live saved project and native TLS. Original Fan and Alarm Panel binaries need separate qualification.                                                                                                                                                                                                 |
| 0.15, setting up Light and Switch           | The five-sample Docker run passed 746 Light and 367 Switch checks. The shipped HTML searched for a different known device and Cancel returned focus and preserved the saved selection for both. A [second browser run](../lab/picker-round-trip-evidence.json) confirmed a different fixture and restored the initial selection in both families. Archived UIRequest tests also exercised paging, permission denial, disconnection and retry. [Docker results](../lab/family-evidence.json) | Native Composer interaction and physical controls have separate acceptance tasks.                                                                                                                                                                                                                     |
| 0.16–0.18, in-place settings and indicators | Director reported the restored dimmer and its indicator capabilities. Proxy 53 set the Docker dimmer to 26% and 72%, with independent HA and Director feedback. The fixture’s original power and brightness were restored. A packaged Light test edited and reopened native settings through the proxy. [Installed driver readback](../lab/installed-setup-readback.json)                                                                                                                   | The [HA indicator run](../lab/indicator-evidence.json) verified color, brightness, power behavior and tracking with fixture settings restored. Rehearse both predecessor paths with different selected and controlled devices, edit presets in Composer, and verify a physical wall-device indicator. |
