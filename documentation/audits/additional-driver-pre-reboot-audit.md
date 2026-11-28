# Additional driver pre-reboot audit

The review covered the current suite changes and their callers, the lab
adapter boundaries, and the dotted companion archive patch. The review
reproduced three blocking defects in simulation. Targeted regressions now
verify the corrected mixed-project, manual Cover and thermostat behavior.

## Architecture and modularity

New suite children could block the shared legacy route. A released legacy Fan
or Alarm Panel variant could also block other valid legacy devices. The
Coordinator verifies suite package identity and the existing shared-wire reply
for every supported family. Legacy traffic also recognizes the exact observed
Fan and Alarm Panel archive variants. The mixed tests exercise a suite Fan,
published original Fan and Alarm Panel variants, and an unrelated valid
original's exact state and command paths.

## Security and error handling

Manual Cover selection now checks the reported device class with the requested
driver family before replacing a saved target. An unreadable legacy cover
blocks a competing add across both cover families. A stale Lock or Alarm Panel
rejection no longer supersedes the result of a newer command.

The disposable the controller fixture pins the verified lab TLS origin, one synthetic
entity and one reviewed room and name. Its preview proves the archive is
absent. Confirmation uses the same reviewed plan and verifies the installed
bytes. An unavailable checksum read remains visible even if Director reports
that it added the device.

## Performance and scalability

The the controller probe runs the normal Quick Setup browse handler on the controller.
It reports elapsed time, page size and verified catalog count without copying
project names, addresses or entity identifiers. Project match checks accounted
for most of the small-catalog warm latency. A position-only media update still
sends redundant native notifications. The review established the extra
notifications in the simulator.

## Readability and maintainability

The shared catalog and preview handlers remain the production entry points.
The private helper only relays pinned lab operations and projects their
reports. Quick Setup's existing searches now also match exact endpoint aliases
while the rows retain device names. Blocked previews name the settings,
connections or selection an installer can check.

## Test simplification

The all-family Director shim checks package, destination, bindings and
duplicate avoidance. Its configuration stub does not establish a complete
device setup across reload. The live Fan fixture separately exercised the
normal selection transfer and kept the same device on a second preview.
Rejection, stale approval and unreachable origin cases remain in the probe
test. The script works with both the suite and the single-file runner.

## Prioritised action plan

| Priority | Finding | Disposition |
| -------- | ------- | ----------- |
| High | A valid mixed inventory could disable unrelated legacy devices | Fixed and verified in the shared binding and exact target tests |
| High | Manual Cover selection could save a device of the wrong class | Fixed and verified in both directions through the real setup and Coordinator entry points in the simulator |
| High | A confirmed thermostat range intent could overwrite a later external change | Clear the intent once matching authoritative feedback arrives. The regression issues an edit after a confirmed range and an external change |
| Medium | A superseded security result could replace the current result | Guard native failure notifications by the active request sequence |
| Medium | Missing HVAC action can leave the previous native indicator visible | Verify the proxy's supported way to clear the state on the controller. Programming already reports Unknown |
| Medium | A plain title with a question mark could disappear | Preserve ordinary punctuation and keep rejecting URL and query-shaped credential data |
| Low | Position-only feedback can send redundant media notifications | Record native call cost before changing the dashboard, queue and progress notification contract |

Native automatic mode visibility, stock room routing, installed predecessor
upgrade and rollback, and Composer and Navigator acceptance remain on the
qualification checklist. The audit makes no hardware claim.
