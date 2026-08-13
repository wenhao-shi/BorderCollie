# Verification Evidence

Date: 2026-08-12

## Non-launching build

```sh
xcodebuild build-for-testing \
  -project BorderCollie.xcodeproj \
  -scheme BorderCollie \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO
```

Result: `TEST BUILD SUCCEEDED`.

An earlier invocation compiled the app and unit bundle but the sandbox denied
one UI-test runner link operation. The exact documented command succeeded on
the final run without a source workaround.

## Unit tests

The compiled unit bundle was run directly so no app window launched:

```sh
env DYLD_LIBRARY_PATH=/private/tmp/BorderCollieDerivedDataBuild/Build/Products/Debug/BorderCollie.app/Contents/MacOS \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  /private/tmp/BorderCollieDerivedDataBuild/Build/Products/Debug/BorderCollie.app/Contents/PlugIns/BorderCollieTests.xctest
```

Result: 63 tests in 2 suites passed in 0.180 seconds. This includes 18 synthetic
historical analytics/dashboard tests plus all 45 pre-existing quota tests.

The chart regression assertions verify that Cost mode retains only agents with
nonzero priced cost, Tokens mode retains only agents with nonzero tokens, and
unpriced token usage remains visible in Tokens mode.

The interaction assertions verify nearest-series projection within the
14-point hover radius, rejection away from every visible curve, and selection
of a single-point series.

The range and aggregation assertions verify that `24h` ends at the requested
instant, spans exactly 86,400 seconds, uses hourly chart buckets with partial
boundary hours, excludes both half-open interval boundaries correctly, and
retains separate calendar-day breakdown rows. Model and day aggregates also
reconcile `in`, `cache-write`, `cache-read`, `out`, reasoning, total, and both
derived rates.

The non-launching build also compiles the metric strip's explicit 8/4/2/1
`ViewThatFits` layout. Runtime window-resizing behavior was not screenshot-tested
because ScreenCaptureKit remains unavailable in this session.

## Dashboard compile and runtime-inspection boundary

The non-launching build compiled the production dashboard, Swift Charts, native
Table, and the offline synthetic preview. A runtime screenshot inspection was
attempted against the built app, but macOS ScreenCaptureKit returned error
`-3811` (`audio/video capture failure`). The debug app was closed afterward.
Interactive light/dark appearance and scrolling were therefore not visually
measured in this session; they are not claimed as verified.

## Live read-only import

`LiveImportMeasurement.swift` compiles only the backend files into a scratch
executable. It reads the four local provider histories and writes only to a
scratch database under `/private/tmp`.

Observed result:

```text
cold_ms=8463 events=5473 claude_code:imported=2008,issues=0 codex:imported=3400,issues=0 opencode:imported=6,issues=0 pi:imported=59,issues=0
warm_ms=130 events=5473 claude_code:imported=0,issues=0 codex:imported=0,issues=0 opencode:imported=0,issues=0 pi:imported=0,issues=0
```

Database audit:

```text
claude_code complete 2008 priced 2003
codex       complete 2465 priced 1299
codex       partial   935 priced 0
opencode    complete    6 priced 0
pi          complete   59 priced 59
complete-event arithmetic violations: 0
raw-path-shaped source keys/IDs: 0
```

The 935 Codex partial records are retained rather than zero-filled: 916 older
records do not report cache-write tokens, and 19 zero-delta records retain a
nonzero source cumulative total that cannot represent the request event. The
OpenCode gateway models observed locally have no first-party price mapping and
therefore remain unpriced rather than treated as free.
