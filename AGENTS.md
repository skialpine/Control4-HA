# Commit review

Before every commit, run the project's `.agents/skills/audit-code/SKILL.md`
workflow against the proposed commit, including complete changed functions and
their callers. If changes follow the audit, re-audit the affected paths before
committing. Apply this rule to implementation, test, documentation and planning
commits alike.

# Control4 lab access

Never operate Composer directly or through computer automation. Prepare exact
driver packages and ask the user to perform Composer steps. If `AGENTS.local.md`
exists, read it before accessing a controller or staging a package.

# Public project privacy

Keep real installation data in local, ignored files outside public artifacts.
Use synthetic names and configuration in source, test fixtures, documentation,
screenshots, OpenSpec, and release packages. Record qualification outcomes
without private project names, locations, addresses, device identifiers, or
installation settings.

# Shared driver behavior

Every driver or behavior change must begin with a review of the pinned Finite
Labs template's libraries, examples and documented extension points. Start new
drivers from the closest applicable template example and follow its documented
initialization, teardown and proxy wiring. Use all applicable library behavior
through its supported contract. Leave native proxy dispatch, state, settings and
groups with the library where it owns them. Keep driver entry points to
family-specific adapters and wiring.

Keep common HA transport, setup, migration and lifecycle behavior in shared
`src/ha` modules. Search for existing helpers before adding one. If the template
cannot express a needed behavior, use a narrow adapter or library extension and
document the gap. In review, identify duplicate implementations and code that
bypasses a library's normal entry point. Remove the duplication or record the
compatibility requirement that justifies it.

For every template update, review the old-to-new diff under
`example-driver/drivers/example_light` and import applicable fixes into the
corresponding suite paths. Record the fix, its regression test and any
inapplicable changes in `documentation/template-reuse.md`.

# Legacy migration

Legacy-driver/project migration must start only from an explicit user-requested
action. Startup, discovery, binding changes and routine updates must not
initiate it. Automated staging or transfer steps may run within that requested
operation, with its preview, validation and rollback requirements.

# Latency qualification

Every common user operation must have opt-in, bounded latency instrumentation
and a recorded benchmark before the feedback handoff. Reuse the prior timing
work across the Light/Switch prototype, Coordinator and HA Gesture Bridge. Cover
control, gestures, feedback, selection/discovery, preparation, startup and
recovery; include linked-C4, scene/group and LED operations as implemented.
Separate local processing phases, HA service acceptance, confirmed feedback and
HA-clock gesture acknowledgment. Record sample counts, distributions, clock and
logging settings. Never label acknowledgments as physical response or divide a
round trip into an assumed one-way latency. Diagnostics must not gate control,
change command ordering, create polling or require verbose logging.

# Intentional setup UI

Basic setup must make choosing a device, its controlled target, current status
and the next useful action clear. Every visible control needs a user-facing
purpose. Put manual identities, operating overrides, binding details, logs and
timing reports in Advanced; hide settings that do not apply to the selected
capabilities. Use plain labels and actionable errors. Browsing never changes
selection or creates controls, and raw protocol details do not belong in the
normal setup flow.

Use one shared setup design and vocabulary across the entire HA driver family,
including future families. It must feel like one product. Automatically resolve
safe configuration and defaults from device capabilities, existing bindings and
supported companion metadata; preserve explicit user overrides. Ask for only
information that cannot be determined reliably. Write for end users, describing
what a device does, what it controls and the next useful action rather than HA
or C4 internals. Keep technical identifiers and protocol terminology in
Advanced.

Declare native Properties before custom setup tabs in every driver. Verify the
actual first tab and landing screen in Composer with the user. Keep the
connection settings in Properties. Quick Setup lists devices from Home Assistant
automatically on entry and when Device type changes. Use plain project and
device names, show the destination Control4 room, and explain what the final
confirmation creates. Preserve edits across search and type changes.

Have an independent agent act as a UI reviewer for every new or changed
user-facing element across the driver family and its Home Assistant companion.
Include native Properties and Actions, custom pages, Navigator controls, labels,
help, confirmations, errors and empty states. Review shared elements in the
context of the drivers that use them.

Before handoff, give the reviewer a rendered preview or screenshot when
available and the task a user is trying to complete. Check appearance, plain
language, consistency, keyboard use and whether the next action stays visible at
normal and constrained pane sizes. Record actionable findings and recheck
affected flows after edits. Identify anything that still needs the user's visual
check in Composer or Navigator.

## Usability review and feature preservation

Before changing navigation, visibility, or a proxy capability, list the tasks an
installer or homeowner can complete on the shipping and prototype drivers.
Include Composer's native proxy editor, Properties, Actions, Device Setup,
Navigator, programming, and existing installations. Name the starting state,
action and observable result. A matching XML key alone establishes only that the
interface is declared.

Give the independent UI reviewer those tasks, the previous interface and the
rendered candidate. Have them attempt each affected task from the normal entry
point, including finding it without being told which tab to open. Check labels
against what actually happens, keyboard/focus after save or failure, the number
of navigation steps, and whether primary actions stay reachable in a small pane.
Use fixtures that exercise the relevant capabilities. A binary bulb cannot
qualify a dimmer editor, and a virtual switch cannot qualify physical LEDs.

Record a result per task: demonstrated, failed, or awaiting native verification.
For settings, exercise editing, readback after reopening and the downstream
effect where observable. Ask the installer to verify Composer-owned surfaces on
the installed candidate. Distinguish a source or simulated check from that
observation. An inaccessible predecessor task blocks parity signoff until
restored or the user explicitly accepts its removal. Independently recheck each
correction on the rebuilt candidate.

For a navigation change, review a sketch or working prototype before packaging.
Give the reviewer a realistic goal (for example, “make the wall button blue when
the light is on”), without the control label or the route. Record where they
looked first, what they expected to happen, ambiguous terms, extra steps and how
they recovered. Judge the complete Composer pane at the user's scale, including
space taken by native chrome. Review headings, grouping, alignment, focus and
the prominence of common actions alongside functional parity. If two layouts
trade off ease of setup against access to everyday controls, compare both on the
same tasks before choosing one.
