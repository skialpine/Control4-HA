# Home Assistant Thermostat

In the Home Assistant Coordinator, open **Quick Setup** and choose
**Thermostat**. Select the climate device, review its destination room, and
confirm the new driver. To change the thermostat later, open **Device Setup**.

The native thermostat displays temperature, the selected mode, active heating or
cooling, and setpoints as reported by Home Assistant. To set the temperature,
use the single setting or heat and cool bounds shown by the thermostat. The
driver uses the temperature units reported by Home Assistant and waits for
updated feedback after accepting a request.

When supported, use **Set Comfort Setting** in Composer **Programming** to
select a Home Assistant preset. Use **Set Target Humidity** to request a
supported humidity level. **Target humidity** shows the reported target
percentage. A value of −1 means the target is unknown.

For a BP Thermostat replacement, document its schedules, hold clearing, mode
selectors, external temperature sensor, and Programming. Verify the
replacement's controls and feedback before approving any cutover.
