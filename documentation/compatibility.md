# Platform and identity contract

The selected template is v0.9.112 at the full revision in
`provenance/template-lock.json`. Its example-driver baseline is Control4 OS
3.3.0. The suite checks the package's `minimum_os_version` using the template's
`CheckMinimumVersion` before starting control. A rejected platform gets an
explicit required/current OS message. LuaJIT, DriverWorks callbacks, persisted
values, `light_v2` and `uibutton` are required. Source and shim checks qualify
the API contract; actual Director/Navigator/Composer qualification is pending
task 11.2 for the functional replacement packages. The separate
[manufacturer rehearsal](../lab/manufacturer-update.md) records the narrower
change already exercised on Director.

The separate HA companion retains HA 2026.11.1 as its minimum. The exact
companion/C4 release pair is not yet qualified. Do not infer release support
from these foundation builds.

| Family      | Candidate package      | Intended first-demo path                                                                                                                            |
| ----------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Coordinator | HA.Coordinator.c4z     | Update HA.Coordinator.c4z on the existing BP or prototype instance. Preserve legacy children on provider 1 and their programming.                   |
| Light       | HA.Light.c4z           | Update HA.Light.c4z on the existing BP or prototype instance. Preserve the light_v2 proxy, saved inputs, target links, scenes and gesture programs. |
| Switch      | Control4.HA.Switch.c4z | Preview and explicitly request migration from the old Switch, verify the mappings and rehearse rollback.                                            |

The canonical candidates restore the original archive names and models. The old
side-by-side development archives used the Control4.HA prefix for Coordinator
and Light. Existing side-by-side instances have their own identities. Quick
Setup checks project devices before offering to add a Light.

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
Control4 variable and sends its typed value to the selected light. First-demo
qualification also requires the original packages running in a saved Director
project and the prototype consumer protocols.

Optional template modules selected: `light ui`. Dependency discovery bundles
only actually required Lua modules per package. XML, deferred and version
helpers are included only where a dependency requires them. Expression, OAuth,
crypto, telemetry and DriverCentral licensing modules must not enter runtime
packages. `python3 tools/check_packages.py` verifies each build.
