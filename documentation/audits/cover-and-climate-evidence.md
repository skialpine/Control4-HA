# Blinds, Garage Door, and Thermostat evidence

The closest pinned Finite Labs example for these packages is the generic
DriverWorks example in template revision
`1041c5fe4fd0329fd5363a5da65e9e710362baa4`. Its libraries supply handler
dispatch, lifecycle conventions, published values, logging, and setup-page
transport. The suite's shared endpoint adapter supplies the selected-entity
binding and feedback lifecycle. The template has no dedicated covering,
relay/contact, or ThermostatV2 library. The family adapters use the native proxy
messages for those surfaces.

| Starting state and task                                                                                                             | Observable result                                                                                                                                                                                            | Evidence                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| A simple shade is selected. Use its native editor to open it, then try an intermediate position.                                    | Open requests the selected cover. An unsupported intermediate position sends no request.                                                                                                                     | Lua simulator, native editor pending                        |
| A position-and-tilt shade is selected. Change lift in the editor and slat tilt in Programming.                                      | Each request sends its own percentage. When an updated tilt arrives, the reported lift stays the same. Open, Close and Stop are distinct actions for lift and tilt.                                          | Lua simulator, native editor pending                        |
| A shade has linked keypad buttons. Press Open and then test Close and Toggle.                                                       | The connected button requests its assigned movement.                                                                                                                                                         | Lua simulator, physical keypad pending                      |
| A shade loses feedback and later returns with fewer capabilities.                                                                   | Control pauses while unavailable. The new report updates position and removes unsupported discrete control and Stop. Identical state reports do not repeat notifications.                                    | Lua simulator                                               |
| A stock Garage Door experience has wired relay and limit connections. Open the closed door and simulate travel followed by loss.    | The open request targets the door. Motion and loss report separately and neither sets an open or closed limit.                                                                                               | Lua simulator, stock experience and physical motion pending |
| A partly open door reconnects. Wait for full open, then close it from Programming or a linked button.                               | Status shows partly open, asserts only the open limit at full open, releases both limits during travel, and asserts only the closed limit at full close.                                                     | Lua simulator, native experience pending                    |
| A Cover or Garage Door has a saved open and close override. Reopen its settings and request an intermediate position.               | The property persists. The native control uses discrete endpoints and continues to offer Stop when the endpoint supports it. A reported position can be displayed without accepting intermediate targets.    | Lua simulator, native editor pending                        |
| A selected cover has a step keypad link. Open, stop partway and click again.                                                        | The link requests Stop during reported movement and reverses the last known direction after confirmation. Reconnection loses the remembered direction.                                                       | Lua simulator, predecessor and physical keypad pending      |
| A thermostat with a single setpoint is selected. Change the setpoint in the thermostat editor.                                      | Home Assistant receives a scalar setpoint. The driver applies the advertised step and waits for feedback.                                                                                                    | Lua simulator, native editor pending                        |
| A thermostat reports separate heat and cool bounds. Request the heating bound in Fahrenheit while Home Assistant uses Celsius.      | Home Assistant receives the converted heating bound and current cooling bound. The proxy receives the updated bound after confirmed state arrives.                                                           | Lua simulator, native editor pending                        |
| A thermostat reports separate heat and cool bounds. Adjust either bound, then adjust the other before feedback.                     | Home Assistant receives both requested bounds in the final range regardless of edit order. The proxy waits for confirmed feedback. After a rejection or reselection, the next edit uses the confirmed range. | Lua simulator, native editor pending                        |
| A thermostat has fan modes, a comfort preset, and a humidity target. Choose supported options and try an out-of-range target.       | Mode and preset go to their exact actions. Out-of-range humidity sends nothing.                                                                                                                              | Lua simulator, Navigator and Programming pending            |
| A thermostat recovers after losing feedback and later reports a different unit.                                                     | The native proxy receives the confirmed scale and temperature. Available comfort choices disappear during loss and return with the thermostat.                                                               | Lua simulator, native editor pending                        |
| An installer opens Device Setup on an established driver. Search, choose a device, reopen, and inspect the saved settings.          | The shared setup flow restores the selected endpoint and preserves applicable connections.                                                                                                                   | Composer and installed candidate pending                    |
| An installer begins in Coordinator Quick Setup. Select each family and review its room before confirming.                           | The driver is created in the approved room with its saved endpoint and verified Coordinator binding.                                                                                                         | Composer and installed candidate pending                    |
| An installed BP driver has saved room links and Programming. Preview a replacement, verify feedback and restore the original route. | The installer can review the old and new connections before cutover and recover the predecessor route.                                                                                                       | Exact package and live replacement pending                  |

Blinds uses the native blind proxy for lift. Tilt currently uses Control4
Programming and the typed tilt variable. A separate native louver panel and
shade association still need qualification. Test a binary shade, a
position-capable shade, and a slatted cover with both settings. The proxy is
told which direction a blind is moving. Until the shade settles, the movement
notification uses the open or closed endpoint as its target, including for
intermediate moves. The native effect of the proxy's stopped notification on
initial feedback and loss still needs a Controller Programming check.

Garage Door provides a native Cover proxy and the relay and contact outputs for
the stock Control4 garage experience. The installer can keep the preferred room
control visible when both are configured. The stock experience connections
require installer verification. Unknown and motion both leave the two electrical
limit contacts idle. The driver status and Programming report loss separately.
The legacy Cover package declares a separate Step-by-Step / Up-Stop-Down keypad
binding. The new drivers use standard Home Assistant cover commands to implement
that sequence. Exact click behavior and migration of saved references remain to
be verified on an installed predecessor.

An independent browser review of the 2026112433 Device Setup pages exercised
keyboard navigation, focus after a refused save, and restoring the saved
position mode on reopening at 480 × 530 and 960 × 720. The transport was
simulated. Composer Properties, stock controller connections, and Navigator
still need native verification for Garage Door.

The controller read back the existing Demo selection after the 2026112433 Blinds reload.
An intermediate target left the Demo state at its starting position in Open and
close mode. In Automatic, the same native target received HA acceptance and
Control4 published the confirmed new percentage. A final command restored the
starting position and an independent HA read verified it.

ThermostatV2 uses Home Assistant's configured temperature scale. A thermostat
whose units are unavailable can still accept a supported mode selection. Preset
and target humidity use Control4 Programming. Native preset and humidity
settings, external temperature sensor bindings, explicit verified hold and mode
helpers, and schedule migration remain pending. For dual setpoints, the driver
waits for the first service result before sending any later edits together. The
display updates only from Home Assistant state reports.

The wave-two adapter suite passed 147 simulated assertions. It ran the pinned
template's Programming, condition, binding and proxy entry points with synthetic
Home Assistant reports and captured requests. It also verified that a service
reply alone leaves the last confirmed feedback intact.

Native contract sources:
[Control4 DriverWorks proxy protocol](https://control4.github.io/docs-driverworks-proxyprotocol/),
[Home Assistant cover features](https://contributors.home-assistant.io/core/entities/cover/),
[Home Assistant climate actions](https://www.home-assistant.io/integrations/climate/).
