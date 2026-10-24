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

## Request history

Codex rollouts are read as request observations keyed by `response_id`, at the
top-level event timestamp. A model change is a **top-level** `turn_context`
event and applies from that point in the file. The thread's cumulative counter
is used to reconcile, not to create usage: a counter restart or a `compacted`
event resets the baseline and never fabricates the gap. A duplicate request in a
copied fork is one row. Older rollouts with only cumulative `token_count`
events remain one honestly session-level row per session, and the chart says so.

Claude Code and OpenCode records keep their message/request timestamps and
stable ids. Re-reading a file replaces the same `(source, record_id)` row, so
restart and re-ingestion are idempotent.

## Storage and migration

`HistorySchema.version` stays 1. Two additive tables were added:

- `activity_request` holds every row written since this change.
- `activity_source_status` retains per-source scan and diagnostic counts.

`activity` is left untouched, so existing quota, balance and activity rows
survive. `activity_unified` is the read surface:

- a request row supersedes the same `(source, record_id)` legacy row;
- any Codex request row supersedes that session's legacy cumulative aggregate,
  so the two can never be added;
- a legacy Codex session with no request rows remains visible as `legacy`
  precision.

No version bump, table drop or destructive rewrite is involved.

## Source completeness

`activity_source_status` records, per source:

- the last attempted and last successful scan;
- inputs that could not be read;
- malformed records;
- records that disagreed with their cumulative counter;
- records whose token breakdown was partial or had no total;
- how many records the last scanned pass observed.

A pass that skipped unchanged files retains the previous counts instead of
erasing them. The History attribution card and the Tokens widget name the
source, the counts and the last successful scan. An unchanged file is not
evidence of a clean one.

## Provenance

`source` is the CLI/tool (`claude_code`, `codex`, `opencode`). `billingProvider`,
`accountId` and `workspaceId` are separate fields filled only when the source
published them. OpenCode messages publish `providerID` (for example `litellm`),
not a workspace. The History breakdown for an OpenCode Go workspace therefore
requires a published account or workspace before counting a record; otherwise
it says how many local records were not attributed, instead of assigning them
to that workspace. Project and branch attribution for trusted records is
unchanged.

## Runtime evidence

`Tests/QuotaBarUITests/UXRenderTests.swift` contains an opt-in
`renderActivityAccountingEvidence` test. It drives the real Codex adapter with a
sanitized rollout (two days, two models, a resumed session), writes controlled
Claude and OpenCode rows, and renders the production `TokenUsageChartView` and
`HistoryRootView`. Run it with:

```sh
FRUGALBAR_RENDER_DIR=.build/issue128-evidence/render \
  swift test -c debug --filter "UXRenderTests/renderActivityAccountingEvidence"
```

The PNGs and accessibility dumps land in that directory. Fixtures never touch
the live history database, preferences or credentials.
