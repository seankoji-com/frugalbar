# Sync export (snapshot schema v1)

`SnapshotExporter` (`Sources/QuotaBarCore/Export/`) turns the Mac's snapshots, events and
notification choices into the one JSON document the phone and watch read. These are the handoff
notes for that adapter: what it decides, and the sizes it was measured at. It publishes nothing
itself; the publisher, sign-in and Drive code come later and send the bytes it returns.

The canonical fixtures and their format are in
[`Tests/Fixtures/snapshot-v1/`](../Tests/Fixtures/snapshot-v1/README.md).

## The only Mac model change

`DualBarMetrics` gained `quantityUsed`, `quantityRemaining`, `quantityLimit` (`Decimal`) and
`quantityUnit`. Five providers fill them from the figures their `usedText` already printed, and
nothing on the Mac reads them:

| Provider | Rows | Fields |
|---|---|---|
| GitHub REST (consolidated) | REST, GraphQL | remaining and limit, `req/hr` and `pts/hr` |
| GitHub GraphQL (standalone) | the one row | remaining and limit, `pts/hr` |
| Grok | on-demand | used and cap, `USD` |
| Kiro | monthly, bonus, overage | used and limit, `credits` |
| DevPass | plan / spend | used and limit in `credits`; used (and limit when capped) in `USD` |
| Command Code | 5h, weekly, credits | used and limit in `credits`; remaining only on the remaining-only credits row |

Basis and reset handling live in the adapter: no provider sets `currencyBasis` or a row reset for
the export.

## Adapter decisions

- **Window identity** comes from `SnapshotExportTable`: vendor, row position, and for DevPass the
  metric. Labels are copied (cut to 64 escaped bytes) and never read for anything else. A
  non-nil row with no entry fails the export: `SnapshotExportState` withholds that publish, keeps
  the last good document, and Settings shows "Sync export error: unmapped row (vendor, rowN)".
- **Billing cycles** (`measuresElapsedTimeOnly`) export as window `cycle` with only `cycleStart`
  and `cycleEnd`: `usedFraction`, `resetsAt` and `windowSeconds` are null, `resetSource` is
  `none`, and they are never eligible. An elapsed fraction is not usage.
- **Never measured.** A snapshot with no reading at all (an `unavailableSnapshot` placeholder: not
  measured, no rows, no API credits) exports `measuredAt: null` and `primary` as
  `unavailable {reason: noReading}`. Its placeholder tier ("Not configured") is not exported as a
  plan.
- **Out of range.** A `primary` or API-credit value outside its domain becomes
  `unavailable {reason: outOfRange}`. A window whose fraction or quantity is outside its domain
  exports `usedFraction: null`, no `quantity`, and `unavailable: {reason: outOfRange}`; it stays
  eligible only if blocked. Decimals are exact `Decimal` text and are never rounded to fit.
- **Events.** Surfaced kinds only (`AIEvent.isSurfaced`), `occurredAt` within 7 days of
  `publishedAt`, newest first, at most 100. When the cap drops events, `eventsTruncated` is set
  as it is for size overflow, so the phone's gap notice covers both. URLs other than https, or
  over 512 bytes, are dropped. Source captions are fixed per source kind and name no host.
- **`macClockOffsetMs`** is the one signed integer: the sign says which way the Mac's clock was
  off. Its magnitude has the same 2^53 − 1 bound.
- **Encoding.** Compact UTF-8, keys in schema order, `primary` and API-credit metrics tagged with
  `type`. The bytes are deterministic, which is what lets the fixtures compare them exactly.
- **Identity collision.** If two exported identities in one document share a digest (or one
  instance appears twice), the export fails the same way as an unmapped row.

## Measured sizes (REQ-MAC-BOUNDS e)

Measured on 2026-10-15 at the stage head, with
`swift test --filter providerEncodedSizeReport` (it prints the `SNAPSHOT-SIZE-REPORT` line):

| Figure | Encoded provider size |
|---|---|
| Typical: median across the fixtures, leaving out the synthetic max-size sets | 620 bytes (54 providers) |
| Median across every fixture provider, max-size copies included | 5,738 bytes (130 providers) |
| Worst case: every field at its limit, 3 windows and 8 API credits (`events-overflow`, `providers-overflow`) | 5,738 bytes |

At the worst case, 45 providers fit in the 256 KB budget with no events (`providers-overflow`
keeps 45 of 60). The round-5 reviewer's 7.1 KB estimate (about 35 providers) assumed 6 windows;
no provider fills more than 3 rows today.
