# T-01 Trajectory executor report

Status: Pending execution

## Outcome

Replace this section with the delivered outcome or exact blocker. State whether the feature is complete, partially complete, or blocked; do not equate compilation with runtime correctness.

## Design and contract compliance

| Requirement | Result | Evidence |
| --- | --- | --- |
| Standalone Trajectory destination | Pending | |
| Every indexed provider has coarse turns | Pending | |
| Fine detail only from proven source evidence | Pending | |
| Capability availability separate from timing quality | Pending | |
| Existing turn/accounting records remain canonical | Pending | |
| Single importer scan and atomic batch | Pending | |
| Order, Active time, and Clock time modes | Pending | |
| Shared stable selection identity | Pending | |
| Metadata-only privacy boundary | Pending | |
| Long-session measurement gate | Pending | |

## Source capability matrix

Report availability as unavailable, partial, or complete. Report timing quality separately as exact, inferred, or not applicable. Link every supported claim to audited source evidence and synthetic tests.

| Source/schema | Turn timing | Model timing | First output | Tools | Nesting | Retries | Compaction | Usage link | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Codex | Pending | Pending | Pending | Pending | Pending | Pending | Pending | Pending | |
| Claude Code | Pending | Pending | Pending | Pending | Pending | Pending | Pending | Pending | |
| OpenCode | Pending | Pending | Pending | Pending | Pending | Pending | Pending | Pending | |
| Pi | Pending | Pending | Pending | Pending | Pending | Pending | Pending | Pending | |

## Architecture delivered

Describe:

- normalized activity/capability models and invariants;
- schema migration and indexes;
- importer correlation/checkpoint behavior;
- backend session pagination/report queries;
- hierarchy and timeline projection;
- view-model state/error behavior;
- SwiftUI overview, ledger, inspector, filtering, and accessibility.

## Files changed

List task-owned production, test, project, and documentation files with one-line responsibilities. Mention any planned file that was intentionally not needed and why.

## Migration and data integrity

Report:

- fresh schema version;
- schema-3-to-4 preservation evidence;
- batch rollback/checkpoint evidence;
- reset/removal isolation;
- idempotent import/rebuild evidence;
- whether any local database was migrated during validation.

## Privacy review

State the inspection method and result for:

- SQLite columns and stored values;
- checkpoint state;
- logs and error messages;
- search/filter index;
- fixtures and previews;
- accessibility text;
- source read-only behavior.

List any residual privacy risk. Never include prohibited source content in this report.

## Verification

| Command/test | Scope | Result | Boundary |
| --- | --- | --- | --- |
| Focused model tests | Pending | Pending | |
| Store/migration tests | Pending | Pending | |
| Provider importer tests | Pending | Pending | |
| Projection/backend/model tests | Pending | Pending | |
| Non-launching build-for-testing | Compile/test-build | Pending | Does not prove launched UI behavior |
| `git diff --check` | Patch hygiene | Pending | |

Include exact test counts and failures. If a command was not run, say so and why.

## Performance measurements

Report development Mac hardware, macOS version, release-build command, synthetic dataset construction, nesting/open-span shape, warmup/repetition method, and measurements.

| Activities | Order projection | Active-time projection | Clock-time projection | Mode switch | Scrolling/selection observation |
| ---: | ---: | ---: | ---: | ---: | --- |
| 100 | Pending | Pending | Pending | Pending | Pending |
| 1,000 | Pending | Pending | Pending | Pending | Pending |
| 10,000 | Pending | Pending | Pending | Pending | Pending |

State whether the under-100-ms 10,000-activity target passed. If optimization was added, include before/after evidence and the measured bottleneck.

## Deviations and decisions

List every deviation from `contract.md` or `/docs/trajectory-review-design.md`. For each, provide the mechanism that forced it and whether user approval was obtained. If none, state “None.”

## Remaining limitations and blockers

List unavailable provider capabilities, unmeasured runtime boundaries, known source-version fragility, and work that genuinely remains. Do not list required unfinished work as a future enhancement if the task is being reported complete.

## Repository and delivery state

- Branch: Pending
- Working tree: Pending
- Commit: Not authorized / Pending
- Push: Not authorized / Pending
- Installation: Not authorized / Pending
- App launch/runtime UI validation: Pending

## Worklog

Execution evidence and chronological decisions: [`worklog.md`](worklog.md)
