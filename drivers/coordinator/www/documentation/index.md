# Home Assistant Connection

This driver connects Control4 to Home Assistant. Start in **Properties**. Use
**Quick Setup** to add Home Assistant devices to rooms.

1. In Composer, open **Properties** on Home Assistant Connection. Enter the
   hostname or IP address in **HA Host** and select **HA Protocol**. Leave **HA
   Port** blank to check common ports. If Home Assistant answers on exactly one
   of them, the driver fills in the port. Enter the port yourself if you already
   know it or the field stays blank.
1. In Home Assistant, open your profile and select **Security**. Under
   **Long-lived access tokens**, create a token named **Control4**, copy it, and
   paste it into **HA Token** in Composer.
   [Home Assistant account and token help](https://www.home-assistant.io/docs/authentication/)
1. When **Driver Status** says **Connected to Home Assistant**, open **Quick
   Setup**. The connection is ready to find devices. You can check each added
   device's status in its own **Device Setup** tab.

If you updated an existing connection, keep its saved settings. A saved **HA
URL** remains editable. If the driver shows **Home Assistant URL**, enter the
host and port there, select **Yes** in **Use SSL** for HTTPS or **No** for HTTP,
and use **Long Lived Access Token** for the token.

## Add devices to rooms

Once the connection is working, you can add a driver yourself or use **Quick
Setup** to add several devices together.

1. Open **Quick Setup**. The list hides devices that already have a matching
   Control4 driver. Choose **Show all devices** to include them. Use **Device
   type** to narrow the list, or search by name or room.
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
   Quick Setup installs any missing driver files as it creates the controls.
   Open the new driver's **Device Setup** tab and check its **Controls** and
   status. If an addition was interrupted, review the same device again to see
   which steps finished.

For an ordinary light or switch, the Coordinator can find it without an extra
Home Assistant integration. The optional HA Gesture Bridge also discovers
compatible wall controls, remotes and their linked devices. If you use it, add
**HA Gesture Bridge** in Home Assistant under **Settings → Devices & services**.
Return to Quick Setup and refresh the list.

## Migrate older switch drivers

Open **Quick Setup** on Home Assistant Connection. When there are older switch
drivers that use a different Control4 driver type from the new version, the
section at the top lists them automatically. Save a project backup and review
the listed changes before starting. Migration keeps your switches, names, and
rooms. Test that each new driver turns its switch on and off and run any
programming you changed. Return to Quick Setup and choose **Confirm testing**.
Confirm those tests, then choose **Check old drivers**. The wizard identifies
which originals you can delete separately in Composer.

When a switch needs programming changes, Quick Setup prepares a replacement and
shows the driver name and its Control4 room. The original still controls the
switch. Open **Programming**, select the listed device and event, and change the
indicated actions to use the new driver. Keep the other actions in each script.
For a switch that triggers a program, recreate the event using the new driver
and verify the program in Composer. Then remove the actions from the matching
event on the old driver.

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

If a driver update interrupts migration, return to **Quick Setup** and choose
**Restore original connections**. Quick Setup checks the switch and its
connections before restoring them. Follow the instructions shown after it checks
the saved migration against the updated drivers.

### Migrate a switch with button events

1. Save a project backup. In **Quick Setup → Migrate switch drivers**, review
   the Home Assistant device and connections, then select **Start migration**.
   Read the return instructions and select **Continue migration**. Quick Setup
   adds a replacement in the same room with a temporary name and copies
   supported button and LED settings. If Composer selects the replacement, go
   back to the Coordinator’s **Quick Setup** to continue.
1. Follow the next step shown for that switch. If a connected device also needs
   to migrate, handle it first and select **Recheck connections**. Move any
   listed programming before proceeding. Use **Tools → Detective Suite →
   Programming** to find the scripts that use the original. When Quick Setup
   verifies the names before programming, the replacement uses the original name
   and the source is labeled as the old driver. The old driver keeps control
   while you move the listed actions.
1. Quick Setup transfers a verified selection and its supported connections
   automatically. If it asks you to confirm the load, open the shown entity in
   Home Assistant and compare it with the load the original controls. Choose
   **Confirm load and transfer** if they match. Quick Setup rechecks the match
   and connections before setting up the replacement and moving the verified
   connections. If you’re unsure, choose **Get manual setup steps**. Find the
   device in the new driver’s **Device Setup** before disconnecting the original
   in **Connections**. Use **Move verified connections** when Quick Setup offers
   it.
1. Test the new driver. Try the buttons you use and any on/off control,
   programming or scenes you changed. If you finished the transfer manually,
   select **Confirm testing** or **Apply original name**, as shown.
1. Choose **Review old drivers for removal** after you confirm testing. Quick
   Setup checks the replacement again and lists the originals ready to delete in
   Composer.

If Quick Setup shows **Restore the project backup**, restore it before
continuing with any switch in the batch. Return to Quick Setup and choose
**Refresh status**.

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
drivers. Use the **Lua** tab to read either report.

For detailed Coordinator diagnostics, select **5 - Trace** under **Log Level**
in **Properties**. Set **Log Mode** to **Print** for the **Lua** tab, **Log**
for the controller log, or **Print and Log** for both. Trace reports request and
response outcomes, including scene migration requests and verification. Raw
network dumps stay disabled. Logs can contain local project information. Logging
turns off after three hours.

Source and notices: <https://github.com/skialpine/Control4-HA>.
