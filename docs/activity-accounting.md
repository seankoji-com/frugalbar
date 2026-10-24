# Local activity ledger

FrugalBar records what local CLI tools reported, at the time they reported it.
It does not estimate missing usage, convert local tokens into subscription
quota, or treat a tool's name as a billing identity.

## Token fields

Each adapter declares how its components relate:

| Source | Semantics | Total |
| --- | --- | --- |
| Claude Code | additive | input + output + cache reads + cache writes |
| OpenCode | additive | the published `tokens.total`, else the sum of reported components |
| Codex | `cacheIncludedInInput` | the published `total_tokens`, else input + output |

Codex's `cached_input_tokens` and `cache_write_input_tokens` are subsets of
`input_tokens`, and `reasoning_output_tokens` is inside `output_tokens`. They
are retained for inspection but never added again. A total the source published
is stored as `published`; a sum of every component is `derived`; a sum of only
the components that were reported is `partial`; a pre-ledger row is `legacy`.
`nil` means no figure was observed, never zero.

Counts are parsed exactly. `NSNumber.doubleValue` rounds above 2^53 and
`Int(Double(Int.max))` traps, so an integer is read from its exact
`Int64`/`UInt64` representation; only a non-negative value that fits `Int`
becomes an observation. A fractional, negative or out-of-range figure stays
unknown and is counted as malformed.

## Request history

Codex rollouts are read as request observations at their recorded times. A
model change is a **top-level** `turn_context` event and applies from that point
in the file.

Two shapes state a request:

- `token_usage_record` carries `usage` and a `response_id`; the row is keyed by
  that response.
- `event_msg` `token_count` carries `info.last_token_usage` beside the
  cumulative counter. That is a request too, keyed by session, millisecond and
  cumulative value, so a fork's copy is the same row and a same-second repeat
  is not collapsed. A `last_token_usage` for the same request a
  `token_usage_record` already stated (same session, second and total) is not
  stored twice.

The thread's cumulative counter is used to reconcile, not to create usage. A
per-request figure that disagrees with the difference between two cumulative
readings is counted as inconsistent and still stored as published. A counter
below its last value, or a `compacted` event, resets the baseline and never
fabricates the gap.

A file whose cumulative counter states more than its request rows account for
also keeps one session-level row with the published cumulative total (keyed by
session). A file that is fully reconstructed by its request rows adds no
aggregate. A cumulative-only rollout remains one honestly session-level row.

Claude Code and OpenCode records keep their message/request timestamps and
stable ids. Re-reading a file replaces the same `(source, record_id)` row, so
restart and re-ingestion are idempotent.

## Storage and migration

`HistorySchema.version` stays 1. Three additive tables were added:

- `activity_request` holds every row written since this change;
- `activity_source_status` retains the per-source scan and diagnostic roll-up;
- `activity_input_status` retains the same counts per input path.

`activity` is left untouched, so existing quota, balance and activity rows
survive. `activity_unified` is the read surface. It is rebuilt from
`activity_aggregate` and `activity_reconciled_aggregate` on every open (views
hold no rows, so replacing them is not a migration).

For a Codex session aggregate — an old `activity` row or a session row written
by the adapter — reconciliation is explicit and by published totals:

- an aggregate is **proven superseded** when request rows for its session,
  observed at or before the aggregate's recorded turn and all carrying known
  totals, sum to at least its total;
- while it is not proven, the aggregate stays visible and request rows observed
  inside it are withheld from totals because they are already part of that
  total;
- a request observed after the aggregate's turn is additive: the cumulative
  counter cannot contain it;
- a request row with the same `(source, record_id)` as a legacy row replaces
  that row.

The request rows are never deleted or rewritten by this decision, and no
missing remainder is allocated to a time the source did not record.

No version bump, table drop or destructive rewrite is involved.

## Source completeness

`activity_input_status` records, per input path:

- malformed records;
- records that disagreed with their cumulative counter;
- records whose token breakdown was partial or had no total;
- records observed;
- whether the input could not be read.

`activity_source_status` sums those rows for the source. An unchanged input is
not re-read, so its row — and any malformed count in it — stays charged while a
different file is read cleanly. A changed file replaces its own row; a source
that appends to an existing file (Claude Code, OpenCode) adds the new region's
counts to that row. An input that no longer exists is removed with the input
set. A relaunch reads the persisted rows before any pass has run.

The History attribution card and the Tokens widget name the source, the counts
and the last successful scan. An unchanged file is not evidence of a clean one.

## Provenance

`source` is the CLI/tool (`claude_code`, `codex`, `opencode`). `billingProvider`,
`accountId` and `workspaceId` are separate fields filled only when the source
published them. OpenCode messages publish `providerID` (for example `litellm`),
not a workspace.

The History breakdown for an OpenCode Go workspace uses
`.matchingPublishedIdentity` with the subject's published identity. A record is
included only when every identity the target names is also published by the
record, and the target names an account or workspace. A target with no account
or workspace is uncorrelated: provider identity alone is not enough, because
two workspaces can bill through one provider. Uncorrelated and mismatched
records stay explicitly unattributed, and the card says how many were not
attributed to this subscription. Project and branch attribution for matching
records is unchanged.

## Runtime evidence

Two seams render the production `TokenUsageChartView` and `HistoryRootView` from
controlled data:

- `Tests/QuotaBarUITests/UXRenderTests.swift` runs
  `renderActivityAccountingEvidence` and `renderActivityEvidenceSeam` under the
  test host;
- `ActivityEvidenceRenderer` is built into `QuotaBarUI`. It renders the same
  views from a throwaway store, then exits, without opening the live history
  database, preferences or credentials and without injecting quota.

The renderer needs one call from the app entry point, which is outside this
repair's source scope. Once that call is present:

```swift
// Sources/QuotaBarApp/AppMain.swift, in QuotaBarApp.init(), after CLIArguments
if ProcessInfo.processInfo.environment[ActivityEvidenceRenderer.environmentKey] != nil {
    ActivityEvidenceRenderer.runFromEnvironmentAndExit()
}
```

```sh
FRUGALBAR_ACTIVITY_EVIDENCE_DIR=/tmp/frugalbar-activity-evidence ./frugalbar
```

The process prints the chart total, layers, OpenAI project paths, OpenCode
project paths (empty) and the unattributed-workspace message, then exits 0. The
directory contains the PNGs and accessibility dumps. Until that call is added,
use the test-host invocation:

```sh
FRUGALBAR_RENDER_DIR=.build/issue128-evidence/render \
  swift test -c debug --filter "UXRenderTests/renderActivity"
```

Both seams host the views offscreen with `NSHostingView`; they do not prove a
GUI session against a logged-in desktop, and the accessibility tree of
`HistoryRootView` is shallow in that host. The PNG is the readable artefact.
