# Install Home Assistant for Control4

The Home Assistant Connection links Control4 to your Home Assistant server. Use
**Home Assistant Light** for dimmers, color lights and on/off lighting. Use
**Home Assistant Switch** for on/off equipment such as a relay. Your Control4
installer adds the drivers and chooses the rooms in Composer Pro.

## Before you start

- Use three driver files from the same build revision. The development packages
  require Control4 OS 3.3.0 or later. Native testing used a CORE 1 on 3.4.3.
- The development tests run Home Assistant 2026.11.1 and 2026.11.2 in Docker
  with a simulated Director connection. Ordinary lights and switches work
  through Home Assistant directly. HA Gesture Bridge 0.1.3 is the optional
  companion tested with these versions. It adds compatible wall switches,
  dimmers, remotes, button presses and indicators.
- These are development qualification versions. Ask your installer for the
  matching package set and check its release notes before changing an existing
  project. [Current qualification](first-demo-packages.md)

## In Home Assistant

1. Open the devices you plan to use and verify they operate from Home Assistant.
   Give them recognizable names and set their areas. Those names appear during
   Control4 setup, and an area that matches one Control4 room can suggest the
   destination room.
1. In a Home Assistant administrator account, open the profile and select
   **Security → Long-lived access tokens**. Create a token and enter it in
   Composer when the installer is ready. The current driver uses administrator
   permissions to receive device state changes and prepare companion devices.
   [Home Assistant token help](https://www.home-assistant.io/docs/authentication/)
1. To add the optional companion for the pilot, open **Settings → Marketplace →
   Add from link**, then enter `https://github.com/skialpine/HA-Gesture-Bridge`.
   Install **HA Gesture Bridge**, restart Home Assistant, and add it under
   **Settings → Devices & services → Integrations → Add integration**. The
   repository link is the pilot distribution path. The companion is a custom
   integration loaded by Home Assistant. The Apps store on Home Assistant OS
   distributes separate applications.
   [Home Assistant Marketplace](https://www.home-assistant.io/integrations/marketplace/)

If Marketplace cannot install the pilot repository, use the manual installation
steps for the matching companion release. After restarting Home Assistant, look
for **HA Gesture Bridge** under **Add integration**.
[Companion manual installation](https://github.com/skialpine/HA-Gesture-Bridge#install)

## In Composer Pro

1. Save a project backup. On the intended controller, import
   `HA.Coordinator.c4z`, `HA.Light.c4z` and `Control4.HA.Switch.c4z`. Driver
   Information should show the same revision for all three packages.
   [Control4 manual driver installation](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm)
1. Add **Home Assistant Connection** once for this Home Assistant server. In its
   **Properties**, enter **HA URL** and **HA Token**. Continue when **Driver
   Status** says **Connected to Home Assistant**.
1. Open **Quick Setup**. Choose devices from Home Assistant and assign each to a
   Control4 room. Select **Review devices** and confirm the room, name and
   action for every row. The confirmation button says what will happen, such as
   **Create 1 driver** or **Finish setup for 1 driver**. Rows marked **Keep
   existing Control4 device** keep their settings. **Control4 setup results**
   shows what finished. For a driver added from Composer Search, open **Device
   Setup → Choose device**, select its Home Assistant device, and choose **Use
   selected device**. A single compatible connection is selected automatically.
   With multiple connections, choose the intended one under **Connections**.
   [Device setup guide](device-setup.md)
1. Open the new driver and verify the selected device and **Controls** if shown.
   If it controls a load, send a safe command from the Control4 app. Check the
   device response and the reported state. For a wall control with gestures,
   open Composer **Programming** and reselect the driver after refreshing the
   **Device Events** list. Configure a test action for a supported gesture, such
   as **Top - 2 taps** on a compatible Switch. Try the gesture and verify the
   programmed action runs. Reconnect Composer to Director if the event list is
   still stale.
   [Connected lighting, gestures and indicators](connected-control4-lighting.md)

## Existing Control4 drivers

Save a backup and keep the original packages. Update supported **HA
Coordinator** and **HA Light** instances in place using their existing
filenames. Check that each keeps its saved selection, connections and
programming. For an original or prototype **HA Switch**, add an unconfigured
**Home Assistant Switch** replacement. Open **Device Setup → Review an older
driver** on the replacement and select the original. Follow the preview and
verify any connections or programming it asks you to recreate in Composer. Keep
the original driver and project backup until the new switch passes a control and
programming check. Use that backup to restore the project if the cutover fails.
[Compatibility](compatibility.md)

Use the Coordinator’s **Check for driver updates** action to check the suite.
The current development builds report availability and verify the files.
Installation still needs an installer.
[Driver releases](build.md#check-for-a-driver-release)
