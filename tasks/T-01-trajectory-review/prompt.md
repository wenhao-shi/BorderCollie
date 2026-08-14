# Executor prompt

You are implementing T-01 in the BorderCollie repository. Complete the metadata-only Trajectory feature end to end according to the task packet and repository contracts.

Start by reading, in this order:

1. `/AGENTS.md`
2. `/tasks/T-01-trajectory-review/AGENTS.md`
3. `/tasks/T-01-trajectory-review/contract.md`
4. `/docs/trajectory-review-design.md`
5. `/docs/usage-dashboard-design.md`
6. `/docs/usage-dashboard-plan.md`
7. `/tasks/T-01-trajectory-review/plan.md`
8. the current `/tasks/T-01-trajectory-review/worklog.md`

Then inspect `git status`, the relevant production code, project membership, and tests before editing. Existing and unrelated working-tree changes belong to the user; preserve them.

## Objective

Deliver a native SwiftUI `Trajectory` destination that lets the user inspect every locally indexed Claude Code, Codex, OpenCode, and Pi session.

- Reuse `UsageActiveTurn` for outer turns.
- Reuse `UsageEvent` for tokens and cost.
- Add normalized metadata-only activity and capability records through the existing provider importer pass and atomic `UsageImportBatch` transaction.
- Build session discovery, a pure hierarchy/timeline projection, a main-actor view model, and synchronized overview/ledger/inspector UI.
- Provide Order, Active time, and Clock time modes with explicit evidence quality and unavailable coverage.
- Preserve the privacy allow-list. Never persist, index, log, fixture, or display conversation/tool payloads or raw local paths.

## Required method

Execute `/tasks/T-01-trajectory-review/plan.md` in order. Stage 0 is blocking for fine-grained mappings: read source mechanisms and build an evidence matrix before writing provider activity parsers. Do not infer a tool, request, parent, usage link, retry, first-token boundary, or compaction from adjacency or timestamp proximity.

If an agent source exposes only outer turns, implement the complete coarse trajectory and declare the missing capabilities unavailable. That is required truthful degradation. Do not create synthetic detailed rows to make providers look uniform.

Prefer upstream/installed source and provider fixtures for the audit. If structural inspection of private histories is unavoidable, suppress all values and inspect only keys/types/relationships. Never emit private content into terminal output, the task packet, code, tests, or chat.

Use the fixed names, signatures, persistence schema, atomicity rules, UI contract, performance target, and test requirements in `contract.md`. Do not edit the contract to fit your implementation. If a load-bearing contract requirement is impossible, record exact evidence in `worklog.md`, stop at that boundary, and fill `report.md` as blocked instead of substituting an easier design.

## Execution behavior

- Work autonomously through every unblocked stage.
- Append evidence, decisions, commands/results, and next steps to `worklog.md` throughout execution.
- Keep the project buildable after each stage.
- Add synthetic tests for every supported and unavailable provider capability.
- Update repository docs and root `AGENTS.md` to match actual implemented behavior.
- Measure the 100/1,000/10,000-activity projection and UI boundary before adding custom virtualization.
- Use the non-launching build-for-testing command specified in `contract.md` for final compilation.
- Do not commit, push, install, or launch the app unless separately authorized.

## Completion

Do not stop after scaffolding, a source audit, a backend-only slice, or a turn-only UI when fine-grained evidence was proven. Finish all unblocked stages, run proportional verification, inspect the final diff/status, and complete `report.md`.

Your final response must lead with the actual outcome and include:

- what was implemented;
- exact provider capability/fidelity boundaries;
- migrations and privacy guarantees;
- tests, build, and performance measurements actually run;
- remaining limitations or blockers;
- commit/push/install status;
- links to `worklog.md` and `report.md`.
