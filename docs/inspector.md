# Inspector

Click a provider row in the popover to open its inspector. It answers three questions about one vendor: how fast am I spending each window, what has happened to this account recently, and what can I redeem.

## Burndown | History

The chart card has two views. Readings come from the local history database (`~/Library/Application Support/FrugalBar/history.sqlite3`), loaded when the inspector opens, never on the refresh path.

| View | Shows | Range |
|---|---|---|
| **Burndown** | The current window of one bar label (5H, WK, MO…), remaining % from the window start to its reset. Defaults to the longest window; a picker switches bar label when the vendor publishes several | The window itself |
| **History** | Used % over time for every bar label, with reset, restore and credit markers from the event log | 24h / 7d / 30d |

### Burndown lines and when each is absent

| Line | Meaning | Present only when | Otherwise |
|---|---|---|---|
| **Remaining** (solid) | `1 − used` from stored readings, since the last reset-sized drop | There are measured readings inside the current window and its reset is still ahead | "No readings yet — history accumulates as FrugalBar polls" |
| **Ideal pace** (dashed) | A straight line from 100% at the window start to 0% at the reset | The vendor published **both** a window length and a reset time | No ideal line, and the caption "No window length published, so no pace line can be drawn". Nothing is assumed from a typical 5-hour or weekly window: a pace line at a constant asserts something nobody measured |
| **Projection** (dotted) | Where remaining would reach at the recent pace, to the earlier of exhaustion and the reset | `BurnRateForecast` can fit a pace: at least 3 readings spanning 10 minutes in the last hour, usage is rising, and the vendor has not blocked the window | No projection. A flat window has nothing to project, and a blocked one has no usable headroom to run out of |
| **Now** (vertical rule) | The current time | Always | — |

The summary line under the chart is built from the same facts and omits any clause whose input is missing: "27% left · 21h 0m to reset · out in 2h 15m". A blocked window leads with the block and calls its figure reported, not usable: "Blocked by the vendor · 4% reported remaining · 24h 0m to reset".

Points carry urgency as a shape (circle, diamond, triangle, square for blocked), not colour alone.

Hover a chart, or click it and press the left and right arrow keys (VoiceOver: adjust), to read one poll: its timestamp to the second and each window's recorded share to two decimals, as stored (a reading past the allowance reads 103%, though the line is drawn at 100%). A readout only groups windows recorded by the same poll. Escape clears it. If the history database cannot be read, the chart, the events list and the History row say so instead of showing zero; if only the reset markers cannot be read, the History chart says resets may be missing.

The provenance's History row counts this instance's readings only (not a sibling OpenCode Go workspace's) since the date the read started from, which reaches back past 30 days to the start of a longer published window.

## Recent events

The vendor's five newest [events](events.md) of the kinds FrugalBar surfaces (resets, outages, newly selectable models), each with its source caption. Scheduled window rollovers are left out here; they are markers on the chart. Status-page and reset-tracker history is backfilled on the first poll, so these usually fill at once; an empty list means nothing has been recorded, not that nothing happened.

## Reset credits row

Shown only when the vendor published a banked-reset figure.

| Figure | OpenAI | Anthropic |
|---|---|---|
| Banked | `rate_limit_reset_credits.available_count` | Sum of `resets_left` over `cedar_ember.grants` |
| Redeemable now | `applicable_available_count` | Sum over grants flagged `usable_now` |

The row is absent when the vendor reports no credit field. FrugalBar never shows 0 as a stand-in for "not reported". OpenAI's `credits.balance` is not displayed: its unit is unverified. Anthropic currently serves grants only to the claude.ai web session, so the Claude row has no credits row for a CLI login (see [events.md](events.md#what-is-deliberately-not-inferred)).

## Copy JSON

The footer's **Copy JSON** puts a pretty-printed export (`InspectorExport`, sorted keys, ISO-8601 dates, nil fields omitted) on the clipboard for bug reports. It carries what the row already shows and nothing secret: no keys, tokens or error text.

| Field | Value |
|---|---|
| `vendor`, `displayName`, `category` | Identifiers |
| `status`, `unavailableReason` | `measured` / `unavailable`, and why |
| `plan`, `latencyMs`, `lastUpdated` | As shown in the diagnostics block |
| `resetCreditsAvailable`, `resetCreditsApplicable` | The reset-credit figures, when published |
| `bars[]` | Per window: `label`, `usedFraction` (null when unread), `isBlocked`, `measuresElapsedTimeOnly`, `resetsAt`, `windowLengthSeconds` |
| `readingsCount` | How many of this instance's stored readings the inspector loaded, the same figure as the History row; omitted when they were not, or could not be, read |
| `readingsSince` | Where that count starts; omitted with it |

Code: `Sources/QuotaBarUI/Components/MetricDetailModalView.swift`, `MetricDetailCharts.swift`, `Sources/QuotaBarUI/History/BurndownPresentation.swift` (pure presentation; tested in `BurndownPresentationTests`).
