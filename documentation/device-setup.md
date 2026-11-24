## Choose a device

Add the Home Assistant Connection and connect it to your Home Assistant
installation. A new Light or Switch connects automatically when there is only
one compatible Coordinator. If there are multiple Coordinators, choose the one
you want in Composer **Connections**. Use the **Home Assistant Connection**
input on a Light or the **HA Suite Coordinator** input on a Switch. Each driver
has a **Device Setup** tab. In native **Properties**, **Selected Device** names
the Home Assistant selection. **Controls** appears when a wall control operates
another named light or switch.

1. Open **Device Setup** and choose **Choose device**.
1. Search by name, room or exact Home Assistant entity ID. The Light list
   includes lights, compatible switches and toggle helpers. Related entity IDs
   find the same result when they control the same load. Choose **Reload
   devices** if the list is out of date.
1. Select a result and choose **Use selected device**. Searching, highlighting a
   result or closing the list leaves the current selection in place. The driver
   prepares buttons and indicators when the chosen device supports them.
1. Check **Controls** for the selected load or connected Control4 light. In
   **Buttons only** mode, **App control** shows **Off**. The status updates when
   Home Assistant reports the selected device's current state.

For ordinary lights and switches, follow these steps with Home Assistant as it
is. The optional **HA Gesture Bridge** helper adds named physical devices and
remotes. When you choose a compatible device, the helper finds its buttons, any
configured indicator lights and its linked load. Devices with several
independent outputs can have more than one choice. Select the output you want.

New drivers cover lighting, switches and compatible button devices. Existing BP
sensor drivers have their own connection and upgrade rules.
[Compatibility](compatibility.md)

### When the wall control and the light have different names

The selected name identifies the wall control. **Controls** identifies the
device it operates. If a paddle controls a different light in Home Assistant,
the driver follows that link. If the light disappears, restore the link in Home
Assistant and choose the device again. The paddle's own relay stays idle.

For a Light with a connected Control4 target, **Automatic** uses the explicit
**App Control Link** when it is connected. Connect **Top Control Link**,
**Toggle Control Link** or **Bottom Control Link** to the light or group each
paddle should operate. If all connected paddles share a target, the app uses it
automatically. If they control different lights, choose the app's target by
connecting **App Control Link** or choosing the device by name under **Light
controlled by the app** in Device Setup. The On, Off and Toggle **Button Links**
let external keypads operate this driver. A remote with buttons and no load
defaults to **Buttons only**.

### Program button presses

In Composer **Programming**, select the Light or Switch and look for the button
and tap count, such as **Bottom - 3 taps**. Choose single, double or triple
taps, hold or release, depending on what the selected device reports through HA
Gesture Bridge. Refresh Composer after choosing a new device if its events do
not appear.

### Replace a legacy Home Assistant driver

In **System Design**, select the Home Assistant Connection, open **Quick Setup**
and review the drivers listed under **Migrate drivers**. The review identifies
each driver by its project name and room and shows the Home Assistant device it
will control. A Light used for an on/off load keeps its Light role.

1. Save a backup of the Control4 project. Select **Start migration** after you
   confirm the backup, then acknowledge the prompt to return to Quick Setup.
   Composer may select the replacement automatically. Return to the Home
   Assistant Connection to see the migration status.
1. Follow the steps for any listed scene, load group or programming action. In
   **Agents → Advanced Lighting**, open each named scene and preserve its saved
   member settings when moving it to the replacement. In **Programming**, open
   the named event and move only the listed actions. Choose **Recheck and
   continue** to verify those edits. While you make them, the original driver
   retains its Home Assistant connection. A scene or script you move can operate
   the replacement after it connects.
1. When Quick Setup shows **Test the new drivers**, double-click each
   replacement in **System Design** to test its controls. The replacement uses
   the original name and room. Run the scenes and programming listed under the
   driver, then return to Quick Setup and choose **Confirm testing**.
1. Confirm the checks and choose **Check old drivers**. Delete the drivers
   marked ready in Composer, then return to Quick Setup and choose **Check
   removal**.

If a setting or connection needs review, leave the original in place. If the
wizard reports that a migration must be recovered, use the saved project backup
to restore the original references.

### When setup needs attention

| What you see                                | What to do                                                                                                                                                                                                                                    |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Not configured                              | Choose a device. If the button is unavailable, connect this driver to the Home Assistant Connection.                                                                                                                                          |
| Driver did not respond                      | Check **Driver Status** and **Next step** in Properties, then select **Retry loading setup**.                                                                                                                                                 |
| Waiting for device                          | Allow Home Assistant to report the device's current state. Check the device in Home Assistant if the message persists.                                                                                                                        |
| Device unavailable                          | Select **Refresh device state** when it appears. If the device stays unavailable, check the device and its linked target in Home Assistant.                                                                                                   |
| Home Assistant disconnected                 | Check the address and account on the Coordinator.                                                                                                                                                                                             |
| Home Assistant denied access                | Check the Coordinator account's permissions. The helper's device list and button setup require a Home Assistant administrator. After correcting access, reopen the chooser if listing failed or choose **Retry setup** if preparation failed. |
| The device list changed                     | Open the list again and choose the device from the current results.                                                                                                                                                                           |
| Driver and helper versions are incompatible | Install a compatible driver and HA Gesture Bridge version, then reopen the list.                                                                                                                                                              |
| Setup needs attention after a restart       | Choose **Retry setup** to finish a previously requested choice, or open the list to choose again.                                                                                                                                             |
| Waiting for buttons                         | Check the device and its input sources in HA Gesture Bridge.                                                                                                                                                                                  |

For a Light, Composer’s native **Properties** shows the settings supported by
its selected light, including brightness presets and transition rates for
compatible dimmers. Use native **Properties** for linked Control4 keypad colors.
In **Device Setup**, **Indicator lights** controls the LEDs built into the
selected Home Assistant device.

### Device settings and troubleshooting

Device Setup and the classic Properties list show the settings that apply to the
selected device. If your system uses a custom Home Assistant sensor for device
names and rooms, select **Troubleshooting** and enter its entity ID in **Sensor
for custom device names**. Reopen the chooser to see the names.

**Log Mode** controls where troubleshooting messages go. **Print** sends them to
the Composer Lua tab, **Log** writes them to the controller log, and **Print and
Log** does both. Logging turns off after three hours and returns **Log Level**
to **Info**. Changing the output mode or restarting the driver while logging is
on starts a new timer. The Coordinator has the same options in **Properties**.

If Home Assistant's reply or state update is missing, the Light driver checks
the selected device once. If the check fails, choose **Refresh Home Assistant
devices** in **Actions** after checking Home Assistant. You can keep the current
device selection.

If a linked Control4 light keeps dimming after a button release, choose **Print
device diagnostics to Lua** in **Actions**. If all release attempts fail, the
last command result in the **Lua** tab explains what to check.

For a Home Assistant light, expand **Light compatibility** on **Device Setup**
if automatic detection gives the wrong light type or the device ignores color
commands. **Light type override** changes the controls offered for that light.
**Color format override** selects HS, RGB, or XY for color commands. For tunable
white, enter lower and upper Kelvin limits together, such as `2700-6500`, and
select **Apply**. Choose **Automatic** or clear the range to restore the
detected setting. The driver still reports the state confirmed by Home
Assistant.

- **Button behavior** appears for devices with buttons, Control4 lighting
  connections or an existing override. In **Automatic**, the text below the
  selector names what the app controls and tells you when button presses are
  available in Control4 Programming. The other control options name their
  targets too. For a Switch, the option ending in **only** keeps on/off control
  and turns off button events and indicator settings. Choose the option ending
  in **+ presses** to use button events and supported indicators too. **Button
  presses only** turns off app control and keeps button presses available for
  programming. An explicit choice survives a restart.
- **Light controlled by the app** lists different linked lights and groups by
  name. A shared target needs no selection. If a saved choice loses its link,
  the selector offers the available destinations. A dedicated **App Control
  Link** connection takes precedence.
- **Selected device ID** and **Controlled device ID** help distinguish a wall
  control from its target when troubleshooting.
- To investigate button events or a linked Control4 light, open
  **Troubleshooting**. Set **Log Mode** to **Print** and **Log Level** to **4 -
  Debug**. Repeat the action and check the **Lua** tab. The Light reports
  commands it forwarded or skipped and the linked light’s reported power and
  brightness. Director can deliver feedback before the send result. Each
  diagnostic reports up to 25 entries. To start a new capture, turn **Log Mode**
  off and back on, then set **Log Level** to **4 - Debug** again.
- **Latency Diagnostics** records timing samples when enabled. Expand
  **Troubleshooting** and choose **Show timing report** to read them. Use
  **Clear timing samples** before measuring a new setup. Logging and timing can
  be enabled independently.

### Indicator lights

With a supported HA Gesture Bridge device selected, find **Indicator lights on**
followed by the device name in Device Setup. A dropdown applies when you select
a choice. If **Brightness (%)** is a number field, enter the value and select
**Apply**. The color selector shows the confirmed saved color even when the LED
is off or follows the switch. Changing the color preserves the current behavior.
To turn an indicator off, choose **Always off** when the device offers it.

A single indicator has one behavior selector. For multiple indicators, use
**Behavior** under an indicator's name to change it individually, or **Indicator
behavior** to apply a shared setting to every indicator. **Keep current LED
setting** leaves the settings in place. **On when the device is on** and **On
when the device is off** follow the wall device's own state.

The color list and behavior choices come from the selected device. Brightness
shows reported steps when available. Devices that accept a percentage can round
it to a supported level. The displayed setting follows device feedback, which
can arrive after Home Assistant accepts the change. Indicator settings can be
absent or disappear while the device or helper is unavailable. Device selection,
startup and reconnection only read indicator settings.

### Indicator programming

In Composer Programming, choose the button whose indicator you want to change.
Additional buttons include a stable identifier in brackets so saved programs
keep working if you rename an indicator. Enter a color as six hexadecimal
digits, such as `FF0000` for red. The driver chooses the closest supported
color. For brightness, enter a percentage from 0 to 100 using a level the device
offers under **Indicator lights**. Choose **Always Off** under **Set LED
Behavior** to turn an indicator off. The available choices follow the connected
device.
