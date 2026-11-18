# Home Assistant Switch

Choose this driver for equipment with on/off control. Use the Navigator button,
a connected relay control, or the driver's Turn on, Turn off and Toggle
programming commands. The icon and relay feedback follow the state reported by
Home Assistant.

In **Buttons only** mode the icon shows two buttons while button presses are
available for programming. App control is off in this mode.

If the switch controls a lamp you want to present as lighting in Control4,
choose **Home Assistant Light** instead.

<!-- #embed ../../../../documentation/device-setup.md -->

## Legacy button programming

The relay and Button Links accept legacy `BUTTON_ACTION` click packets. Button
IDs 0 and 1 turn the load on or off, respectively. An empty button ID or another
nonnegative button number toggles the load. The driver ignores presses, releases
and packets with missing or invalid fields.
