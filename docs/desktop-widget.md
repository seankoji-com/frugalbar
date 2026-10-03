# Desktop widget

A small panel that charts your subscription usage windows over time, with a strip of current headroom underneath. Open it from the gear menu (**Desktop Widget**, ⌘D). Choosing it again hides it.

## Layouts

The segmented **Chart | Overview** control in the filter bar picks the body. The choice is stored with the filters.

| Layout | Shows |
|---|---|
| **Chart** (default) | Burndown lines, the average and the headroom strip, described below |
| **Overview** | One tile per provider with each of its windows: a bar, the figure in the chosen metric and a reset tooltip. Tiles follow the popover's provider order and visibility. A configured provider that cannot be read keeps its tile and says why; one that is not configured has none. A hand-entered billing cycle is labelled elapsed time, never usage. Window and range filters are chart-only and hidden here |

The Overview has **no total, average or combined figure**: each number belongs to one provider's own window. Its tiles are read as, for example, "Claude, Max (5x). weekly 60 percent remaining, resets in 3 days. 5-hour blocked".

## What it shows (Chart layout)

| Part | Content | Source |
|---|---|---|
| Lines | One line per subscription window, drawn from stored quota readings | Real readings only. Gaps are never filled or interpolated, and a reset, an outage or a long gap breaks the line instead of joining across it. |
| Markers | A mark on the latest reading of each line, and on readings under pressure. Shape carries urgency: circle normal, diamond warning, triangle critical, square blocked | The reading's own urgency and blocked flag |
| Average | A heavy dashed line, labelled "Average (N windows)" | Mean of the selected windows' readings, see below |
| Headroom strip | Current remaining % per window with a micro bar and reset countdown. "blocked" or a dash when there is no figure | Latest snapshots |
| Header | Overall health symbol and "updated N ago" for the oldest reading | Snapshots |

Windows that measure elapsed time only (a recorded subscription **cycle**) are excluded: they report no usage.

### The average is not a quota

Vendors meter different things over different windows, so FrugalBar never combines them into one allowance. The average line is the mean of real readings that exist in each time bucket (5 min buckets for 24h, 30 min for 7d, 2 h for 30d; the line also breaks across a gap of more than 2 hours). `sampleCount` is whatever contributed to the bucket and is never padded to the number selected, which is why the label can read "Average (2–3 windows)". The line breaks whenever the set of contributing windows changes, so one vendor's outage shows as a gap rather than a plunge. It appears only when two or more windows are charted. Hovering it says "Mean of the selected windows' real readings — not a combined quota."

## Filters

| Filter | Options | Default |
|---|---|---|
| Subscriptions | All, or any subset of vendors that have a consumable window. Ticking every vendor is stored as "all", so a provider you add later appears automatically | All |
| Window | A window label (for example `5H`, `WK`, `MO`) or "Longest window per subscription". The menu shows "All" for that default | Longest per subscription |
| Range | 24h, 7d, 30d | 24h |
| Metric | Used or Remaining | Remaining |

## Pinned or floating

**Preferences → General → Desktop widget → Position**:

| Mode | Behaviour |
|---|---|
| Pinned to desktop (default) | On the wallpaper, one level above the desktop icons and beneath every ordinary window. Above the icons on purpose: below them, Finder's desktop layer takes every click and the panel cannot be dragged, resized or filtered |
| Floats above windows | A normal floating panel above other windows |

Either way the panel can be dragged by its background, resized (minimum 340 × 260, default 420 × 320), joins all Spaces, and doesn't steal focus from the app you are using. The chart is always drawn dark.

## Persistence

Everything lives in the app's explicit preference suite (`CredentialStore.preferences`), not `UserDefaults.standard`, which an unbundled executable keys off its process name.

| Key | Holds |
|---|---|
| `QuotaBarDesktopWidgetVisible` | Whether it was open. If so, it reopens at launch. Quitting does not close windows, so a widget left open comes back |
| `QuotaBarDesktopWidgetMode` | `desktop` or `floating`. A missing or unrecognised value means `desktop` |
| `QuotaBarDesktopWidgetFrame` | Last position and size. Restored only if it is large enough and still intersects a connected screen, so an unplugged monitor cannot strand it off-screen |
| `QuotaBarDesktopWidgetFilters` | The filters above, and the layout, as JSON. Decoding is tolerant: an unknown vendor is dropped and an unknown or missing field takes its default |

## Why it is not a WidgetKit widget

A WidgetKit widget must ship as a signed `.appex` inside a `.app`. FrugalBar ships as a bare SwiftPM binary with no `.app` bundle, so there is nothing to host one. The widget is instead an `NSPanel` the app owns. The consequences:

- It exists only while FrugalBar is running. It does not appear in the macOS widget gallery or Notification Centre.
- It reads the live in-process store and the same history database as the History window, so it needs no extra request to any vendor.
- Empty states say why: "No subscription windows yet" (no provider with a usage window), "No readings in this range" (history still accumulating).

## Accessibility

- The chart is one accessibility element with a spoken summary of every series and the average, and the label names the metric and range.
- Each headroom row is read as, for example, "OpenAI WK window, 62 percent remaining. Resets in 3 days". A window with no figure reads "blocked" or "no reading", never 0.
- Urgency uses marker shape and the health symbol, not colour alone.
- Every control (vendor menu, window menu, range, metric) has a label.

Code: `Sources/QuotaBarUI/Widget/` (`DesktopWidgetWindow`, `DesktopWidgetView`, `AggregateBurndownPresentation`), preferences in `Sources/QuotaBarCore/Keychain/KeychainManager.swift`.
