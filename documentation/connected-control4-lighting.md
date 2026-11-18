# Connected Control4 lighting

Connect the Light driver's **App Control Link** to a Control4 light or lighting
group. In Automatic mode the app uses that light. If there is no App Control
Link connection, Automatic uses a single shared paddle target. When the paddles
control different lights, connect a dedicated App Control Link or use the **App
Control Link** setting in **Properties** to choose Top, Bottom or Toggle. The
dedicated connection takes precedence. Device Setup shows the name of the
connected target and whether its state is available.

The **Top**, **Bottom** and **Toggle Control Links** are independent. For
example, a Kitchen Light can be the app target while the top paddle operates
Hall Light and the bottom paddle operates a Stair Lights group. Home Assistant
gestures on a named role follow only that role's link. Extra buttons and
multi-press gestures remain available to programming. Local app commands
continue when Home Assistant is unavailable.

In-place Light updates retain the original keypad input IDs 200 (On), 201 (Off)
and 202 (Toggle) and the prototype paddle output IDs 203 (Top), 204 (Bottom) and
205 (Toggle). The dedicated App Control Link uses 310. The prototype's saved
Top, Bottom or Toggle choice remains available. New Lights default to Automatic.

App On lets the connected light or group choose its current On preset. Selecting
a level such as 35% sends that level to the target. A target's watched state
confirms the displayed level. The wrapper keeps its own HA preset settings for
HA mode. An Advanced Lighting Scene can include the Light driver or the
connected light or group. A scene that includes the Light driver operates its
current target, including delayed and flashing steps. Dimmers without native
transitions fade in steps, up to four updates per second. Existing scenes saved
by the Light prototype remain available on the same driver instance. Keep the
original scene references for the upgrade rehearsal.

## Choose the app and button behavior

Select **Automatic** for a wall dimmer that controls its own load. When the App
Control Link is connected, Automatic directs app commands to that Control4 light
or group. In **Buttons only**, the app does not control a load. Use this mode
for a keypad whose taps are programmed independently.

For a five-button wall control, use **Top - 2 taps** to run a scene and **Extra
4 - 1 tap** for a separate action. For example, connect Bottom Control Link to
the Stair Lights group for local control and use Extra 4 for a separate scene.
Each press follows one route.

When the wall device reports **Indicator lights** in Device Setup, choose its
indicator and supported color or brightness. If a second channel is available,
apply the change to the first channel and verify the second is unchanged. Linked
Control4 keypad colors are on native Light Properties and apply to the Control4
keypad.

## Verification

The shared Light engine and driver setup run in
`test/test_ha_connected_light.lua`. It exercises an ordinary target, a group
protocol binding resolved to its proxy, binary/dimmer capabilities, distinct
paddle links, missing and retired targets, device preset ownership and native
feedback. The fake proxy models the app's named On and its Dim-to-Warm color
follow-up. Both leave the target's preset in control, while explicit brightness
and color remain available. The test also covers app commands without a
Coordinator and forced synchronization with unchanged state. The scene harness
covers saved prototype scenes, packed scene elements, separate color and
brightness rates, timed steps, flash, explicit stop and target replacement.
Confirm a same-instance upgrade and run the existing scene from Composer or
Navigator with the real linked light and group.

Opt-in timing spans cover connected power, level, ramp, stop, color, paddle
dispatch and watched feedback. The tests verify coverage through the C4 shim.
Native Director routing, group membership behavior and controller/hardware
latency still need measurement in the Control4 lab.
