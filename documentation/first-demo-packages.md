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

## Revision 2026111824 Light qualification

The development inventory SHA-256 is
`996b3bdf9b2ae19d6874ef7f9fe3c64a9216a00f54244a6a835cb676fe257b95`. The Light
archive SHA-256 is
`d8fc3586691aa9311d7119eb1b4ac77ae4a4dd062bebb3ddb8551f273d32f51d`. The archive
comparison passed against the six pinned predecessors. The packaged Light passed
159 adapter assertions, including saved scenes and cold readback. The Docker lab
passed 458 Light checks using real Home Assistant services and simulated
Director. The matching Coordinator archive passed 123 mixed-family checks
against the original BP command sources.

On CORE 1, the existing HA Light retained IDs 52 and 53, its selection, bindings
and `ENTITY_ID`. Proxy 53 set the dimmer to 26% and 72%. The saved Switch double
tap program still turned the Light off. A temporary scene sent through the proxy
set the dimmer to 40% before reload. The same activation after reload did not
change brightness. The temporary scene was removed and the fixture's starting
settings were restored. The next native check uses a scene saved in the project.
The
[Light parity matrix](audits/light-switch-functional-parity.md#light-qualification-against-bp-106-and-prototype-1)
records the remaining baseline, Composer, Navigator and physical checks.

## Revision 2026111825 Light qualification

The development inventory SHA-256 is
`57eea380a297999c38c2d7f2841364369fe4d9d38b1a7ec1c239f68dfd381fca`. Light's
archive SHA-256 is
`5790b1958af741cb9974ec7ca806e46ea325cf0203eb5d7fd4d0790715e87a9b`. The archive
comparison passed against the six pinned predecessors. The packaged Lua passed
159 Light adapter assertions, 103 connected Light assertions and 123 Coordinator
compatibility checks against the original BP command sources. The Light and
Coordinator archives passed 458 checks and recorded 135 timing samples against
Home Assistant 2026.11.1 with simulated Director, logging Off and level Info.

Director gave the first scene saved in Composer ID zero. Revision 2026111824
left the test dimmer at brightness 64 when that scene called for 255. Revision
2026111825 restores the template's zero-ID support. The in-place update retained
the selected device, Device Link, proxy 53 and `ENTITY_ID` on Light 52. Director
and HA confirmed the saved level of 100% before and after a same-revision
reload. The test restored the fixture's starting power and brightness.

The two native activations took 78 and 70 ms to return from Director. Observing
the requested level through the isolated HA API took 2,226 and 2,220 ms from
dispatch, including polling, the scene's saved transition and fixture behavior.
With simulated Director and zero scene transition, three runs measured a median
of 23.87 ms from dispatch to HA service acceptance and 44.92 ms to the Light
driver consuming the resulting state. These samples measure software boundaries
on simulated hardware.

## Revision 2026111826 Light qualification

The development inventory SHA-256 is
`4d0da1a0f62b1b43fbb467f3fd9aa5bfe2b9d408dfd64519219583883ccbff1b`. Light's
archive SHA-256 is
`7d45bb326ce9e1e7b6367bedd755ac7d1d98fd5a1743944fb5ca2b39b98542e5`. The package
verifier confirms the native Default On, Preset and Previous Level capabilities.
The Device Setup HTML is byte-identical to revision 2026111825. The packaged
Light passed 159 adapter and 103 connected Light assertions, including
remembered HA brightness and explicit preset behavior. The isolated Home
Assistant run passed 458 checks with simulated Director, logging Off and level
Info.

The user observed Advanced Properties opening to Device Setup on the preceding
revision. The outer Properties pane showed the dimmer editor, preset controls
and rates. Its On mode only showed a brightness field. An independent review
confirmed the profile change matches the pinned Light example and Light Group,
and identified native selection and save/reopen as the remaining checks. CORE 1
retained Light 52, proxy 53, selection, bindings and `ENTITY_ID` on the update.
Director and HA again confirmed the saved scene reached 100%, and the fixture
returned to its prior settings.

The next Composer screenshot still showed only the brightness field. Director's
`GET_SETUP` reported both brightness modes disabled for Light 52's proxy. On a
fresh temporary test copy of the same package it reported both modes enabled and
included Previous On preset ID 10, matching Light Group. The temporary instance
was removed. Revision 2026111827 exercised a runtime capability notification on
the existing Light. Both flags stayed disabled and the proxy retained its preset
IDs, rates and button settings.

Revision 2026111828 keeps the native profile from revision 2026111826 and
removes the experimental notification. Its Light archive SHA-256 is
`7fba309553325ff034dbaf042ce0f1f66f0161a1d8ce1fb11949c647d4de6403`. This
candidate was applied to the existing Light in Composer. Director confirmed the
new revision on Light 52. Proxy 53 still reported both modes disabled and kept
its original preset IDs 1 and 2. The Composer update therefore reproduced the
same limitation as the development helper.

The original proxy's Default On Brightness remained functional. After the
isolated dimmer was switched off from 33% and again from 67%, an ordinary On
command brought it to the saved 100% on both attempts. Director and Home
Assistant confirmed 100% and brightness 255 respectively. The checks took 4,272
and 4,320 ms from Director command through the test's polling and the fixture's
feedback. The fixture returned to its original state, and the native preset
settings remained unchanged.

On the same controller a temporary HA Light controlled the pinned template's
simulated Example Light through a native App Control Link. Director reported
27%, Off and 100% on both light proxies. Command plus polling took 165, 174 and
124 ms, respectively. Both temporary instances were removed. The existing HA
Light retained revision 2026111828.

A second ordinary-light run used a 43% On preset on the example target. After
the target's own On confirmed the preset, turning it off and back on through the
connected HA Light returned both proxies to 43% in 136 ms through Director and
polling.

The App Control Link also controlled a temporary Light Group containing a
simulated Example Light. The source, group and member all reported 27%, Off and
100%. The checks took 381, 335 and 223 ms through Director and polling. The
group was then set to a 47% On preset. The linked On command kept 47% and
readback took 168 ms. The linked source's scene moved the group and its member
to 69%. CORE 1 became unreachable during the first attempt. After the operator
rebooted it, the interrupted fixtures were removed and the retry completed. The
retry fixtures were also removed.

### Navigator Off and the Default On preset

On CORE 1, the HA Light and Light Group sent the same brightness target and Off
preset ID during a 36% to Off transition. The published Light Group revision
2026111801 reported a 0% target. The in-place HA Light reported 43690. Home
Assistant recorded one ordinary Off request with a 750 ms transition and no
brightness increase. A direct ramp to 0% on the same HA Light reported the
correct target.

An alternating diagnostic on HA Light held the incoming command, load and final
feedback constant. Director reported 43690 with the Off preset ID in the
in-progress notification on both baseline trials. It reported zero on both
trials with that one field omitted. Final feedback retained the Off preset ID.
This establishes the trigger on this HA Light. Why Light Group handles the same
field differently and what Navigator displays after the fix remain open.

Revision 2026111831 passed the in-place Director rehearsal on Light 52, proxy
53\. From both 36% and 55%, each sampled Director target was 0 and Home Assistant
recorded just one `turn_off` with a 750 ms transition. The native preset edit
saved and read back 55%. An ordinary Navigator-style On command made Director
report 55% and Home Assistant report 140 of 255. The test restored the prior
preset and dimmer state. Native Composer edit and reopen, the preset Test
button, and direct Navigator observation remain unverified. The archive omits
the diagnostic code, although Director kept the prior trace property metadata
after the in-place update.

The same Light saved and used separate 53% and 55% Default On edits. After the
driver reloaded, it still used 55%. Switching to Previous Level returned to 37%,
and switching back to the preset returned to 55%. The test restored the original
preset and dimmer state. Revision 2026111832 also honors the saved On level from
a proxy with no named mode. The adapter test covers both a native setting
command and startup readback of a pre-existing preset without an edit.

After the in-place update to revision 2026111832, both Director On and
Navigator-style On used the saved 55% on the same Light and proxy. Home
Assistant confirmed 140 of 255 on both trials. The original preset and dimmer
state were restored.

The operator reported that Off now behaved correctly in the Control4 app and
that On briefly showed the prior brightness before settling at the saved preset.
Director captured the operator's preset edits, and Home Assistant received the
corresponding brightness values. With a saved 55% preset and a previous level of
75%, a lab replay found an invalid Director target during the 750 ms On
transition and a single Home Assistant request for 55%. A direct 55% ramp with
no preset ID reported 55% through the transition.

Published Light Group revision 2026111801 showed the same kind of discrepancy
with the same HA dimmer as its sole member. Its in-progress notification
specified 55% and the On preset ID, while its own proxy reported a 0% target.
The member command sent the numeric level without a preset ID and the member
proxy reported 55%. Both proxies settled at 55%.

On the same HA Light, a second controlled experiment omitted only the
in-progress preset ID. With the ID present, Director reported 43690 for both
Default On at 55% and Previous Level at 37%. Without it, every sampled target
matched the saved or remembered brightness. The Home Assistant service requests
and final preset IDs matched between both variants. Revision 2026111834 applies
this to the three affected built-in presets. The adapter tests check the numeric
targets and verify that a custom preset still carries its identity during a
ramp.

On CORE 1, the normal revision 2026111834 package kept the same Light 52 and
proxy 53. Across 33 Director samples for Default On at 55% and 34 for Previous
Level at 37%, every reported target matched the selected mode. The preceding Off
runs reported only 0% targets. Home Assistant received one request per
operation, and the operator's saved preset and fixture state were restored. The
operator then confirmed that the On bounce was gone in the Control4 app.

Light Group's 2026111801 settings also reproduced the Default On mismatch in an
offline test. With preset 1 active at 75%, `SET_PRESET_LEVEL` saved 55% while
the active On level stayed at 75%. The follow-up `UPDATE_BRIGHTNESS_PRESET`
brought the active level to 55%. The live Group Off comparison reported a valid
zero target throughout the fade.

### Revision 2026111834 runtime and BP scene evidence

The exact revision 2026111834 Coordinator, Light and Switch packages passed
1,116 checks against the isolated Home Assistant 2026.11.1 lab. The run used
five repetitions, packaged HTML and driver Lua, simulated Director IPC and
native proxy calls, and real HA services. Light passed 749 checks and Switch
passed 367. Logging was Off. The package hashes matched the build inventory.

A separate CORE 1 rehearsal pushed a 55% scene to a temporary proxy running the
original BP 106 scene handlers. Director stored the parsed scene and kept the
record intact after the protocol driver updated to 2026111834. The upgraded
driver received `CLEAR_ALL_SCENES` during reload. Advanced Lighting did not send
the synthetic scene back because it had no saved project scene. An ordinary
level command still reached the linked example light. The rehearsal established
storage and routing preservation.

The native repeat used a one-light scene saved in Composer at 55%. Before the
update, the BP 106 scene handlers stored the scene and its level under the
original `ALS:<id>` key. After the in-place update to 2026111834, Director
reported the same protocol ID (239), Light V2 proxy (240), scene ID (1),
membership and level. Activation through the Advanced Lighting agent brought
both the upgraded proxy and its isolated linked Example Light to 55%. The test
used a temporary package alias and simulated load. The original Light 52 was
verified at 2026111834 and was outside this rehearsal.

For the prototype repeat, CORE 1 installed the pinned Light 1 code under a
temporary alias with a lab-only binding action. The original Top Controller Link
drove an independent Example Light to 37%. Director reported the selected Home
Assistant paddle, the connected-light mode, and dimming and ramp support. With
suite Coordinator 2026111828, the prototype reported that its selected entity
snapshot timed out. Its `HA_GET_STATE` request includes consumer and
active-entity fields. The suite's legacy receiver accepts only the stock BP
single-field request. The fixture can route brightness to the linked test light,
and the original proxy's feedback and mixed-version Home Assistant state still
need qualification.

The operator saved a 62% scene in Composer with the prototype fixture as its
only member. The native agent activated the scene on Prototype Light 1 and sent
the linked Example Light to 62%. The in-place update to 2026111834 kept the same
protocol (249), proxy (250), room, Home Assistant paddle selection, Top
Controller Link and scene definition. Activating the saved scene again brought
both the same proxy and the linked Example Light to 62%. The light was reset to
37% before each activation. These results qualify brightness and routing on a
simulated load. The scene's color field stayed intact, and color output was
outside the measurement.

### Revision 2026111837 template fade verification

The suite now uses template v0.9.114 with upstream PR #242. On CORE 1 (OS
3.4.3), the existing Light 52 and proxy 53 kept their Home Assistant selection
and native preset settings after the update. Director reported only 0% in both
Off fades, 55% across 22 Default On samples, and 37% across 21 Previous Level
samples. Each transition produced one Home Assistant service call, and both
systems confirmed the final levels. The original preset settings and lab light
state were restored.

The adapter regression applies custom preset 42 and verifies that the proxy
shows 64% throughout its fade and receives preset 42 on completion. A separate
CORE 1 probe used two disposable Example Lights and a 750 ms ramp from 37% to
64%. With synthetic preset ID 42 in the old fade notification, the proxy kept
showing 37% until the fade finished. With v0.9.114, all 14 active ramp samples
showed 64%. Both settled at 64%. This tested the native proxy notification.

The operator then saved **Lab 64** at 64% in Composer and reselected the Light.
Director reported the saved preset as ID 1000. A native command applied that
preset from 37% on Light 52 without changing its On mode. All 14 samples taken
during the 750 ms fade showed a 64% target. Director settled at 64%, and Home
Assistant confirmed brightness 163 out of 255 after one service call. The
original light state was restored, and the preset settings matched their
pre-test values on readback.
[Upstream fix #242](https://github.com/finitelabs/control4-driver-template/pull/242)

### Revision 2026111838 mixed Coordinator

The packaged Coordinator passed 139 mixed-project checks against the pinned BP
child command sources and the actual Prototype Light 1 and Switch 107 archives,
using simulated Director and Home Assistant transport. The prototype checks
covered direct-load selection, live feedback, control and reconnect on the
retained provider. The isolated legacy tests also checked offline release, stale
replies and subscription sharing until the last reader releases an entity. The
isolated HA 2026.11.1 run passed 458 family checks for Light and 223 for Switch
with the same package hashes. The real-HA run used three repetitions with
logging off and simulated Director IPC.

Native mixed-project verification and prototype gesture, linked-load and setup
flows remain open.

## Revision 2026111910 first-demo qualification

The six pinned reference archives passed the offline package contract. The
packaged Coordinator passed 139 mixed-project assertions with the pinned BP
command sources and the actual Prototype Light and Switch archives. That harness
uses simulated Director and Home Assistant transport. On HA 2026.11.1, the
current Light passed 755 checks using the packaged Light and Coordinator, real
HA fixture services and simulated Director IPC. Five repetitions produced 225
control samples with log output off. The samples separate HA service acceptance,
independent HA feedback and receipt of feedback by the driver.

Fresh temporary copies of both HA 2026.11.1 and 2026.11.2 each passed 1,131
family checks, 12 packaged browser picker checks, and nine paired Coordinator
and consumer checks on the same archives. Startup, reconnection and changed
selection were tested with simulated Director IPC. The temporary copies were
removed and the primary lab was preserved. Version-specific receipts are in
`.cache/version-runs/2026111910`.

The installer used the native Composer editor on Light 52 to add, test, edit,
reopen and remove a temporary preset. They tested 61%, then 43%. The simulated
HA dimmer received brightness 156 and 110 of 255 in that order. Director
confirmed the temporary preset was removed, the saved On mode still used its 57%
preset, and the existing Lab 64 preset remained at 64%.

The installed Light also accepted changes through the Device Setup indicator
request. The simulated Hallway wall dimmer reported each change independently.
Changing color, brightness or behavior left the other fields intact. An
unsupported color was rejected without a change. The page reported the confirmed
blue color when the indicator was on. The original Green, 50% and Off settings
were restored. These checks exercise the installed driver and the companion's
simulated endpoints. Physical indicator verification remains open.

Each row below uses five samples and a monotonic clock on the test host. The
Coordinator and Light had log output and latency diagnostics off. The observed
HA read includes the independent read performed after the native setup reply.

| Indicator operation | Setup reply min / median / max (ms) | Observed HA read min / median / max (ms) |
| ------------------- | ----------------------------------: | ---------------------------------------: |
| Color               |            121.24 / 125.46 / 129.91 |                 132.86 / 140.60 / 145.36 |
| Brightness          |            352.63 / 400.28 / 406.26 |                 366.05 / 414.83 / 425.97 |
| Behavior            |            403.11 / 408.83 / 412.23 |                 415.73 / 424.08 / 427.24 |

## Revision 2026111911 first-demo qualification

The source tests and six-archive package comparison passed. On HA 2026.11.1, the
packaged Light and Coordinator passed 749 checks with real Home Assistant
services and simulated Director IPC. The shipped Device Setup page kept the
manual entity ID field focused after rejection, retained the rejected draft,
associated the live error and help with the field, and allowed a correction in
the browser rehearsal. The Composer check still needs to exercise the manual
field itself.

The complete 2026111911 package set passed 1,131 family, 12 browser picker and
nine paired checks on each of HA 2026.11.1 and 2026.11.2. The receipts match all
three candidate archive digests. Each version produced 225 Light and 60 Switch
control samples and 49 setup observations with log output off. The test host
used a monotonic clock to distinguish service acceptance, observed state, and
feedback consumed by the driver. The tests used real HA and simulated Director
IPC. Both temporary HA copies were removed, and the primary lab was preserved.
[Version rehearsal](../lab/recovery-evidence.json)

All four installed suite instances on the CORE 1 lab controller moved to
2026111911 with their project names, rooms, selections and bindings intact. The
migrated Switch retained its saved Turn On action, and the independent fixture's
programming was unchanged. On Light proxy 53, Director's native On command and
the saved Lab 64 preset reached 57% and 64% on the simulated HA dimmer. Home
Assistant reported brightness 145 and 163 out of 255. The test restored the
dimmer's initial state and confirmed that its saved On mode remained selected.

The installed Advanced Lighting agent activated the existing HA Light parity
scene, ID 0. Its sole member, Light proxy 53, reached the saved 100% level in
Home Assistant. The existing Bottom - 2 taps program on Switch 54, event 45,
then turned off the Light from 57% after a synthetic Home Assistant button
event. The scene definition, programming references, and Switch power were
unchanged. The Light returned to its starting state.

GitHub's six published assets for v2026111823-beta.1 matched the downloaded
sizes and SHA-256 digests. Coordinator 2026111822 had previously verified the
manifest and driver files through its Pre-release check. On 2026111911, the
installed Coordinator reported that the preview was older than the installed
suite and that Production had no release. Both checks kept the Coordinator
connected to Home Assistant. The original release channel was restored.
[Published preview](https://github.com/skialpine/Control4-HA/releases/tag/v2026111823-beta.1)

The Light also received the four existing indicator programming commands on
Director. Five requests each verified current color, brightness, behavior and
the bulk color command using the simulated Hallway wall dimmer’s single
indicator. Each request preserved the unrelated settings. The original color,
brightness and behavior were restored. The host used a monotonic clock with
driver log output off.

| Programming command   | Director reply min / median / max (ms) | Confirmed HA read min / median / max (ms) |
| --------------------- | -------------------------------------: | ----------------------------------------: |
| Set LED Current Color |                  94.01 / 94.45 / 96.14 |                  106.39 / 107.62 / 107.83 |
| Set LED Brightness    |                97.25 / 152.03 / 173.60 |                  110.78 / 169.36 / 189.49 |
| Set LED Behavior      |               144.27 / 153.11 / 176.21 |                  155.16 / 164.39 / 190.93 |
| Set All LED Colors    |               115.62 / 166.23 / 196.42 |                  131.56 / 181.76 / 207.22 |

## Revision 2026111912 Switch migration mode verification

The Coordinator's Quick Setup wizard and the replacement's Device Setup
migration review use the same eligibility check. BP 106 does not have an
operation mode property. Prototype 107 must report direct mode before automatic
migration can proceed. For a switch using button events, the review points to
the manual procedure in the Coordinator's Documentation tab. If the mode could
not be read, the review asks the installer to check the original switch's
Properties.

Regression tests cover an eligible direct-mode prototype and verify that
unreadable and button modes cannot authorize forward changes. They also check a
mode change during Home Assistant verification and during an already-staged
plan. Rollback remains available for an interrupted relay transfer.

The independent browser review used the packaged pages with simulated driver
responses at 1024 × 650, 520 × 420, and 360 × 320. The list placed only the
eligible row in the review, Refresh list stayed reachable with every row
blocked, and both Quick Setup and Device Setup returned keyboard focus when
leaving a review. Device Setup displayed the reason and offered Close review.
The manual guide fit at all three sizes and explains how to preserve
programming-only mode, test gestures and indicator behavior, and keep the
original until the replacement is tested. The physical walkthrough is still
open.

All four suite instances on the CORE 1 lab controller upgraded to 2026111912 in
one batch. Their names, rooms, selections, bindings and saved programming were
preserved. The migrated Switch retained its verified Turn On action.

The pinned Prototype Switch 107 archive was then installed in a disposable
fixture on the same Coordinator. Quick Setup listed **Control HA Device** as
ready. It kept **Control HA Device with Button Events** and **Programming Events
Only** blocked and showed the documentation route for both. The preview left the
legacy connection intact and created no replacement. The test removed its
fixture and confirmed the original project graph was restored.

In the prototype, selecting a direct device through the old Select Device action
updated the Entity ID property while the programming variable still reported the
previous value. Entering the ID in the property directly aligned both values
before the native preview. The assessment requires agreement before trusting a
saved device.

After the installer saved a fresh lab project backup and requested the
rehearsal, the pinned prototype operated the simulated binary light on and off
over its original legacy connection. The native Quick Setup action then migrated
this direct-mode fixture. The replacement published its UI Button in the same
room under the original name, and Director showed the old connection
disconnected. The replacement's selected endpoint matched the original, and its
On and Off commands changed the same HA light.

For the operator-requested restore, the private helper removed the disposable
replacement, reconnected the original driver and restored its name. The original
kept its saved entity and operated the HA light in both directions again. The
test restored the light's starting power, removed the remaining fixture, and
verified the existing project identities, names, connections, setup and
programming. The native restore exercises operator recovery after a successful
cutover. Simulated failure tests exercise automatic recovery for both BP 106 and
prototype 107. This fixture had no saved scripts or relay connections. The
prototype button and indicator migration still needs a physical walkthrough.

### Built-package Home Assistant matrix and no-companion setup

The exact 2026111912 Coordinator, Light and Switch archives passed 1,131 family
checks, 12 browser picker checks and nine paired checks on each of Home
Assistant 2026.11.1 and 2026.11.2. The archived receipts match all three archive
digests. The matrix used real Home Assistant in temporary labs and simulated
Director. It exercised selection changes, two consumers, transport faults and
reload. The temporary labs were removed and the seed lab was preserved.

In a separate temporary 2026.11.1 instance with HA Gesture Bridge absent, manual
selection of a native `input_boolean` passed 64 Light and 124 Switch checks.
Both packaged drivers sent explicit On and Off and toggled from both confirmed
states. The run observed the scoped HA service result, confirmed Home Assistant
state, and resulting proxy or programming feedback. It used five samples per
row, the host's monotonic clock and opt-in diagnostics with verbose logging off.
Values below are minimum, median and p95 in milliseconds.

| Driver and operation   | HA service result     | Confirmed HA state    | Driver feedback       |
| ---------------------- | --------------------- | --------------------- | --------------------- |
| Light On               | 23.02 / 23.65 / 24.50 | 22.77 / 23.45 / 24.35 | 23.79 / 44.30 / 45.65 |
| Light Off              | 23.18 / 23.49 / 24.82 | 22.93 / 23.32 / 24.31 | 23.19 / 44.03 / 45.91 |
| Light Toggle from off  | 22.99 / 23.79 / 24.71 | 22.85 / 23.58 / 24.21 | 44.04 / 44.88 / 45.81 |
| Light Toggle from on   | 22.76 / 23.34 / 24.86 | 22.57 / 23.23 / 24.54 | 43.82 / 43.98 / 45.93 |
| Switch On              | 22.81 / 23.19 / 23.85 | 22.55 / 23.07 / 23.64 | 43.37 / 44.22 / 44.93 |
| Switch Off             | 22.45 / 22.76 / 23.56 | 22.27 / 22.66 / 23.44 | 42.85 / 43.85 / 44.60 |
| Switch Toggle from off | 22.13 / 23.29 / 24.41 | 22.02 / 23.19 / 24.04 | 43.19 / 44.32 / 45.52 |
| Switch Toggle from on  | 22.67 / 23.00 / 23.15 | 22.56 / 22.72 / 23.01 | 42.88 / 43.72 / 44.04 |

These times measure software control of a Home Assistant helper. The native
Director and hardware checks have separate evidence. Local receipts are in
`.cache/version-runs/2026111912` and
`.cache/first-demo-1910/no-companion-1912.json`.

## Recovery re-audit after revision 2026111912

The exact 2026111913 archives passed the same matrix on Home Assistant 2026.11.1
and 2026.11.2. Each run passed 1,131 family checks, 12 picker checks and nine
paired checks. The temporary labs were removed.

Revision 2026111914 passed archive validation and independent keyboard tests of
the packaged Quick Setup at 520 × 420 and 1024 × 650. Unfinished setup stayed
visible by saved name and room and went through review with the saved driver
type. The retry screen named the exact staged Switch and kept removal hidden
while the operation was pending. Fresh setup, stale Entity ID and missing-room
recovery passed. These browser tests simulated Director replies.

The same 2026111914 archives were staged together and installed on the CORE 1
lab controller. Director verified all four instance revisions, selected devices,
names, rooms, proxies, connections, gesture programming and the saved Turn On
action on the migrated Switch. Quick Setup found three devices already in
Control4 and ten available to add. The migration section was hidden with no
remaining sources or cleanup. The saved Advanced Lighting scene produced 100% on
the isolated HA dimmer, and the existing Switch double tap triggered the saved
Off action. Both project definitions remained intact and the test restored the
HA dimmer's starting state.

Local regressions verify that an interrupted add resumes the exact staged
driver, a hidden driver that still has a provider cannot be duplicated, and a
different Coordinator cannot verify the same entity ID. The wizard rechecks both
drivers and their relays before moving control and again before allowing
removal. A legacy peer with debug logging enabled pauses shared feedback while
approved HA reads and subscriptions stay scoped. An explicit linked-device retry
can restore feedback after logging is disabled.

### Power before the first snapshot

The mixed-project run against the exact 2026111915 Coordinator passed 139 checks
with the pinned BP drivers and Prototype Light 1 and Switch 107. A second run
sent native power and relay commands before the first state read returned. The
following observations are Home Assistant service requests from a simulated
Director and Home Assistant transport.

| Driver                 | Explicit On and Off before feedback | Toggle before feedback           |
| ---------------------- | ----------------------------------- | -------------------------------- |
| BP Light 106           | Sent `turn_on` and `turn_off`       | No power request                 |
| BP Switch 106          | Sent `turn_on` and `turn_off`       | Sent `turn_on`                   |
| Prototype Light 1      | No power request                    | No power request                 |
| Prototype Switch 107   | Sent `turn_on` and `turn_off`       | Sent `turn_on`                   |
| Suite Light and Switch | Waited for the selected snapshot    | Waited for the selected snapshot |

The original Switches can operate before feedback and assume On for a cold
Toggle. The suite waits for a confirmed state, then sends explicit or
state-dependent power commands through the verified target. The first-state
comparison used the predecessors' native handlers and separate suite driver
tests. Physical-response and installer checks remain open.

### Predecessor migration mappings

Legacy inspection requires the pinned package filename, model, BP manufacturer,
version and expected connection roles. The room and display name locate the
instance in Composer. Director supplies the actual protocol and proxy IDs.

| Surface                   | BP / prototype Light                                                                                                                                                                | BP / prototype Switch                                                                                                                                                                                                                      |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Identity                  | `HA.Light.c4z`, `HA Light`, 106 or 1. Keep the native Light V2 proxy on 5001 and use the existing instance.                                                                         | `HA.Switch.c4z`, `HA Switch`, 106 or 107. Install `Control4.HA.Switch.c4z` as a replacement with its own Experience Button proxy on 5001.                                                                                                  |
| Home Assistant connection | Preserve input 999 and its verified Coordinator.                                                                                                                                    | Move ownership from `HA_DEVICE` input 999 to the replacement's suite input 1. Verify both refer to the same Home Assistant connection.                                                                                                     |
| Relay and buttons         | Preserve On, Off and Toggle outputs 200–202, and prototype controller inputs 203–205.                                                                                               | Relay output 1 maps to output 2. The old button outputs 200–202 map by On, Off and Toggle to 300, 302 and 301. Review button connections in Composer.                                                                                      |
| Saved device              | Restore `Entity ID` and the `ENTITY_ID` variable by their existing identities. Prototype mode and preparation describe the selected device and its load.                            | Use the checked entity to set up the replacement as a direct Switch. Update programs that reference the old `ENTITY_ID` to the replacement's selected endpoint by meaning. Keep a button device and its load distinct in manual migration. |
| Programming and state     | Keep native Light V2 events and commands on the same proxy. Prototype tap programming and indicator commands retain their qualified mappings.                                       | Recreate Turn On and Turn Off on the replacement; it dispatches `TurnOn` and `TurnOff`. Map state checks and gesture triggers by meaning. Test each mapped event rather than carrying over its numeric ID.                                 |
| Indicator commands        | Preserve the template and qualified prototype command names. The `Button` selector identifies the channel; `Color`, `Brightness` and `Behavior` carry the setting for that command. | Recreate supported indicator actions after selecting the physical device. Check the discovered channel, palette and brightness or behavior options before testing the action.                                                              |

The archive comparator records each declared event, connection, property,
variable, command and parameter difference. Runtime fixtures check reciprocal
ownership, protocol/proxy identity, saved entity agreement and named program
references. The mappings identify the review or transfer step. The native and
physical qualification entries record which steps have been demonstrated.

## Revision 2026111919 Device Setup qualification

The chooser filters one list by name, room or exact Home Assistant entity ID.
Light lists compatible lights, switches and toggle helpers. Independently
controllable loads stay selectable. A raw relay and equivalent representation
share one row when Home Assistant gives the relationship. The row uses the
physical device's name when its buttons or indicators are available. Related
entity IDs still find that row. Home Assistant publishes the Switch as X target
and inversion as registry options, and the Coordinator reads only registry
entries that correspond to the scoped list.
[Switch as X source](https://github.com/home-assistant/core/blob/2026.11.2/homeassistant/components/switch_as_x/entity.py),
[Entity registry lookup](https://github.com/home-assistant/core/blob/2026.11.2/homeassistant/components/config/entity_registry.py)

The previous Composer check showed the last-used tab reopening and a disabled
selection button after an unknown ID. Independent review of the 2026111919 Light
and Switch packages exercised name, room and ID search at 520 by 420 pixels and
1024 by 650 pixels. The unknown ID produced an empty result without a selection
action. Reload stayed beside Cancel through results, empty results and errors.
It preserved the query and returned focus to search. The Coordinator's Quick
Setup Refresh kept focus and ignored a second keypress while the first request
was pending. Browser review used simulated driver replies. In Composer, the
installer confirmed that `light.badid` showed no selection action, and that
`switch.ha_lab_switch_paddle` found one **Entryway wall switch** row under the
same search field. The current selection still displayed **Hallway wall
dimmer**. Device Setup and Properties were visible in the same tab row.

The Lua tests cover authoritative cached selection, one richer row for proven
aliases, independently selectable same-name loads and an explicit refresh
joining the current request. Ordinary selection sends the initial subscription
without a separate Home Assistant lookup to approve the cached choice. Quick
Setup rereads eligibility before it creates or connects a driver. Its preflight
rejected a removed load before contacting Director to add it.

On the CORE 1 lab controller, all installed suite drivers reported 2026111919
after staging and updating the coordinated package set. Director retained
project names, selections, bindings and saved programming, including the
migrated Switch action. A read-only request to the installed Device Setup
handlers found 13 Light choices and 6 Switch choices. The entryway relay ID
found one enhanced wall switch in each list, the binary Porch light appeared in
Light, and the unknown ID was absent from both. Explicit reload found the same
enhanced choice. Native readback before and after browsing matched for both
drivers.

The installed Light honored the retained 57% On preset and 64% custom preset.
The saved Advanced Lighting scene drove the simulated dimmer to 100%. The saved
Switch double-tap action then turned it off while the switch load stayed in its
original state. The scene and programming were unchanged, and the dimmer was
restored after testing.

Both Home Assistant 2026.11.1 and 2026.11.2 passed 1,131 family checks, 12
picker checks and 9 paired-driver checks per version. The six predecessor
comparisons, installed readback and all six Docker receipts matched the exact
driver archives. Both temporary verification instances were removed.

## Revision 2026111920 migration rollback

The 139 mixed-project checks passed on both the 2026111919 and 2026111920
Coordinator archives with the pinned BP and prototype drivers. They exercised a
saved Call Service action, scoped feedback and both prototype families after
reconnect on a simulated Director.

The 2026111920 Switch migration test moves the planned On and Off actions to the
staged replacement, then makes its readiness check fail. For BP 106 and
Prototype 107, the wizard returned the existing connection and relay to the old
driver. The edited programming still pointed to the prepared replacement. The
wizard kept old-driver removal unavailable and identified when to restore the
project backup and how to retry. A retry used the same driver and verified the
moved actions. This was a scripted Director simulation. The earlier CORE 1
manual BP programming move and native prototype rollback are separate runs.

An independent browser review of the exact 2026111920 Coordinator archive
checked the rollback message and instructions at 1024 by 650 and 520 by 420
pixels. The installer could reach **Recheck and continue** by keyboard, and
pressing Enter submitted one request. Recovery with no programs to move showed
only the retry instructions. If the old driver's return could not be verified,
the page directed the installer to the backup and hid retry.

CORE 1 accepted the coordinated 2026111920 update and reopened the saved project
with the original names, selections, bindings, migration record and programming.
A simulated fourth tap and following triple tap on button five advanced Last
Sequence twice and Gesture Count once for each installed family. Last Gesture
reported the triple tap, and both saved loads and programs remained in place.

An installed-picker benchmark used the Python monotonic clock from the Director
command request to its correlated first-page response. Measurement started after
authentication and subscription setup. Each row has ten samples with Log Mode
and Latency Diagnostics off and Log Level at Info. The measurements span real
Director and the simulated HA lab.

| Driver | Operation       | Minimum | Median | p95 and maximum |
| ------ | --------------- | ------- | ------ | --------------- |
| Light  | Warm open       | 95 ms   | 152 ms | 294 ms          |
| Light  | Explicit reload | 126 ms  | 132 ms | 153 ms          |
| Switch | Warm open       | 36 ms   | 37 ms  | 83 ms           |
| Switch | Explicit reload | 69 ms   | 72 ms  | 82 ms           |

CORE 1 also ran five Light Programming requests each for indicator color,
brightness, behavior, and bulk color against the simulated wall dimmer. The
requested field changed independently and all original values were restored.
Median Director replies were 94, 153, 160 and 179 ms, respectively. Median times
to independent HA readback were 106, 164, 171 and 190 ms. Both intervals used
the test host's monotonic clock. These checks cover one simulated indicator
channel. Physical output and multi-channel behavior remain to be checked.

The exact driver archives passed 1,131 family checks, 12 packaged picker checks,
and 9 paired checks on both HA 2026.11.1 and 2026.11.2. A separate HA 2026.11.1
run with HA Gesture Bridge absent exercised the documented **Choose device**
flow. The packaged Light and Switch each moved between two native toggle helpers
and returned to the initial selection. On, Off and both Toggle directions
confirmed their HA feedback after choosing the helper. Setup through an existing
saved entity ID also passed. The companion-enabled picker selected both an
ordinary load and a richer button device in each family. Temporary HA
allocations were removed after the checks.

The companion-free setup exposed a lab provisioning issue. A differing seed
archive was detected after creating a Docker container. Provisioning now checks
the existing private seed before Docker writes. The regression verifies that a
conflict preserves the original backup and creates no resources.

A disposable Light V2 driver on CORE 1 played a looping flash through the
simulated Porch light. The test observed six alternating HA state transitions,
then verified that native Stop halted the loop and Remove prevented the scene
from starting again. The first confirmed state arrived in 602 ms. Five observed
transition intervals ranged from 704 to 786 ms, with a 757 ms median and 786 ms
p95. These intervals use the host monotonic clock at independent HA readback and
include the programmed scene delay. The test removed the temporary driver,
restored the starting light state and compared the saved project and programs.

## Revision 2026111921 programming confirmation

The Switch migration wizard keeps the existing driver in control when it can no
longer find a structural reference and cannot establish that the reviewed
program uses the replacement. The installer first rechecks old references, then
confirms the named replacement and room. Flat, unconditional On and Off actions
still use their verified mapping. A reference that reappears before confirmation
returns that switch to review. The confirmation is scoped to the saved operation
and the specific switch.

An independent review exercised the exact packaged Coordinator page at 1024 by
650 and 520 by 420 pixels. The checkbox names the replacement and room, and
keyboard activation sends one confirmation for the checked switch. Refresh
clears it and restores heading focus. The mapped On-only example continued with
its existing programming check. The live Composer walkthrough of this new
confirmation remains open.

All installed suite drivers on CORE 1 reported 2026111921 after the update. The
saved migration status and programming survived. The candidate passed 139
mixed-predecessor checks and 1,131 family checks, 12 picker checks, and 9 paired
checks on each supported HA version. The package hashes match the installed and
Docker receipts.
[Toggle timing](performance-contract.md#linked-toggle-comparison-on-2026111921)

## Revision 2026111922 Light reload checks

On the CORE 1 lab controller, the installed canonical Light kept its 57% On
preset and its Lab 64 preset. Using the native proxy, Home Assistant confirmed
both levels on the simulated dimmer. The saved Advanced Lighting scene reached
100%, and the existing Bottom double-tap program turned the light off. Native
readback confirmed that the saved scene and programming stayed intact. The
dimmer returned to its initial power and brightness.

The saved Prototype Light rehearsal updated in place from its earlier 2026111834
rehearsal build to 2026111922. Director retained the same protocol and proxy
IDs, room, event selection, connected-light mode, Top Controller Link, native
presets and saved 62% scene definition. The Advanced Lighting agent brought both
the Light proxy and its distinct simulated Example Light target to 62% before
and after the update. The candidate alias changes only the fixture model in the
archive XML and ships the exact candidate Lua.

The BP Light rehearsal used the same approach. Its virtual App Control Link was
reconnected to its previous test target before the baseline check. The
subsequent reload kept that link, the existing protocol and proxy IDs, saved
properties, presets and the original 55% scene. The native agent brought both
the Light proxy and the separate Example Light target to 55% before and after
the reload. Both rehearsals restored the target's initial level.

The setup tests also restored the saved selection when Director returned it as a
native table, and verified that a persisted explicit clear suppresses the old
selection after startup. These storage checks ran with simulated Director and
passed all 628 setup assertions. Separately, sending four taps followed by three
on the simulated fifth button skipped the fourth tap and delivered the triple on
both installed drivers. Native readback confirmed that the loads and saved
programs stayed intact. Composer's rendered event lists remain open.

Native Light and Switch programming each ran five commands for current indicator
color, brightness, behavior and all-channel color. Home Assistant confirmed all
40 commands on the simulated indicators. Each command preserved the unrelated
indicator fields. The Switch setup page correctly omitted indicator settings
when the companion advertised no mapping. A temporary mapping exposed the
fixture's color, brightness and behavior. The run restored both fixtures'
settings and the Switch's original empty mapping.

### Exact-package recovery matrix

The three canonical archives match the staged Director batch and the isolated HA
receipts. Home Assistant 2026.11.1 and 2026.11.2 each passed 764 Light, 367
Switch, 12 picker and nine paired recovery checks. Both temporary containers and
volumes were removed. These package tests used real HA services, a simulated
Director and virtual loads. Physical wall indicators and native Composer event
lists still need verification.

The packaged Coordinator also passed 139 mixed-project checks with the original
BP command sources and both pinned prototype archives. These tests cover direct
loads, saved Call Service routing and reconnect with a simulated Director and HA
transport.

A third isolated HA 2026.11.1 instance verified the exact 2026111922 packages
with HA Gesture Bridge absent. For each family the run selected a native toggle
helper by saved ID and through Device Setup, then confirmed On, Off and both
directions of Toggle. Light passed 64 saved-ID and 66 picker checks. Switch
passed 124 saved-ID and 126 picker checks. Each path recorded 20 command
samples.

## Revision 2026111923 Switch feedback recovery

After an accepted Switch command, the driver gives Home Assistant three seconds
to send the state change. If the expected feedback is missing, it reads the
selected device once. Live feedback supersedes an outstanding read. When
commands overlap, the final confirmation waits for their service results. A
failed read reports the switch as unavailable and a subsequent confirmed report
restores it. An ordinary confirmed command uses the existing push path.

Light and Switch offer **Refresh device state** in Device Setup when a command
left the state unconfirmed. The action reads the same selected device.
Properties names the tab and action. A refresh from an older page cannot restart
a pending replacement selection. Keyboard review exercises recovery after both
failure and success, and a new confirmed report clears the earlier error.

The independent reviewer tested the exact Light and Switch archives at 1000 by
550 and 320 by 300 pixels. Twenty recovery cases passed across the two families
and pane sizes, along with four ordinary setup retries. The scoped refresh
stayed visible as the primary action. Failure returned focus to Refresh.
Recovery returned focus to Change device whether the reply or the connected
state arrived first. The native Properties and Navigator surfaces still require
observation in the installed interface.

The verified lab update reloaded the three canonical packages and retained both
Switch instances and the Coordinator. The saved Light scene reached 100%, the
saved double-tap program turned off the Light, and both installed families
ignored a fourth tap and reported the following triple tap. Both predecessor
Light rehearsal instances also reloaded using the candidate Lua under their
existing aliases. Their fixture selections, target links, preset definitions and
saved scene membership stayed intact. The virtual target reached the saved 55%
and 62% levels, then returned to its original state.

The installed Coordinator checked the Production channel and reported that it
had no published release. Both child families stayed connected during the check.
The candidate's packaged Coordinator also passed 139 simulated mixed-predecessor
checks using the pinned BP sources and both prototype archives.
[Predecessor task matrix](audits/light-switch-functional-parity.md)

### Qualification record

The exact three C4Z digests match the archive verifier, the lab install receipt,
both isolated HA matrices and the no-companion run. Each of HA 2026.11.1 and
2026.11.2 passed 1,131 family checks, 12 picker checks and ten paired checks.
The paired run withheld a state push from one accepted command per family and
observed exactly one selected-state read for each command. The no-companion run
passed 380 checks across saved ID and Device Setup paths. The test removed all
three temporary HA installations.
[Recovery and native toggle timings](performance-contract.md#revision-2026111923-feedback-recovery)

The archive verifier, mixed-predecessor harness, simulated browser review, and
native Director receipt support different parts of the qualification. Remaining
first-demo checks include the full native mixed-project cutovers, the rendered
Composer and Navigator screens, and physical indicators. The coordinated
unattended installer also needs a supported Control4 installation interface. The
[OpenSpec tasks](../openspec/changes/build-ha-driver-suite/tasks.md) track the
handoff conditions.

## Revision 2026111925 Quick Setup recovery

An unrelated Home Assistant device going offline no longer invalidates an open
draft. The Coordinator refreshes availability and still requires a fresh review
when the eligible list or capability details change.

When an added driver has already configured its device and its acknowledgment
was lost, Quick Setup shows the saved name and room in the default list. The
installer reviews and confirms finishing setup. The Coordinator completes the
receipt without creating another driver or repeating configuration. A duplicate
endpoint match still requires review.

If the initial switch migration check fails or times out, the existing migration
section offers a retry. A successful retry opens the driver list or hides the
section when no work remains.

The independent browser review exercised the packaged Coordinator at 320 × 300
and 1000 × 550 pixels. All eight checks passed, including keyboard retry, focus
after recovery, retained draft edits and the explicit setup confirmation. The
catalog and commissioning tests exercised the backend with simulated Home
Assistant and Director replies. Native Composer verification is pending.
