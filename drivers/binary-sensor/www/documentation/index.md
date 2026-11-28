# Home Assistant Binary Sensor

Use Quick Setup on the Home Assistant Coordinator to add the sensor to the
Control4 room where it belongs. To change the choice later, open **Device
Setup** on the sensor and choose it by name. Composer **Properties** shows its
current signal, such as Open, Closed, Occupied or No motion.

In Composer **Connections**, use **Contact Sensor** to supply a contact signal
to a compatible device. The contact opens when Home Assistant reports an active
signal and closes when it reports an inactive signal. Programming can test the
confirmed active or inactive signal, check availability, and respond to either
transition or a loss of signal. During an outage the contact connection keeps
its last value. Check **Sensor is available** before relying on a reading.
Reconnecting initializes the contact from the current state.

The package retains the legacy HA Binary Sensor identity and contact output for
an in-place update. Verify the selected sensor and the connected contact after
updating the driver and Coordinator on a backed-up project.
