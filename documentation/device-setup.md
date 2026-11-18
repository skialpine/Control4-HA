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
1. Search by device name or room. Use **Light** for a dimmer, a color light or a
   group of lights. Use **Switch** for an on/off device such as a relay. A
   compatible button device can appear in either list.
1. Select a result and choose **Use selected device**. Searching, highlighting a
   result or closing the list leaves the current selection in place. When you
   choose a replacement, the current device stays connected until the new device
   passes its check.
1. Check **Controls** for the selected load or connected Control4 light. In
   **Buttons only** mode, **App control** shows **Off**. The status updates when
   Home Assistant reports the selected device's current state.

For ordinary lights and switches, follow these steps with Home Assistant as it
is. The optional **HA Gesture Bridge** helper adds named physical devices and
remotes. When you choose a compatible device, the helper finds its buttons, any
configured indicator lights and its linked load. Devices with several
independent outputs can have more than one choice. Select the output you want.

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
connecting **App Control Link** or choosing **Button used by the app** in Device
Setup. The On, Off and Toggle **Button Links** let external keypads operate this
driver. A remote with buttons and no load defaults to **Buttons only**.

### Program button presses

In Composer **Programming**, select the Light or Switch and look for the button
and tap count, such as **Bottom - 3 taps**. Choose single, double or triple
taps, hold or release, depending on what the selected device reports through HA
Gesture Bridge. Refresh Composer after choosing a new device if its events do
not appear.

### When setup needs attention

| What you see                                | What to do                                                                                                                                                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Not configured                              | Choose a device. If the button is unavailable, connect this driver to the Home Assistant Connection.                                                                                              |
| Driver did not respond                      | Check **Driver Status** and **Next step** in Properties, then select **Retry loading setup**.                                                                                                     |
| Waiting for device                          | Allow Home Assistant to report the device's current state. Check the device in Home Assistant if the message persists.                                                                            |
| Device unavailable                          | Check the device and its linked target in Home Assistant.                                                                                                                                         |
| Home Assistant disconnected                 | Check the address and account on the Coordinator.                                                                                                                                                 |
| Home Assistant denied access                | Check the Coordinator account's permissions. The helper's device list and button setup require a Home Assistant administrator. Reopen the list or choose **Retry setup** after correcting access. |
| The device list changed                     | Open the list again and choose the device from the current results.                                                                                                                               |
| Driver and helper versions are incompatible | Install a compatible driver and HA Gesture Bridge version, then reopen the list.                                                                                                                  |
| Setup needs attention after a restart       | Choose **Retry setup** to finish a previously requested choice, or open the list to choose again.                                                                                                 |
| Waiting for buttons                         | Check the device and its input sources in HA Gesture Bridge.                                                                                                                                      |

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

- In **Choose device** or **Change device**, expand **Enter a Home Assistant
  device ID** and select **Save device ID** after entering the ID. This field
  accepts the exact Home Assistant entity ID for a light, switch, or toggle
  helper (`input_boolean`). Use it to select a toggle helper or a device outside
  the picker. If Home Assistant cannot verify the new ID, the driver keeps the
  current selection. Correct the problem and enter the ID again. Clearing a
  saved manual ID removes that selection. Choosing by name clears the manual
  entry when setup succeeds.
- **Button behavior** appears for devices with buttons, Control4 lighting
  connections or an existing override. Leave it on **Automatic** to follow the
  device and connections. App commands go to the Home Assistant target or, for a
  Light, the connected Control4 light. **Buttons only** turns off app control
  and keeps button presses available for programming. An explicit choice
  survives a restart. On a Switch with both a linked device and buttons, choose
  **Control linked device only** for on/off control without button events or
  indicator settings. **Control device and report presses** also makes button
  events and supported indicators available.
- **Button used by the app** lets a Light use the linked Top, Bottom or Toggle
  button for app control. In **Automatic**, the app uses a shared destination.
  This setting appears when a button link can provide the app target. A
  dedicated **App Control Link** connection takes precedence.
- **Selected device ID** and **Controlled device ID** help distinguish a wall
  control from its target when troubleshooting.
- **Latency Diagnostics** records timing samples when enabled. Expand
  **Troubleshooting** and choose **Show timing report** to read them. Use
  **Clear timing samples** before measuring a new setup. Logging and timing can
  be enabled independently.

### Indicator lights

With a supported HA Gesture Bridge device selected, find **Indicator lights on**
followed by the device name in Device Setup. Change an available **Current
color**, **Brightness (%)** or **Behavior**, then select **Apply** beside that
setting. For example, choose **Blue** under **Current color**. This changes the
stored color while keeping the indicator's behavior. To turn an indicator off,
choose **Always off** under **Behavior** when the device offers it.

**Behavior for all indicators** appears when the available indicators share a
behavior. Choosing a shared behavior submits that change to all of them. **Use
Device Setting** leaves their current settings in place. To change just one
indicator, use **Behavior** under its name and select **Apply**.

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
