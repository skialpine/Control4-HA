# Home Assistant Fan

Use Quick Setup on the Home Assistant Coordinator to add the fan to a Control4
room. Open **Device Setup** on the fan to choose a different device.

Use the fan control to turn it on or off. Home Assistant fans that report speed
control can report a confirmed speed after a command. The driver uses the number
of steps reported by Home Assistant, including nine-step fans, or a percentage
scale when the device reports a finely adjustable range. Check **Speed
Reported** before using **Speed Percent** in Programming.

In Composer **Connections**, use **On Button Link**, **Off Button Link** or
**Toggle Button Link** to configure a compatible Control4 keypad. Programming
also offers on, off, toggle and an availability check. Use **Set Fan Option** to
choose oscillation or a preset from a compatible fan. Its list is filled from
the current Home Assistant device. Programming can read the reported setting
through **Oscillation state** and **Fan preset**.

This driver has a separate package identity from the original HA Fan packages.
An in-place update from those packages requires separate qualification.
