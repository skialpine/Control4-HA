# Home Assistant Connection

This driver connects Control4 to Home Assistant. Start in **Properties**.
**Quick Setup** is available when you want to add lights and switches to rooms.

1. In Composer, open **Properties** on Home Assistant Connection. In **HA URL**,
   enter the address you use to reach Home Assistant, for example
   `http://homeassistant.local:8123`. Include the port if needed and leave off
   any dashboard path.
1. In Home Assistant, open your profile and select **Security**. Under
   **Long-lived access tokens**, create a token named **Control4**, copy it, and
   paste it into **HA Token** in Composer.
   [Home Assistant account and token help](https://www.home-assistant.io/docs/authentication/)
1. When **Driver Status** says **Connected to Home Assistant**, open **Quick
   Setup**. The connection is ready to find devices. You can check each added
   device's status in its own **Device Setup** tab.

If you updated an existing connection, keep its saved settings. To change them,
enter the host and port (for example, `homeassistant.local:8123`) in **Home
Assistant URL**, set **Use SSL** to **Yes** for HTTPS or **No** for HTTP, and
use **Long Lived Access Token** for the token.

## Add devices to rooms

Once the connection is working, you can add a driver yourself or use **Quick
Setup** to add several devices together.

1. Open **Quick Setup**. The list hides devices that already have a matching
   Control4 driver. Choose **Show all devices** to include them. Use **Device
   type** to show only lights or only switches, or search by name or room.
1. Select the devices you want to add. Check the room on each selected row. When
   the Home Assistant area matches one Control4 room, the page suggests it.
   Choose a room for the other rows. Use the room action to fill missing rooms
   for several selected devices at once. You can change an individual room on
   its device row.
1. Choose **Review devices**. Check each Control4 name, room and proposed
   change. An existing match keeps its settings. If a device needs attention,
   check the matching driver and review again.
1. Confirm the changes to create the listed controls in their rooms and link
   them to Home Assistant. Use **Back to edit** to change the selection first.
   Open the new driver's **Device Setup** tab and check its **Controls** and
   status. If an addition was interrupted, review the same device again to see
   which steps finished.

Install the family's Light and Switch packages on the controller before adding
devices. For an ordinary light or switch, the Coordinator can find it without an
extra Home Assistant integration. The optional HA Gesture Bridge also discovers
compatible wall controls, remotes and their linked devices. If you use it, add
**HA Gesture Bridge** in Home Assistant under **Settings → Devices & services**.
Return to Quick Setup and refresh the list.

## Migrate older switch drivers

Open **Quick Setup** on Home Assistant Connection. When there are older switch
drivers that use a different Control4 driver type from the new version, the
section at the top lists them automatically. Save a project backup and review
the listed changes before starting. Migration keeps your switches, names, and
rooms. Test that each new driver turns its switch on and off and run any
programming you changed. Return to Quick Setup and choose **Review old drivers
for removal**. Confirm those tests, then choose **Check old drivers**. The
wizard identifies which originals you can delete separately in Composer.

When a switch needs programming changes, Quick Setup prepares a replacement and
shows the driver name and its Control4 room. The original still controls the
switch. Open **Programming**, select the listed device and event, and change the
indicated actions to use the new driver. Keep the other actions in each script.
For a switch that triggers a program, recreate the event using the new driver
and verify the program in Composer.

Return to Quick Setup and choose **Check programming**. For recognized On and
Off actions, it checks the replacement action in the same event before moving
control. **Tools → Detective Suite → Programming** can help find other
references. If a scene operates the switch through a script, follow the same
steps for that script. Test changed programming after the new driver is
connected and before removing the original.

Some programming, such as conditional actions and events triggered by the old
switch, needs your review in Composer. After **Check programming**, the wizard
asks you to confirm that the reviewed programming uses the new driver. The old
driver controls the switch until you confirm and the connection is verified.

If migration restores the old driver after a failed connection check, the old
driver controls the switch again. Any programs you moved still point to the new
driver. Keep it in place to retry, or restore the project backup to return to
the original programming.

### Manual migration for button switches

1. Save a project backup. In Composer, record the original driver's name, room,
   selected wall control, controlled device, button behavior, indicator settings
   and connections. Use **Tools → Detective Suite → Programming** to find
   scripts that the driver triggers or that use it.
1. Add a **Home Assistant Switch** to the same room with a temporary name. Keep
   its device selection empty while preparing it. In **Device Setup**, plan to
   choose the same wall control and linked load. If the original used
   **Programming Events Only**, choose **Buttons only** on the replacement.
1. Disconnect the original driver's Home Assistant link in **Connections**.
   Configure the replacement in **Device Setup**, then move its relay and button
   connections. Recreate the original gestures, actions and conditions on the
   replacement. Check that indicator settings and any programmed indicator
   actions address the same buttons.
1. Test the switch, each gesture you use and any changed programming or scenes.
   Rename the original to distinguish it, then give the replacement the original
   name. Keep the original until the replacement passes these tests. Restore the
   saved project backup if you need to undo the cutover.

## Run a Home Assistant action from Programming

Choose **Call Service** on Home Assistant Connection. For example, to turn on a
light at half brightness, enter `light.turn_on` in **Service**, the light's Home
Assistant ID in **Entity ID**, and `{"brightness_pct":50}` in **Data**. Leave
Entity ID or Data blank when the action does not need it.

To use a Control4 variable for the brightness, enter
`{"brightness_pct":${VAR1}}` in Data and choose the variable in **${VAR1}**. The
same rule applies to **${VAR2}** and **${VAR3}**. Put quotes around a
placeholder for text, for example `{"message":"${VAR1}"}`. If the action fails,
**Last action** in Properties explains what to check.

## Connection details

Open **Properties** to see connection, logging and timing settings. For HTTPS
with a private certificate authority, enter the trusted certificate file on the
controller in **CA Certificate Path**. Use HTTPS when possible. Use HTTP only on
a trusted network.

The Home Assistant address must support WebSocket upgrades at `/api/websocket`.
Redirects are refused. Use a DNS name or IPv4 address; IPv6 literals are not
supported by the pinned helper. A rejected token stops retries until
configuration is applied again. Connection failures retry with a delay capped at
thirty seconds after socket cleanup. **Retry linked device connections**
requests another connection check for existing linked devices. **Last action**
in Properties shows whether the request was sent. Open a linked device’s
**Device Setup** tab to check its status. **Print timing summary to Lua** writes
the diagnostic report to Lua output and the Latency Report variable.

For troubleshooting, open **Actions**. **Print connection diagnostics to Lua**
shows connection status, pending requests, subscription and device counts.
**Print linked Home Assistant IDs to Lua** lists the IDs selected by linked
drivers. Use the **Lua** tab to read either report. In **Properties**, **Debug
Print** prints a connection summary and subsequent connection changes to Lua. It
turns off after ten hours.

Tokens and raw device payloads are excluded from routine logging. Do not enable
raw WebSocket/network debug traces.

Source and notices: <https://github.com/skialpine/Control4-HA>.
