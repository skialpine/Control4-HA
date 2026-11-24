# Design

## Context

The Coordinator already stages and resumes Switch replacements and verifies cutover before removal. The existing assessment recognizes a narrow set of source profiles. Additional legacy HA drivers can share a native proxy type while using different protocol bindings, event IDs, and saved settings. A read-only project assessment found real scene membership and incoming programming on these sources.

## Goals / Non-Goals

**Goals** include keeping the reviewed target, room, native control behavior, and project references intact, and making recovery possible at every write boundary.

**Scope limits** include Light and Switch sources with qualified interfaces and the settings needed to preserve them. Other HA driver families and broad replication of unused keypad variants are outside this change.

## Decisions

1. **Reuse the staged replacement flow.** The existing preview, backup acknowledgment, return-to-Quick-Setup prompt, operation record, verification, and removal review provide one installer path. Updating a package in place would depend on preserving protocol devices, their proxy identities, and their state layout across packages. Stage an independently verified replacement and keep the old instance available for recovery.
2. **Qualify each source profile.** Establish protocol and proxy topology, binding direction and role, persisted selection fields, event and command identities, and a focused version range. Verify the effective target against the configured HA registry, including alias and existing-owner checks. Once the installation is verified, the preview can request explicit selection when saved values disagree. Require an exact identity or an approved choice before transferring control.
3. **Use the reviewed reference set for cutover.** Scan both device IDs for incoming and owned programming, connections, and direct or group scene participation. Record all members and settings of affected scenes and groups. Reuse verified operations for supported transfers. Give Composer instructions only for changes the wizard can verify. Compare settings and references after recheck, and stop on drift or incomplete evidence. Reuse the project snapshot for one discovery pass and read fresh state before cutover and removal review.
4. **Keep recoverable stages and one active authority.** Verify the Home Assistant installation as well as the selected entity. Apply the same ownership checks in commissioning and migration. Revalidate the reviewed plan immediately before transfer and use the existing recovery model for partial failure. Give the replacement the original name and the old driver a distinct retirement name once the names can be verified. Defer automatic suite installation while work is staged. After installer testing, verify the final references again for separate removal review.
5. **Keep compatibility settings with the Light.** Review the pinned template and use its supported capability, settings, and proxy extension points. Store explicit overrides against the selected identity and preserve automatic detection as the default. Construct and validate HA color payloads in the adapter, honoring effective temperature limits. Drive the unavailable event from confirmed availability transitions. Automatic retry with an alternate color format could duplicate commands or hide the cause of a failure.
6. **Map keypad behavior only at verified equivalents.** A brightness link can map to a standard link when it preserves the actual preset, action, and feedback. A temperature or hue link may require a supported preset or an explicit Composer change. Preserve configured behavior when there is a verified equivalent and show the unresolved reference when there is none.

For installation identity, an exact configured route needs no probe. For
aliases on the same port, the Coordinator uses Director to resolve the
addresses and matches a shared IP and port. It cancels the TCP attempt after
resolution. For remaining routes, the Coordinator requests a fresh nonce and
proof on its authenticated Home Assistant session and compares it with the
proof from the companion on the legacy route. The companion returns the nonce and a
one-way proof specific to the running instance. The Coordinator sends no
credentials to that endpoint. A different proof establishes separate scope
only over verified HTTPS, with the original proof rechecked on the live
authenticated session. Missing, stale, or failed reads remain unresolved.

Migration and ordinary commissioning apply the same scope result. Refresh it
before writes and recheck it after migration feedback. Keep the reviewed
routes and exact entity registry result, including an explicit unregistered
result, in the migration checkpoint. Compute fresh route evidence per
operation and discard it when the Home Assistant connection changes.

For a qualified non-binary Light, stage its reviewed overrides using the existing
provider- and session-scoped commissioning exchange. The staged driver validates
and reads back the saved settings while the original still controls the load.
After this succeeds, continue through the existing load selection and feedback
checks. A rejected settings write keeps the original bound.

## Risks / Trade-offs

- A readable scene member can include options that a supported scene edit does not preserve. Compare the saved member settings before and after any transfer and offer supervised Composer steps if needed.
- Native property and event IDs can overlap across drivers. Qualify their behavior and identity before mapping them.
- Some HA integrations advertise color modes or temperature limits that differ from actual device behavior. Keep the overrides explicit, report rejected requests, and use confirmed feedback to show state.
- Scene or program edits can occur while a migration is open. Recheck affected references on continuation and before retirement. Require backup recovery where safe reversal cannot be verified.

## Migration Plan

1. Qualify sources and transfer operations on the lab. Reuse existing evidence for unchanged behaviors.
2. Run one combined lab rehearsal with a scene-bound Light and a Switch with incoming programming. Include a manual dependency or blocked row, a recheck, and recovery. Combine the Composer interface check and installer walkthrough in that pass.
3. For a production migration, review selected drivers and the proposed target and dependency mappings from a backed-up project. Test each replacement before retiring its original. If a cutover fails, reverse verified steps where possible or restore the backup.
