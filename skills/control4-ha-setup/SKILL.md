---
name: control4-ha-setup
description: Guide installation, device selection, troubleshooting, and verified migration for the Home Assistant Connection, Light, and Switch drivers for Control4. Use for the Control4–Home Assistant integration, including HA Gesture Bridge paddles and indicators.
---

# Home Assistant for Control4 setup

Read [the release manual map](references/manuals.md) for the requested task.
Use the manuals bundled with this skill and check their revision against the
three driver packages. On an existing system, use the manual that matches the
installed release before suggesting changes.

## Identify the target and intended behavior

- Identify the Home Assistant instance and Control4 project. Use a read-only
  connector check and the device or project identity the user expects. Ask for
  the target if two instances or devices could match. A lab, a live household,
  and an unavailable connector are separate cases. Resolve a mismatch before
  making changes. Switch to the intended connector and repeat the read-only
  check. Use the manual handoff if the intended connector is unavailable.
- Check Home Assistant version, the selected device's entity and capabilities,
  and HA Gesture Bridge's loaded version when the requested behavior needs it.
  Use exact entity reads where possible. In HA-MCP, read its best-practices
  skill for the matching action. Use its overview, device, state, and
  integration tools for inspection. Keep diagnostic output scoped to the
  selected device and omit credentials and raw payloads.
- Identify what the user wants Control4 to operate. An ordinary light or switch
  can use its native HA entity without the companion. Match the driver to the
  requested Control4 behavior. Use the companion for compatible physical
  controls, gestures and indicators. A selected paddle can operate a separate
  HA load or a connected Control4 light. Use the documented Light links for
  a Control4 target and **Buttons only** for programming without app control.

## Apply the matching setup or recovery procedure

Use the installation, connection and Device Setup manuals for the exact
properties and actions. Give the installer the package revision, confirmed
Home Assistant target, Control4 room, driver type and expected result. When
Composer is required, hand off those steps and ask for the resulting selection
and control check. A connector that can inspect Home Assistant can establish
only the Home Assistant side.

Preserve current selections and bindings until the replacement succeeds.
Explain any persistent HA change and apply it only within the user's
authorization. Ask the user to create and enter any necessary token using the
protected settings described in the manual. Use existing configuration when
it already supports the intended outcome.

For an existing project, use the compatibility and migration references.
Require the documented project backup and explicit migration action. Preserve
the original driver until the replacement and affected programming are tested.
Use the release's documented update controls and honor its stated installation
and recovery capabilities.

## Verify each side

After an authorized HA action, check its service result, the exact entity's
current state, and relevant gesture or indicator feedback. Verify the
Control4 selection, controlled target, app action and any Composer
programming separately. Record checks performed by the assistant, by the
installer and still awaiting confirmation.

When setup fails, identify the step that failed and use the manual's specific
recovery action. Keep permission denial, unavailable entities, unsupported
capabilities and transport failures distinct. For a permission failure,
identify the account and access needed for that specific operation. Keep the
current selection and retry the scoped operation once access is corrected.
Use the Coordinator token owner's permissions for an error reported in
Composer, and the connector's credentials for an error reported by HA-MCP.
