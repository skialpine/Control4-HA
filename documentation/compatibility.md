# Platform and identity contract

The selected template is v0.9.116 at the full revision in
`provenance/template-lock.json`. Its example-driver baseline is Control4 OS
3.3.0. The suite checks the package's `minimum_os_version` using the template's
`CheckMinimumVersion` before starting control. A rejected platform gets an
explicit required/current OS message. LuaJIT, DriverWorks callbacks, persisted
values, `light_v2` and `uibutton` are required. Director checks on CORE 1 used
Control4 OS 3.4.3. The [first-demo record](first-demo-packages.md) distinguishes
completed Director checks from remaining Composer, Navigator and physical
observations. The separate
[manufacturer rehearsal](../lab/manufacturer-update.md) records the narrower
change already exercised on Director.

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
checking their targets on the original Director device IDs. The temperature
migration exception still needs an exact package/proxy match. Other families
receive their own qualification when implemented. See the
[first-demo package comparison](first-demo-packages.md).

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
104 and Alarm Panel 102 need separate package qualification. Run from this
project:

```sh
mkdir -p .cache/legacy-mixed-review
unzip -o dist/oss/c4z/HA.Coordinator.c4z driver.lua driver.xml -d .cache/legacy-mixed-review
LUA_PATH='test/?.lua;;' luajit lab/verify_legacy_families.lua \
  ../HA/Control4-HA-Coordinator .cache/legacy-mixed-review/driver.lua
```

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

To include the actual prototype callers in the mixed-project runner, verify both
archive hashes against
[the baseline inventory](../provenance/first-demo-baselines.json), extract the
archives into separate directories, then pass both directory paths after the
packaged Coordinator Lua path.

```sh
LUA_PATH='test/?.lua;;' luajit lab/verify_legacy_families.lua \
  ../HA/Control4-HA-Coordinator .cache/legacy-mixed-review/driver.lua \
  .cache/prototype-light .cache/prototype-switch
```

The mixed-project run qualifies initial state, power commands, live feedback and
reconnect for those direct loads with simulated Director and HA transport.
Prototype gesture and linked-load state, scoped discovery, preparation, and the
native mixed-project update rehearsal remain open.

Optional template modules selected: `light ui`. Dependency discovery bundles
only actually required Lua modules per package. XML, deferred and version
helpers are included only where a dependency requires them. Expression, OAuth,
crypto, telemetry and DriverCentral licensing modules must not enter runtime
packages. `python3 tools/check_packages.py` verifies each build.
