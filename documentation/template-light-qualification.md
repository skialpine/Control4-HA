# Pinned Light library correction qualification

Base: Finite Labs template v0.9.111, `5efdae849b32d8739d23e4750c0b6e4d60f754c9`.

Local correction: direct commands carry additive `intent = on/off/level`,
distinguishing a logical On from a numeric request even when levels match.
Software steps, pre-on, stop and color commands retain their existing numeric
contract. API remains 1 because existing adapters can ignore the added field.
Permanent `Light:destroy()` retires handlers, timers and queued reports; guarded
entry points prevent old callbacks from recreating work. Each cleanup runs even
if another fails. Drivers still own cancellation of their adapter transports.

Changed runtime paths: `src/lib/light.lua`, `src/lib/light/types.lua`,
`src/lib/light/motion.lua`, `src/lib/light/handlers.lua`. Exact hashes and
change descriptions are recorded in `provenance/sources.json`.

Verification performed locally:

- Focused adapter/lifetime regressions: 19 assertions passed, including logical
  On versus explicit full level, duplicate destroy, stale callbacks, walked
  timers, fault-injected cleanup, handler ownership and destruction during send.
- All 20 template Light behavior/component suites passed against these local
  libraries. The original motion golden test initially rejected the added field;
  seven expected commands now include its explicit intent, with all prior
  numeric/timing expectations retained. Motion then passed 267 assertions.
- The delegated target controls, command intent and teardown contract is pinned
  at hash 1652266875 by the adapted template contract test (3 assertions
  passed). The original contract hash is deliberately not represented as
  unchanged.

These are virtual-clock and proxy-shim results. They do not establish physical
timing, Navigator rendering or native Director qualification. The suite's
packaged HA adapter conformance rig belongs to the subsequent control tasks.
