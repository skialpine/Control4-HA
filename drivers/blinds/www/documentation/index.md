# Home Assistant Blinds

In the Home Assistant Coordinator, open **Quick Setup** and choose **Blinds**.
Select the cover, review its destination room, and confirm the new driver. To
switch covers later, open **Device Setup** on the driver.

Open and close the cover from the blind editor. Stop and position controls use
the features reported by the selected cover. In Composer **Programming**, use
**Set Tilt** to control compatible slats separately. **Tilt Position** shows the
last reported tilt percentage. A value of −1 means the position is unknown. Use
**Position** for the lift percentage.

Under **Properties**, or **Troubleshooting** in Device Setup, use **Position
control** to choose automatic detection, reported percentages, or open and close
controls. **Control method** selects which movement the native blind control
uses when the cover has slats. The lift and tilt Programming actions keep their
specific roles.

Use the **Open Button Link**, **Close Button Link**, or **Toggle Button Link**
to assign a keypad action. **Step-by-Step Button Link** stops supported movement
and reverses the last reported direction after the cover stops. Test the linked
button against its intended cover.

For an existing BP Blinds driver, record keypad bindings and Programming
references before adding this driver. Verify the room, keypad actions, lift,
tilt, and any Control4 scenes or groups before approving removal of the old
driver.
