# Light and Switch functional comparison

Compared BP's original Light and Switch release packages (v1.0.6, driver version
106), the Switch 107 and Light 1 prototypes at `86441f1`, and the suite packages
reviewed on November 17, 2026. The BP Light baseline was the original
`bphillips09/Control4-HA-Light` release. Findings are based on package XML, Lua
dispatch, and existing tests. This comparison did not run the three generations
side by side on hardware.

| Earlier behavior                                                                                                                                                                                              | Development build at the initial audit                                                                                                                                                                | Impact at that point                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| BP Light listed supported HA effects in Navigator, sent the selected effect to HA and displayed the current effect.                                                                                           | The packaged Light disables Extras and the HA adapter has no effect command.                                                                                                                          | Users lose the effect picker on lights that advertise effects.                                                                    |
| BP Switch and both prototypes could operate a manually specified HA toggle helper (`input_boolean`).                                                                                                          | Manual setup accepts `light.*` and `switch.*`. Some metadata can represent helpers, but the command path cannot operate them.                                                                         | Software toggles used for virtual switches or automations lose direct control.                                                    |
| Both prototypes exposed per-indicator and bulk LED programming commands. Prototype Light could follow a selected Control4 light or group with separate on/off indicator colors and refresh its feedback.      | Advanced setup can explicitly set a supported indicator's color, brightness or hardware behavior. Composer programs and bound-target feedback lack equivalent commands.                               | A user can configure an indicator by hand. A program or a linked light cannot drive it the old way.                               |
| Prototype Light could itself participate in an Advanced Lighting Scene that operated its connected Control4 target. Its scene implementation also supported flashing steps.                                   | The source now plays the prototype’s saved scene format through the shared runner for HA loads and linked C4 targets. Shim tests cover delay, flash, stop and target replacement with a linked group. | Rehearse a same-instance update in Composer and run the original scenes with the real HA load, linked light and linked group.     |
| Prototype Light exposed standard paddle taps, double/triple taps, holds and releases through native light button events.                                                                                      | Physical multi-presses still produce named programming events. Standard gesture delivery uses a different event interface.                                                                            | New programming can use multi-press. Existing native-button programs require remapping.                                           |
| Prototype Light released a forwarded paddle hold when a sequence gap or refreshed snapshot indicated a possible missed release. It required a declared release and retained failed cleanup for retry.         | The new code handles disconnects and several invalidation cases, but lacks these protections for a connected target.                                                                                  | A missed release can leave a connected dimmer continuing to ramp. This is a reliability gap inferred from the code paths.         |
| Both earlier families used different binding IDs. BP exposed the exact HA entity through the `ENTITY_ID` programming variable. Switch accepted the legacy `BUTTON_ACTION` click packet as well as `DO_CLICK`. | The suite has new identities and a `Selected Endpoint` variable. Switch handles ordinary Button Link clicks via `DO_CLICK` and has no equivalent legacy packet handler.                               | Old bindings, variables, and programs need explicit assessment. A sender that uses the legacy packet exclusively loses that path. |
| Prototype diagnostics showed Last Gesture, Gesture Count, Last Sequence and a consolidated diagnostic dump.                                                                                                   | The suite has setup status and timing diagnostics but omits those individual troubleshooting fields.                                                                                                  | A difference for installers diagnosing missed events.                                                                             |

Other behavior differences matter for existing installations. BP Light could
turn a light on when choosing a color while off; the suite holds the color for
the next On. The prototype Switch could send manual power commands before
receiving its first snapshot; the suite waits for confirmed state. Individually
valid power, level, group, scene or gesture commands do not establish that old
programming against another package will survive migration.

Sources include the
[original BP Light](https://github.com/bphillips09/Control4-HA-Light/releases/tag/v1.0.6),
[original BP Switch](https://github.com/bphillips09/Control4-HA-Switch/releases/tag/v1.0.6),
[suite connected-light behavior](../connected-control4-lighting.md),
[suite indicator writes](../../src/ha/indicators.lua),
[gesture processing](../../src/ha/gestures.lua),
[connected hold handling](../../src/ha/connected-light.lua), and
[Switch dispatch](../../src/ha/switch-adapter.lua).

## First-demo coverage after the independent review

The first demo must cover the union of the BP and prototype behaviors for each
family. The package comparison checks six pinned archives. The table below
identifies the executable starting points for behavioral qualification. A
passing predecessor test establishes its expected result. Each corresponding
candidate test must exercise the new code and record its result. The last column
lists outstanding evidence.

| Path and source                                                                      | Acceptance case on the candidate                                                                                                                                                                                                                                                                                                                  | Outstanding first-demo evidence                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Coordinator 113 and 114, stock/prototype driver XML and runtime                      | Update the same instance with the original HA URL, protected token, SSL, certificate directory, CA, certificate and key. Retain HA URL variable, Connected/Disconnected events and saved Call Service programs including template variables. Run connect/disconnect and entity diagnostics.                                                       | Restored settings, native program execution and rollback on both starting versions.                                                                                                                                                                                                                                                                                                                               |
| Coordinator 114, legacy family fixtures and transport/lifecycle tests                | Keep provider 1, HA_DEVICE, network 6001 and HA WS. Exercise each of the eleven pinned BP consumers. Deliver just the selected state and events after a reconnect, including auxiliary Thermostat entities. Retired or unauthorized requests must not affect another consumer.                                                                    | Candidate against the eleven-family harness and mixed-version project.                                                                                                                                                                                                                                                                                                                                            |
| Prototype picker and preparation across all three repositories                       | Replay the companion's catalog and activation fixtures through real consumer and Coordinator code. Verify exact event/load identity, paging, warm reopen, revision invalidation, prepare/release, connection status and HA acknowledgment. Exercise companion unavailable and native-only modes.                                                  | Candidate package pair through the pinned producer/consumer fixtures and native commissioning.                                                                                                                                                                                                                                                                                                                    |
| Original BP Light 106, commands.lua                                                  | Exercise synchronize, on/off, native and linked button actions, level and brightness targets, color targets while on and off, group set/ramp, scene push/activate and Navigator effect choices/current selection. Verify resulting HA services and native feedback per fixture.                                                                   | Revision 10 issued the selected effect to the Docker light and received confirmed effect state for rainbow and off. The runtime also exercised deferred color while off. CORE 1 retained and activated a saved 55% scene across the BP 106 to 2026111834 update with a simulated linked load. Navigator appearance and remaining saved program checks are open. [Family evidence](../../lab/family-evidence.json) |
| Prototype Light 1, full Light entry point, group links, publications and scene tests | Retain direct, gesture plus load, programming-only and connected modes. Restore saved DeviceSelection, explicit controller override, App Control Link and individual targets. Exercise presets, group fanout, wrapper scene persistence, flash and synchronization.                                                                               | CORE 1 retained the same scene, selected paddle, room, target binding and proxy in the Light 1 to 2026111834 upgrade. The saved scene drove the linked Example Light to 62% on both revisions. Physical picker and remaining operating modes are open.                                                                                                                                                            |
| Prototype gestures and indicators, both families                                     | Native single/double/triple press, hold and release, additional/custom button events, stable IDs, source loss and missed-release handling. Restore LED choices, per-button and bulk commands, restricted palettes and brightness, bound-light on/off colors and refresh.                                                                          | Saved event/program IDs and native interactions on both generations.                                                                                                                                                                                                                                                                                                                                              |
| BP Switch 106 and prototype 107, Switch entry point and load conditions tests        | Exercise relay open/close/toggle, both button packet formats, manual light/switch/toggle-helper selections, state conditions, and source-specific button/LED programming. Compare explicit power before first state with each baseline.                                                                                                           | First-state policy, saved program mapping and explicitly requested Switch migration on both sources.                                                                                                                                                                                                                                                                                                              |
| Diagnostics, updates and recovery                                                    | Exercise original diagnostic actions, gesture count/sequence and the three-repository timing scenarios. Account for runtime-only commands such as Coordinator's connected-driver update handler by documenting callers, supported successor and update authorization. Repeat clean install, in-place upgrade, interrupted migration and rollback. | Native evidence, comparable timings and installer verification of the final packages.                                                                                                                                                                                                                                                                                                                             |

Reference artifacts and versions are listed in
[the package comparison guide](../first-demo-packages.md). Record unsupported or
conflicting behavior as open until the user accepts an explicit change. The
original/prototype packages and companion remain available as regression
references.

## Light qualification against BP 106 and prototype 1

The published 2026111823 archives passed the identity, wiring and programming
declaration comparison against the pinned predecessors. The Light and shared
suite tests passed against the corresponding source. Each row identifies the
behavior and the highest evidence available for that check.

Candidate 2026111824 passed 159 Light adapter assertions against its packaged
Lua and 458 Light checks with real Home Assistant lab services and a simulated
Director. It also passed 123 mixed-family assertions against the pinned BP
command sources. The real-HA run used three repetitions. The selection check
allows one exact recovery read for the previously selected device before the new
subscription snapshot. Native project, Navigator and physical verification
remain separate.

| Behavior                                                                             | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Remaining check                                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Upgrade an existing Light and keep its Device Link, proxy and programming variable   | Both archives retain the Light V2 proxy and input 999. The foundation restores `ENTITY_ID` across reloads with and without the variable rename API. The BP upgrade on CORE 1 retained the device and proxy IDs. [Foundation test](../../test/test_foundation.lua)                                                                                                                                                                                                                                                                              | A native Prototype Light 1 update retained the same device, proxy and links with a simulated selected wall control and linked light. Existing prototype variable and program references still need verification. |
| Recover a saved manual or physical selection with the same controlled target         | Tests cover both Director string formats, explicit clearing, old picker storage, crossed identifiers and a changed linked load. [Device Setup tests](../../test/test_ha_device_setup.lua)                                                                                                                                                                                                                                                                                                                                                      | Use a physical selection and distinct load through a native reload.                                                                                                                                              |
| Find and choose a compatible device with the optional helper present or absent       | The packaged picker exercised browse, cancel, failure and retry against the Docker lab. The driver-entry test turns a manual toggle helper on and off without the companion. [Packaged picker](../../test/packaged_picker.lua)                                                                                                                                                                                                                                                                                                                 | Verify the manual field, focus and Properties landing in Composer.                                                                                                                                               |
| Use direct HA, HA plus buttons, buttons only or connected Control4 mode              | Saved choices start in their intended mode in the driver tests. An explicit App Control Link owns app control while the paddle links can operate distinct targets. [Device Setup tests](../../test/test_ha_device_setup.lua), [connected Light tests](../../test/test_ha_connected_light.lua)                                                                                                                                                                                                                                                  | Run the four workflows on upgraded instances in the backed-up project.                                                                                                                                           |
| Operate the light through native buttons, programming, dimmer level and rated motion | The BP in-place test operated the original proxy. Tests cover native On/Off/Toggle, legacy brightness packets, ramp start, stop and lost feedback. [Light adapter tests](../../test/test_ha_light_adapter.lua)                                                                                                                                                                                                                                                                                                                                 | Exercise saved programs and a physical keypad on the current packages.                                                                                                                                           |
| Set dimmer presets, On mode, click and hold rates and keypad colors                  | Composer showed the native dimmer editor, rates and Add Preset. CORE 1 revision 2026111837 verified Default On, Previous Level and a custom 64% preset saved in Composer. Director and Home Assistant both confirmed the custom level. The packaged driver reads native settings back after a cold Lua load. [Lab results](../first-demo-packages.md#revision-2026111837-template-fade-verification)                                                                                                                                           | Composer-only checks remaining: edit and remove a saved preset, and use its Test button.                                                                                                                         |
| Choose a color for an off direct Home Assistant load                                 | BP 106 turned the load on. The user approved keeping the template example's behavior, which leaves the light off. The suite holds the color until On because Home Assistant applies color through its On service. [Light adapter tests](../../test/test_ha_light_adapter.lua)                                                                                                                                                                                                                                                                  | Verify the control in Navigator.                                                                                                                                                                                 |
| Select an effect and show its confirmed state                                        | Packed Light operations with the HA Docker fixture exercised effect selection and feedback. [Family load qualification](../family-load-qualification.md)                                                                                                                                                                                                                                                                                                                                                                                       | Verify the effect control in Navigator and its visible current selection.                                                                                                                                        |
| Preserve saved scenes and group behavior including timed steps and flash             | The original BP archive saved a scene that the suite archive played in the test harness. Direct and connected Light tests also cover a cold read of a suite scene, prototype storage, flash, cancellation and group forwarding. Revision 2026111825 restores the template's support for scene ID zero. On CORE 1, the first scene saved in Composer set Light 52 to the saved 100% level before and after reload. [Light adapter tests](../../test/test_ha_light_adapter.lua), [connected Light tests](../../test/test_ha_connected_light.lua) | Native BP 106 and Prototype Light 1 upgrades retained their saved 55% and 62% scenes and drove a linked Example Light. Repeat a saved scene upgrade with a connected group.                                      |
| Preserve button programming for the supported tap counts, holds and releases         | Program IDs survive restart and reorder in the gesture tests. After a failed release, cleanup only uses the original binding. A saved suite double-tap was exercised on CORE 1. [Gesture tests](../../test/test_ha_gestures.lua), [connected Light tests](../../test/test_ha_connected_light.lua)                                                                                                                                                                                                                                              | Check the installed Composer list and exercise a saved native Light gesture from a prototype project.                                                                                                            |
| Set HA indicator behavior, brightness and colors without changing other settings     | The isolated HA indicator run covered independent changes and restored the fixture. Driver-entry tests cover per-channel and bulk programming, unsupported values and no automatic write on selection. [Device Setup tests](../../test/test_ha_device_setup.lua)                                                                                                                                                                                                                                                                               | Test an existing indicator program, a physical LED and a real keypad LED tied to the controlled load.                                                                                                            |
| Read diagnostic status and measure common paths                                      | The Light reports exhausted release retries through the existing diagnostics. The opt-in timing profile measures commands, state, gesture, preparation and recovery at documented boundaries. [Device Setup tests](../../test/test_ha_device_setup.lua), [performance contract](../performance-contract.md)                                                                                                                                                                                                                                    | Record comparable samples on each predecessor and the candidate.                                                                                                                                                 |

## Corrections exercised locally

- Both driver entry points now verify manually entered Home Assistant toggle
  helpers and route their on/off services to the right domain. The new Switch
  accepts legacy click packets at its mapped relay and paddle inputs.

- The shared gesture code releases an active connected paddle after a sequence
  gap, an advancing snapshot or a withdrawn release capability. A hold-only
  source still fires programming. A failed outgoing release retries only on the
  original binding.

- Coordinator exposes the original Connected and Disconnected programming events
  at IDs 1 and 2. Authentication, lost connections, retries, reload and
  duplicate callbacks have driver entry-point tests.

- Quick Setup detects an existing original/prototype Light without claiming
  ownership of it. The preview identifies the installed device and room, leaves
  the project untouched and lets the user return to their selection.

- The shared indicator implementation handles all six Light and four Switch LED
  programming commands and preserves Light's saved per-channel colors. An
  explicitly selected connected paddle supplies on/off feedback. The original
  Refresh LED Feedback action requests its current state. The isolated HA run
  covers combined color and power, brightness, and behavior.
  [Recorded indicator samples](../../lab/indicator-evidence.json)

- Completed prototype Light physical-picker records preserve the exact physical
  choice, prepared load, source registry and button identity. Direct,
  button-enabled HA, programming-only and connected-light configurations have
  separate startup tests. Crossed records, disabled or changed registry entries
  and a changed explicit link cannot issue a load command. A CORE 1 rehearsal
  with a saved project and manual event-only selections still needs coverage.

These corrections have local tests. Native reference preservation and the rest
of the coverage matrix remain open.

### Connected hold cleanup during a mode change

Revision 2026111820 keeps the existing bounded release retry active if a
transient failure occurs while the installer leaves connected mode. The retry
carries the original binding and checks its current peer before sending.

The independent review also replayed a decoded Home Assistant hold into Setup.
After two simulated release failures, the next attempt succeeded on the original
peer at 200 virtual milliseconds. The setup retained the saved selection and
published no additional user gestures during cleanup.

Revision 2026111821 addresses the three follow-up audit findings. A completed
tap rechecks the live peer after its initial press. If the binding lookup fails
during release, the old target's listeners are already detached and the existing
retry checks the original peer again. After four failed attempts, **Print device
diagnostics to Lua** reports the release failure through the existing
command-result readout. Checked-in proxy tests exercise the replacement peer,
the late watcher callback and the one-time diagnostic.

| Starting state                                                           | Task                                            | Observed result                                                                                         | Evidence                                                                                                                                   |
| ------------------------------------------------------------------------ | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| A native keypad holds a linked dimmer, and the first release send fails. | Change **Button behavior** to **Buttons only**. | The existing release retries after 100 ms on the original binding. New holds are disabled in this mode. | Demonstrated through native button packets, the setup controller and a virtual clock. Physical dimmer behavior awaits native verification. |
| A release send is in progress, and its callback changes operating mode.  | Finish the release.                             | Both immediate attempts targeted the original binding. A pending retry completed there after 100 ms.    | Demonstrated with a reentrant proxy fixture.                                                                                               |
| A failed release is awaiting retry.                                      | Rebind the dimmer or remove the driver.         | A replacement peer receives no release. Destruction ends the retry timer.                               | Demonstrated in the connected Light fixture.                                                                                               |

### Prototype Light package review after revision 02

The revision 02 archive report identified 19 missing or changed Actions and
Properties keys against the pinned prototype. The current source declares all 19
with compatible types, list options and writability. The 19 comprise four
Actions, nine read-only Properties and six writable Properties, including
Operation Mode. This was a source comparison. The packaged report and controller
rehearsal must be repeated after a build.

| Original surface                                                                                                        | How the suite handles it                                                                                                                                                                                                       | Local evidence                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Show Advanced Properties and Hide Advanced Properties                                                                   | Both saved Action commands change the existing Properties visibility setting.                                                                                                                                                  | Device Setup tests exercise both Lua Actions and inspect the native setting.                                                                                  |
| Refresh Entities, Select Device, Entity Selection, Discovery Status, Discovery Catalog Entity ID                        | The retained native picker requests the shared catalog. A saved device choice goes through the same explicit selection path as Device Setup. The optional catalog sensor supplies names and rooms.                             | Driver entry-point and Coordinator request tests. The native Composer search dialog needs a visual check.                                                     |
| Operation Mode                                                                                                          | Original mode changes preserve physical identity and select the corresponding load, buttons or connected Control4 target. A later Button behavior override takes precedence.                                                   | Driver entry-point tests change modes and restart a prototype-selected Light.                                                                                 |
| LED Indicator, LED On Color, LED Off Color, LED Status                                                                  | Original RGB fields and the Device Setup palette use the same per-control and per-indicator preferences as saved programming. Each supported color is selectable with a keyboard. Bound-light feedback sends the saved color.  | Tests cover native and web editing, verification of allowed colors, matching bound-light feedback and the absence of device writes while saving a preference. |
| Device Setup, Mode Description, Selected Device, Connected Light, Status, Selected Capabilities and Button Capabilities | Retained native fields mirror the active setup, target, state and capabilities. Button descriptions use the same verified button and gesture definitions as Composer programming. Basic setup presents the shared device page. | Driver entry-point tests read back the retained fields.                                                                                                       |

A later source change also recovers a prototype Light with only a saved event
entity. The Light reads its exact HA Gesture Bridge registry entry. A linked
light must have the same entity, domain and registry identity on reload. A
source without a physical device identity can provide button programming and its
explicitly linked load. Device Setup can retry the exact saved event even when
discovery is unavailable. Tests cover native double press, a changed link, a
replaced registry entry, rejection and retry, explicit clear and a late registry
reply.

Installed revision 02 predates these corrections. A saved-project manual event
rehearsal on CORE 1, a fresh packaged comparison and the independent Switch
migration remain outstanding.

## Pinned `example_light` comparison

Two high-severity issues reproduced in the suite's Light adapter and template
integration. The comparison used the actual upstream sample at v0.9.111,
revision `5efdae849b32d8739d23e4750c0b6e4d60f754c9`, and reviewed the only later
tag, v0.9.112.
[Pinned example](https://github.com/finitelabs/control4-driver-template/tree/v0.9.111/example-driver/drivers/example_light)

### 1. Architecture and modularity

Copier generated the suite with the `light` module. The project's three-line
Light entry point installs a shared HA lifecycle and a purpose-built adapter.
The sample supplies an in-memory bulb with fixed RGB and color-temperature
capabilities. Both use `Light.new`, the library's command and report contract,
`light_v2` at 5001, and library-generated native capabilities. The library owns
settings, presets, keypad feedback, ramps, scenes and groups. The HA adapter
provides negotiated capabilities, HA service commands and feedback, or forwards
commands and watches a connected Control4 light or group. The suite preserves
predecessor binding IDs and explicit separate links to app and paddle targets.
[Suite entry](../../drivers/light/driver.lua) ·
[Light adapter](../../src/ha/light-adapter.lua)

**High, corrected in 2026111817.** Connected-mode delegation ran before the
library dispatcher classified the command. In the same fixture,
`SET_BUTTON_COLOR`, `JOIN_GROUP` and `LIGHT_GROUP_JOIN` worked in direct mode
and were swallowed in connected mode. The target has no handler for these
commands. This affects the Light's own linked keypad and its participation as a
group member. Using a group as the Light's connected target is a separate,
tested path. [Dispatch](../../src/lib/light/handlers.lua) ·
[Connected adapter](../../src/ha/light-adapter.lua)

### 2. Security and error handling

**High, corrected in 2026111818.** In direct mode, a confirmed off fixture
displayed 100% after `ON`. After HA rejected the request with
`permission_denied`, the proxy still showed 100% after ten virtual seconds. The
result is delivered to the driver status, while the library retains the
predicted state without a new report. A test against pristine upstream v0.9.112
confirmed the existing `final` report API settles the estimate after an exact
read. The upstream adapter contract has no async rejection callback. The suite
settles definite no-send outcomes using the last confirmed state. For an
uncertain outcome it requests one exact read of the selected load and reports
the result through the Light library. A failed read marks the Light unavailable.
Command, selection and transport correlation protect newer work.
[Result delivery](../../src/ha/load-command.lua) ·
[Proxy publication](../../src/lib/light.lua)

The independent recovery review used this task list on the Light's usual entry
points. The original BP driver displayed reported brightness. The prototype sent
the command and waited for Home Assistant feedback.

| Starting state                                                    | Task                                                   | Observed result                                                                                                                                                                            | Evidence                                                                                                                                                                                                            |
| ----------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Configured dimmer is off. Home Assistant loses the command reply. | Turn the light on from the usual light control.        | One exact read returned On at 40%. The native proxy settled at 40%.                                                                                                                        | Demonstrated with the real driver entry point and simulated Director and HA. Navigator feedback awaits native verification.                                                                                         |
| An exact read is in progress after a timeout.                     | Use the light again or change the selected device.     | The old reply could not replace a newer command or take the replacement offline.                                                                                                           | Demonstrated with adapter and Coordinator fixtures.                                                                                                                                                                 |
| The command timed out and the state read failed.                  | Find the recovery action from the normal setup screen. | Device Setup and Properties named the existing **Refresh Home Assistant devices** action. Troubleshooting also reported unavailable. Refresh restored the same dimmer at its actual level. | Demonstrated in the integrated driver test. Browser renders at 320 × 300 and 1000 × 550 kept the status and primary action in view and preserved keyboard focus. Composer’s native Actions tab awaits verification. |
| A saved program uses the original Light **Turn On** action.       | Run that program and recover a timed-out command.      | The same one-shot recovery ran through the existing command.                                                                                                                               | Independently demonstrated through the driver entry point in simulation. Execution of the installed program awaits native verification.                                                                             |

Revision 2026111819 also covers a Home Assistant service that accepts the
command and omits the state update. The Light template's deadline now triggers
the same authenticated refresh. Power and brightness share the refresh, a
power-only target needs only power feedback, and a push during recovery
supersedes the read. CORE 1 accepted revision 2026111819 in place and preserved
both devices' selections and bindings. Its saved Switch double-tap program
turned off the fixture Light after the update.
[CORE 1 readback](../../lab/installed-revision-19-readback.json) ·
[Saved program readback](../../lab/gesture-program-readback.json)

The paired lab withheld the Light's state update after the real Home Assistant
service ran. One authenticated read confirmed the selected Light on both
2026.11.1 and 2026.11.2. One sample on each version measured 3.17 and 3.18
seconds respectively from command dispatch to confirmed proxy feedback. The
Python monotonic clock includes the template's wait, test bridge, read and proxy
delivery. Logging was Off.
[HA 2026.11.1](../../.cache/version-runs/2026111819/2026.11.1-paired.json) ·
[HA 2026.11.2](../../.cache/version-runs/2026111819/2026.11.2-paired.json)

| Starting state                                                                     | Task                                         | Observed result                                                                                                                                                  | Evidence                                                                                                                                                 |
| ---------------------------------------------------------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The selected dimmer is off, and Home Assistant accepts the command silently.       | Turn it on from the usual light control.     | The display reflected the confirmed 40% level after one read.                                                                                                    | Demonstrated from the Light proxy with simulated Director and HA. Native Navigator display awaits verification.                                          |
| A saved program uses **Turn On**, and the accepted command's state cannot be read. | Run the program and recover the same device. | Device Setup, Properties and Troubleshooting showed **Device unavailable**. **Refresh Home Assistant devices** restored the existing selection and actual level. | Independently demonstrated through the driver entry point and Coordinator fixture. Execution of a stored program in Composer awaits native verification. |
| The selected dimmer is off and supports hardware fades.                            | Start a timed fade.                          | A final push completed the fade without a read. When omitted, a four-second fade made one read at 5,000 ms and did not poll.                                     | Demonstrated with a virtual clock and simulated transport. The runtime uses the existing opt-in `snapshot.http` measure for the exact HA read.           |

### 3. Performance and scalability

The sample schedules simulated refresh and final feedback. HA uses scoped
Coordinator push, and the connected target uses Director variable watches. Keep
recovery bounded to the selected load. A current, correlated report can repair
an incorrect prediction without adding periodic polling. Dispatch timing alone
does not establish that a group request reached its handler.

### 4. Readability and maintainability

The suite differs from the pin in `light.lua` and eight of seventeen files under
`lib/light`. The changes include real lifecycle teardown, explicit logical On
intent, connected-target capabilities, and stored scene compatibility. Keep the
native command classification near the upstream dispatcher. Make the adapter
responsible for transport and the minimum hooks needed to express delegated
target ownership. The suite and example enable **Default On**. The suite uses
the Control4 mode or saved Default On brightness when supplied. Without a usable
proxy setting, Home Assistant uses the load's remembered brightness.

### 5. Test simplification

The existing suite passed, including 279 inherited conformance assertions. The
two regressions use existing adapter and connected-Light fixtures. Add them
there and extend the existing packaged harness for rejected or missing feedback.
The package persistence test covers saved rows and reload. Actual Composer
`GET_SETUP` replay with a bound keypad and an observed connected group action
remains a native acceptance check.

### 6. Prioritized action plan

| Priority      | Change                                                                                         | Acceptance                                                                                                                                                           |
| ------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| High          | Preserve library handling of native settings and group membership before transport delegation. | Connected `SET_BUTTON_COLOR` reaches Settings. Group join, state publication, synced commands and group-to-member commands all work without a second target command. |
| High          | Reconcile failed HA commands by request and selection generation.                              | Definite rejection returns to confirmed evidence. Ambiguous timeout requests one exact read or shows unavailable. Older results preserve later commands.             |
| Small upgrade | Adopt v0.9.112 through a reviewed merge.                                                       | Configured keypad colors stay explicit and unset colors remain absent. This change has no diff in the sample driver.                                                 |

For the first regression, allowing `SET_BUTTON_COLOR` to return `false` from
`Adapter:delegate` routes it to the existing library setting handler. Use the
same ownership order for the group lifecycle and test execution as well as
membership. For the second regression, the supported reconciliation primitive
after a confirmed read is `light:report({ kind = "final", on = false })`.
Deliver that report only while the command and selection still own the result.

On 2026-11-18, the latest tag and upstream `main` both pointed to v0.9.112,
`61cfcb7671ee4ec76976170f64ea4c1810aa2b30`. That is one tag and one commit past
our pin. It leaves `example_light` unchanged and updates the library to omit
unset keypad colors. The three changed library files and affected conformance
helper merged cleanly in an isolated copy. After updating the old default-color
assertion and the contract-document hash, `make test`, `make suite-build` and
`make suite-verify` passed. Adopt this update before testing the connected-mode
keypad fix. Verify that a real keypad retains its configured colors when an
unconfigured Light first connects.
[Upstream change](https://github.com/finitelabs/control4-driver-template/pull/238)

## Revision 2026111911 Light audit

The independent review reproduced one high-severity release failure and five
medium-severity settings and connected-target failures. The repairs passed the
affected suites and an independent recheck. This review covers the Light paths
below and leaves the full-suite release audit open.

### Architecture and modularity

The connected adapter now uses the template's existing color target resolver
when a native command supplies only a preset ID. The adapter keeps the native
target's capability checks and the existing On-color follow-up suppression.

### Correctness and error handling

| Severity | Reproduction | Correction |
| --- | --- | --- |
| High | A normal paddle release encountered one failed binding lookup. The previously sent hold never released. | A matching release uses the existing bounded retry and checks the original binding again before sending. |
| Medium | The first brightness read threw while a linked dimmer was already on. A later brightness report could not recover it. | Register the variable listener when its initial read fails, so the next confirmed report can restore feedback. |
| Medium | A binding lookup threw before the first step of a two-step scene. The second step still ran. | Treat the lookup failure as a failed send and cancel the remaining steps. |
| Medium | A connected target received no color command for a valid saved preset ID. | Resolve the preset using the template's lookup and forward its color and rate. |
| Medium | A saved color scene could not ramp a linked dimmer-only group. | For an interactive scene ramp, drive brightness even when the linked target cannot apply the saved color. |
| Medium | Deleting the active preset could leave a stale level, and a partial mode selection could reuse a different preset's level. | Keep the applied level tied to its preset ID and fall back to Default On when the active preset is removed. [Upstream issue #244](https://github.com/finitelabs/control4-driver-template/issues/244) |

### Performance

Release cleanup uses the existing retry bound. Failed initial reads register
the same native listener used on the healthy path. The fixes add neither
polling nor another profile or background timer.

### Readability and maintenance

The settings changes remain in the shared Light library. The suite adapter
handles routing to a connected Control4 target and the failure policy for the
suite's scene wrapper.

### Test coverage

The current package test exercises custom preset creation, editing, removal,
resolving conflicting settings from an older install, and transition rates
across two Lua processes. The connected suite includes regressions for the
original binding, recovery from an initial read error, scene cancellation,
and color-preset forwarding. Both tests use a Director shim.

### Qualification priorities

The native Composer edit and the simulated indicator checks were demonstrated
on revision 2026111910. The native update to 2026111911 retained the selected
On mode and saved preset. Director and HA confirmed their 57% and 64% levels.
Physical keypad and indicator evidence, and native setup entry and focus,
remain separate first-demo checks.
