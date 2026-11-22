# Current driver and setup audit, 18 November 2026

The baseline is the six pinned BP and prototype packages, plus the earlier suite
Light that exposed the native proxy editor. The reviewed paths include device
setup, indicator and keypad settings, commissioning, in-place visibility,
package checks and their tests. The main regression was the loss of access to
the standard Light editor. No whole-family parity or hardware signoff follows
from this audit.

## 1. Architecture and modularity

| Finding                                                                                                                                                       | Change in revision 08                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| High. Light opted into hiding the entire native editor to shorten navigation. Its library still implemented the commands, but Composer users lost the editor. | Removed that opt-in in `src/ha/light-adapter.lua`. Device Setup uses the template settings for keypad colors, so native and custom editing share storage.                                                    |
| High. The Switch prototype could set an indicator policy for all channels. The shared settings code had restricted that operation to Light.                   | Restored the applicable device-wide policy and status alongside individual indicator settings. `src/ha/indicator-programs.lua`                                                                               |
| High. Quick Setup ignored the original Switch package when checking existing device ownership, allowing duplicate controls.                                   | Reused the migration module’s read-only package identification during both preview and confirmation. A matched older Switch requires a separate user-requested migration. `src/ha/commissioning-project.lua` |

The Switch comparison also found two reachable prototype tasks missing from the
initial candidate. Switch now accepts a custom discovery catalog for names and
rooms. A physical switch can control the load with or without reporting button
presses. Dedicated regressions exercise unconfigured catalogs and the saved
load-only choice after restart.

## 2. Security and error handling

| Finding                                                                                                          | Change in revision 08                                                                                                                                            |
| ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| High. A rejected native picker edit could appear selected while commands continued to go to the original device. | The property callback immediately restores the last verified choice. Successful verification publishes the new one. `src/ha/native-picker.lua`                   |
| Medium. A completed Quick Setup receipt permanently blocked recreation after the user deleted the device.        | Offer an add only after a clean inventory and an exact lookup confirm absence. Preview and explicit confirmation still apply. `src/ha/commissioning-project.lua` |

The comparison and native visibility checks need property names and visibility
flags. They do not require printing credential values.

## 3. Performance and scalability

Medium. Quick Setup rebuilt the entire disabled table for each page of 50
devices. With 1,000 choices it constructed 10,500 rows before selection was
enabled. The revised loader appends page data and renders the completed list
once. This is a row-count comparison. Browser and controller latency are
separate measurements. `src/ha/commission-ui.js`

## 4. Readability and maintainability

High. A retained prototype selection could expose its old Operation Mode after a
newer Button behavior override took effect. Properties now shows the applicable
controlling setting. Distinguish the Control4 keypad's on/off colors from the
lights built into a Home Assistant device in both help and Device Setup.
`src/ha/device-driver.lua`

## 5. Test simplification

High. Archive verification iterated whichever tabs existed, so deleting all tabs
passed. The checker now requires each family's actual tab name, packaged HTML
and, for Light, the native editor capabilities. It boots the actual compiled
package with its serialized config and checks the writable field returned by
Device Setup. Keep the binary, dimmer, and physical paddle scenarios separate
because they expose different controls. `tools/check_packages.py`,
`test/test_package_setup_pages.py`

## 6. Prioritised action plan

| Priority | Task and acceptance evidence                                                                                                                                                                      | Status                                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| High     | Upgrade the existing Light, open its native editor on a dimmable endpoint, change a preset or rate, reopen and read it back, then restore it. Check linked button preset editing where available. | Requires Composer. A binary light cannot qualify dimmer controls.                                                |
| High     | From Device Setup, distinguish a Control4 keypad button from a physical Home Assistant indicator, edit one color and check focus, readback, persistence and unaffected channels.                  | Template, driver and browser checks cover the editing flow. Physical LED appearance requires a linked device.    |
| High     | On an original Switch, check ownership in Quick Setup and verify that review alone creates nothing. Verify explicitly requested migration separately on the original device.                      | Ownership regression covered in the Director shim. Native migration is a separate acceptance task.               |
| Medium   | Check palette, mixed-capability and load-only device states, and keyboard save, cancel and failure. Compare the first available action at normal and narrow widths.                               | Independent browser review covers the two indicator surfaces. Composer and Navigator use separate native checks. |

For future changes, record the exact predecessor task, capability, entry point
and visible result before revising navigation. Compare the same task on the
candidate and include authoring, persistence and downstream behavior where
applicable. Source declarations, an HTML preview and a native observation each
establish different things. The review instructions in AGENTS.md make task loss
and unverified native behavior explicit.

The independent reviewer exercised the keypad on/off editors and the
whole-device and per-indicator controls in rendered panes at 320 × 300 and 1000
× 700. The first keypad implementation lost keyboard focus after Save. The
recheck covered success, failure, retry and loss of capability. The Switch mode
label was shortened after it did not fit the narrow pane. The manifest
comparison against six source packages is complementary evidence. It cannot
establish editing, hardware response or preservation of saved programming.

### CORE 1 observations

Director confirmed revision 2026111808 on existing Coordinator 42 and Light 52,
and on suite Switch 54. Original Switch 51 reported version 106. None of the
three updated devices reported the retired visibility switch as visible. The
separate Docker test completed 1,109 family checks on the packaged code.

Light 52 reported the paddle entity in its saved programming variable, an older
binary light in its legacy property, and “Not selected” in Device Setup. The HA
paddle currently advertises brightness. This is a failed native
selection-recovery check. A dimmer editor screenshot on this instance cannot
qualify the selected-device workflow until recovery is understood.

### Follow-up with the saved selection and the built-in status light

Revision 09 recovered the selected wall dimmer on the same Light 52 after a cold
reload. Director had returned the persisted JSON object as a Lua table. The old
selection reader required text. The shared storage reader now accepts both forms
and still validates the decoded record. Tests exercise cold selection reads,
completed commissioning receipts and staged migration checkpoints. The saved
revision 08 project retained all 58 existing items, 20 binding edges and three
scripts from the earlier project comparison.

The custom Control4 keypad editor reviewed on 08 addressed the wrong user task.
The relevant hardware is a wall switch enrolled in Home Assistant. On the next
candidate the custom page exposes that device's built-in LEDs; Composer's native
Light editor owns linked keypad colors. The independent review used a single
indicator, behavior-only hardware, multiple indicators and missing capability
information on both families at narrow and wide sizes.

The lab dimmer initially had no indicator mapping. The supported test mapping
now exposes its status light without changing its existing color, brightness or
power. Director confirmed the channel on Light 52. This is a simulated device in
Home Assistant, not a physical Zooz hardware observation.

The user's Composer traceback on revision 09 also reproduced a packaging
failure. The web picker called a Lua module omitted from the compiled Light and
Switch even though repository-based tests loaded it. The call failed before
contacting Home Assistant. The old timeout and generic startup error did not
distinguish that failure from device availability.

### Composer Programming on Light and Switch

Composer's Light V2 picker covers the native Top, Bottom and Toggle actions. The
Switch UI Button proxy exposes Selected. Both drivers use Composer's
driver-event dropdown for additional gestures. Composer alphabetizes that
dropdown. In the five-button lab fixture, the original ordering put Bottom
triple tap last among eight Bottom rows.

Revision 12 uses a short button name and numeric tap count in both drivers. The
independent review reproduced the sorted list from the actual Entryway fixture.
Bottom triple tap moved from row eight to row three and the total visible Switch
events went from 43 to 33. A separate Light test verified that the standard
Bottom triple tap still maps to native action 4 with no new dynamic duplicate.
Extra-button triple taps remain available. Removing four- and five-tap entries
preserves their allocated IDs and existing supported event IDs. Validate the
refreshed list and saved double-tap program in Composer.

Composer's Programming pane can retain an earlier event list during a driver
update. Refresh the Device Events list and select the driver again. If the list
still shows old entries, reconnect Composer to the same project. The Director
reload updates the installed driver and event declarations. Navigator refresh
targets the app and touchscreens.

The Switch uses the UI Button proxy to appear in Control4 experience menus.
Composer showed the default music-and-film symbol in its device tree. Revision
2026112002 declares packaged rocker-switch icons for Composer's device tree and
driver list. The independent preview review checked the 16-pixel icon on both
normal and selected rows and the 32-pixel list icon. The packaged GIFs match
those assets. CORE 5 served both expected GIFs after the in-place update.
Director verified that Fireplace Switch in Patio kept its display name, selected
Home Assistant device and relay connection, and that the Coordinator, Switch and
all 19 Lights returned connected. The existing row's icon in Composer still
showed the default icon on CORE 5 with revision 2026112006. Revision 2026112007
explicitly declares the proxy count shown in the DriverWorks single-proxy icon
example. The rocker artwork and proxy identity are unchanged. Composer still
needs to verify the existing row with this revision.
[DriverWorks icon management](https://control4.github.io/docs-driverworks-fundamentals/#single-proxy-drivers)
