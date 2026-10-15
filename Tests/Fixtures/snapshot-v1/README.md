# Snapshot schema v1 fixtures

The canonical fixtures for the sync snapshot (`SnapshotExporter`). `frugalbar-android` vendors a
copy pinned to one `frugalbar` commit; `MANIFEST.sha256` (`shasum -a 256` format, every file here
but itself) is what both sides check.

| File | Holds |
|---|---|
| `<name>.input.json` | Exporter input, language-neutral. Only the Swift tests read it. |
| `<name>.expected.json` | The exact bytes the exporter publishes for that input. The Kotlin parser and rendering tests run every one of these. |
| `<name>.expected-error.json` | A local exporter failure instead: no document is published. Exporter-only. |

`covers` in each input names the D§2.2.E fixture or the export-adapter table line and branch it
exercises, or a `regression:` it pins; `fixturesCoverEveryTableLineAndBranch` checks that the set
is complete.

`macClockOffsetMs` is an integer in the input and a decimal string (or null) in the expected
documents: it is signed, and the schema's integers are 0…2^53 − 1.

## Input format

Top level: `publisherId`, `publisherLabel`, `publishedAt` (also the clock the 7-day event window
is measured from), `macClockOffsetMs`, `macClockSampledAt`, `untrustedInstanceIds`,
`notificationPrefs`, `snapshots[]` and `events[]`.

- A snapshot mirrors `QuotaSnapshot`: `id`, `vendorId`, `displayName`, `category`, `metric`
  (`type` plus that case's fields), `status` (`kind`, `reason`, `message`), `resetsAt`,
  `lastUpdated`, `planName`, `currencyBasis`, `staleReading`, `row1`…`row3`, `apiCredits`.
  It also carries `auxiliaryInfo`, `cliSource`, `keyMasked`, `latencyMs` and `badgeText` with
  marker values, so a test can prove they never reach the output.
- A row mirrors `DualBarMetrics`, including `usedText` and `resetText` markers the exporter must
  never read, and the quantity fields as decimal strings.
- An event mirrors `AIEvent`; `source` is `AIEventSource.rawValue`.
- `{"repeat": N, "snapshot": {…}}` or `{"repeat": N, "stepSeconds": S, "event": {…}}` stands for N
  copies, with `{n}` in every string replaced by the copy's zero-padded index and each event copy
  S seconds after the one before. Only the overflow fixtures use it.

Times are UTC ISO-8601 with milliseconds. Decimals are strings.

## Updating

1. Change the inputs (or the exporter) in a `frugalbar` PR.
2. Regenerate: `FRUGALBAR_WRITE_SNAPSHOT_FIXTURES=1 swift test --filter SnapshotExportFixtureTests`,
   twice (the second run rewrites the manifest over the new expected files). Review every diff.
3. A `frugalbar-android` PR bumps its `FIXTURES_SOURCE` pin to that commit.
