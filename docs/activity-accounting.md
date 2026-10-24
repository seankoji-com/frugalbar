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
  cumulative counter. That is a request too, keyed by session, exact
  millisecond, counter segment and cumulative value, so a fork's copy is the
  same row and a same-second repeat is not collapsed. Equal time and equal total
  are not identity: two requests that share them stay two rows.

The same request stated in both shapes is stored once. The two rows are paired
one-to-one — never many-to-one and never by whichever shape was read first — on
the source's own provenance: same session, same recorded instant, same counter
segment and same published cumulative counter. A request that published no
cumulative counter is not cross-paired at all, because nothing then proves the
two shapes are the same request; both observations are kept rather than one
being guessed away. A `compacted` event starts a new counter segment, so a
counter value repeated after it is a new observation. A duplicate notification
of one request remains one row and is not reported as inconsistent.

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
- `ActivityEvidenceRenderer` is built into `QuotaBarUI`, and
  `Sources/QuotaBarApp/AppMain.swift` calls it from `QuotaBarApp.init()` after
  the CLI early exits and before any delegate, poll, store, preference or
  credential is touched. It renders the same views from a throwaway store, then
  exits, without opening the live history database and without injecting quota.

```sh
FRUGALBAR_ACTIVITY_EVIDENCE_DIR=/tmp/frugalbar-activity-evidence ./frugalbar
```

The process prints the chart total, layers, OpenAI project paths, OpenCode
project paths (empty), the `window=start..end` that the hosted attribution view
itself reported, and `readings=`, the quota rows left in its throwaway store
(zero: the fixture writes activities only). The directory contains the PNGs and
accessibility dumps. The project lists and window come from the view's own
completed reload, not from a separate attribution computation, so a render that
quietly fell back to `Date()` cannot print a correct-looking result. The test-host
invocation remains available:

```sh
FRUGALBAR_RENDER_DIR=.build/issue128-evidence/render \
  swift test -c debug --filter "UXRenderTests/renderActivity"
```

The controlled ledger's clock is fixed, not `Date()`: a standard reference of
2026-10-20T12:00:00Z with both request days at 10:00Z on 2026-10-19 and
2026-10-20. The second day is therefore always behind the reference and inside
the seven-day window, at any local hour. `Fixture.around(reference:calendar:)`
derives the same two past days for an injected reference and calendar;
`ActivityEvidenceClockTests` covers morning, the 10:00 boundary, midday,
evening and daylight-saving transitions in several time zones.

`HistoryRootView` takes that instant as an explicit `clock` (production defaults
to `Date()`). One reload reads it once and uses it for the range edge, the
overview/marker/activity queries, and pace and attribution presentation, so
`since` and `until` cannot come from different moments. Both evidence views are
constructed with the fixture reference, and each reports its completed reload
through `loadObserver`; the renderer waits for that report instead of sleeping.
`HistoryViewClockTests` hosts the production view against January 2026 data
under two references — one that includes it and one that does not — so the
outcome follows the injected instant rather than the host calendar.

Sample mode is an injected dependency for the same reason. `HistoryRootView`
takes a `SampleModeConfiguration`; the app default reads and writes the stored
preference, while the evidence route passes `.explicit(false)`, which is a fixed
value with a writer that does nothing. It is resolved once in `init`, not by an
eager stored-property initializer: an initializer that read
`CredentialStore.isSampleModeEnabled` fired even for an explicit caller, so a
user who had left sample mode on made the evidence route draw sample mode over
its fixture store and call `SampleDataGenerator` into it. `readings=0` in the
printed report is the check that it did not.

Both seams host the views offscreen with `NSHostingView`; they do not prove a
GUI session against a logged-in desktop, and the accessibility tree of
`HistoryRootView` is shallow in that host. The PNG is the readable artefact.
