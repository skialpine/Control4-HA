# Install Home Assistant for Control4

The Home Assistant Connection links Control4 to your Home Assistant server. Use
**Home Assistant Light** for dimmers, color lights and on/off lighting. Use
**Home Assistant Switch** for on/off equipment such as a relay. Your Control4
installer adds the drivers and chooses the rooms in Composer Pro.

## Before you start

- Use driver files from the same build revision. The development packages
  require Control4 OS 3.3.0 or later. Native testing used a Control4 controller on 3.4.3.
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

1. Save a project backup. Download **HA.Coordinator.c4z** from the chosen
   release. In Composer, choose **Driver → Add or Update Driver or Agent** and
   open that file. The Coordinator includes the drivers Quick Setup can create.
   For manual installation, download and extract `control4-ha-drivers.zip` from
   the same release, then import the individual `.c4z` files you need.
   [Control4 manual driver installation](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm)
1. Add only **Home Assistant Connection** to the project. In **Properties**,
   enter **HA Host**, choose **HA Protocol**, and enter **HA Token**. Leave **HA
   Port** blank to check common ports or enter the port you already use.
   Continue when **Driver Status** says **Connected to Home Assistant**.
1. Open **Quick Setup** to create drivers. Choose devices from Home Assistant
   and assign each to a Control4 room. Select **Review devices** and confirm the
   room, name and action for every row. The confirmation button says what will
   happen, such as **Create 1 driver** or **Finish setup for 1 driver**. On
   confirmation, Quick Setup installs any missing driver files for the devices
   it creates. Rows marked **Keep existing Control4 device** keep their
   settings. **Control4 setup results** shows what finished. For a driver added
   from Composer Search, open **Device Setup → Choose device**, select its Home
   Assistant device, and choose **Use selected device**. A single compatible
   connection is selected automatically. With multiple connections, choose the
   intended one under **Connections**. [Device setup guide](device-setup.md)
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
programming. For an original or prototype **HA Switch**, open **Home Assistant
Connection → Quick Setup → Migrate switch drivers** after importing the matching
Switch package. Review the Home Assistant device, relay and any button links
before selecting **Start migration**. Read the return instructions and select
**Continue migration**. Quick Setup transfers verified connections and
identifies work that needs attention. If Composer selects a temporary
replacement, go back to the Coordinator’s **Quick Setup** to continue. Quick
Setup automatically transfers a verified selection. If it asks you to confirm a
proposed load, compare its name and entity ID in Home Assistant with the load
the original switch controls, then choose **Confirm load and transfer** if they
match. If you’re unsure, choose **Get manual setup steps**. Keep the original
driver and project backup until the replacement passes its control and
programming checks. Use the backup to restore the project if Quick Setup says
**Restore the project backup**. After restoring, return to Quick Setup and
select **Refresh status**. [Compatibility](compatibility.md)

Use the Coordinator’s **Check for driver updates** action to install a newer
verified suite release from the selected channel. **Automatic Updates** controls
scheduled checks and installations.
[Driver releases](build.md#check-for-a-driver-release)

## Find where setup stopped

| What you see                                                  | What to check                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The device fails in Home Assistant                            | Test the selected entity and any separate linked load in Home Assistant. For a paddle, verify its input under HA Gesture Bridge before retrying Device Setup.                                                                                                                                           |
| The Coordinator is disconnected                               | In **Home Assistant Connection → Properties**, check Driver Status, HA URL and the saved account. For HTTPS, verify the trust chain and the final reachable origin. [Connection](connection.md)                                                                                                         |
| The Coordinator connects but the picker or preparation fails  | Check **Driver Status** and **Next step** on the selected Light or Switch. Correct the named error and retry the failed step. The current choice stays in place while a replacement is checked. [Device Setup](device-setup.md#when-setup-needs-attention)                                              |
| A physical paddle or the app operates the wrong light         | Read **Selected Device** and **Controls** on the Light. Compare the app target with the separate paddle links in Composer **Connections**. [Connected lighting](connected-control4-lighting.md)                                                                                                         |
| An old Switch migration stops or a replacement fails its test | Read the affected row in the Coordinator's **Quick Setup**. Keep the original and use the saved project backup if the prior settings, links or programming cannot be restored and verified. [Coordinator documentation](../drivers/coordinator/www/documentation/index.md#migrate-older-switch-drivers) |

For a support report, note the Coordinator and affected driver revisions, the HA
and optional companion versions, the step that failed, and the exact short
status shown. Share only the relevant error text. Keep tokens, certificate keys
and raw Home Assistant messages out of the report.

## Optional assistant setup

For a release that includes the assistant skill, download
`control4-ha-setup.zip` from the same release as the drivers. Extract the
`control4-ha-setup` folder and install it using your assistant's Agent Skills
instructions. Its reference map lists the matching manuals and the Home
Assistant connector requirements. Use the skill to check Home Assistant
readiness and prepare the Composer handoff.
[Suite releases](https://github.com/skialpine/Control4-HA/releases)
