# Home Assistant Lock

Choose a lock in Device Setup. Use the lock controls in Control4 to lock or
unlock it. The current state comes from Home Assistant. A reported jam marks the
lock as faulted and makes the **Lock jammed** Programming event and **Lock is
jammed** condition available.

If your lock needs a code, set its **Default code** on the lock entity in Home
Assistant, when that option is available.

Use **Quick Setup** on the Home Assistant Connection to add the driver in a
room. To reconnect an existing driver, choose the lock in **Device Setup**.
[Installation and troubleshooting](https://github.com/skialpine/Control4-HA/blob/main/documentation/installation.md)
