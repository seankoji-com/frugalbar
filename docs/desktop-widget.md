# Desktop widget

A small panel that shows how much you are using your AI tools. Open it from the gear menu (**Desktop Widget**, ⌘D). Choosing it again hides it.

## Layouts

The segmented **Story | Tokens** control in the filter bar picks the body. The choice is stored with the filters. Chart and Overview were retired on 23 November 2026 and have since been removed; a stored choice of either opens as Story, and the other saved filters are kept.

| Layout | Shows |
|---|---|
| **Story** (default) | One pool, told in sentences: how much is left of the window the story follows, how much has gone and how fast against an even pace, when it would run out (labelled with its basis, recent rate or the window's average), when it resets, its other windows, and recent events, above the chart of that window. It follows the popover's top Use-now pick; the pool menu pins any other pool |
| **Tokens** | Raw token consumption across providers as a stacked area, described under [Tokens layout](#tokens-layout) |

The story makes no claim that was not measured or published. A spent or blocked pool says when it comes back; a stale one leads with the failed poll and makes no projection. Figures are "% left" and times use one unit (`39h`, `5d`), as in the popover.

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
| An unreadable history database, or a token query that stops part-way | "Could not read token history", never an empty or partial chart |
| No pass has finished since FrugalBar started | The activity table is empty on a first run and, on every later one, missing whatever the tools wrote while the app was closed. An empty chart says "Reading your local sessions…" and checks every few seconds; a chart with data says its totals may be incomplete. Never "No token activity". Nothing is remembered from an earlier run: that would vouch for a table nothing has caught up |
| A pass that could not read everything | An adapter failed, or skipped a transcript it may not open, a database that will not open, an OpenCode table that has gone, or an OpenCode query that fails part-way (the rows it read first are kept). Its tokens are missing from every total. A chart says "Some local sessions could not be read…"; an empty one says "Could not read all local sessions". A skipped input is retried on the next pass |
| An empty range, once a clean pass has finished this run | "No token activity in this range" and where tokens are counted from |

**What "complete" does and does not mean.** It means every adapter read every input it found without error, in this run. It does not mean the table is live: it trails the tools by up to one poll (about two minutes). And a malformed record inside a readable file is dropped by its adapter without a trace, which no status can see.

**Codex lands in lumps.** Codex records one cumulative total per session, placed at that session's last turn, so a long session is a single bump at its end rather than spread over its length. Spreading it would invent a distribution nobody recorded, so the chart says so under itself whenever Codex is drawn. Claude Code and OpenCode record per message.

### Controls

The vendor menu lists the providers that have token data, and the range picker offers 24h, 7d and 30d. The header names the selection and range ("All subscriptions · tokens · 24h") beside the overall health symbol. It shows no "updated" age, which would describe quota readings and not token history.

## Filters

| Filter | Layout | Options | Default |
|---|---|---|---|
| Pool | Story | The Use-now top pick, or any pool | Top pick |
| Subscriptions | Tokens | All, or any subset of providers with token data. Ticking every provider is stored as "all", so a provider you add later appears automatically | All |
| Range | Tokens | 24h, 7d, 30d | 24h |

## Pinned or floating

**Preferences → Display → Desktop widget → Position**:

| Mode | Behaviour |
|---|---|
| Pinned to desktop (default) | On the wallpaper, one level above the desktop icons and beneath every ordinary window. Above the icons on purpose: below them, Finder's desktop layer takes every click and the panel cannot be dragged, resized or filtered |
| Floats above windows | A normal floating panel above other windows |

Either way the panel can be dragged by its background, resized (minimum 340 × 260, default 420 × 320), joins all Spaces, and doesn't steal focus from the app you are using. The panel is always drawn dark.

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
- Empty states say why. The Tokens layout's are listed under [What it will not draw](#what-it-will-not-draw); the story leads with a failed poll rather than drawing an old figure as current.

## Accessibility

- The Tokens chart is one accessibility element. It speaks the total, each provider's share and every footnote shown under it, from the same strings, so what is read out is what is drawn. Layers are told apart by hue, which is why the three are kept well apart (OpenCode is drawn in blue, not its brand amber, which sits next to Claude's salmon).
- Urgency uses the health symbol's shape, not colour alone.
- Every control (layout, pool menu, vendor menu, range) has a label.

Code: `Sources/QuotaBarUI/Widget/` (`DesktopWidgetWindow`, `DesktopWidgetView`, `WidgetFilters`, `ProviderStoryPresentation`, `TokenUsagePresentation`), preferences in `Sources/QuotaBarCore/Keychain/KeychainManager.swift`.
