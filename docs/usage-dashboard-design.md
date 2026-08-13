# Historical Usage Dashboard Design

Status: backend and dashboard UI implemented with 24h/7d/30d tracking periods;
automated verification passes, while interactive screenshot QA remains pending.

This document defines a local historical usage dashboard for Claude Code,
Codex, OpenCode, and Pi. It is intentionally separate from the existing
subscription-quota trackers described in `docs/tracker_design.md`.

The dashboard answers a different question from the quota views:

- Quota views show current provider limits and reset times.
- The historical dashboard shows locally observed token activity and a
  counterfactual estimate of what that activity would cost at public API rates.

Cursor is outside the dashboard because its local history has not been shown to
provide complete accounting data. The existing Cursor quota view is unchanged.

## Product Decisions

- Track exactly four agents: Claude Code, Codex, OpenCode, and Pi.
- Add one aggregate `Usage` destination to the existing sidebar-detail window.
- Keep the existing provider quota destinations and menu-bar quota surface.
- Use local histories as the usage source; do not query billing APIs for
  historical events.
- Never copy prompts, responses, tool arguments, or credentials into the
  dashboard database.
- Normalize usage into `in`, `cache-write`, `cache-read`, `out`, `total`, and
  `cost`.
- Treat reasoning/thinking tokens as a subset of `out`, never as an additional
  token bucket.
- Display input cache-hit rate and output share as derived percentages.
- Calculate historical API-equivalent cost with the official public price that
  was effective when each event occurred.
- Cost is a token-only counterfactual. It is not a subscription charge or an
  invoice reconstruction.
- Claude Code uses Anthropic as its fixed pricing authority and Codex uses
  OpenAI. OpenCode and Pi preserve the provider recorded by each event.
- Unknown data remains unknown. Missing tokens or prices must not silently
  become zero.

## Goals

- Compare the four agents over rolling 24-hour, 7-day, and 30-day ranges.
- Switch the hourly/daily chart between token and API-equivalent cost views.
- Show totals for every normalized token bucket.
- Show input cache-hit rate and output share using declared equations.
- Break usage down by model or day without losing agent provenance.
- Import new events incrementally so opening or refreshing the dashboard does
  not rescan all history.
- Make every cost reproducible from the stored token event and a versioned
  pricing rule.
- Degrade honestly when a source schema, model mapping, or price is unknown.

## Non-Goals

- Replacing the existing subscription-quota pages or menu-bar rows.
- Reporting the user's actual Claude or ChatGPT subscription cost.
- Estimating the monetary value of subscription-plan limits.
- Including Cursor historical usage.
- Storing conversation content or providing transcript search.
- Charging web search, container time, code execution, or other per-tool fees in
  the initial `cost` metric.
- Uploading usage data or adding cloud synchronization.
- Presenting source-reported gateway cost as an official first-party price.

## Canonical Accounting Contract

Every normalized event exposes the following values:

| Field | Contract |
| --- | --- |
| `in` | Uncached input tokens that were neither written to nor read from cache. |
| `cache-write` | Input tokens newly written to a provider cache. |
| `cache-read` | Input tokens served from a provider cache. |
| `out` | All billed output tokens, including reasoning or thinking tokens. |
| `total` | `in + cache-write + cache-read + out`. |
| `cost` | Estimated token-only cost at the effective official standard API rate. |

The names describe disjoint buckets. In particular, an adapter must not leave
cached input inside `in`; doing so would double-count both `total` and `cost`.

### Derived Rates

The dashboard displays two percentages:

```text
observed input = in + cache-write + cache-read

input cache-hit rate = cache-read / observed input

output share = out / total
```

- Input cache-hit rate is unavailable when `observed input` is zero.
- Output share is unavailable when `total` is zero.
- Both values use the same active date and agent filters as the chart.
- A cache write is not a hit; it stays in the denominator but not the numerator.
- Output has no cache-hit metric because none of the four sources reports an
  output-cache token class.

### Reasoning Tokens

`reasoningOutputTokens` is optional drill-down metadata. It must satisfy:

```text
0 <= reasoningOutputTokens <= out
```

It may support secondary copy such as `includes 65.5M reasoning`, but it is not
added again to `total` or `cost`.

### Unknown Versus Zero

Token buckets are nullable at the ingestion boundary:

- `0` means the source explicitly reported no tokens in that bucket.
- `nil` means the source did not report the bucket or its semantics failed
  validation.

An event becomes `complete` only when all four disjoint token buckets are known
and the total invariant passes. Partial events remain stored for provenance but
are excluded from complete-token and cost aggregates. The UI reports how many
events were excluded.

## Source Adapters

The paths below are defaults, not hard-coded assumptions. Resolvers should
honor the corresponding agent or XDG configuration location where one exists.

### Claude Code

Default source:

```text
~/.claude/projects/**/*.jsonl
```

Mapping:

| Normalized field | Claude usage field |
| --- | --- |
| `in` | `input_tokens` |
| `cache-write` | `cache_creation_input_tokens` |
| `cache-read` | `cache_read_input_tokens` |
| `out` | `output_tokens` |
| reasoning detail | `output_tokens_details.thinking_tokens` |

Preserve the cache-write TTL breakdown from
`cache_creation.ephemeral_5m_input_tokens` and
`cache_creation.ephemeral_1h_input_tokens`. The displayed cache-write count is
their sum, while pricing uses the separate values because Anthropic prices the
two durations differently.

Deduplicate repeated transcript representations by stable request/message
identity. A repeated assistant message with the same source identity is one
billable event, not multiple events.

Pricing authority is always `anthropic` for this dashboard. This is an explicit
counterfactual rule even if a future Claude Code configuration routes through a
partner platform.

### Codex

Default source:

```text
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

Use `event_msg.token_count.info.last_token_usage` for request-level usage. Do
not sum `total_token_usage`, which is cumulative session state.

Mapping:

| Normalized field | Codex usage field |
| --- | --- |
| `cache-write` | `cache_write_input_tokens` when reported |
| `cache-read` | `cached_input_tokens` |
| `out` | `output_tokens` |
| reasoning detail | `reasoning_output_tokens` |

Codex `input_tokens` is an inclusive input total. The adapter derives `in` by
subtracting the cache-read and cache-write classifications reported by that
record. It must reject a negative result and verify the reconstructed total
against `total_tokens`.

Associate each token event with the most recent applicable turn context so the
event retains the model used for that request. Deduplication identity must
include the rollout identity and stable event position or turn identity; a
timestamp alone is insufficient.

Pricing authority is always `openai`.

### OpenCode

Default source:

```text
~/.local/share/opencode/opencode.db
```

Read assistant message records from the provider-owned SQLite database without
modifying it. Use the message timestamp, `providerID`, `modelID`, `tokens`, and
source-reported `cost` fields.

Mapping:

| Normalized field | OpenCode field |
| --- | --- |
| `in` | `tokens.input` |
| `cache-write` | `tokens.cache.write` |
| `cache-read` | `tokens.cache.read` |
| `out` | `tokens.output + tokens.reasoning` |
| reasoning detail | `tokens.reasoning` |

OpenCode reports reasoning separately from visible output and includes both in
`tokens.total`. The adapter therefore adds reasoning into canonical `out`, then
retains the original reasoning count as subset metadata.

OpenCode's source-reported cost is retained for reconciliation, not substituted
for the official-price calculation. The stable OpenCode message ID is the
deduplication identity.

### Pi

Default source:

```text
~/.pi/agent/sessions/**/session.jsonl
```

Mapping:

| Normalized field | Pi field |
| --- | --- |
| `in` | `usage.input` |
| `cache-write` | `usage.cacheWrite` |
| `cache-read` | `usage.cacheRead` |
| `out` | `usage.output` |
| reasoning detail | `usage.reasoning` |

Preserve the recorded provider, model, and per-bucket source costs for
reconciliation. Deduplicate with session identity plus response/message
identity; use an ordinal only as a versioned fallback for older records.

## Normalized Persistence Model

The historical dashboard must not extend `SubscriptionQuota`. Quota snapshots
and historical accounting have different lifetimes, update mechanisms, and
failure semantics.

A conceptual event model is:

```swift
struct UsageEvent {
    let id: String
    let agent: UsageAgent
    let pricingAuthority: PricingAuthority
    let rawProviderID: String?
    let rawModelID: String
    let canonicalModelID: String?
    let occurredAt: Date

    let inputTokens: Int64?
    let cacheWriteTokens: Int64?
    let cacheWrite5mTokens: Int64?
    let cacheWrite1hTokens: Int64?
    let cacheReadTokens: Int64?
    let outputTokens: Int64?
    let reasoningOutputTokens: Int64?
    let totalTokens: Int64?

    let sourceReportedCost: Decimal?
    let estimatedAPICost: Decimal?
    let pricingRuleID: String?
    let completeness: UsageCompleteness

    let sourceID: String
    let sourceSchemaVersion: String
    let importerVersion: Int
}
```

The persisted representation should store money as a scaled integer, such as
USD nanodollars, rather than a binary floating-point value. Conversion to
`Decimal` belongs at the model/display boundary.

### Database Tables

The local dashboard database needs four logical tables:

1. `usage_event`
   - One deduplicated accounting event.
   - Unique key on `(agent, source_id)`.
   - Indexed by timestamp, agent, canonical model, and completeness.
2. `import_checkpoint`
   - Opaque source-key hash, filesystem identity, size or database high-water mark, modification time,
     byte offset where applicable, and importer version.
3. `pricing_rule`
   - Pricing authority, canonical model, effective interval, per-token bucket
     rates, threshold/modifier rules, source URL, and retrieval date.
4. `model_alias`
   - Raw provider/model identifier to canonical pricing identifier, with an
     effective interval and provenance.

Daily and model summaries should be SQL queries or ephemeral view-model data,
not independently persisted totals. This prevents aggregate drift after a
parser or pricing correction.

## Incremental Import

Import runs when the Usage screen opens and when the user presses Refresh. It
does not join the 30-second quota polling loop.

For append-only JSONL sources:

1. Resolve candidate files.
2. Compare file identity, byte size, modification time, and importer version to
   the checkpoint.
3. Resume from the last verified byte offset when the file only grew.
4. Reimport that source file when it shrank, was replaced, or the importer
   version changed.
5. Upsert by stable source identity inside a transaction.
6. Advance the checkpoint only after the transaction commits.

For OpenCode SQLite:

1. Open the provider database read-only.
2. Query records newer than the stored message/time high-water mark while also
   allowing stable-ID upserts at the boundary.
3. Commit normalized events and the checkpoint atomically in BorderCollie's
   database.

Cancellation must leave the prior checkpoint intact. A full **Rebuild Index**
operation may be added later as a recoverable maintenance action, but normal
refresh must be incremental.

### Index Recovery

The index is derived entirely from provider histories and the checked-in price
catalog. Recovery is therefore: quit BorderCollie, move
`~/Library/Application Support/BorderCollie/usage-analytics.sqlite3` and its
`-wal`/`-shm` companions aside, then reopen the Usage screen. The next refresh
recreates schema version 1 and imports all discovered sources. Moving the files
aside preserves a recoverable copy; no provider-owned history is modified.

## Pricing Model

### Meaning Of Cost

The displayed value is labeled **Estimated API-equivalent token cost**. It is:

- based on public, first-party, standard API prices;
- priced with the rule effective at the event timestamp;
- independent of Claude and ChatGPT subscription fees;
- exclusive of negotiated discounts, credits, taxes, partner-platform
  premiums, and per-tool fees.

It must never be labeled `actual cost`, `amount billed`, or `subscription cost`.

### Calculation

For an event whose pricing inputs are complete:

```text
estimated cost =
    in × input rate
  + cache-write-5m × cache-write-5m rate
  + cache-write-1h × cache-write-1h rate
  + cache-read × cache-read rate
  + out × output rate
```

Providers with one cache-write rate use the combined cache-write count. Rates
are stored per token even when the source publishes them per million tokens.

Apply documented request-level pricing modifiers only when the event retains
the data needed to prove the modifier, such as a long-context threshold. If a
required dimension is absent, the cost is unavailable or explicitly marked as
assumption-based; it is not guessed silently.

### Effective-Dated Catalog

Each pricing rule includes:

- pricing authority;
- canonical model ID;
- `effectiveFrom` and optional `effectiveUntil`;
- input, cache-write, cache-read, and output rates;
- request-level modifier rules;
- official source URL;
- retrieval timestamp;
- catalog schema version.

Changing the catalog recomputes derived cost from stored tokens. It does not
overwrite the source-reported cost or raw model ID.

Official references used for the initial catalog design:

- [OpenAI GPT-5.6 Sol model pricing](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
- [OpenAI GPT-5.6 Terra model pricing](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [OpenAI GPT-5.6 Luna model pricing](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [OpenAI GPT-5.5 model pricing](https://developers.openai.com/api/docs/models/gpt-5.5)
- [OpenAI Codex token accounting source](https://github.com/openai/codex/blob/main/codex-rs/tui/src/token_usage.rs)
- [Anthropic model and cache pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [Anthropic Messages usage schema](https://platform.claude.com/docs/en/api/go/messages)

### Pricing Catalog Maintenance

1. Verify the standard first-party token prices and effective date on the
   provider's official model or pricing page.
2. Add a new effective-dated rule in `UsagePricingCatalog.rules`; do not edit an
   old rule when the provider changed price at a known date.
3. Add an alias only when an observed raw model ID is demonstrably the same
   first-party model. Unknown gateways remain unpriced.
4. Update the catalog retrieval timestamp and source URL.
5. Extend the price-boundary and cache-class tests, then run the unit bundle and
   non-launching build check. The backend replaces the local catalog and
   reprices stored events on its next refresh.

### Unpriced Events

An event is unpriced when any of these are true:

- the model cannot be mapped to an official canonical model;
- the official provider has no public token price;
- a required token bucket is unknown;
- the effective price interval is missing;
- a pricing modifier is known to apply but cannot be calculated.

Unpriced events remain visible in token views. Cost views report their token and
event coverage instead of treating them as free.

## Aggregation

Store event timestamps in UTC. Resolve day boundaries at query time using the
user's current calendar and time zone so a travel or time-zone change does not
mutate raw records.

Supported ranges:

- 1 day
- 7 days
- 30 days

The interval includes the current local calendar day and the preceding `N - 1`
days. All cards, chart series, percentages, and breakdown rows use the identical
interval and selected-agent set.

Model aliases affect pricing identity only. The breakdown table should show a
human-readable canonical label when known while retaining the raw model ID in
detail or accessibility text.

## User Interface

### Navigation

Add one `Usage` sidebar destination above the individual trackers. Preserve the
native `NavigationSplitView` source-list appearance and stable selection model.
Do not turn the dashboard into a separate window or modal flow.

### Detail Layout

The detail is a vertically scrolling dashboard with system-adaptive colors:

1. Toolbar
   - 24h/7d/30d segmented picker.
   - Manual Refresh action.
2. Header summary
   - Estimated API-equivalent token cost.
   - Exact visible date interval.
   - Pricing/coverage annotation.
3. Hourly/daily chart
   - `Cost` / `Tokens` segmented picker.
   - Use local-hour buckets over an exact rolling 24-hour interval for `24h`;
     use local-calendar day buckets for `7d` and `30d`.
   - Preserve partial first/current-hour buckets and fill missing chart buckets
     with zero without changing the calendar-day breakdown.
   - One series for each enabled agent.
   - Toggleable legend entries for Claude Code, Codex, OpenCode, and Pi.
   - Hide zero-valued agents for the active chart metric. An unpriced agent is
     absent from Cost mode but remains visible in Tokens mode.
   - While the pointer is within 14 points of a visible series, show a selected
     point with dashed guides to both axes and an agent/date/value annotation.
     Leaving the curve or plot clears the selection.
   - Hover hit-testing uses only enabled, nonzero series; a legend-hidden series
     must not capture the pointer.
   - Group line and area marks by agent and use non-overshooting interpolation;
     token and cost curves must never render below zero.
4. Metric strip
   - Total tokens.
   - `in`.
   - `cache-write`.
   - `cache-read`.
   - `out`, with optional `includes <reasoning>` detail.
   - Input cache-hit rate.
   - Output share.
   - Use explicit 8/4/2/1-column responsive layouts. Every breakpoint divides
     the eight metrics evenly, so the strip never leaves an empty grid slot or
     a partially filled final row.
5. Breakdown table
   - Model mode: agent, model, `in`, `cache-write`, `cache-read`, `out`, total,
     cost, cost share, input cache-hit rate, and output share.
   - Day mode: the same detailed accounting grouped by local calendar day.
6. Coverage/error footer
   - Unpriced and partial event counts.
   - Last successful import time.

Use native Swift Charts for the hourly/daily visualization and native table/list
behavior for the breakdown. Detail cards may use semantic system surfaces; the
sidebar and root split panes retain their system backgrounds.

### State Ownership

- Date range, chart metric, breakdown mode, and enabled-agent filters are
  window-scoped UI state. Use `@SceneStorage` where practical.
- Imported events, checkpoints, and the pricing catalog are app-wide persisted
  state owned by an actor-isolated store.
- Import/aggregation lifecycle belongs to a dashboard model owned by the Usage
  detail root.
- Existing quota view models and menu-bar state remain unchanged.

### Empty And Partial States

- No source histories: explain which four local agents are searched and offer
  Refresh.
- Some agents absent: render available agents and identify absent sources.
- Partial records: omit them from complete totals and state the excluded count.
- Unpriced records: include tokens, omit their monetary contribution, and show
  pricing coverage next to cost.
- Import failure: preserve the last successful indexed data and report the
  failing source without clearing the dashboard.

## Proposed File Boundaries

Names may be adjusted during implementation, but responsibilities should stay
separate:

```text
BorderCollie/UsageDashboard/
  UsageAnalyticsModels.swift
  UsageAnalyticsStore.swift
  UsageImportCoordinator.swift
  UsageSourceImporter.swift
  ClaudeCodeUsageImporter.swift
  CodexHistoryUsageImporter.swift
  OpenCodeUsageImporter.swift
  PiUsageImporter.swift
  UsagePricingCatalog.swift
  UsageAggregator.swift
  UsageDashboardModel.swift
  UsageDashboardPresentation.swift
  UsageDashboardView.swift
  UsageAgentVisuals.swift
  UsageDailyChart.swift
  UsageMetricStrip.swift
  UsageBreakdownTable.swift
```

`UsageSourceImporter` is justified because it has four real implementations.
Do not introduce separate factories, repositories, or provider interfaces
unless a second implementation requires the boundary.

## Privacy And Security

- Read provider histories only; never modify them.
- Do not read auth files for historical ingestion.
- Parse only identifiers, timestamps, models, usage, and source-reported cost.
- Do not persist conversation bodies, working-directory names, project paths,
  prompts, responses, reasoning text, or tool inputs/outputs.
- Never log raw JSONL records or database message blobs.
- Error messages may include an agent and sanitized filename but not source
  content.
- Store the analytics database inside BorderCollie's Application Support
  directory with user-only permissions.
- Fixtures committed to tests must be synthetic and contain no copied user
  conversation content or stable local identifiers.

## Correctness Invariants

Each implementation and migration must preserve:

1. No event is counted more than once.
2. `total = in + cache-write + cache-read + out` for complete events.
3. Reasoning is a subset of `out` and is never double-counted.
4. Input cache-hit rate uses `cache-read / observed input`.
5. Output share uses `out / total`.
6. Zero and unknown remain distinguishable.
7. Cost is reproducible from a pricing rule ID and normalized token buckets.
8. Price changes do not overwrite source-reported observations.
9. Failed imports do not advance checkpoints or discard prior indexed data.
10. No conversation content enters the analytics database, logs, or fixtures.

## Acceptance Criteria

The design is implemented only when:

- all four importers pass synthetic parser and deduplication fixtures;
- aggregate totals reconcile with independently calculated fixture totals;
- each complete event satisfies the accounting invariant;
- price boundary dates select the correct effective rule;
- cache-write TTL pricing is covered where the source exposes it;
- missing prices and partial tokens produce explicit coverage, not zero cost;
- `24h` covers exactly 24 elapsed hours ending at query time, while `7d` and
  `30d` use local calendar boundaries consistently;
- the chart, cards, rates, and table share one filter state;
- previews use synthetic stored data and never scan live histories;
- existing quota and menu-bar behavior remains unchanged;
- the non-launching project build succeeds.
