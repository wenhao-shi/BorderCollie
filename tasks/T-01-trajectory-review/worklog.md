## 2026-08-14

- Stage 0 evidence gate: read the existing importer, store, evaluation, and
  dashboard boundaries. The only source-backed outer intervals are Codex task
  start/completion markers (exact), OpenCode assistant creation/completion
  timestamps (exact), and Claude Code/Pi human-to-terminal-assistant message
  boundaries (inferred). No inspected implementation proves stable request,
  first-output, tool, parent, retry, or compaction lifecycles, so no fine rows
  are emitted.
- Added the normalized activity/capability contracts and sanitizer. Stable IDs
  are agent-namespaced source IDs; capabilities use agent/session/family. The
  sanitizer removes control characters, trims, limits scalar length, and drops
  empty values.
- Extended the existing import batch and atomic store transaction. Schema 4
  adds the two metadata tables and required indexes; reset/removal deletes
  events, turns, trajectory rows, and checkpoints together; checkpoints remain
  the final write. Added session union queries, descending keyset pagination,
  report reads, and explicit-ID-only usage joins.
- Extended all four existing importer passes to version 3. Each discovered
  session receives complete turn timing with the audited exact/inferred quality
  and unavailable capabilities for every finer family. No second history scan
  or raw source payload storage was added.
- Added the pure projection and the dedicated backend/model/view destination.
  The projection validates missing parents and cycles, preserves open/point
  semantics, supports Order/Active time/Clock time, and uses stable IDs across
  overview, ledger, and inspector. The SwiftUI surface is metadata-only and
  preview/live state is injected at the model boundary.
- Added 7 focused Swift Testing cases for normalization, capability state,
  hierarchy/projection, store round trips and rollback, schema migration, and
  keyset pagination. Existing provider importer tests now assert the complete
  capability matrix. The non-launching test build passed; app-hosted tests were
  not run because they can launch the app process.
- Release projection benchmark used a deterministic one-turn synthetic report
  with 100, 1,000, and 10,000 activities, one warmup, and five timed samples
  per mode. On a MacBook Pro Mac15,6 with Apple M3 Pro (11 cores, 36 GB),
  macOS 26.6.1, medians in milliseconds were:

  | Activities | Order | Active time | Clock time |
  | ---: | ---: | ---: | ---: |
  | 100 | 0.326 | 0.303 | 0.274 |
  | 1,000 | 2.682 | 2.054 | 1.722 |
  | 10,000 | 13.613 | 12.725 | 12.683 |

  Projection and mode recomputation are below the 100 ms target for this
  synthetic shape. Scrolling and selection were not runtime-checked.
- Final compile verification passed and patch whitespace validation was clean.
  No commit, push, installation, app launch, or external source mutation was
  performed.
- Added the fully synthetic `PreviewProvider`, inclusive timeline drag-range
  selection using the pure overlap predicate, and native hover help for timing.
  Re-ran the non-launching test build successfully after these changes.
- Follow-up review remediation fixed stale session/report selection, moved
  session keyset pagination into bounded SQLite result reads, rooted activities
  under their canonical turns so turn folding is reachable, retained every
  range-overlap ID across the timeline and multi-selection ledger, and removed
  detail-owned minimum-width constraints.
- Expanded the focused suite from seven to eight cases. The fixtures now use
  matching batch agents, exercise source-removal isolation for all trajectory
  record families, compare migrated schema 3 with a fresh schema, insert a new
  leading session between keyset pages, and verify stale/cleared model selection.
- The first focused runtime attempt was blocked before test execution by the
  command sandbox's denial of `testmanagerd.control`. Re-running the same
  `test-without-building` command outside that sandbox passed all eight focused
  cases. The complete 80-case `BorderCollieTests` target then passed.
