# AI events

FrugalBar keeps a log of things that happened on the platforms you use: a quota window rolled over, a vendor restored your usage early, a model was listed, a price changed. The log is a record of **observations**. Nothing in it is inferred from silence, and no event is created to fill a gap. That is the same rule as "never synthesise a quota", applied to history: an event claiming something happened when nothing was measured is the same defect as an invented percentage.

## Event kinds

| Kind | Meaning | Evidence | Source label shown |
|---|---|---|---|
| **Usage reset** | A quota window rolled over at the reset time the vendor published. | Two consecutive polls: the previous poll's `resetsAt` has passed and the new poll reports a reset time more than 60 s later. A drop in the used fraction alone never counts. | From the vendor's usage endpoint |
| **Usage restored** | Used fell by 15 points or more *before* the published reset. This is how an unscheduled restore looks from outside. If the vendor also moved the reset time forward (a vendor-wide "we've reset everyone's limits" that restarts the clock), the event says the window restarted early. | Two measured polls of the same window: both fractions, a previous reset time still in the future, and a current reset time. The event states those figures and never says why. | From the vendor's usage endpoint |
| **Reset credit** | The vendor granted a banked reset credit you can redeem. | OpenAI: `rate_limit_reset_credits.available_count` in the Codex usage payload rose between two polls that both carried it. Anthropic: the summed `resets_left` of the `cedar_ember` grants rose (see the note below on why this is empty today). | From the vendor's usage endpoint |
| **New model** | A model appeared in a source FrugalBar fetched. | A model id first seen in the OpenRouter catalog, or a vendor feed item whose title announces a model. | From the OpenRouter model catalog, or From the `<feed>` feed |
| **Price change** | A model's API price differs from the one stored last poll. | OpenRouter catalog prices on both sides of the change, or a vendor feed item whose title announces pricing. | As above |

### What is deliberately not inferred

- **A lost reading is not a drop to zero.** Reset, restore and credit detection all need both polls to be `.measured`. A 401 or a timeout never produces a "usage restored" banner.
- **A restore is not a reset.** The two detectors split on one fact, the vendor's reset time: once it has passed, a drop is a Usage reset; while it is still ahead, a drop is a Usage restored. A restore whose reset time also jumped forward is recorded as a restore that restarted the window, and the reset detector stays silent, so no poll is announced twice.
- **Credits count the banked total only, and only when both polls published it.** `applicable_available_count` (redeemable right now) changes as you consume usage, so it is shown but never triggers an event. A count that drops out of one poll and comes back is not a grant. `credits.balance` is not displayed anywhere: its unit is unverified.
- **No first-launch backlog.** Reset credits, restores and resets are edge-triggered (they need a previous poll). The catalog's first poll seeds silently. A feed's first poll keeps only items from the last 7 days, and undated items are treated as history.
- **Price needs two figures.** A price appearing where there was none, or vanishing, is stored but not announced.
- **Variants are ignored.** OpenRouter ids containing `:` (`:free`, `:thinking`, `:extended`) never produce events.
- **Anthropic reset grants are parsed but currently empty.** FrugalBar asks the OAuth usage endpoint for them (`?cedar_ember=1`, a feature flag the claude.ai web UI uses). As of 3 Oct 2026 Anthropic answers a CLI login with `eligible: false, ineligible_reason: "surface"` and no grants, even for an account that holds a full reset on claude.ai, so the Claude row shows no reset-credit figure. Nothing is substituted for the missing figure. If Anthropic opens the surface, the row and the Reset credit event start working without a code change.
- **Feed matching is conservative.** A false "New model" banner costs more trust than a missed one, and the catalog catches most releases anyway. A new-model item needs an announcement phrase *and* a versioned model name in the title ("Claude Sonnet 5.5", "GPT-6", "Gemini 4"); "Introducing Gemini in Chrome" or "Meet the new Gemini app" name a family, not a release, and never qualify. A price item needs a pricing phrase in the title plus a model, plan or API context; rate-limit or usage-limit increases are allowance news, not price news, and are never recorded as a price change. Summaries alone never qualify.

## Where the evidence comes from

| Source | Request | Credential | Vendors | Notes |
|---|---|---|---|---|
| Quota polls | The vendor usage endpoint you already configured | Yours, as for the quota row | All with a measured window | No extra request |
| OpenRouter catalog | `GET https://openrouter.ai/api/v1/models` | **None** (public) | Anthropic, OpenAI, Google, xAI, by id prefix (`anthropic/`, `openai/`, `google/`, `x-ai/`) | The only source for Grok model and price news. Polled every 6 hours; if nothing is reachable (launch before Wi-Fi), the retry comes 10 minutes later. Events are recorded *before* the new baseline is stored, so a crash in between re-derives them rather than losing them |
| OpenAI news | `https://openai.com/news/rss.xml` | None | OpenAI | Official |
| Google AI blog | `https://blog.google/technology/ai/rss/` | None | Gemini | Official |
| Google DeepMind | `https://deepmind.google/blog/rss.xml` | None | Gemini | Official |
| Anthropic news | Community scrape, `Olshansk/rss-feeds` on GitHub | None | Claude | **Unofficial.** The caption reads "(unofficial scrape)" so it never looks like Anthropic speaking |

xAI publishes no feed, so Grok model news comes from the catalog only. Other vendors' models in the catalog (Meta, Mistral, DeepSeek) are ignored.

External sources are polled at most **every 6 hours**, independently of the 2-minute quota poll. A failed fetch (network, non-2xx, unparseable body, unreadable stored state) yields no events and leaves stored state untouched, so a bad poll cannot reseed the catalog or re-announce a feed backlog.

## Deduplication

Every candidate goes through one call, `QuotaHistoryStore.recordEvents`, which inserts each `id` once and returns only the newly inserted events. Notifications are driven by that return value and nothing else, so a restart, a repeated poll or a feed that re-serves an item cannot post twice.

Ids are built from the facts that define the event, never from a UUID or from prose (`AIEvent.makeID`: kind, vendor, then components):

| Kind | Id components |
|---|---|
| Usage reset | window label, new reset time (epoch s) |
| Usage restored | window label, published reset time, before %, after % |
| Reset credit | previous count, new count, poll time (edge-triggered, so the poll time separates a second grant from a re-derivation) |
| New model | OpenRouter model id, or the feed item's own guid |
| Price change | model id, new prompt price, new completion price (a later second change is a new event) |

Rewording a title cannot create a second copy of an event. Renaming a feed (`VendorFeed.name`) does: it re-announces that feed's backlog, so don't.

## Notifications

Banners are posted with `osascript` `display notification`. FrugalBar ships as a bare executable with no bundle id, so macOS attributes the banner to the process that runs it rather than to "FrugalBar".

| Rule | Behaviour |
|---|---|
| Per-kind toggles | **Preferences → General → AI events → Notify about.** On by default for Usage restored, Reset credit, New model, Price change. |
| Usage reset | Not in that list. It stays per vendor under **Preferences → General → Reset alerts**, off for every vendor by default. The log records resets for all vendors whether or not you opted in: the log is a record, the banner is the opt-in. |
| Age cutoff | An event whose `occurredAt` is older than **48 hours** is recorded but never announced. This stops a feed's first week of items, or a model listed long after its `created` date, from arriving as stale news. |
| Consolidation | One banner per kind per poll. Several events become "3 new models" with the titles in the body. |
| Tracking switch | **Track model releases and pricing** gates only the outbound polling (catalog and feeds). On by default because the requests carry no credential and read public data. Quota-derived events are recorded regardless. |
| Quota-recovery toggle | The separate "Quota-recovery notifications" setting is unrelated and off by default. |

## Where events appear

| Place | What you see |
|---|---|
| Popover | A "Recent events" card with the newest 3 events and a "See all" link. Hidden when there are no events. The store holds the newest 20. |
| History → Events tab | Every recorded event grouped by day. Filters: vendor, time range (24 Hours / 7 Days / 30 Days / All Time, default 7 Days), and kind chips (all on by default). Each row shows kind symbol, vendor, title, relative time, source caption, a detail line and a link to the vendor page when there is one (http/https only). Sample mode shows a note: the fixture records no events. A read failure shows an error card, never an empty list. |
| History → timeline | Dashed vertical markers for Usage reset, Usage restored and Reset credit on the vendor you are viewing. Catalog and feed events say nothing about the allowance the chart plots, so they are never markers. |
| Inspector | "Recent events" for that vendor. See [inspector.md](inspector.md). |

Every kind has its own SF Symbol, so colour is never the only channel. Rows carry a spoken label of the form "New model, Claude: Claude Sonnet 5.5 listed, 3 hours ago, from the OpenRouter model catalog".

## Data and retention

Three tables, all additive (`CREATE TABLE IF NOT EXISTS` on every open) in the same SQLite file as quota history:

| Table | Holds | Retention |
|---|---|---|
| `event` | The log. Primary key `id`. | **365 days.** Pruned on the external-poll cadence (every 6 hours), whether or not catalog and feed tracking is on. |
| `catalog_model` | Last seen catalog entry per model, with prices as decimal text (so a binary float can't invent a price change), `first_seen`, `last_seen`. | Not pruned |
| `feed_item` | `(feed, item_id)` pairs already judged, so each item is classified exactly once. | Not pruned |

Quota readings keep their own 90-day retention. The schema version was **not** bumped for these tables: a bump drops user data. See `AGENTS.md`.

## For maintainers

All code is in `Sources/QuotaBarCore/Events/`. `AIEventKind` and `AIEventSource` rawValues are persisted, so never rename a case; add one.

**Add a feed.** Append a `VendorFeed(name:url:vendorId:isOfficial:)` to `VendorFeed.all` in `VendorFeedWatcher.swift`. Pick a `name` you will never change (it is persisted in `feed_item` and in the source as `feed:<name>`). Set `isOfficial: false` for any third-party scrape. Add parsing cases to `FeedParserTests` only if the format is new; classification is shared. Tune wording in `FeedItemClassifier` conservatively and extend `FeedItemClassifierTests` with a title that must *not* match.

**Add a catalog vendor.** Add a prefix to `CatalogDiff.vendor(forModelId:)` in `OpenRouterCatalogWatcher.swift`.

**Add a poll detector.** Write a pure `enum` in `Sources/QuotaBarCore/Events/` that takes `previous` and `current` snapshot dictionaries (and an explicit `now`), requires both polls `.measured`, treats a missing figure as no event, and returns a small event struct. Then:

1. Add the `AIEventKind` case (`title`, `symbolName`, `pluralTitle`, `notificationCaption`) and decide whether `EventsPresentation.markerKinds` includes it.
2. Build the `AIEvent` in `AIEventEngine` with an id made from facts via `AIEvent.makeID`.
3. Return it from `QuotaNotificationObserver.observeTransitions` and pass it through `AIEventEngine.recordPollEvents` in `AppMain.recordAIEvents`.
4. Add a toggle in `SettingsView` and, if it should default on, to `CredentialStore.defaultEventNotificationKinds`.
5. Test with an explicit `now`, and show the test fails when the guard is removed (see `UsageRestoreDetectorTests`).

Tests live in `Tests/`: `UsageRestoreDetectorTests`, `CatalogDiffTests`, `FeedItemClassifierTests`, `VendorFeedWatcherTests`, `AIEventEngineTests`, `AIEventStoreTests`.
