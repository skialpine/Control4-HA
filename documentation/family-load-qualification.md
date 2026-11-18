# Light and Switch load qualification

The Light and Switch drivers use the same Coordinator connection and Device
Setup flow. Match the driver to what the device does in Control4.

## General relay or fireplace switch

Add **Home Assistant Switch** to the room and connect its Coordinator binding.
In **Device Setup**, choose the Home Assistant switch that represents the
equipment's on/off control. Review the selected target before using the
Navigator button or a programmed action. If discovery cannot identify the device
by name, open **Choose device** and expand **Enter a Home Assistant device ID**.

The Navigator experience sends a toggle and updates its icon when Home Assistant
reports the new state. Programming can use **Turn on**, **Turn off** and
**Toggle**, plus conditions for on, off and availability. The relay connection
exposes the same binary control and confirmed feedback. This example uses the
lab's simulated relay for all service and feedback checks. Fireplace ignition,
interlocks and physical operation require qualification with the equipment.

## Switch used for lighting

Use **Home Assistant Light** when the relay controls a lamp and should be
presented as a light. In **Device Setup**, choose that switch's lighting
endpoint or enter its exact ID in the device picker. Control4 presents binary
lighting controls and sends only Home Assistant switch power commands. A
dimmable HA light adds brightness controls once that capability is established.

Color-capable lights use the capabilities Home Assistant reports. A color chosen
while the light is off is held for the next On. Color temperature uses the
device's reported Kelvin range. A transition-capable light receives the rate in
seconds. Home Assistant service acceptance and a resulting state report are
separate.

## Evidence matrix

| Operation                                  | Packaged adapters with isolated Home Assistant                                                                                                                                             | Native Control4 and equipment                                                                |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Binary HA light and switch used as a light | On, Off and Toggle via the template Light proxy. Exact power-only HA requests and pushed state.                                                                                            | Controller proxy commands and Navigator display pending.                                     |
| Dimmable light                             | Explicit levels and a rated level on the brightness-only fixture. The requested rate is distinguished from service acceptance and final state.                                             | Native slider, hold/release and physical fade evidence pending.                              |
| Full color and white temperature           | xy command on HA's HS Demo light, RGB on RGBW and RGBWW Demo lights, and Kelvin on the CCT Demo light. HA performs the integration-specific conversions.                                   | Native conversion and display verification, gamut comparisons and physical channels pending. |
| General relay or fireplace switch          | Navigation SELECT, relay OPEN/CLOSE, three Button Links, and programming On/Off/Toggle through the Switch adapter. Exact on/off pushes drive the icon, relay state and programming events. | Native Navigator, relay wiring, programming conditions and physical equipment pending.       |
| Color while off                            | A chosen color sends with the next On and produces matching HA feedback on Demo.                                                                                                           | Native controller and physical behavior pending.                                             |

The [family evidence](../lab/family-evidence.json) identifies the exact packages
and HA version. To reproduce the run against the allowlisted lab:

```sh
.cache/lab-venv/bin/python lab/verify_families.py --samples 5 --runtime-profile
```

The runner uses actual packaged Lua in separate Coordinator and family
processes, local Director and proxy shims, and real HA Container services.
External timing starts immediately before the native command is written to the
family process. The three end points are Coordinator receipt of the service
result, Coordinator receipt of matching pushed state, and observed family
processing of that state. The shim uses a virtual clock for local runtime
instrumentation. Rates include the fixture's deliberate simulated delay and
local timer scheduling. The test does not infer network transit time or a
physical response from these boundaries.

The five-repeat profiled run recorded 215 Light samples and 60 Switch samples
with Log Mode Off. The 200 ms rated level had median acceptance at 22.20 ms,
matching pushed level at 223.28 ms, and family consumption at 243.62 ms. The
confirmed-state phases include the explicit fixture delay. The evidence file
contains the operation distributions and separate local runtime spans.

## Template motion, presets and scenes

Native HA loads use the template engine's brightness/color presets, brightness
and color On modes, groups, scene steps and button hold gate. A plain On leaves
HA in charge of its remembered level. A configured Control4 brightness On mode
carries its selected level in the HA request. Color kept for the next On and
setting persistence are owned by the template.

For example, choose a 55% brightness On mode on the lab dimmer, then turn it on
from Control4. The native request sends brightness 140 of 255. A scene targeting
40% sends the scene's separate target. A group targeting 25% sends 64 of 255.
When the dimmer advertises transitions, its top button hold can ramp from 25%
toward full and a release sends an immediate estimated replacement target. With
an unrated backend, a level target is immediate and release sends no synthetic
stop.

The template conformance tests cover preset choices, held-off color across a
restart, Min/Max On and group membership, a multi-step scene, rated button and
group holds, and controlled stop with an interpolating simulated target. The
family adapter tests verify that a later step does not run after a failed
source, explicit override, selection change or destruction. An explicit command
also cancels a press still within the hold gate.

The HA fixture can cancel its pending simulated transition when another service
request arrives. That verifies replacement-target traffic and final feedback in
the lab. A real integration or device can finish a transition already accepted
even after C4 has retired its own pending work. Hardware-stop support, flash
scenes and native Director or physical group/scene scheduling remain separate
checks. Connected Control4 targets own their own presets and motion.

In the real HA fixture, median command-to-acceptance was 24.50 ms for the
brightness On mode, 22.99 ms for a scene level and 22.91 ms for a group level.
Hold start to acceptance, including the template's 250 ms hold gate, used five
samples with minimum 249.16 ms, median 250.41 ms and p95 252.62 ms. Hold release
to the replacement target's matching HA state had a 23.14 ms median. Hold start
does not have a matching full-level state sample because release interrupts it.

The 2026111801 Light package selected the Docker demo bed light’s rainbow and
off effects five times each. The packaged Coordinator, Light adapter and
simulated Director/proxy exchanged real Home Assistant requests. Across ten
operations with driver logging off at Info and a local monotonic clock,
median/p95 command-to-HA-acceptance time was 27.37/29.92 ms.
Command-to-confirmed-HA-state was 26.67/28.62 ms, and
command-to-family-consumption was 38.31/49.77 ms. Feedback and service results
arrive independently. The test measures software delivery.
