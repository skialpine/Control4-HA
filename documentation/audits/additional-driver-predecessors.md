# Additional driver predecessor evidence

The original BP command harness passed 303 assertions across 11 families at
Coordinator revision `9102878246e6fe670367d6efc3ed82db2bcc7b5c`.
[Source pins](../../provenance/sources.json) identify each original command
source and its provenance. The task matrix uses those source revisions.
Published archive identities were checked separately through each archive's
embedded driver XML. A matching version or connection number alone does not
establish that an installed project survives an update.

All nine original families use Device Link 999. All expose Entity ID and the
`ENTITY_ID` variable. Other settings, bindings and Programming tasks are listed
where the XML or source establishes them. No additional events or conditions are
declared in the pinned XML for these nine. The contact, proxy and variable
surfaces supply their own Programming operations.

| Family and model  | Pinned source version | Published archive and embedded version                                     | Tasks to preserve                                                                                                                                                                                     |
| ----------------- | --------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HA Alarm Panel    | 102                   | `HA.Alarm.Panel.c4z` 101                                                   | Arm, disarm and view status through the security panel and partition at 5001 and 5002. Select the partition for a room through 7002. Preserve supported modes and code behavior.                      |
| HA Binary Sensor  | 102                   | `HA.Binary.Sensor.c4z` 102                                                 | Retain the selected entity, contact output 1 and state changes seen by connected devices and Programming.                                                                                             |
| HA Blinds         | 102                   | `HA.Blinds.c4z` 102                                                        | Move, stop, set position or tilt where supported. Verify capability and level readback through blind 5001 and bindings 200–202.                                                                       |
| HA Fan            | 104                   | `HA.Fan.c4z` 102 and `HA.Fan.3-speed.c4z` through `HA.Fan.6-speed.c4z` 103 | Control power and distinguish speed variants through fan 5001 and button bindings 200–202. The pinned nine-speed source also needs archive-level qualification.                                       |
| HA Garage Door    | 101                   | `HA.Garage.Door.c4z` 101                                                   | Open or close through relay 1, preserve closed/open limit contacts 2–3 and bindings 200–202.                                                                                                          |
| HA Generic Sensor | 110                   | `HA.Generic.Sensor.c4z` 110                                                | Retain sensor type, unit fallback and refresh settings. Refresh manually, read value and last update, keep four existing state variables and temperature/humidity links 500/600.                      |
| HA Lock           | 102                   | `HA.Lock.c4z` 102                                                          | Lock, unlock and verify native lock status at 5001. Review configured code handling without copying a secret to migration evidence.                                                                   |
| HA Media Player   | 102                   | `HA.Media.Player.c4z` 102                                                  | Control playback and volume, read now-playing state and retain audio/video routing through 2001, 4001, 5001 and 7000.                                                                                 |
| HA Thermostat     | 108                   | `HA.Thermostat.c4z` 108                                                    | Preserve current temperature, mode and setpoints through thermostat 5001, temperature 1 and room selection 7000. Review schedule, hold, external mode settings and saved Set Comfort Setting scripts. |

The published Alarm Panel archive is one revision behind the harness. The
published Fan archives cover the default and three- through six-speed products.
The pinned Fan 104 source and nine-speed variant do not have matching published
archive evidence. Test those with a provided archive before qualifying any
in-place update.

Binary Sensor and Generic Sensor now have in-place candidates using their
original package and model, input 999, sensor outputs and saved Programming
variables. Simulated startup and reload verify the retained variable IDs,
settings and selected target. Native project update and saved Programming
readback remain qualification steps. The remaining candidates need individual
retained-identity review or a verified replacement path. Thermostat uses the
replacement path.

### Thermostat replacement checks

The released revision 108 archive declares scheduling, hold modes, a clear-hold
button and an external mode selector. The archived runtime enables native
scheduling when configured, saves named presets and suppresses scheduled preset
changes during an active hold. A timed hold clears through the selected HA
button when it expires. The external mode selector provides options for the
saved Home, Away and Sleep mappings. The native climate preset and the separately
configured selector are distinct operations.

The replacement rehearsal needs one fixture with those options enabled. Confirm
the original runs a saved schedule and a saved Programming comfort command.
Record the primary climate target, separately selected helper roles and option
mappings, room assignments, preset fields and hold state. Then verify the
replacement executes the same tasks, handles an unavailable helper while primary
temperature control remains available, and restores the original route and
references on rollback. Preview leaves the original connected and lists any
setting or reference that the replacement cannot transfer.

[Legacy driver task matrix](legacy-driver-parity.md) records the separate
a later build compatibility scope.
