# T-01 executor context

## Mission

Implement BorderCollie's metadata-only Trajectory feature end to end. You are expected to arrive with no prior knowledge of this repository or feature. The task packet and linked repository documents are your context; do not rely on recalled behavior of DeepSeek Harness or any supported agent.

This is a real implementation task, not a prototype. A diagram backed only by guessed events is a wrong result. A coarse turn-only view is acceptable only where the source audit proves finer evidence unavailable, and that limitation must be visible in capability data and UI.

## Required reading order

Before editing production code:

1. Read `/AGENTS.md` completely. It governs the whole repository.
2. Read `/tasks/T-01-trajectory-review/contract.md` completely. It freezes this task's interfaces and invariants.
3. Read `/docs/trajectory-review-design.md` completely. Part one explains DeepSeek's mechanism; part two defines the approved BorderCollie design.
4. Read `/docs/usage-dashboard-design.md` completely before changing import, storage, timing, privacy, or aggregation semantics.
5. Read `/docs/usage-dashboard-plan.md` for the existing backend delivery/validation history.
6. Read `/tasks/T-01-trajectory-review/plan.md`, `/tasks/T-01-trajectory-review/prompt.md`, and the current `worklog.md`.
7. Inspect the current working tree and relevant implementation/tests before deciding how to edit.

Do not edit `contract.md` to match a convenient implementation. If a fixed contract cannot work, record the mechanism and stop for design review.

## Project orientation

BorderCollie is a macOS 26.5 SwiftUI Xcode application, not a Swift Package. The historical analytics system is local, SQLite-backed, actor-isolated, incremental, and separate from live subscription-quota polling.

Read these code paths first:

- `BorderCollie/ContentView.swift`: root navigation.
- `BorderCollie/UsageDesign.swift`: mandatory presentation tokens/components.
- `BorderCollie/UsageDashboard/UsageAnalyticsModels.swift`: usage/import contracts.
- `BorderCollie/UsageDashboard/UsageEvaluationModels.swift`: `UsageActiveTurn` and session/evaluation models.
- `BorderCollie/UsageDashboard/UsageImportSupport.swift`: source identity, discovery, checkpoints, importer protocol.
- `BorderCollie/UsageDashboard/UsageImporters.swift`: Claude Code, Codex, Pi, and OpenCode adapters.
- `BorderCollie/UsageDashboard/UsageAnalyticsStore.swift`: schema, migration, atomic apply/reset, reads.
- `BorderCollie/UsageDashboard/UsageAnalyticsBackend.swift`: import coordination and repricing.
- `BorderCollie/UsageDashboard/UsageEvaluationBackend.swift`: session discovery, interval union, report aggregation, backend composition pattern.
- `BorderCollie/UsageDashboard/UsageDashboardModel.swift`: stale-result/error-preservation pattern.
- `BorderCollie/UsageDashboard/EvaluationRunsModel.swift`: session/run async state pattern.
- `BorderCollie/UsageDashboard/EvaluationRunsView.swift`: native `HSplitView`, inset list, grouped detail, turn rows.
- `BorderCollie/UsageDashboard/UsageDailyChart.swift` and `UsageChartInteraction.swift`: current Swift Charts interaction/testing patterns.
- `BorderCollieTests/`: test style and in-memory SQLite fixtures.

Current historical source locations are resolved by code, not by this packet: Claude Code JSONL, Codex session JSONL, OpenCode SQLite, and Pi JSONL. Cursor is a live quota source only and must not be added to historical Trajectory.

## Load-bearing feature decisions

### One session, separate destination

Trajectory is a fourth root sidebar destination. It analyzes one local session. Evaluations remains the explicit time-range/multi-session analysis surface. Do not require the user to create an Evaluation Run to inspect a session.

### Metadata only

Persist only allow-listed identity, ordering, timing, kind, status, hierarchy, model/tool name, failure category, capability, and usage-link metadata. Never retain conversation or tool payloads. The database being local does not weaken this rule.

### Existing records stay canonical

- Outer turn: `UsageActiveTurn`.
- Tokens/cost: `UsageEvent`.
- Provider parsing: existing `UsageSourceImporter` implementations.
- Atomic source prefix: existing `UsageImportBatch` plus new trajectory arrays.
- Import transaction: `UsageAnalyticsStore.apply(_:)`.

Do not duplicate these truths into parallel systems.

### Evidence before rows

Stage 0 must prove source identity and boundary semantics. A tool name in content is not proof of a tool duration. Temporal containment is not proof of parentage. Nearest timestamp is not proof of a usage link. Missing terminal data is not failure.

Capability declarations exist specifically to distinguish:

- source can provide this detail, but the session observed zero instances;
- source provides only part of the detail;
- source cannot provide this detail.

### Three time modes

- Order: canonical source order, equal slots, default.
- Active time: durations with human idle outside the union of turns removed.
- Clock time: wall-clock gaps preserved.

The axis must name the mode. Never call source-order width duration. Never extend an open activity to the current time.

## How to perform the source audit safely

Prefer, in order:

1. current upstream source at a pinned commit/version;
2. installed package/application source or documented schema;
3. synthetic/test fixtures shipped by the provider;
4. redacted structural inspection of local histories only when necessary.

If local private histories are needed, avoid commands that dump records. Extract only keys, types, enum-like discriminator names, presence counts, and timestamp/ID relationships while suppressing values. Do not paste private values into tool calls, worklog, report, tests, source comments, or chat.

For code claims, cite the exact source file and line or commit URL in the updated design document. For unsupported mappings, state “unavailable” or “I don't know”; do not generalize from one example record.

## Implementation discipline

- Use `rg`/`rg --files` for discovery.
- Use `apply_patch` for source/document edits.
- Preserve unrelated changes in a dirty worktree.
- Do not use destructive Git commands.
- Do not commit, push, install, or launch without separate authorization.
- Do not read auth files for historical ingestion or audit.
- Do not add dependencies unless the fixed design truly requires one and the user approves it.
- Do not introduce abstractions with one implementation.
- Keep comments sparse; use them for audited source-field semantics and non-obvious invariants.
- Keep production and preview paths injected. A preview must never open the live store or scan histories.
- Keep one scroll owner. A SwiftUI `Table` already scrolls.
- Keep the window size contract in the root scene/view.

When implementation reveals a minor omission, choose the smallest decision consistent with `contract.md` and record it. When it reveals a load-bearing mismatch—source identity absent, privacy requirement incompatible with a desired row, required signature impossible, migration unsafe—stop and bring evidence back for design review.

## Worklog protocol

`worklog.md` intentionally starts empty. Append entries during execution; do not reconstruct them only at the end.

Each entry should use:

```markdown
## YYYY-MM-DD HH:MM — <stage and short action>

- Evidence: <files/lines, source commit, command, or measurement>
- Decision: <what changed or what remains unavailable>
- Validation: <exact command/result or “not yet run”>
- Next: <next bounded step or blocker>
```

Never include prohibited source content or raw local paths in the worklog.

## Report protocol

Fill `report.md` when implementation ends or blocks. Lead with the outcome. Report:

- completed stages and any blocked requirement;
- exact source capability matrix and evidence boundary;
- files changed and architecture delivered;
- schema migration and rollback evidence;
- tests/builds run with counts/results;
- release performance measurement setup and results;
- privacy audit method/result;
- user-visible behavior and unavailable detail;
- uncommitted/commit/push/install state.

Do not claim runtime validation from compilation, or full source fidelity from synthetic tests.

## Verification

Run focused Swift Testing tests during development. The default final compile check is non-launching:

```sh
xcodebuild build-for-testing \
  -project BorderCollie.xcodeproj \
  -scheme BorderCollie \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO
```

Avoid direct app-hosted `xcodebuild test`; it can launch the UI and hang. If runtime UI inspection becomes necessary, obtain explicit authorization and report that boundary separately.

Before handoff:

- run relevant tests;
- run the non-launching build;
- run `git diff --check`;
- inspect full status/diff;
- confirm no private content or unrelated files entered the change;
- complete `report.md` and the final worklog entry.
