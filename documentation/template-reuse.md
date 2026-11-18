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

Use the template test shim, virtual clocks, Light conformance kit and existing
library tests. Translate prototype behavioral tests into adapter/contract tests
without carrying forward a second scene engine, property framework, transport
stack or Base compatibility layer.

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

The generic example's live **Log Mode** and **Log Level** changes and three-hour
expiration now run once in the shared foundation used by all three drivers. The
foundation caps levels that enable raw network dumps, and the separate legacy
Coordinator **Debug Print** action retains its existing timer.

The Light example uses the library's refresh hook and reports a matching
snapshot as final. The Home Assistant adapter uses the same hook, with the local
`feedback.refresh = "deadline"` extension because normal HA reports are pushed.
The ledger waits until the expected transition has landed before requesting a
read. The adapter uses the Coordinator's existing exact-load read and correlates
the result to the current command.
