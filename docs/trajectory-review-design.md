# Trajectory: DeepSeek Harness review and BorderCollie design

## Review scope

This review examines DeepSeek Harness's `Trajectory` (`轨迹`) feature at upstream commit [`47f943859bef60e4160492346772ded9b24f765a`](https://github.com/deepseek-ai/deepseek-harness/tree/47f943859bef60e4160492346772ded9b24f765a), committed on 2026-08-13. Pinning the commit matters because the repository describes itself as a developer preview with compatibility-breaking changes expected.

The review is based on static inspection of the source, package documentation, tests, and browser snapshots. The upstream application and test suite were not run locally because the checkout had no installed workspace dependencies and `pnpm` was unavailable. Claims below therefore describe mechanisms present in this commit, not measured runtime behavior.

## Conclusion

Trajectory is an agent-behavior viewer, but only for behavior already visible to DeepSeek Harness. It is not a separate process monitor, screen recorder, OpenTelemetry trace viewer, or inference system that reconstructs behavior after the fact.

The mechanism is:

```text
Harness action
  -> typed event appended to the session log with seq + wall-clock time
  -> durable JSONL history and live session/event stream
  -> browser session keeps a contiguous raw-event window
  -> target-specific state machines correlate related events
  -> Trajectory snapshot groups messages, requests, tools, and compaction
  -> ledger + three-lane overview + local details inspector
```

The visually clear diagram is the last stage of the design. The load-bearing part is the append-only, typed event history. A comparable UI over sources that expose only turn start/end timestamps would be a simplified stand-in: it could truthfully show active turns, but it could not show model requests, nested tool work, TTFT, prompt changes, retries, or compaction with the same fidelity.

## What the user sees

The feature is a second tab in the normal conversation surface. Its browser plugin registers the `Trajectory` view, its localized label, its event definitions, and its view builder; the host-side package entry deliberately does nothing ([client registration](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/index.ts#L22-L64), [empty host entry](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/index.ts#L1-L4)).

The view has three coordinated surfaces:

1. A sticky toolbar controls duration scaling, whole-turn folding, assistant-call folding, and local search.
2. A compact overview projects activity into three lanes: Input, Model, and Tools.
3. A two-column ledger lists the event kind and a concise content preview. Selecting a row or a request opens a resizable inspector containing status, source, hierarchy, request options, token usage, prompt/tool-schema changes, payload/result, and timing where those fields exist.

The upstream browser snapshot demonstrates the intended reading order: system prompt, user turn, numbered assistant request, tool call/result rows, subsequent assistant request, and the next user turn. The tool inspector exposes Summary, Payload, Result, Schema, and Timing tabs ([snapshot](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/apps/web/tests/snapshots/navigation-panes/trajectory.expected.md)).

Trajectory renders these record kinds:

| Record | Source evidence | What it represents |
| --- | --- | --- |
| `SYSTEM` | `request/header` | Initial or changed system prompt and tool catalog |
| `USER` | `user/message` plus inbox classification | A new human turn or a steering message |
| `CONTEXT` | non-user `user/message` source | Plugin- or harness-injected context |
| `ASSISTANT` | step lifecycle, chunks, final message, retry, step end | One model request/reply lifecycle |
| `TOOL` | `tool/call` and `tool/result` | Root tool execution, arguments, result, and error state |
| `SUBTOOL` | code-dispatch start/result events | Nested work emitted beneath a root tool call |
| `COMPACTED` | compaction start/summary/end/checkpoint | Context-compaction request and result |

## End-to-end implementation

### 1. The session log is the source of truth

DeepSeek Harness's core session object owns an append-only event log. Every append receives a contiguous sequence number and a `Date.now()` timestamp, snapshots and validates the payload, deep-freezes the event, appends it to memory, and publishes `session/event` to observers ([`Session.append`](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/core/session/src/index.ts#L569-L655)). The sequence is the causal ordering mechanism; the timestamp is the timing input used later by Trajectory.

Persistence is a separate plugin concern. The JSONL backend accepts contiguous batches through the persistence coordinator, and consecutive assistant text/reasoning/tool-call deltas can be packed into lossless chunk rows to reduce storage size ([JSONL configuration](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/session/session-persistence-jsonl/src/index.ts#L59-L82), [persistence append](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/session/session-persistence/src/coordinator.ts#L662-L709)). Trajectory does not introduce a second telemetry store.

This event-source design explains why completed sessions can be replayed into the same UI as a live session. It also makes the limitation precise: an activity absent from the session log is absent from Trajectory.

### 2. History and live updates carry the same raw events

The host exposes paged session history as raw `SessionEvent` values plus an optional host-computed tool rendering hint. Pages are cut at whole append-origin message boundaries rather than arbitrary row counts, so a page does not split a message's chunks or detach a compaction summary from its replacement ([history API](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/host/apiproxy/src/api/sessions.ts#L264-L283), [pagination](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/host/apiproxy/src/api-proxy.ts#L282-L313)).

Live events use the same data model. The host forwards each appended event as a `session/event` mux frame, and the browser routes that frame into the open session ([host forwarding](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/host/apiproxy/src/api-proxy.ts#L3470-L3494), [client reception](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/sessions/session.ts#L460-L471)).

The browser `Session` retains a contiguous raw-event window. It loads the tail first, prepends older pages, buffers live events during open or gap repair, rejects overlaps, and refetches when it detects a sequence gap ([session window](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/sessions/session.ts#L59-L109), [older-page prepend](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/sessions/session.ts#L364-L409), [live append](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/sessions/session.ts#L646-L676)). This is why the live and historical paths converge before visualization.

### 3. A generic correlation engine turns events into business lifecycles

Trajectory does not scan the raw event array directly in React. The client runtime provides `ConversationNodeDefinition`, a small state-machine interface with:

- `match`, which assigns an event to a stable business identity and marks it as lifecycle start or update;
- `start` and `update`, which fold matching events into typed state;
- `publication`, which chooses immediate, animation-frame, or no UI publication;
- `buildViewNode`, which publishes one target-specific node.

The interface is defined in [`contract/conversation.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/contract/conversation.ts#L164-L228). The assembler dispatches each raw event through all registered definitions, correlates them by `kind + id`, and incrementally applies changed nodes to each registered view builder ([dispatch](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/sessions/conversation-assembler.ts#L337-L384), [view flush](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/runtime/src/client/sessions/conversation-assembler.ts#L259-L315)).

This is a significant architectural choice. Chat and Trajectory are independent projections of the same event window. Trajectory neither reads nor mutates Chat's rendered snapshot; it owns definitions whose `target` is `trajectory` and a separate snapshot builder.

### 4. Trajectory owns state machines for each behavior family

The assistant definition correlates `step/start`, `assistant/chunk`, `assistant/message`, `llm/retry`, and `step/end` by `turn:step`. Text, reasoning, tool-call arguments, usage, and first-token time are incrementally assembled from chunks. Ordinary content deltas publish at animation-frame cadence rather than forcing one React update per chunk ([assistant chunk fold](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts#L107-L165), [assistant lifecycle](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts#L277-L358)).

The assistant's recorded timing fields are:

- request start: the `step/start` event time;
- first token: the first token-delta event time;
- completion: the final `assistant/message` event time;
- usage: accumulated usage chunks, or final message usage when chunks did not supply it.

The tool definition correlates root `tool/call` and `tool/result` events by call ID. It additionally folds nested `tool/code-dispatch-start` and `tool/code-dispatch` events into a parent/child tree, rejecting cycles and limiting depth to 256 ([tool correlation](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-tool-definition.ts#L112-L158), [tool lifecycle](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-tool-definition.ts#L218-L263)). This nested event family, rather than a generic subprocess observer, is what produces `SUBTOOL` rows.

Other definitions classify user versus steering messages, retain request headers and prompt changes, fold compaction events, and carry turn/session endings. Request headers preserve complete system-prompt and tool-catalog snapshots so the inspector can show their initial value or diff ([message classification](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-message-definitions.ts#L47-L121), [request headers](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-request-header-definition.ts#L9-L80), [compaction](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-compaction-definition.ts#L30-L110)).

### 5. The target snapshot reconciles independently assembled contributions

Each definition publishes a keyed `TrajectoryContribution`: node, assistant lifecycle, tool tree, request header, compaction, turn end, or session end. `TrajectorySnapshotBuilder` keeps those contributions sorted by their event sequence anchor and derives:

- finalized event nodes and their turn/step locations;
- assistant and compaction requests;
- the currently streaming assistant;
- running tool calls;
- the tool schema that applied when each call occurred.

It also repairs display semantics at session boundaries: a still-running compaction becomes interrupted, and a turn error is attached to the last assistant request in that turn ([contribution contract](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-contract.ts#L11-L66), [snapshot builder](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-snapshot-builder.ts#L138-L282)).

Stable keys matter here. Streaming updates replace a contribution with the same key instead of appending a new visual row. Structural changes trigger a sorted rebuild; content-only changes update the existing position.

### 6. A second fold creates the visual ledger

`deriveTrajectoryLayout` converts the target snapshot into ordered turns, step/message groups, and display cells. It interleaves prompt changes, compactions, user/context messages, assistant replies, root tools, and nested tools in event-sequence order. Assistant text and reasoning stay in one `ASSISTANT` cell; tool-call blocks expand into adjacent `TOOL` cells and recursively expanded `SUBTOOL` cells ([layout fold](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/layout.ts#L133-L254), [assistant expansion](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/layout.ts#L666-L756), [nested-tool expansion](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/layout.ts#L977-L1042)).

The layout preserves two representations of content:

- a compact single-line preview for scanning;
- full input, output, reasoning, source blocks, prompt snapshots, and schemas for the details inspector.

It also attaches disjoint input, cache-read, cache-write, output, and reasoning token fields to assistant and compaction records when the source provides them.

## How the overview timeline works

The timeline is derived from the same cells as the ledger, so row selection and time selection share record indexes. Record kinds map to three fixed lanes:

| Lane | Records |
| --- | --- |
| Input | System, user, and context |
| Model | Assistant and compaction |
| Tools | Tool and subtool |

There are four internal projection modes ([timeline model](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/timeline.ts#L7-L35), [projection math](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/timeline.ts#L64-L180)):

| Mode | Horizontal position | Width | Idle gaps |
| --- | --- | --- | --- |
| `sequence` | record order | equal | absent |
| `duration` | recorded time after idle compression | recorded duration | removed |
| `time` | wall-clock time | point marker | preserved |
| `actual` | wall-clock time | recorded duration | preserved |

The current toolbar exposes only the `Duration` toggle. `sequence` is the default; enabling Duration selects `duration`. The `actualTime` control exists but is rendered with `hidden`, so `time` and `actual` are implemented but not currently user-accessible ([mode selection](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryView.tsx#L271-L286), [hidden control](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryToolbar.tsx#L74-L85)). This is important when interpreting the demo: the default diagram expresses operation order, not elapsed wall-clock proportion.

Assistant spans can be split visually into TTFT and decoding. TTFT is `firstTokenTime - stepStartTime`; decoding is `completedTime - firstTokenTime`. The UI shows these values after a 500 ms hover only when all three timestamps are finite and ordered ([timing derivation](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryTimeline.tsx#L50-L80), [span rendering](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryTimeline.tsx#L671-L723)). Tool spans use `tool/result.time - tool/call.time`. User, context, and system records are point-like zero-duration events.

Interaction is directly coupled to the ledger:

- wheel gestures zoom around the cursor;
- left drag selects an inclusive time interval and marks every overlapping record;
- clicking a block selects its ledger row;
- clicking whitespace focuses the nearest row;
- right drag pans a zoomed viewport;
- right click, double click, or Escape clears the selected interval.

The pointer and wheel implementation is in [`TrajectoryTimeline.tsx`](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryTimeline.tsx#L348-L520). The overlap predicate is inclusive, `span.start <= range.end && span.end >= range.start`, which makes point markers selectable ([focus selection](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/timeline.ts#L182-L200)).

## Why the UI remains usable on long sessions

The implementation contains explicit long-session mechanisms rather than relying on React to render the entire log:

- history opens at the current tail and loads older pages on demand or near the top;
- the ledger virtualizes when any older history remains or when the visible record count exceeds 100;
- it renders 12 overscan rows and anchors the virtualizer to the end;
- stable semantic row identities survive prepending older history;
- zero-height request separators are grouped with the next measurable record;
- scrolling upward disables tail-follow so streaming output does not interrupt inspection;
- content-only streaming frames reuse virtual row structure and measurements;
- local search indexes stable records and throttles streaming re-index work to at most once per three seconds.

The constants and virtualizer configuration are visible in [`TrajectoryTable.tsx`](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryTable.tsx#L31-L36) and [its virtualizer setup](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryTable.tsx#L1769-L1837). Scroll anchoring and tail-follow are handled separately from data folding ([scroll behavior](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/TrajectoryTable.tsx#L2137-L2207)). The search index includes previews, full input/output/reasoning, schemas, tool IDs, message sources, and prompt snapshots ([search index](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-search-index.ts#L39-L131)).

## Strong design choices

### The data model earns the visualization

Sequence, time, lifecycle identity, and parent/child call identity are captured before presentation. The UI does not guess that adjacent text means one request or that a process-looking row belongs to the preceding tool. This is why the overview and ledger can stay synchronized under streaming, history paging, retries, cancellation, and compaction.

### Raw evidence and presentation remain separate

The browser retains raw events, the generic assembler owns correlation, Trajectory's snapshot owns its business projection, and React owns view-local selection/folding/search. This separation permits a different Chat projection without making either view depend on the other's rendered state.

### Unknown timing is shown as unknown

In-flight assistant and tool rows do not continuously fabricate durations from `now`. Their time is blank until a terminal event exists, and the timeline uses a start marker rather than an invented live span. That preserves the distinction between recorded history and a UI estimate.

### Summary and detail use the same record

The compact ledger is not a lossy export. Selecting the row opens the full evidence already attached to that cell. The hierarchy links between request, assistant message, tool, and subtool make the inspector navigable without crowding the timeline.

## Limitations and risks

### It observes only harness events

Trajectory cannot see arbitrary child processes, filesystem work, network requests, editor actions, or human activity unless a DeepSeek Harness plugin emits the corresponding typed events. `SUBTOOL` specifically represents `tool/code-dispatch-*`, not generic subprocess descendants. Calling the feature a universal agent tracker would be incorrect.

### Timing measures event append boundaries

The timestamps come from `Date.now()` when events are appended. They are wall-clock timestamps, not a monotonic clock, provider-side timestamps, or profiler spans. Duration accuracy therefore depends on producers emitting start/end events close to the underlying operation. A wall-clock adjustment could also distort a span; the layout clamps negative durations to zero rather than detecting clock discontinuity.

### Some interruption records are synthetic projections

When a turn closes without a final assistant or tool result, Trajectory creates display nodes at fractional sequence positions such as `boundary.seq - 0.9` and `boundary.seq - 0.8` to freeze interrupted content ([assistant interruption](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts#L201-L239), [tool interruption](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/packages/client/ui-trajectory/src/client/trajectory-tool-definition.ts#L160-L201)). Those rows are useful and evidence-based, but they are projections inferred from a closed boundary, not literal persisted events.

### Loaded-window scope is partial by design

Selection, search, request totals, and the overview operate on the currently loaded history window. An ellipsis/load-earlier control marks an omitted prefix rather than assigning fabricated duration to it. A user must load older pages before treating the view as a whole-session total.

### The privacy surface is much broader than BorderCollie's current one

Trajectory retains and renders prompts, assistant reasoning, complete system prompts, tool catalogs and JSON schemas, tool arguments, tool results, message-source metadata, provider/model names, and token usage. Its in-memory search index also includes those fields. This is appropriate for a local harness debugger, but it conflicts with BorderCollie's existing rule that imported analytics must not persist prompts, responses, tool content, working directories, or raw paths.

### The presentation package is large

At this commit, the feature contains separate event definitions, snapshot assembly, layout folding, timeline math and interaction, search, virtualization, ledger rendering, inspector rendering, and CSS. The architecture has clear layers, but reproducing the UI before defining a smaller product scope would import substantial implementation and testing cost.

## Relevance to BorderCollie

BorderCollie's current evaluation model stores accounting events and `UsageActiveTurn` intervals. A turn has session identity, model, start/end time, and an `exact` or `inferred` timing label. Reports deliberately recompute token/cost summaries and merge active intervals to derive additive agent time, effective wall time, and human idle. That model can support a truthful evaluation-level timeline of sessions and turns.

It cannot currently support a DeepSeek-equivalent behavior ledger. The stored turn contains no event kind, step/request identity, parent tool call, prompt change, tool start/end, retry, compaction, or display payload. Even when an upstream agent log contains some of those facts, the current importer normalizes only accounting events and complete active turns.

The transferable lesson is therefore the data path, not the React appearance:

1. Audit each supported source for durable lifecycle events and record an explicit fidelity matrix.
2. If detailed behavior is a product goal, introduce a normalized activity-event model separate from `UsageEvent` and `UsageActiveTurn`.
3. Preserve source identity, session, turn/step, stable event ID, parent ID, start/end timestamps, event kind, status, and timing quality before designing the diagram.
4. Decide the payload policy independently. A metadata-only trajectory can retain tool names and durations without persisting prompts, reasoning, arguments, results, paths, or credentials.
5. Derive both the ledger and the overview from the same normalized records so selection cannot drift.
6. Keep source gaps visible. Providers with only turn boundaries should render coarser spans rather than synthetic tool behavior.

The detailed contract below refines those requirements. Before implementation, the source audit must still prove which fields are available for Codex, Claude Code, OpenCode, and Pi; without that evidence, a detailed cross-agent Trajectory would be unsupported.

## Review verdict

DeepSeek Harness Trajectory is well conceived because it treats agent behavior as a replayable event-sourced domain, then builds a dedicated read model for visualization. Its most reusable ideas are:

- typed lifecycle events captured at the execution boundary;
- one raw history path for live and historical views;
- target-specific incremental correlation rather than UI-side adjacency guesses;
- shared identities between timeline, ledger, and inspector;
- explicit unknown/inferred states;
- paging, virtualization, and tail-follow designed together;
- a compact overview paired with evidence-rich local inspection.

For BorderCollie, copying the visual surface first would solve the wrong problem. The approved direction is a metadata-only trajectory: retain behavior identity, hierarchy, status, and timing where a source proves them, while continuing to exclude conversation and tool payloads. The design below makes the source-capability audit the first implementation gate so the diagram cannot outrun its evidence.

# BorderCollie metadata-only trajectory design

## Design status

This section defines the proposed architecture and implementation plan. It does not claim that detailed lifecycle evidence is already available from every supported source. The current implementation proves only the outer turn boundaries summarized in [Current source baseline](#current-source-baseline); Stage 0 must audit the remaining source schemas before detailed import code is accepted.

The product decision is:

- build a native SwiftUI trajectory for locally indexed Codex, Claude Code, OpenCode, and Pi sessions;
- retain `UsageActiveTurn` as the source of truth for outer turn timing;
- add a separate metadata-only activity model for finer behavior;
- render only source-proven detail and label availability (complete, partial, or unavailable) separately from exact/inferred timing quality;
- never persist or index prompts, responses, reasoning text, tool arguments/results, commands, paths, credentials, or raw source records.

This is not a source-compatible port of DeepSeek's React package. The upstream [MIT license](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/LICENSE) permits reuse with its notice preserved, but BorderCollie should transfer the event/projection architecture and reimplement the presentation in SwiftUI.

## Product boundary

### Goals

1. Let the user select any locally indexed session and inspect its turns in source order.
2. Show model requests, first-output timing, tools, nested tools, retries, and compaction only for source formats that expose defensible lifecycle evidence.
3. Keep a coarse but truthful turn timeline available when fine-grained evidence is unavailable.
4. Explain source coverage in the UI so absence of a row is not confused with proof that an activity did not occur.
5. Keep timeline, ledger, selection, and inspector as projections of the same stable record identities.
6. Preserve current incremental import, source-reset recovery, atomic checkpoints, error isolation, and local-only storage behavior.
7. Remain useful for long sessions without changing the 30-second live-quota polling path or launching agent processes.

### Non-goals

- Capturing screens, editor actions, arbitrary subprocesses, filesystem operations, or network requests.
- Modifying, instrumenting, or wrapping the supported agents.
- Reconstructing a lifecycle from adjacent text when the source does not provide a stable identity or documented boundary.
- Storing or displaying transcripts, prompts, assistant content, reasoning, commands, tool payloads/results, schemas, working directories, or project names.
- Reproducing DeepSeek's payload search, prompt diffs, schema inspector, or live event stream.
- Combining multiple sessions into one trajectory. Evaluation Runs remains the cross-session/time-range analysis surface.
- Including subscription-quota utilization.
- Treating an inferred boundary as exact, or a missing terminal event as a completed span.

### Navigation decision

Add `Trajectory` as its own sidebar destination rather than placing it inside `Evaluations`.

The two surfaces answer different questions:

| Surface | Scope | Question |
| --- | --- | --- |
| Usage | Time range across agents | How many tokens and how much API-equivalent cost? |
| Evaluations | Explicit run plus selected sessions | What did this evaluation consume, and how much active/effective time did it take? |
| Trajectory | One local session | What behavior occurred, in what order, and for how long? |
| Live quota | Current provider limits | How much quota has been consumed? |

Requiring an Evaluation Run before opening a session would add an unrelated workflow dependency. Conversely, putting a multi-session trajectory inside an evaluation would blur source order and parent/child identity. The Trajectory destination may offer an `Open in Trajectory` action from an Evaluation session row later, but it owns its own session selection and view state.

## Current source baseline

BorderCollie already discovers four local history sources and incrementally imports them through `UsageSourceImporter`. The proven outer-boundary fidelity is:

| Source | Current session/turn evidence | Current quality | Fine-grained trajectory status |
| --- | --- | --- | --- |
| Codex | `event_msg.task_started` to `event_msg.task_complete` | Exact | Unproven until Stage 0 audits `response_item` and related records |
| OpenCode | Assistant `time.created` to `time.completed` | Exact | Unproven until Stage 0 audits message parts and tool tables |
| Claude Code | Human message to terminal assistant message | Inferred | Unproven; tool-use content must not be mistaken for timed tool lifecycle evidence |
| Pi | Human message to terminal assistant message | Inferred | Unproven; tool-use content must not be mistaken for timed tool lifecycle evidence |

“Unproven” is intentional. A source may contain a tool name without containing a trustworthy tool start, result, parent identity, or completion timestamp. The audit must assess each field separately rather than assigning one blanket fidelity level to an agent.

Current-code evidence:

- `UsageSourceImporter` is the existing four-provider normalization boundary (`BorderCollie/UsageDashboard/UsageImportSupport.swift:152-157`).
- Claude Code derives inferred turns from human and terminal assistant messages (`BorderCollie/UsageDashboard/UsageImporters.swift:170-216`).
- Codex derives exact turns from explicit task markers (`BorderCollie/UsageDashboard/UsageImporters.swift:344-387`).
- Pi derives inferred turns from user and terminal assistant messages (`BorderCollie/UsageDashboard/UsageImporters.swift:498-555`).
- OpenCode derives exact turns from assistant-created/completed timestamps (`BorderCollie/UsageDashboard/UsageImporters.swift:714-735`).
- `UsageActiveTurn` already carries stable session/source identity, interval, and timing quality (`BorderCollie/UsageDashboard/UsageEvaluationModels.swift:12-68`).
- `UsageAnalyticsStore.apply(_:)` already commits events, turns, and checkpoints in one transaction (`BorderCollie/UsageDashboard/UsageAnalyticsStore.swift:84-100`).
- The current privacy contract forbids imported content and raw paths (`docs/usage-dashboard-design.md:677-690`).

## Architecture

### Data flow

```text
Read-only local agent histories
  -> existing source discovery and incremental checkpoints
  -> one provider importer pass
       -> UsageEvent                 token/cost evidence
       -> UsageActiveTurn            outer active interval
       -> TrajectoryActivity         fine-grained metadata, when proven
       -> TrajectoryCapability       declared per-session source coverage
  -> one SQLite transaction per source batch
  -> session query joins turns + activities + linked usage metadata
  -> pure TrajectoryProjection derives hierarchy, rows, lanes, and time spans
  -> @MainActor TrajectoryModel owns filters, selection, loading, and errors
  -> SwiftUI overview + ledger + metadata inspector
```

Trajectory must not rescan histories through a second importer hierarchy. `UsageImportBatch` should be extended with activities and capability declarations so usage, turns, trajectory metadata, and the checkpoint describe the same consumed source prefix. `UsageAnalyticsStore.apply(_:)` remains the atomic boundary.

### Ownership boundaries

| Layer | Owner | Responsibility | Must not do |
| --- | --- | --- | --- |
| Source discovery | Existing import support | Resolve configured locations, file identity, offsets, and reset conditions | Interpret behavior |
| Provider importer | Existing four importers | Parse source semantics, normalize IDs/boundaries, emit usage/turn/activity/capability records | Produce SwiftUI rows or retain raw payloads |
| Store | `UsageAnalyticsStore` | Schema migration, atomic upsert/reset, indexed session reads | Infer parentage or timing |
| Backend | New `TrajectoryBackend` | Refresh through `UsageAnalyticsBackend`, page session summaries, load one session report | Render views or mutate source histories |
| Projection | New pure `TrajectoryProjection` | Validate hierarchy, order records, derive lanes/time coordinates, calculate display-only durations | Read disk/database or invent missing evidence |
| View model | New `TrajectoryModel` | Main-actor async state, filters, paging, selection, stale-result rejection | Parse provider records |
| SwiftUI | New Trajectory views | Native controls, overview, ledger, inspector, accessibility | Own source truth or independently recalculate record identity |

No new protocol is required for a single backend or projection implementation. The existing `UsageSourceImporter` protocol already has four implementations and is the correct provider variation boundary.

## Domain contracts

### Outer turns remain canonical

`UsageActiveTurn` remains the sole persisted outer turn interval. Trajectory reads those records instead of copying them into a second table. This preserves the existing contract that a turn begins at human submission and ends at terminal agent completion, including model generation, tools, subprocess time, and network waits while excluding the following human idle gap.

Fine-grained activities may reference a turn by its stable normalized ID. The reference is logical rather than a mandatory SQL foreign key because:

- an activity can be observed before a turn has a terminal boundary and is therefore persisted;
- session-level compaction or source records may not belong to a completed turn;
- a malformed or partial source must remain inspectable without fabricating a parent turn.

An activity with no valid turn remains session-scoped and is shown as unscoped. The projection must not attach it to the nearest turn by timestamp.

### Normalized activity

The implementation should use a record conceptually equivalent to:

```swift
enum TrajectoryActivityKind: String, Codable, Sendable {
    case modelRequest
    case tool
    case subtool
    case retry
    case compaction
}

enum TrajectoryActivityStatus: String, Codable, Sendable {
    case observed       // a source-proven point event
    case open           // start exists; no terminal evidence exists
    case succeeded
    case failed
    case interrupted
}

enum TrajectoryBoundaryQuality: String, Codable, Sendable {
    case exact
    case inferred
}

enum TrajectoryOrderQuality: String, Codable, Sendable {
    case sourceSequence
    case sourceRecord
    case timestamp
}

struct TrajectoryActivity: Equatable, Sendable, Identifiable {
    let id: String
    let agent: UsageAgent
    let sessionKey: String
    let turnID: String?
    let parentActivityID: String?

    let kind: TrajectoryActivityKind
    let status: TrajectoryActivityStatus
    let sourceOrder: Int64
    let orderQuality: TrajectoryOrderQuality

    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let firstOutputAtMilliseconds: Int64?
    let startQuality: TrajectoryBoundaryQuality
    let endQuality: TrajectoryBoundaryQuality?
    let firstOutputQuality: TrajectoryBoundaryQuality?

    let rawModelID: String?
    let toolName: String?
    let attempt: Int?
    let failureCategory: TrajectoryFailureCategory?
    let usageEventID: String?

    let sourceKey: String
    let sourceID: String
    let sourceSchemaVersion: String
    let importerVersion: Int
}
```

This type is a contract, not a requirement to keep all declarations in one file. Its invariants are:

1. IDs are deterministic and derived from an agent plus a hashed stable source lifecycle ID. A byte offset is a fallback only when the audit proves source replacement triggers a full reset.
2. `sourceOrder` is deterministic within a session. Equal values are ordered by stable activity ID. `orderQuality` states whether order came from an explicit source sequence, source record order, or timestamp fallback.
3. Terminal spans require `endedAtMilliseconds >= startedAtMilliseconds`, a terminal status, and an `endQuality`. An `open` activity has no end. A point event uses equal start/end timestamps and status `observed`.
4. First-output time is retained only when the source identifies the first model output boundary; the UI must call it TTFT only when the audited source semantics actually mean first token.
5. `parentActivityID`, `turnID`, and `usageEventID` are set only from source-proven identities. Timestamp proximity is not correlation evidence.
6. A tool activity stores only a sanitized tool name. A model activity stores only a model identifier. Free-form previews are not part of the model.
7. Failure detail is an allow-listed category such as timeout, cancelled, tool error, or unknown; raw error messages are excluded.
8. Cycles, cross-session parent links, and self-parent links are rejected by normalization or surfaced as sanitized import issues. Orphans remain root-level records rather than being silently discarded.

### Capability is data, not an assumption

An empty tool lane is ambiguous: the session might not have used tools, or its source might not expose tools. The store therefore needs explicit per-session capability rows, conceptually:

```swift
enum TrajectoryCapabilityFamily: String, Codable, Sendable {
    case turnTiming
    case modelTiming
    case firstOutputTiming
    case tools
    case toolNesting
    case retries
    case compaction
}

enum TrajectoryCapabilityAvailability: String, Codable, Sendable {
    case unavailable
    case partial
    case complete
}

struct TrajectoryCapability: Equatable, Sendable {
    let agent: UsageAgent
    let sessionKey: String
    let sourceKey: String
    let family: TrajectoryCapabilityFamily
    let availability: TrajectoryCapabilityAvailability
    let timingQuality: TrajectoryBoundaryQuality?
    let sourceSchemaVersion: String
    let importerVersion: Int
}
```

Capabilities are emitted by the provider importer after it identifies the source schema; they are not inferred from whether a particular event kind happened to occur. `partial` means the source exposes only part of the required identity or boundary set. Availability and timing quality are separate axes: a complete lifecycle can still use inferred timestamps.

The UI uses fixed local copy for each capability state. Importers must not persist raw schema descriptions or unsupported source fragments as explanatory text.

### Identity and ordering

The source adapter owns normalization because only it understands the source's lifecycle keys. The following rules apply:

- `sessionKey` continues to use BorderCollie's one-way normalized source/session identity.
- `sourceKey` continues to identify the imported file or database independently from a session.
- `sourceID` identifies the source lifecycle; `id` namespaces it by agent.
- A root tool and subtool use explicit source call/parent IDs. Nesting by temporal containment or adjacency is prohibited.
- The ledger's canonical order is `(sourceOrder, startedAtMilliseconds, id)`.
- Wall-clock order is a display mode, not the canonical causal order.
- Reimporting unchanged input must reproduce identical IDs and order.

### Timing semantics

Trajectory exposes three explicitly named projections:

| Mode | Position | Span width | Idle gaps | Purpose |
| --- | --- | --- | --- | --- |
| Order | Canonical source order | Equal record slots | Removed | Reliable behavioral reading order |
| Active time | Recorded timestamps mapped across the union of active turns | Recorded duration | Human idle removed | Compare work inside a session |
| Clock time | Recorded wall-clock timestamp | Recorded duration | Preserved | Investigate when work and idle occurred |

`Order` is the default because it remains valid across sources with unequal timing fidelity. The selected mode must be visible beside the axis; an order diagram must never look like a duration chart.

For Active time, the projection uses the same union-of-turn-intervals concept as Evaluation Runs. It removes only gaps outside the union of known active turns. An activity outside every known turn is not forced into the compressed axis; it remains in the ledger and is marked unscoped. Clock time remains available for inspecting it.

Unknown timing rules:

- An open activity renders a start marker, not a span extended to `Date.now()`.
- A missing first-output boundary produces no TTFT value.
- Inferred boundaries are visually and accessibly labeled.
- Negative or reversed intervals are rejected, not clamped.
- Durations are source-boundary durations, not CPU time or provider-side latency.
- Refreshing a still-active session may change an open activity to terminal, but prior terminal data is never rewritten from a weaker inference.

### Usage linkage

Trajectory does not duplicate token or price fields. When a provider supplies a stable relationship between a model activity and an existing `UsageEvent`, `usageEventID` links them and the inspector reads normalized token/cost values from the accounting record. If the relationship is not source-proven, the inspector shows usage as unavailable rather than assigning the nearest usage record.

This preserves pricing as an independent effective-dated concern and prevents trajectory import from becoming a second accounting path.

## Persistence contract

### Schema

Advance `UsageAnalyticsStore.schemaVersion` from 3 to 4 and add:

1. `trajectory_activity`, containing the normalized activity fields above.
2. `trajectory_capability`, with a primary key of `(agent, session_key, family)` plus source, schema, importer version, availability, and optional timing quality.

Required indexes:

- `trajectory_activity(session_key, source_order, started_at_ms)` for a session ledger;
- `trajectory_activity(session_key, started_at_ms, ended_at_ms)` for timeline reads;
- `trajectory_activity(agent, source_key)` for source reset/removal;
- `trajectory_activity(parent_activity_id)` for hierarchy resolution;
- `trajectory_capability(agent, source_key)` for source reset/removal.

Do not add a raw JSON, payload, preview, command, path, prompt, response, or error-message column. Migration from schema 3 creates empty trajectory tables and preserves all existing usage, turn, pricing, evaluation, and checkpoint data.

### Atomic import and reset

Extend `UsageImportBatch` with `activities` and `trajectoryCapabilities`. `UsageAnalyticsStore.apply(_:)` must validate that every emitted record belongs to `batch.agent`, then perform all mutations in its existing transaction:

1. For reset or removed source keys, delete usage events, active turns, trajectory activities, trajectory capabilities, and checkpoints for that source.
2. Upsert usage events, active turns, activities, and capabilities.
3. Advance checkpoints last.

Any failure rolls back the whole source batch. A truncated, replaced, or importer-version-changed source is fully rebuilt. A parse failure before commit preserves the prior indexed prefix and checkpoint.

JSONL importers may retain pending lifecycle correlation in the checkpoint high-watermark, but only as metadata: hashed IDs, timestamps, kinds, nesting IDs, and allow-listed names. They must not put payload text into checkpoint state. A start record should upsert an `open` activity; a later terminal record replaces it under the same stable ID.

### Read and error isolation

- Histories remain read-only.
- Historical refresh stays user/screen driven and does not join quota polling.
- One agent import failure must not erase or hide the prior indexed data of that agent or any other agent.
- Schema drift produces a sanitized import issue and does not advance the affected checkpoint.
- Database and source errors may name the agent and a sanitized filename, but never record contents or raw paths.
- The existing Application Support database location and user-only permissions remain unchanged.

## Query and projection contracts

### Session list

`TrajectoryBackend` derives session summaries from the union of usage events, active turns, activities, and capability rows. This lets an incomplete session remain discoverable even when it has no terminal turn or billable usage record.

The destination provides agent and period filters. Period choices are 24h, 7d, 30d, and All; filter state is window-scoped with `@SceneStorage`. Sessions sort newest first and load in pages of 200. A `Load earlier` row makes partial list scope explicit.

Because transcript titles and project paths are prohibited, a session is labeled from non-sensitive metadata such as agent, start time, model set, duration, and an abbreviated local session key. It is never named from conversation content or a working directory.

### Session report

A session report contains:

- one session summary;
- canonical `UsageActiveTurn` rows;
- normalized trajectory activities;
- capability declarations;
- only the `UsageEvent` rows linked by proven `usageEventID` values;
- sanitized import/coverage issues relevant to that session.

The backend does not build view rows. `TrajectoryProjection` consumes the report and produces immutable display records with stable IDs, hierarchy depth, lane, canonical order, projected time span, evidence badges, and linked summary metrics.

### Hierarchy validation

The projection:

1. indexes activities by ID;
2. accepts a parent only when it exists in the same session and does not create a cycle;
3. places an invalid or missing-parent activity at the session root with a coverage warning;
4. nests subtools only under source-proven tool parents;
5. groups activities under a turn only through `turnID`;
6. keeps retry point events beside their source-proven model request when linked, otherwise at the turn/session root.

The same flattened projection supplies the overview, ledger, and inspector. Views exchange record IDs, never row indexes, so filtering, folding, or paging cannot make selection refer to a different activity.

## Presentation contract

### Layout

The Trajectory destination uses a native `HSplitView` inside the root detail column:

- left: paged inset session list;
- right: selected session detail;
- toolbar: period, agent filter, Refresh, and timeline mode;
- detail header: agent, date range, models, turn/activity counts, and compact capability summary;
- fixed overview: Turn, Model, and Tools lanes;
- ledger: hierarchical activity rows;
- inspector: metadata for the selected row.

This follows the existing Evaluations choice to use a real `NSSplitView` rather than nesting another `NavigationSplitView`. The root window continues to own its minimum size.

The overview lanes are:

| Lane | Records |
| --- | --- |
| Turn | `UsageActiveTurn` intervals and unscoped boundary markers |
| Model | model requests, first-output milestone, retry, and compaction |
| Tools | tools and recursively indented subtools |

The ledger shows kind, allow-listed name/model, status, start, duration, and evidence quality. It has no content-preview column. The inspector may show identity, source kind, hierarchy, timestamps, derived duration/TTFT, normalized token buckets and cost when linked, and capability explanation. It has no Payload, Result, Prompt, Reasoning, Schema, or Command tab.

### Interaction

- Selecting a block selects and reveals the same ledger record.
- Selecting a ledger row highlights the same overview block and opens the inspector.
- Hover may show duration and TTFT only when their boundaries are valid.
- Turn and tool groups can be folded without changing record identity.
- A range selection highlights records whose known spans overlap the inclusive range; point records participate at their timestamp.
- Search/filter covers only kind, status, model identifier, sanitized tool name, and failure category.
- Clear selection uses Escape and an explicit close control in the inspector.

The first implementation loads all metadata records for one session. Before adding detail paging or custom virtualization, measure a synthetic 10,000-activity session. If interaction or scrolling misses the performance gate defined below, add SQL paging and stable scroll anchoring as a separate stage. This avoids importing DeepSeek's web-specific virtualizer before SwiftUI demonstrates the same need.

### Native presentation rules

- Use `UsageDesign` tokens for all spacing, radii, and metric fonts.
- Use `GroupBox` for titled containers and `.continuous` rounded shapes.
- Do not nest scroll views. The ledger `Table` owns its scrolling; the overview and inspector remain outside that scroll container.
- Use sentence case and native toolbar controls.
- Colour reinforces lane and status labels but is never the only channel.
- Changing durations use `.contentTransition(.numericText())` where refresh updates an open session.
- Empty/error states use `ContentUnavailableView` with Refresh when recovery is possible.
- Previews inject synthetic session reports and never open histories, SQLite, credentials, or network connections.
- Every timeline element and ledger row exposes kind, status, timing quality, start, duration, and hierarchy through accessibility labels/values.

## Privacy and security contract

Persisted and searchable fields are allow-listed.

Allowed:

- agent and hashed session/source/lifecycle identifiers;
- event kind, parent/turn relationship, source order, and status;
- timestamps and exact/inferred quality;
- model identifiers;
- sanitized tool names, limited to 128 Unicode scalar values with control characters removed;
- retry attempt and allow-listed failure category;
- source schema and importer versions;
- logical links to existing normalized usage events;
- capability availability and quality.

Prohibited:

- user, system, assistant, or reasoning text;
- transcript/session titles derived from content;
- tool arguments, results, schemas, commands, patches, and terminal output;
- filenames from tool activity, working directories, project/repository names, and raw source paths;
- URLs, request/response bodies, headers, credentials, cookies, and tokens;
- raw JSONL records, OpenCode message blobs, or free-form error messages;
- an in-memory search index over any prohibited source field.

The parser should select allowed values directly from each source object and discard the object before returning the batch. It must not serialize a redacted copy of the raw record; an allow-list is safer because new upstream fields remain excluded by default.

Any later proposal for an opt-in full-content debugger is a separate product and privacy decision. It must not reuse this schema by quietly adding payload columns.

## Source-adapter contract

Stage 0 must produce an evidence table for each provider and source schema version with these columns:

| Question | Required evidence |
| --- | --- |
| Session identity | Stable source field and normalization rule |
| Turn identity | Stable start/end correlation or explicit reason it is inferred |
| Model request | Stable request/step ID, start, terminal marker, and model relationship |
| First output | Exact source event semantics; distinguish first token from first stored chunk/message |
| Tool lifecycle | Stable call ID, call time, result time, and terminal/error semantics |
| Nesting | Explicit parent call ID; temporal containment is insufficient |
| Retry | Stable association with a model request and attempt/status semantics |
| Compaction | Explicit start/end or point-event semantics |
| Ordering | Explicit sequence, source record order, or timestamp fallback |
| Usage link | Stable relationship to the normalized usage record |
| Privacy | Source fields read, fields retained, fields discarded |

Every supported mapping requires a synthetic fixture and a code comment naming the audited source field. If a required identity or boundary is absent, the importer emits an unavailable/partial capability and no synthetic activity.

Provider schema changes increment that provider's importer version. The reset/rebuild path is the compatibility mechanism; adapters do not carry speculative fallbacks for unobserved versions.

## Failure semantics

- `open` means no terminal evidence was imported; it does not necessarily mean the agent is still running.
- `interrupted` requires an explicit cancellation/session/turn boundary whose semantics prove interruption.
- `failed` requires an explicit source failure status. An absent result is not failure.
- Unknown parentage stays unscoped/root-level.
- Unsupported capability and no observed activity are displayed differently.
- If a source record has valid usage but invalid trajectory metadata, retain the usage event, report the sanitized trajectory issue, and advance only if the importer can deterministically skip that trajectory fragment. A structural ambiguity that could corrupt subsequent correlation fails the source batch and preserves the checkpoint.
- A failed refresh preserves the last successful session report while showing the error, matching the current dashboard's stale-data behavior.

## Implementation plan

### Stage 0: source capability audit — blocking gate

1. Pin the currently installed/source-supported versions or recognizable schema variants for Codex, Claude Code, OpenCode, and Pi.
2. Inspect their durable local records read-only. Record exact field paths, identity rules, timestamp semantics, and counterexamples in the Current source baseline table or a linked appendix in this document.
3. Classify every capability family as unavailable, partial, or complete, with separate exact/inferred timing quality.
4. Create minimal synthetic fixtures representing only the audited structures. Do not copy local conversation content or stable local identifiers.
5. Confirm whether first-output evidence means first token, first streamed chunk, or only final message. Use the precise user-facing term.
6. Confirm which fine activities can link to existing usage events without timestamp-nearest matching.

Exit gate: every proposed importer mapping has a source mechanism and synthetic fixture; unknown fields remain unavailable. If no source proves fine-grained behavior, stop after shipping only the existing turn trajectory rather than inventing detail.

### Stage 1: domain model and schema migration

1. Add trajectory activity, capability, status, quality, order, failure-category, session-summary, and session-report models.
2. Add schema-version-4 migration, tables, indexes, row decoding, upserts, and source-key deletion.
3. Extend `UsageImportBatch` and import reports with activities and capabilities.
4. Extend atomic apply validation and transactions to cover the new records.
5. Add store queries for paged session summaries, one session's turns/activities/capabilities, and linked usage events.

Validation gate:

- migrate an in-memory schema-3 fixture without losing events, turns, evaluations, pricing, aliases, or checkpoints;
- reject invalid intervals, self/cross-session parents, invalid quality/status combinations, and agent mismatches;
- prove rollback and checkpoint preservation when any activity/capability write fails;
- prove reset/removal deletes only the affected source's trajectory rows;
- inspect the schema to confirm no prohibited payload column exists.

### Stage 2: provider normalization

Implement one audited provider at a time, ordered by strongest proven evidence from Stage 0 rather than by a predetermined brand order.

For each provider:

1. Extend its existing importer pass; do not create another filesystem/database scan.
2. Emit deterministic activities and session capabilities.
3. Persist open lifecycle state and metadata-only correlation state safely across incremental JSONL checkpoints when required.
4. Handle append, no-op refresh, terminal update, truncation/replacement, incomplete lifecycle, malformed record, and schema-version change.
5. Increment importer version and prove a rebuild produces the same IDs/order as a clean import.

Validation gate per provider:

- synthetic tests cover every supported kind and every unavailable/partial declaration;
- repeated import is idempotent;
- start in one batch and terminal record in a later batch updates one stable activity;
- no content or raw identifier reaches the database, issue text, or test fixture;
- existing token/cost and active-turn tests remain unchanged in meaning.

All four providers must at minimum retain their current coarse turn timeline. Detailed parity across providers is not an acceptance criterion; accurate capability reporting is.

### Stage 3: backend and pure projection

1. Add `TrajectoryBackend` that composes the existing usage refresh with trajectory queries.
2. Add paged session discovery across usage, turns, activities, and capabilities.
3. Implement hierarchy validation and deterministic flattening.
4. Implement Order, Active time, and Clock time projection math.
5. Implement shared selection/range-overlap logic by stable record ID.
6. Join token/cost metadata only through proven `usageEventID` links.

Validation gate:

- tests cover equal timestamps, point events, open spans, inferred boundaries, overlaps, nested tools, orphans, cycles, unscoped activities, idle compression, and stable ordering;
- Order mode never implies duration;
- Active time removes only human-idle gaps outside the union of turns;
- Clock time preserves gaps;
- selection results are identical whether initiated from overview or ledger;
- unavailable capability is distinguishable from an observed count of zero.

### Stage 4: Trajectory destination

1. Add the root sidebar destination and `TrajectoryView` split layout.
2. Add period/agent filters, paged session list, Refresh, loading, stale-data error, empty state, and preview injection.
3. Build the three-lane overview from projection records.
4. Build the hierarchical ledger with fold state and shared selection.
5. Build the metadata-only inspector and compact capability summary.
6. Add mode switching, hover details, range selection, Escape clearing, and `Open in Trajectory` from Evaluation session rows if it does not complicate the first delivery.

Validation gate:

- every locally indexed session is reachable through filters and All-period paging;
- coarse turn-only sessions remain useful and visibly limited;
- no unsupported lane or metric appears as zero;
- no nested scrolling, view-owned minimum window size, or live source access in previews;
- keyboard, VoiceOver labels, contrast, and non-colour status channels are checked;
- all spacing, radii, and metric typography use `UsageDesign`.

### Stage 5: scale and resilience

1. Generate synthetic sessions at 100, 1,000, and 10,000 activities with nesting and open spans.
2. Measure initial projection, mode switching, selection latency, and scrolling in a release build on the development Mac.
3. Target less than 100 ms for projection/mode recomputation at 10,000 activities and interactive scrolling without repeated multi-frame stalls. These are acceptance targets, not current measurements.
4. If the target fails, profile before choosing SQL detail paging, cached projections, or custom virtualization. Record the measurement that justifies the added mechanism.
5. Verify a source failure, database lock, cancellation, and app relaunch preserve the last committed data and recover on the next refresh.

Exit gate: measured evidence supports the selected loading/rendering strategy; otherwise the performance limitation remains explicit and the feature does not claim long-session readiness.

### Stage 6: repository-wide completion

1. Update `docs/usage-dashboard-design.md`, `docs/usage-dashboard-plan.md`, and `AGENTS.md` with the implemented schema, privacy rules, source matrix, files, and workflow.
2. Add synthetic model/store/importer/projection/backend/view-model tests.
3. Run the relevant unit tests and the non-launching build-for-testing command from `AGENTS.md`.
4. Verify previews remain synthetic and the app does not access credentials or network for Trajectory.
5. Record any unavailable provider capability and any unmeasured runtime boundary in the final implementation report.

## Proposed file map

New files should be introduced only when the boundary has independent logic or tests:

| File | Responsibility |
| --- | --- |
| `UsageDashboard/TrajectoryModels.swift` | Normalized activity/capability/report contracts |
| `UsageDashboard/TrajectoryProjection.swift` | Pure hierarchy, ordering, lane, and timeline math |
| `UsageDashboard/TrajectoryBackend.swift` | Refresh composition and session queries |
| `UsageDashboard/TrajectoryModel.swift` | Main-actor filters, paging, selection, and error state |
| `UsageDashboard/TrajectoryView.swift` | Destination and split-view composition |
| `UsageDashboard/TrajectoryTimeline.swift` | Overview rendering and pointer/keyboard interaction |
| `UsageDashboard/TrajectoryLedger.swift` | Hierarchical table and metadata inspector |

Existing files that must change:

- `UsageAnalyticsModels.swift`: import batch/report fields;
- `UsageAnalyticsStore.swift`: schema 4, atomic writes/resets, and queries;
- `UsageImporters.swift`: audited provider normalization in the existing pass;
- `UsageImportSupport.swift`: metadata-only checkpoint state helpers if shared by at least two importers;
- `UsageAnalyticsBackend.swift`: imported activity counts and refresh reporting;
- `ContentView.swift`: Trajectory destination;
- `EvaluationRunsView.swift`: optional navigation link only after the destination exists;
- test targets and project file membership.

Do not introduce a generic event bus, repository interface, factory, or renderer protocol unless a second real implementation needs it.

## Acceptance criteria

The feature is complete only when:

1. Every session currently discoverable by BorderCollie's four importers can be opened in Trajectory, even if only outer turns are available.
2. Each detail family advertises availability (complete, partial, or unavailable) separately from exact/inferred timing quality.
3. Every fine-grained row has a documented source identity and boundary mechanism; no row is created from textual or temporal adjacency alone.
4. Turn timing remains identical to Evaluation Runs because both read `UsageActiveTurn`.
5. Overview, ledger, range selection, and inspector resolve the same stable IDs.
6. Open and unknown activities never acquire fabricated durations.
7. Token/cost detail appears only through a proven existing usage-event relationship.
8. Source refresh is incremental, idempotent, atomic with checkpoints, and recoverable after reset or cancellation.
9. The persisted schema, checkpoints, logs, search index, fixtures, and UI contain none of the prohibited content fields.
10. A failure in one source preserves previously committed data and does not blank other sources.
11. Synthetic 10,000-activity measurements either meet the declared target or trigger an evidence-backed scaling stage before long-session readiness is claimed.
12. Unit tests and the non-launching macOS build verification pass, with any runtime/UI boundary reported explicitly.

## Deferred decisions

The following are deliberately outside the first implementation and require new evidence or product approval:

- live tail-follow while an agent is running;
- full-content local debugging mode;
- cross-session or cross-agent combined trajectories;
- exporting trajectory records;
- generic subprocess or OpenTelemetry ingestion;
- custom virtualization before SwiftUI performance is measured;
- provider instrumentation when local histories lack required lifecycle evidence.

These are not hidden extensions of the metadata schema. Each changes the privacy, capture, or performance boundary and should receive its own design review.
