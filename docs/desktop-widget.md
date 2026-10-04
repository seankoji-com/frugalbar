# Desktop widget

A small panel that shows how much you are using your AI tools. Open it from the gear menu (**Desktop Widget**, ⌘D). Choosing it again hides it.

## Layouts

The segmented **Tokens | Chart | Overview** control in the filter bar picks the body. The choice is stored with the filters.

| Layout | Shows |
|---|---|
| **Tokens** (default) | Raw token consumption across providers as a stacked area, described under [Tokens layout](#tokens-layout) |
| **Chart** | Burndown lines, the average and the headroom strip, described under [Chart layout](#what-it-shows-chart-layout) |
| **Overview** | One tile per provider with each of its windows: a bar, the figure in the chosen metric and a reset tooltip. Tiles follow the popover's provider order and visibility. A configured provider that cannot be read keeps its tile and says why; one that is not configured has none. A hand-entered billing cycle is labelled elapsed time, never usage. Window and range filters are chart-only and hidden here |

The Overview has **no total, average or combined figure**: each number belongs to one provider's own window. Its tiles are read as, for example, "Claude, Max (5x). weekly 60 percent remaining, resets in 3 days. 5-hour blocked".

## Tokens layout

One layer per provider, stacked bottom to top in a fixed order (Claude, OpenAI, OpenCode), with a line along the top for the total and a legend of each provider's total in the range. The y axis is tokens (`1.2k`, `340k`, `12M`); the x axis is time.

| Range | Bucket width |
|---|---|
| 24h | 30 minutes |
| 7d | 3 hours |
| 30d | 12 hours |

Buckets sit on local midnight, so every width divides the day and edges fall on whole hours.

### Where the numbers come from

The local activity history: tokens that Claude Code, Codex and OpenCode recorded on this Mac, ingested into the history database already used by the History window. They are summed inside SQLite per source per bucket, so a 30-day range does not load every record.

### What it is not

- **Not a quota.** There is no percentage, no "remaining" and no allowance anywhere in this view. Tokens share one unit, which is why stacking and summing them is meaningful; quota windows do not, and the other layouts never combine them.
- **Not what a vendor billed.** It is what local tools recorded.
- **Cache tokens are included**, as each tool reports them. The tools may not count cache the same way, so compare each provider's trend over time, not providers against each other. There is deliberately no "without cache" switch: whether a tool's input figure already contains its cached input is not something FrugalBar has verified per tool, and a wrong figure is worse than none.

### What it will not draw

| Case | What happens |
|---|---|
| A provider with no token source (Gemini, Grok, Kiro, ClinePass, Copilot, OpenRouter, DevPass, Command Code) | No layer, never a flat zero. It is named under the chart: "No token counts for Gemini, Grok." |
| A record whose tool reported no token figure | Not summed, and not counted as zero. The chart says how many were left out |
| A provider with no tokens in the range | No layer and no legend entry |
| A time bucket where a tool recorded nothing | Zero observed tokens, which is true |
| A provider you hid | Not drawn, like everywhere else |
| An unreadable history database | "Could not read token history", never an empty chart |
| The first ingestion has not finished | The activity table is empty, or partly filled, until FrugalBar has read your session history once. An empty chart says "Reading your local sessions…" and checks every few seconds; a partly filled one says its totals may be incomplete. Never "No token activity" |
| A tool whose sessions could not be read | The latest pass failed for it, so its tokens are missing from every total. A chart says "Some local sessions could not be read…"; an empty one says "Could not read all local sessions" |
| An empty range, once a clean pass has finished | "No token activity in this range" and where tokens are counted from |

**Codex lands in lumps.** Codex records one cumulative total per session, placed at that session's last turn, so a long session is a single bump at its end rather than spread over its length. Spreading it would invent a distribution nobody recorded, so the chart says so under itself whenever Codex is drawn. Claude Code and OpenCode record per message.

### Controls

The vendor menu lists the providers that have token data, and the range picker offers 24h, 7d and 30d. The window menu and used/remaining switch are quota concerns and are hidden here. The header shows no "updated" age, which would describe quota readings and not token history.

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
- The Tokens chart is one element too. It speaks the total, each provider's share and every footnote shown under it, from the same strings, so what is read out is what is drawn. Layers are told apart by hue, which is why the three are kept well apart (OpenCode is drawn in blue, not its brand amber, which sits next to Claude's salmon).
- Each headroom row is read as, for example, "OpenAI WK window, 62 percent remaining. Resets in 3 days". A window with no figure reads "blocked" or "no reading", never 0.
- Urgency uses marker shape and the health symbol, not colour alone.
- Every control (vendor menu, window menu, range, metric) has a label.

Code: `Sources/QuotaBarUI/Widget/` (`DesktopWidgetWindow`, `DesktopWidgetView`, `AggregateBurndownPresentation`), preferences in `Sources/QuotaBarCore/Keychain/KeychainManager.swift`.
