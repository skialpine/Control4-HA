# Home Assistant Light

Choose this driver for lamps, dimmers and lighting relays. It uses Home
Assistant's reported power, brightness and color capabilities. Binary loads show
on/off controls. When a supported color is chosen while the light is off, the
next On applies that color.

Native HA loads use Control4's Light controls for presets, On modes, groups and
scenes. A basic On uses the light's remembered brightness until you choose a
Control4 brightness On mode. Rates are available when the HA light reports
transition support. Releasing a hold on that light sends an estimated
replacement level. The device may finish an already accepted transition if it
cannot interrupt it.

If the selected light offers effects, choose **Effect** in Navigator to apply
one. The displayed effect follows Home Assistant.

In Composer Programming, select the Light to use the top, bottom or toggle
paddle’s tap, double-tap, triple-tap, hold or release. Additional buttons and
gestures appear under their own names when the wall control supports them.

<!-- #embed ../../../../documentation/device-setup.md -->

**Set LED On Color** and **Set LED Off Color** save tracking preferences. **Set
LED Current Color** changes the indicator immediately. **Set All LED Colors**
changes all available indicators and saves both tracking colors for each. Each
indicator must support changing color.

To have the indicators follow a connected light, open Device Setup and choose
**Follow Bound Device** under **Behavior for all indicators**. **Follow the
light linked to** selects which connected paddle supplies the light's state.
When several paddles control different lights, choose one here to start
tracking. Use **Refresh LED Feedback** in Actions to ask that light for its
current state. Black in a saved tracking color switches the indicator off. **Use
Device Setting** stops following the light and leaves the indicator in its
current setting.
