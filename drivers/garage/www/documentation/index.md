# Home Assistant Garage Door

In the Home Assistant Coordinator, open **Quick Setup** and choose **Garage
doors**. Select the door, review its destination room, and confirm the new
driver. To select a different door later, open **Device Setup**.

For a Control4 Garage Door controller with separate Open and Close inputs,
connect them to **Open Door Relay** and **Close Door Relay**. Connect **Stop
Door Relay** if the selected door supports Stop and the controller has a Stop
input. Match the closed and open inputs to **Closed Limit Contact** and **Open
Limit Contact** in Composer Connections. Verify travel and both limits.

The Control4 Garage Door controller supplies the Garage Door app control. The
driver also offers a native **Cover** control. If the room already uses the
Garage Door controller, use Navigator settings to show the intended control. The
original **Garage Door Relay** connection accepts open, close, and toggle.

Use the native **Open Button Link**, **Closed Button Link**, and **Toggle Button
Link** for keypad control. Leave **Blind Group** unconnected when wiring a
Control4 Garage Door controller.

Under **Properties**, or **Troubleshooting** in Device Setup, choose **Position
control** to use automatic detection, show reported percentages, or allow open
and close commands only for position targets. **Step-by-Step Button Link** stops
supported movement and reverses the last reported direction after the door
stops.

**Door status** reports the latest known state. During travel or when feedback
is unavailable, neither limit contact is asserted. The open limit requires a
reported position of 100%. In Programming, **Toggle** requires a known
direction. Use **Open** or **Close** to request a specific direction. **Stop**
and **Set Position** send a request only when the door reports that capability.

If the opener exposes its light separately in Home Assistant, add it as a Light
in the same room. If it exposes remote lockout separately, choose its device
type in Quick Setup and name the control **Lock remotes**.

BP Garage Door replacements require a binding review. The relay uses a different
connection number in this driver. Record the existing relay, contacts, keypad
links, and Programming references before changing them.
