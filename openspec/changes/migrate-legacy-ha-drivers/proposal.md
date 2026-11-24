# Proposal

## Why

Installers replacing legacy HA drivers need to keep the same Home Assistant targets, room names, controls, lighting scenes, and programming. Existing installations include scene members and incoming programming, so recreating a device in the same room is only the first step.

## What Changes

- Extend the Coordinator's explicit Quick Setup migration review to eligible legacy HA Light and Switch drivers using the existing staged replacement workflow.
- Recover the intended Home Assistant entity, identify existing controllers for that target, and review settings, bindings, scenes, load groups, and programming before cutover.
- Move references through verified operations where available. Guide and verify Composer steps for the rest. Keep rollback and separate removal review.
- Close the practical Light compatibility gaps with an unavailable programming event and Advanced overrides for light type, outbound color format, and white temperature limits. Keep automatic detection as the default.
- Preserve used brightness, color temperature, and hue keypad behavior where an equivalent can be demonstrated. Show unsupported bindings and keep affected drivers pending.
- Qualify the workflow with a single grouped lab rehearsal covering a scene-bound Light and a Switch with incoming programming.

## Capabilities

### New Capabilities

### Modified Capabilities

- `migration-assistance` — Extend the existing staged migration to additional legacy HA Light and Switch sources, including scene and group dependencies.
- `native-lighting` — Add migration-relevant compatibility overrides and a dedicated unavailable event.

## Impact

Coordinator Quick Setup and shared migration modules, the Light adapter and settings, Light and Switch migration tests, and installer documentation. This change builds on the corresponding capability specs in the driver suite change. Its acceptance evidence can be gathered independently of the suite's release handoff.
