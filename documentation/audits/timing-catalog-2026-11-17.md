# Shared timing/catalog audit: 2026-11-17

Reviewed the shared transport, passive timing collector, catalog/eligibility,
complete JSON string decoder, entry-point wiring and their focused tests.
Initial review found one High, two Medium and one Low issue. All were fixed and
re-audited; no verified Critical/High/Medium findings remain in this scope. This
is not a whole-suite release audit or native/physical qualification.

## 1. Architecture & modularity

Common behavior remains in `src/ha`, using the template's transports, promises,
values, table helpers and existing codec. One Coordinator retains catalog
records and family indices; consumers do not add persistent catalog caches.
Timing observes existing work and introduces no polling or diagnostic traffic.

Light/Switch family adapters and UI wiring remain pending. Reserved metric names
and simulated timing do not claim those features are implemented.

## 2. Security & error handling

High, fixed: the optional request-timing callback indexed `result.kind` on
opaque successful scalar replies. Diagnostics On could therefore throw and
change the receive outcome while Off accepted it. Outcome extraction now checks
table type, and actual Hub regressions prove boolean/numeric callback parity
with diagnostics both Off and On.

Private tokens/payloads are absent from runtime timing data. Fixed operation and
outcome categories, bounded sample windows and contained clock errors preserve
that boundary. The locally cached HA token remains outside packages/reports.

## 3. Performance & scalability

Medium, fixed: a failed old-generation HTTP read returned `retired` to its
caller but recorded `timeout`/`failed`. The connection now derives one safe
failure kind and applies retirement consistently to both outcomes. An
enabled-diagnostics regression checks the complete path.

The collector records lifetime aggregates and explicitly windowed percentiles,
with logging and clock context. Disabled capture avoids clock reads. The codec
change is limited to the established string-span optimization and permissive
four-byte correction; strict parsing and typed values remain covered. Its CPU
benchmark is explicitly workstation-only.

## 4. Readability & maintainability

Low, fixed: provenance prose claimed no prototype implementation was copied
while the JSON adaptation header/inventory described its reuse. The prose now
acknowledges that precise scope and retains attribution and public-release
gates.

The shared catalog distinguishes upstream revisions from eligibility/content
revisions and retains one record pool. Registry-only hidden-state changes can
therefore invalidate cursors without another descriptor download.

## 5. Test simplification

Medium, fixed: an older subscription send-failure test counted deliveries before
advancing its clock, so it could not see the documented retries. It now counts
after the advance and checks one initial failure, three bounded attempts and no
pending callbacks. Production recovery semantics were not changed for the test.

Focused checks include Hub 216, HTTP snapshot/catalog 47, performance 28, strict
string 22, eligibility 25, integrated catalog policy 16, connection 77 and
configuration 17 assertions. These 448 Lua assertions pass offline. Token-cache
and project Python tests also pass. Existing unfinished Light conformance tests
remain intact and are not reported as a passing full-suite run.

Additional boundary coverage remains useful as affected features are added:
clock failure during real handler execution, empty/byte-limited multi-page
catalogs, unavailable aliases, and native fallback through the combined package
matrix. These are qualification items, not additional verified defects from this
review.

## 6. Prioritised action plan

| Priority | Severity | Item                                                 | Status               |
| -------- | -------- | ---------------------------------------------------- | -------------------- |
| 1        | High     | Passive scalar-result handling must preserve control | Fixed and re-audited |
| 2        | Medium   | Match retired HTTP timing and caller outcomes        | Fixed and re-audited |
| 3        | Medium   | Observe actual retries in the send-failure test      | Fixed and re-audited |
| 4        | Low      | Reconcile provenance narrative                       | Fixed and re-audited |

No commit was made. Future commits must run the required audit against their
complete proposed contents. Continue functional and latency qualification per
`documentation/performance-contract.md`; native Director/physical evidence and
unfinished family features remain separate release gates.
