# Home Assistant Sensor

Use Quick Setup on the Home Assistant Coordinator to add the sensor to a
Control4 room. Open **Device Setup** on this driver to choose a different
measurement later. **Reading** in Composer shows the confirmed value and the
unit reported by Home Assistant. Choose **Refresh Sensor** in Actions to request
the latest reading for the selected sensor.

In Composer **Connections**, use **Temperature Value** for a compatible
temperature input or **Humidity** for a compatible humidity input. The **Sensor
Type** setting under **Troubleshooting** defaults to Automatic. Select a type
explicitly when the integration leaves out what the sensor measures. If it
reports a temperature without its unit, **Unit Fallback** lets you select
Celsius or Fahrenheit. Choose the scale the sensor actually reports.

Programming can react to a changed reading, check availability, and read the
formatted **Reading** or the **Numeric Reading** variable. Before using the
numeric value, check **Reading is numeric**. The last numeric value remains
stored through an outage or a change to a text reading so an invalid reading
cannot appear as zero.

The package retains the legacy HA Generic Sensor identity, temperature and
humidity connections, and Programming variables. The last confirmed numeric
values stay available through the legacy numeric aliases. Use **Sensor is
available** or **Reading is numeric** to guard these readings.

Existing installations that enabled **Poll Timer** retain a periodic refresh of
their selected sensor. Turn it off under **Troubleshooting** to use Home
Assistant updates. Fresh installations use Home Assistant updates by default.
Verify the selected sensor and connected inputs after an in-place update.
