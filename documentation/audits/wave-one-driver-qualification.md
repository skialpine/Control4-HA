# Wave one driver qualification

The first three drivers use the Finite Labs general driver example through the
suite's existing initialization, handler routing, logging, values and Device
Setup. Their adapters share endpoint authority, callbacks and teardown. The
pinned template has no native contact output, sensor value output or fan
adapter. Control4 defines those messages and the adapters call them directly.
[Control4 DriverWorks Proxy and Protocol Guide](https://control4.github.io/docs-driverworks-proxyprotocol/)

Run the focused checks from the repository root with `test/run_test.sh` and the
following filenames. The simulator drives the template command dispatcher and
captures proxy messages, events and variables. Its clock supports timing-count
assertions. Native Composer and Navigator observations require an installed
candidate.

| Suite                               | Passing assertions | What it exercises                                                                |
| ----------------------------------- | -----------------: | -------------------------------------------------------------------------------- |
| `test_ha_wave_one_adapters.lua`     |                102 | Native adapter controls, feedback, malformed inputs, reconnect and replacement   |
| `test_ha_binary_legacy_startup.lua` |                 26 | Production entry points, saved state and native callback handling across reloads |
| `test_ha_endpoint_discovery.lua`    |                 20 | Shared scoped discovery, endpoint identity and service validation                |

| Task from the normal entry point                                                                                                                                | Simulated result                                                                                                                                                                               | Native verification                                                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Connect a binary door reading to a stock contact input. Close and open the door.                                                                                | A first closed state sends state-only feedback. A transition sends the matching contact notification and Programming event.                                                                    | Observe the new contact in Composer Connections and the stock contact's state change.                                                                                                           |
| Use an occupancy reading in Programming. Interrupt the signal and reconnect.                                                                                    | The reporting labels follow the device class and loss clears availability without reporting closed. Reconnect initializes the current value without replaying the lost edge.                   | Observe the Programming condition and event while the device loses and restores feedback. A contact binding has no unavailable notification, so its consumer keeps its last contact state.      |
| Connect a temperature reading to a native temperature input. Receive zero, use an explicit fallback for a later unitless report and request the latest reading. | Zero stays numeric, Celsius and Fahrenheit reach the temperature connection, and the fallback applies only when the report lacks a unit. The refresh action requests only the selected sensor. | Check the destination device's readback, the Troubleshooting setting after reopening and the readback effect on that native input.                                                              |
| Replace the temperature role with a humidity reading and then lose the measurement.                                                                             | The old binding receives an unavailable notification and humidity reaches its own binding. An unknown reading clears availability while retaining the last numeric value.                      | Observe the selected humidity consumer processing initialization, value and loss.                                                                                                               |
| Use the native Fan control or a linked Control4 keypad with a power-only fan.                                                                                   | The native adapter advertises one level, and the On, Off and Toggle links issue the matching exact-target commands. Service acceptance never creates proxy feedback.                           | Confirm the controls and arrival of actual button clicks in Composer and Navigator.                                                                                                             |
| Set and cycle a speed on a nine-speed fan. The device later reports a different speed.                                                                          | A native speed maps to the corresponding Home Assistant percentage and the displayed speed follows the confirmed report. Late command completions cannot replace the latest command result.    | Verify the proxy and Navigator honor the selected endpoint's speed count, including a transition between a power-only and a nine-speed endpoint. Verify an unavailable fan does not appear off. |

Fan oscillation and preset modes use a dynamic Programming list on endpoints
that report the relevant capabilities. The simulator verifies that a power-only
or unavailable endpoint offers no choices and an unavailable or removed preset
cannot issue a request. Navigator uses the native power and speed controls. Fan
direction still awaits qualification.

Additional simulator checks exercise the closed and open contact events,
duplicate feedback, subscription loss and a late report from the previous
selection. The sensor reads native humidity on request and on bind, keeps out of
range and wrong-unit data out of the native humidity connection, and converts
Kelvin to Celsius and Fahrenheit while preserving the source unit. Generic mode
suppresses inferred native routing. A non-finite measurement retires the last
native reading and a subsequent snapshot restores it.

The percentage fan accepts a valid native percentage and rejects fractional or
out of range inputs. Rejection, timeout and selection replacement leave the last
confirmed speed alone. The Fan startup test runs the production entry point,
verifies a manual selection before saving it, reloads the driver and withholds
authority until fresh feedback arrives. The first power command after reload
addresses the restored selection.

The legacy fan's linked On and Toggle behaviors requested full speed. The
candidate uses the default speed chosen by Home Assistant or its integration.
Preserving a deliberately chosen fixed power-on speed for an existing
installation would require a verified device setting or an installer choice
during migration. The legacy archives also tied native speed positions to a
specific package variant. The candidate derives levels from the selected device,
so preserving a custom threshold mapping would require an explicit mapping and
readback in the same migration.

The Binary Sensor and Generic Sensor candidates retain their exact legacy
package identities and native connections. The startup simulator verifies
existing entity selections and Programming variable IDs. For Generic Sensor it
also checks the four reading aliases and saved type, unit fallback and poll
settings through an update and a cold restart. The legacy **Refresh Sensor**
action requests only the selected sensor. A previously enabled **Poll Timer**
keeps that request on its previous 30-second interval. Fresh sensors use pushed
updates. Fan variants use a different package identity.

Native in-place updates, replacement verification, the controller latency and
installer-observed surfaces require their respective qualification runs.

The standard Home Assistant entity attributes used here include binary device
class, sensor device class and measurement unit, and fan `supported_features`,
`percentage_step` and `percentage`.
[Binary sensor](https://www.home-assistant.io/integrations/binary_sensor/) ·
[Sensor entity](https://contributors.home-assistant.io/core/entities/sensor/) ·
[Fan entity](https://contributors.home-assistant.io/core/entities/fan/)
