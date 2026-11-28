# Security and media driver qualification

The candidates use the suite's shared Device Setup, selection, handler
lifecycles, state subscription, values, and timing. The pinned Finite Labs
example supplies the driver lifecycle and shared UI conventions. Its native
proxy helper targets lighting. These families use the published Control4 Lock,
Security Panel and Media Service proxy interfaces for their family-specific
commands and state. Standard Home Assistant actions provide transport.
[Control4 proxy reference](https://control4.github.io/docs-driverworks-proxyprotocol/)

| Predecessor task                                                                                                                | Candidate path                                                                                                                                                              | Evidence                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lock is connected and the door is unlocked. Choose Lock in Navigator and observe the locked state. Choose Unlock to reverse it. | Native Lock proxy and confirmed Home Assistant state. On a jam, show a fault and fire the jam event once on the reported transition.                                        | Handler and simulated push. Navigator awaits installer verification.                                                                                                                     |
| Configure the predecessor's Lock Code in Properties so a coded lock operates.                                                   | Configure the lock's supported default code in Home Assistant. Verify a wrong or missing default gives a recoverable result.                                                | Home Assistant entity contract. The original Properties path awaits a product decision and qualification.                                                                                |
| Assign an alarm partition to a room and choose a supported arm mode.                                                            | Security room connection and native arm request. Compare available modes in Navigator and try a restricted test panel.                                                      | State mapping and mode validation in the simulator. The native arm menu uses a static capability in the documented proxy contract and awaits verification of per-device mode visibility. |
| Enter a code at the alarm prompt and disarm.                                                                                    | Pass the supplied code to that request and render fresh state after Home Assistant reports it. Check missing code, rejection, and reselect while a reply is pending.        | Simulated native requests and delayed replies. Composer and Navigator prompts await qualification.                                                                                       |
| Select the Media Player as a room source, play, pause, and skip. Watch the track information change.                            | Media Service, HDMI/audio outputs, and Room Audio endpoint. Dashboard buttons follow the reported feature mask.                                                             | Synthetic transport and feedback messages. Room routing and native dashboard await installer verification.                                                                               |
| Set volume, shuffle, and repeat. Reopen Now Playing and verify current settings.                                                | Volume and mute readback, with shuffle and repeat from current Home Assistant state.                                                                                        | Synthetic dashboard and queue messages. Reopening native Now Playing awaits installer verification.                                                                                      |
| Reopen Now Playing when the track lacks artwork.                                                                                | Now Playing retains supported text metadata and uses an empty artwork value. The candidate adds Programming source selection by exact name from the current HA source list. | Simulator exercises valid and stale source names and rejected artwork fields. Native browse and authenticated artwork qualification are pending.                                         |

Exact update or explicit replacement has yet to be rehearsed for the predecessor
Lock, Alarm Panel, and Media Player packages. The candidates use distinct
package identities. Test predecessor events, conditions, room and AV links, and
settings before migration signoff.

## Simulator results

The Device Setup fixture loaded each driver's normal entry point with the real
Coordinator and simulated HA replies. Lock, Alarm Panel and Media Player each
selected and persisted the exact endpoint, sent a native command and changed
state only after a separate HA report arrived. Reload kept each selection,
cleared its state until the new snapshot and sent no service command.
[Device Setup tests](../test/test_ha_device_setup.lua)

- Lock accepted explicit Lock, Unlock and Toggle where confirmed state allowed
  them. It published movement, lock state, battery thresholds and one jam event
  per transition. An existing jam recovered without replaying its event. Delayed
  replies expired when feedback was lost.
- Alarm Panel qualified Home, Away, Night, Vacation and Custom Bypass when
  advertised by the entity. The fixture covered numeric and text codes, missing
  code, rejection, timeout, offline recovery and initialization without a
  service replay. The driver suppresses credential parameters on both native
  bindings, including a partition command addressed to the panel.
- Media Player qualified transport, power, room volume and mute, queue state,
  confirmed shuffle and repeat, exact source choice, app and track metadata, and
  requested Navigator and room targets. Offline feedback clears the active
  source and Now Playing. Signed and private URLs do not cross this path.

The native-handler suite passed 181 assertions. Its transport and notification
tests run without Composer or Navigator. Installer checks for room assignment,
the alarm mode menu and prompts, and the media dashboard remain open.
[Security and media adapter tests](../test/test_ha_security_media_adapters.lua)

The shared Device Setup test sends a synthetic code through the native partition
to the Coordinator. Home Assistant rejects the request and echoes the code in
the fixture's raw error. The resulting status gives the installer a permission
error. Trace, Properties, Device Setup and exported timing contain no code. The
same path drops private media URLs from the displayed metadata while preserving
the track title. [Device Setup privacy checks](../test/test_ha_device_setup.lua)

For the lab use Home Assistant Demo and synthetic devices. Exercise restricted
alarm features, missing or rejected credentials, delayed lock state and jam,
active and idle players, exact source membership, and private artwork input in
the controlled simulator. Keep controller timings and transport acceptance
separate from confirmed state and physical response.
[Lock](https://contributors.home-assistant.io/core/entities/lock/) ·
[Alarm panel](https://contributors.home-assistant.io/core/entities/alarm-control-panel/)
·
[Media player](https://contributors.home-assistant.io/core/entities/media-player/)
