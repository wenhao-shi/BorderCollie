# Historical Usage Dashboard Implementation Plan

Status: stages 0–5 complete; stage 6 automated verification and documentation
complete. Interactive screenshot QA remains pending because ScreenCaptureKit
could not start a capture stream in the current session.

This plan implements `docs/usage-dashboard-design.md`. It is ordered so that
data correctness and provenance are proven before the dashboard UI can present
finished-looking totals.

No stage may substitute placeholder values for unavailable source data or
pricing.

## Stage 0: Freeze Source Contracts And Fixtures

### Work

- Record the installed schema/version evidence for Claude Code, Codex,
  OpenCode, and Pi.
- Define adapter-specific stable event identities.
- Create minimal synthetic fixtures for:
  - one complete event;
  - cached reads;
  - cache writes;
  - reasoning included in output;
  - repeated/duplicate records;
  - missing optional fields;
  - malformed records;
  - multiple models in one session.
- Document whether each raw input counter is inclusive or exclusive of cached
  tokens.

### Gate

- Every fixture has a hand-calculated normalized result.
- No fixture contains copied conversation text, credentials, real paths, or
  stable local identifiers.
- Codex cache-write semantics are validated with a nonzero source fixture or
  explicitly marked unsupported for the affected source version.

## Stage 1: Add The Normalized Model And Local Store

### Work

- Add agent, pricing-authority, completeness, token-bucket, and source-provenance
  models.
- Add the local SQLite schema for events, checkpoints, pricing rules, and model
  aliases.
- Isolate database access behind one actor.
- Implement schema migration and recoverable index recreation.
- Store money as scaled integer units and convert only at the model/display
  boundary.
- Add unique constraints and query indexes described by the design.

### Tests

- Fresh database creation.
- Migration from every introduced schema version.
- Idempotent event upsert.
- Transaction rollback preserves the prior checkpoint.
- Concurrent read requests remain serialized safely through the store actor.

### Gate

- Reimporting the same normalized event does not change row counts or totals.
- A failed batch writes neither partial events nor a new checkpoint.

## Stage 2: Implement The Four Importers

Implement one importer at a time; do not wire the dashboard until all four pass
their parser suites.

### 2A: Claude Code

- Resolve the configured Claude data directory.
- Parse assistant usage without retaining message content.
- Preserve 5-minute and 1-hour cache-write buckets.
- Deduplicate repeated transcript representations.
- Validate thinking tokens as a subset of output.

### 2B: Codex

- Resolve the Codex home and dated rollout files.
- Track applicable turn/model context.
- Normalize `last_token_usage`, not cumulative session usage.
- Split inclusive input into uncached input, cache writes, and cache reads.
- Validate reconstructed totals and source-version behavior.

### 2C: OpenCode

- Resolve the XDG/OpenCode data location.
- Open the source database read-only.
- Query assistant messages incrementally by stable ID/high-water mark.
- Preserve raw provider/model IDs and source-reported costs.

### 2D: Pi

- Resolve Pi session roots.
- Parse message usage and provider/model IDs.
- Preserve per-bucket source cost for reconciliation.
- Deduplicate by session plus response/message identity.

### Cross-Importer Tests

- Complete-field mapping.
- Missing-field handling.
- Arithmetic overflow rejection.
- Negative-token rejection.
- Duplicate suppression.
- Append-only refresh.
- Truncated/replaced source recovery.
- Cancellation before checkpoint commit.
- Unknown schema/version reporting.

### Gate

- Every accepted complete event satisfies:

  ```text
  total = in + cache-write + cache-read + out
  ```

- Partial records retain provenance and are excluded from complete aggregates.
- Parser tests prove that conversation bodies never reach persistence models.

## Stage 3: Add The Effective-Dated Pricing Catalog

### Work

- Define a checked-in pricing catalog format with official source URL,
  retrieval date, and effective interval.
- Add fixed pricing-authority mapping:
  - Claude Code → Anthropic.
  - Codex → OpenAI.
- Add provider/model mapping for observed OpenCode and Pi providers.
- Implement model aliases without changing stored raw model IDs.
- Implement per-bucket pricing and documented request-level modifiers.
- Preserve source-reported cost separately for comparison tests.
- Add a maintenance procedure for updating prices without changing old token
  events.

### Tests

- Exact effective-date boundary selection.
- Input, cache-read, cache-write, and output price arithmetic.
- Anthropic 5-minute versus 1-hour cache-write rates.
- OpenAI cache-write and cached-input rates where applicable.
- Long-context modifier boundaries where documented.
- Unknown model/provider and missing-rate behavior.
- Source-reported cost remains unchanged after repricing.

### Gate

- Every priced event references one auditable pricing rule.
- Every unpriced event returns an explicit reason.
- No price is sourced from memory, a model guess, or an unlabeled third-party
  table.

## Stage 4: Build Aggregation And Coverage Queries

### Work

- Add an exact rolling 24-hour interval plus 7- and 30-day local-calendar
  intervals.
- Aggregate hourly chart values for `24h` and daily chart values for `7d` and
  `30d`, with explicit zero buckets.
- Aggregate detailed normalized token buckets, cost coverage, and rates by
  canonical model and by local calendar day.
- Calculate:

  ```text
  observed input = in + cache-write + cache-read
  input cache-hit rate = cache-read / observed input
  output share = out / total
  ```

- Calculate complete-token, priced-token, and event coverage.
- Keep raw counts in integer types until display formatting.

### Tests

- Local midnight inclusion/exclusion.
- Daylight-saving and time-zone boundary cases.
- Empty denominator behavior for both rates.
- Agent filtering applies identically to every aggregate.
- Cost coverage excludes unpriced events without treating them as zero.
- Model alias changes affect grouping/pricing but not source provenance.

### Gate

- One synthetic dataset reconciles independently across events, chart series,
  cards, percentages, and both breakdown modes.

## Stage 5: Build The Usage Dashboard UI

### Work

- Add a stable `Usage` sidebar selection above individual trackers.
- Keep existing quota routes and the menu-bar quota view unchanged.
- Add `UsageDashboardView` with a vertical `ScrollView`.
- Add toolbar range selection and Refresh.
- Add token/cost chart mode and toggleable agent legend.
- Add proximity-gated pointer interaction with dashed x/y guides and a compact
  agent/date/value annotation for the nearest visible series.
- Add the metric strip, including input cache-hit rate and output share.
- Add model/day breakdown modes.
- Add empty, partial, unpriced, importing, and stale-data states.
- Persist window-scoped filters with `@SceneStorage` where practical.
- Add synthetic previews that cannot scan local histories.
- Use semantic system colors and native Swift Charts/table behavior.

### Accessibility And Desktop Behavior

- Provide accessibility labels that include agent, date, metric, and value for
  chart data.
- Clear hover state outside the plot and when chart metric or enabled-agent
  filters change.
- Keep every chart distinction available through labels, not color alone.
- Verify keyboard focus for toolbar controls and table mode selection.
- Preserve native sidebar selection and system appearance in light and dark
  modes.

### Gate

- All visible sections derive from one immutable aggregate snapshot for the
  active filters.
- Hover hit-testing ignores hidden and zero-valued series and supports a
  single-point series.
- Refresh keeps the last successful dashboard visible while import is running.
- A partial source cannot make the total appear complete.

## Stage 6: Integration, Performance, And Documentation

### Work

- Measure cold full import and warm incremental refresh on the local dataset.
- Confirm refresh work runs off the main actor except for observable UI state.
- Confirm chart/table scrolling remains responsive at 30 days.
- Verify app termination during import cannot corrupt the index.
- Update `docs/tracker_design.md`, `README.md`, and `AGENTS.md` to distinguish
  quota tracking from historical analytics.
- Document price-catalog maintenance and index-rebuild recovery.

### Verification

Run focused unit tests first, then the project's non-launching compile check:

```sh
xcodebuild build-for-testing \
  -project BorderCollie.xcodeproj \
  -scheme BorderCollie \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO
```

Do not use app-hosted `xcodebuild test` as the default because it can launch the
macOS app and disturb the desktop session.

### Final Gate

- All acceptance criteria in `usage-dashboard-design.md` pass.
- Existing quota parser/display tests still pass.
- No credential, auth, transcript, or real local-history content is present in
  the diff.
- `git status` contains only intended source, test, asset, project, and
  documentation changes.
- The final report separates compile validation, parser fixtures, local import
  measurement, and any behavior not exercised at runtime.

## Recommended Delivery Slices

Commits should remain reviewable and preserve working intermediate states:

1. Normalized models, SQLite schema, and store tests.
2. Four importers plus synthetic fixtures and deduplication tests.
3. Effective-dated pricing catalog and arithmetic tests.
4. Aggregation, coverage, and rate tests.
5. Dashboard UI, navigation, previews, and accessibility.
6. Performance evidence and maintainer-documentation updates.

Do not merge a chart backed by fixture-only or partially normalized data as a
finished dashboard. The first user-visible slice should already use the real
incremental store and expose coverage honestly.
