# Prototype cleanup through template libraries

Reference revisions: Light/Switch `86441f1cfdf4ba60f054890444241e4a36d06b8c`,
Coordinator `9102878246e6fe670367d6efc3ed82db2bcc7b5c`. This is a replacement
map for the new suite, not authorization to distribute unlicensed prototype
code.

| Prototype responsibility                                                              | Template implementation to use                                                                      | HA-specific code that remains                                                |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `light/scenes.lua` and scene/ramp handlers in `light/driver.lua`                      | `lib.light.scenes`, `.motion`, `.buttons`, `.settings`, `.oncolor`, `.groups` behind `lib.light`    | Adapter service translation and confirmed HA reports                         |
| Light native capability/brightness/color notification helpers                         | `lib.light.proxy`, `.caps`, `.color`, `.range`                                                      | HA capability mapping and connected-target facts                             |
| Custom event, binding, variable and condition allocation                              | `lib.events`, `lib.bindings`, `lib.values`, `lib.conditionals`                                      | Stable semantic keys and declared gesture identities                         |
| Direct lifecycle callback dispatch in each driver                                     | `drivers-common-public.global.handlers` and `lib.utils`                                             | Retired lifetime/selection checks around HA callbacks                        |
| Raw timer handles and repeated timer bookkeeping                                      | `drivers-common-public.global.timer`; Light-owned timers for lighting                               | HA request timeouts and bounded reconnect policy                             |
| Coordinator `GetFile`, transfer handling and ad hoc request callbacks                 | `lib.http`, `deferred`, `lib.redact`                                                                | Authentication, origin restrictions and HA result correlation                |
| Coordinator `module/websocket.lua` and socket framing                                 | Template-vendored `drivers-common-public.module.websocket`                                          | HA authentication/subscription protocol, membership ownership and recovery   |
| Hand-written property updates and advanced visibility in `module/property_screen.lua` | `lib.utils.UpdateProperty`, `lib.ui.tab-properties`, `lib.ui.page`, combobox/color/pickgrid widgets | Family/capability visibility policy and one shared catalog                   |
| `module/connected_light.lua` XML parsing, color conversion and native publishing      | XML helpers, `lib.light.color` / `.range`, `lib.light` native output                                | Explicit App Control Link resolution and watched target transport adapter    |
| Custom `module/button_link.lua` output/hold work                                      | `lib.light` link/hold behavior and persistent `lib.bindings` for additional declared buttons        | Gesture freshness, sequence/session validation and release on source loss    |
| Coordinator `InstallDrivers` and homegrown deployment sequencing                      | `lib.companions`                                                                                    | Explicit selected-device preview, room/name decisions and rerun records      |
| Per-driver update checks and settings                                                 | `lib.github-updater`, `lib.update-settings`, `lib.driver-filenames`                                 | One Coordinator operation, complete-manifest checks and recovery bookkeeping |
| Prototype Python build scripts and Base loader/submodule                              | Copier Makefile, preprocessor, dependency discovery, driverpackager and package tools               | Small suite-specific integrity/inventory/release checks                      |
| Prototype `module/json.lua`                                                           | Template `JSON.lua` with its supported strict null/array options                                    | Boundary schema checks; never lose null/object/array distinctions            |

`lib.http` and WebSocket helpers supply transport mechanics, not ownership of HA
selections or authorization to broaden queries. `lib.companions` deploys and
binds but does not establish programming-transfer support. The updater provides
download/reload mechanisms; suite manifests and lifecycle recovery still need
their own tests. A generic cache cannot replace revision checks for the shared
HA catalog.

The Coordinator saves migration state through `lib.persist`. Its cache can
return a pending write, and `flush` dispatches pending values without confirming
that Director stored them. The gateway cutover checkpoint includes the scene
attempt so the same durable batch can verify the approved plan later. Before
removing original scene members, migration verifies that plan and a separate
removal intent in Director storage. The migration fixture covers a readback
still showing the gateway checkpoint, an unavailable intent, a changed saved
plan, and a restart during removal. A decoded checkpoint can lose the JSON
object markers on empty scene and group maps. The proof canonicalizes those
empty maps and still compares the remaining checkpoint data exactly.

The HA connection waits for the template WebSocket deletion callback before
reusing a probed URL. Virtual-clock tests cover automatic and manual port
selection while exercising the template's socket cache.

The GitHub updater extension stages archives and waits for Director to accept
each child reload. The Coordinator checks the resulting revision by calling each
child's live UIRequest handler through the template helper. The running
Coordinator verifies its own revision after reload.

Use the template test shim, virtual clocks, Light conformance kit and existing
library tests. Translate prototype behavioral tests into adapter/contract tests
without carrying forward a second scene engine, property framework, transport
stack or Base compatibility layer.

The Light library owns its motion and report deadlines. The Switch uses the
template's one-shot timer and native UI Button notifications because it has no
Light motion engine. Both adapters use the shared HA load command module for
service outcomes and exact selected-state reads. Device Setup uses the same
scoped read for either family's recovery action.

The pinned Composer Kit uses each option value as its display text. The shared
property renderer accepts optional `choice_labels` to display the resolved
target's name while preserving the value used by the property's normal save
handler. Light and Switch use this for Button behavior.

The pinned Light library currently needs two local corrections before the
adapters can rely on it: explicit logical power intent on commands and permanent
destruction. Record their changed files and hashes in the provenance inventory;
keep their API changes additive and independently tested for a later template
update. Do not replace an available library simply because it needs a narrow
fix.

## Template updates

1. Read the current commit from `provenance/template-lock.json` and select the
   new upstream tag and commit. Review the full old-to-new diff, including
   `example-driver/drivers/example_light` on every update. The example lives
   outside the files Copier renders into this project.
1. Render or update from the selected tag using the current
   `.copier-answers.yml` options. Review the merge against the previous template
   base. Preserve the suite's package, proxy and binding IDs and its saved
   programming and settings.
1. Import each applicable example-driver fix into the matching suite adapter or
   shared library and carry over its regression coverage. Keep native proxy
   settings, groups, scenes and keypad behavior in `lib.light`. Implement the HA
   transport and connected Control4 target through the adapter. Record the
   upstream commit, the destination and tests for each fix and the reason for
   any skip. Record an empty example diff when there is none.
1. Update the generated Copier answers, the template lock and provenance hashes.
   Run `make check`, `make test`, `make suite-build`, `make suite-verify` and
   `make suite-verify-first-demo`. Rehearse affected native behavior on the
   approved controller and record the result with the tested archive revision.

From a checkout of the upstream template, use the exact old and new revisions:

```sh
git diff OLD_REVISION NEW_REVISION -- example-driver/drivers/example_light
git log OLD_REVISION..NEW_REVISION -- example-driver/drivers/example_light
```

### v0.9.111 to v0.9.112

The example directory diff is empty. The upstream library update leaves unset
keypad colors absent and retains colors supplied by the proxy or saved settings.
Its conformance change was imported. The suite's connected adapter now delegates
only target control after the library handles settings, membership, group
synchronization and reads. The connected Light test covers keypad color
persistence, both group routes, ramp distance and avoiding a command echo to the
same group.
[Upstream keypad fix](https://github.com/finitelabs/control4-driver-template/pull/238)

### Example Light variable restoration

Upstream PR #240 adds `values:restoreValues()` to the example Light's
`OnDriverInit` so the `Connected` variable keeps its programming ID across a
Director restart. The suite already performs that restore in
`ha.foundation.init` during `OnDriverInit`, before the Light proxy writes
`Connected` in late initialization. The foundation restart test now checks the
original variable ID with and without the newer Director rename API.
[Upstream example fix](https://github.com/finitelabs/control4-driver-template/pull/240)

### Group driver member-count hook

Upstream PR #239 adds `Group:onChange(fn)` for drivers that own a group through
`lib.light.group`. The callback receives the online and total member counts. HA
Light participates through the kit's member-side `lib.light.groups` and can also
use an existing Control4 group as a connected target. Neither role reads the
group owner's internal membership tables. The separate Light Group project owns
its member handling and already publishes a change callback with on-count and
synchronization status.
[Upstream group hook](https://github.com/finitelabs/control4-driver-template/pull/239/files)

### Advanced Lighting Scene IDs

The pinned library accepts scene ID zero. The suite's added range guard excluded
it, so CORE 1 could save its first scene but the Light ignored its activation.
Retain the template's zero-based ID contract when validating incoming IDs. The
Light adapter regression test saves and activates ID zero after a cold read.

### Native Brightness On Mode

The pinned `example_light` and Light Group profiles both enable `defaultOn` and
`onModes`. The suite originally enabled only `onModes`. The CORE 1 Composer
screen showed a Default On Brightness spinner where Light Group showed Preset
and Previous Level choices. Revision 2026111826 adds the template's `defaultOn`
profile option. The package verifier requires the native On mode and default-on
capabilities. The adapter test confirms that an ordinary HA On with remembered
brightness and an unset Control4 mode still leaves brightness to Home Assistant.
Explicit On presets have their own test.

CORE 1 reported both brightness mode flags enabled and supplied a Previous On
preset for a fresh test copy of the same driver. Its existing BP-upgraded Light
reported both flags disabled. The revision 2026111827 experiment sent the flags
through `DYNAMIC_CAPABILITIES_CHANGED`, and the existing proxy continued to
report them disabled. Revision 2026111828 removes that notification change and
retains the template profile. Applying it in Composer also left both flags
disabled on the existing proxy. Director later reported both flags enabled after
a controller reboot, and Composer showed both controls on the existing Light.

Both published driver sources use the template's same brightness notification
path. They also use the same two inputs for preset edits. A single
`SET_PRESET_LEVEL` packet updated the Default On fallback and left the active
preset level stale until the proxy's follow-up `UPDATE_BRIGHTNESS_PRESET`. Keep
those values in sync in the shared settings library. The regression exercises
both edit commands, ordinary On and the preservation of a different On mode.
CORE 1's complete native command sequence already includes the follow-up.

An upgraded Light can expose Default On Brightness without a named On mode. The
template already chooses its saved fallback level in that case. The HA adapter
now passes that level through when the proxy supplied it. An On with no usable
proxy value still leaves the remembered level to Home Assistant.

The stock `example_light` on OS 3.4.3 reported a target of 65535 while fading to
its 55% Default On preset. The upstream fix in `0f02a91` sends the numeric
brightness target during the fade and sends the preset ID once the light
settles. This replaces the suite's built-in-only workaround. The suite imports
the measured proxy behavior in `test/light_proxy_fake.lua` and tests Off,
Default On, Previous Level and a custom preset through the HA adapter. Before
the backport, the fake proxy held 37% throughout the requested fade to 64% for
the custom preset. With the fix it showed 64% and reported preset 42 on landing.

[Upstream fix #242](https://github.com/finitelabs/control4-driver-template/pull/242)

### v0.9.112 to v0.9.114

Tag v0.9.114 includes the fade fix and its proxy fixture updates. The rendered
group library also adds `Group:onChange` from PR #239. HA Light uses the member
side of the library, so it needs no subscription to the group owner's callback.
The only example diff is PR #240's variable restore in `OnDriverInit`. The suite
foundation already does that work, and its restart test covers stable variable
IDs. The upstream lighting suite exercises the new callback, proxy fixture and
fade behavior.

The suite's Light settings regression found that a removed brightness preset
could still supply the active On level when Director includes `LEVEL` on the
removal. The suite clears that selected ID and ignores the removal's level.
Re-selecting the same mode preserves the level reported by the proxy, while a
new mode with an uncached preset cannot inherit a different preset's level. The
packaged two-VM test exercises addition, editing, removal, stale stored values,
and rate persistence. Recheck these behaviors when adopting the next template
pin.
[Upstream issue #244](https://github.com/finitelabs/control4-driver-template/issues/244)

### v0.9.114 to v0.9.116

The `example-driver/drivers/example_light` diff is empty. Both intervening
changes arrive through the template libraries and tests.

- PR #245 keeps the live brightness preset removal fix and adds cleanup when
  startup setup names a preset that is absent. It also checks the preset origin
  before resolving a stored device color. The suite uses that same lookup for
  App Control Links. Tests cover Default On after restart and ID reuse,
  coordinate-only and preset color routing, and Color Agent ID collisions in
  direct and linked modes.
- PR #243 declares the restore phase for bindings, events and values and tests
  each driver's startup in a fresh Lua VM. The shared foundation restores
  bindings early alongside values. Light and Switch restore their saved
  programming events in late initialization. Device Setup still retires the old
  extra tap events, and prototype Light events use IDs outside the library's
  cleanup range.

Revision 2026111924 passed source checks and the packaged suite, including the
two-VM Light settings readback. The independent review exercised a saved
double-tap event during startup before Home Assistant connects on both driver
fixtures and confirmed the retired fourth-tap row stayed hidden. Native Composer
checks for preset removal, Color Agent selection and the Programming list remain
pending.

[PR #243](https://github.com/finitelabs/control4-driver-template/pull/243) ·
[PR #245](https://github.com/finitelabs/control4-driver-template/pull/245)

### v0.9.116 to v0.9.117

The `example-driver/drivers/example_light` diff is empty. PR #246 adds
`Group:dissolve()` to the group-owner library. The owner calls it when its
driver is deleted so each member receives `LIGHT_GROUP_LEAVE`. The regression
checks that every member receives one notice and that later commands reach no
member.

The render updates `src/lib/light/group.lua`. HA Light uses the member-side
`lib.light.groups`, and its connected adapter can target an existing Control4
group. The suite has no group-owner driver to wire to `Group:dissolve()`. The
existing connected Light and conformance tests cover receiving
`LIGHT_GROUP_LEAVE` and resuming individual control. The pinned template's
lighting tests also exercise its new group deletion regression.

[Upstream group deletion fix](https://github.com/finitelabs/control4-driver-template/pull/246)

### Member cleanup after a missed leave

The shared `lib.light.groups` checks saved group IDs against Director's device
registry when routing commands or sending new feedback. It skips missing groups
and clears their saved membership after two lookups at least one second apart. A
lookup that cannot see the member itself keeps saved memberships and any prior
observation that a group was missing. It leaves previously unobserved
memberships eligible for routing. The connected Light regression covers built-in
Load Groups and Light Group, including an incomplete lookup after a group goes
missing, a group that reappears and an overlapping group that remains active.

### Native brightness and color rate readback

CORE 1 returned a 750 ms default brightness rate and a separate 0 ms color rate
for the lab dimmer. The template's setup reader applied both fields as
shared-rate edits, so the color field overwrote the brightness default. The
suite now restores both reported fields independently and uses the available
rate for both defaults when the reply has only one. The existing command
handlers still apply explicit shared-rate edits. The adapter regression
exercises a brightness ramp with no supplied rate and checks the resulting
0.75-second Home Assistant transition.

### Applying the rule by driver

Light uses `example_light` as its Light V2 reference. Keep native membership,
presets, settings and reads in the Light library. A connected target needs the
resolved commands and confirmed feedback for the load it owns.

The template includes a generic example and `example_light`. Switch uses the
shared lifecycle, Device Setup, HA command handling and the template's value and
event libraries. Its adapter supplies native on/off, relay and experience-button
behavior. Coordinator uses the template's network, HTTP, logging, companion and
GitHub helpers. Its HA protocol and release-family selection remain suite
responsibilities. Review the generic example for shared lifecycle and logging
behavior on all drivers.

The template HTTP helper operates on individual requests. The HA Coordinator
limits background snapshot submissions before calling the HTTP helper because
the queue belongs to the active HA connection and can use live subscription
feedback. HTTP completion and error handling use the template's deferred
callbacks. The Hub test exercises the queue, feedback and reconnect behavior.

For calls to a Home Assistant switch, the Coordinator sequences requests for the
same entity before passing them to the template WebSocket transport. It uses the
template's one-shot timers for the queue deadline. The Hub tests exercise
feedback arriving before the service reply, independent devices, selection
changes and timeout handling.

The suite uses the pinned GitHub updater's file writer and Director reload
request. The local extension exposes those already-used operations so the
Coordinator can hand over the manifest-verified archive bytes and resume from
its saved batch. The template's existing update path still downloads through the
same library and sends companions before its own reload. Tests cover its alias,
write readback and reload order alongside the suite's recovery tests.

The generic example's live **Log Mode** and **Log Level** changes and three-hour
expiration run in the shared foundation. The logger's level cap extension allows
**Trace** for the Coordinator while keeping the template's Ultra packet dumps
disabled. The template logger reports Coordinator connection changes. Light and
Switch use its **Debug** level for bounded button-event diagnostics. Light also
reports linked Control4 commands and feedback at this level. **Log Mode**
replaces the old **Debug Print** and **Debug Mode** settings. The one-time
diagnostics actions can be run from **Actions**.

The Light example uses the library's refresh hook and reports a matching
snapshot as final. The Home Assistant adapter uses the same hook, with the local
`feedback.refresh = "deadline"` extension because normal HA reports are pushed.
The ledger waits until the expected transition has landed before requesting a
read. The adapter uses the Coordinator's existing exact-load read and correlates
the result to the current command.
