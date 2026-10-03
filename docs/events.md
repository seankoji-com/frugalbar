# AI events

FrugalBar keeps a log of three things on the platforms you use: **resets**, **outages**, and **models that became selectable on your subscription**. The log is a record of **observations** of things that already happened. Nothing in it is inferred from silence, nothing is created to fill a gap, and no forecast or "reset expected" guess is ever read. That is the same rule as "never synthesise a quota", applied to history.

## Event kinds

| Kind | Meaning | Evidence | Caption |
|---|---|---|---|
| **Vendor reset** | A vendor reset usage for everyone (or a plan tier), or granted a banked reset to apply later. | A community tracker's curated record of the announcement, after it landed, with a link to the post. See [Reset trackers](#reset-trackers). | Via claude-resets.com (community tracker) |
| **Usage restored** | Used fell by 15 points or more *before* the published reset: how a vendor reset looks from your own account. If the vendor also moved the reset time forward, the event says the window restarted early. | Two measured polls of the same window: both fractions, a previous reset time still in the future, and a current reset time. | From the vendor's usage endpoint |
| **Reset credit** | The vendor granted your account a banked reset credit. | OpenAI: `rate_limit_reset_credits.available_count` in the Codex usage payload rose between two polls that both carried it. Anthropic: the summed `resets_left` of the `cedar_ember` grants rose (empty today, see below). | From the vendor's usage endpoint |
| **Outage** | The vendor's official status page opened a **major** or **critical** incident on a product you use. | The status page's incident, its impact, its affected components and its own start time. | From status.claude.com |
| **Outage resolved** | The status page marked that incident resolved. | The incident's `resolved_at`; the detail gives the duration. | From status.claude.com |
| **New model** | A model appeared on the list your own account can select. | The account-scoped model list your tool's CLI reads, fetched with the same credential as the quota. See [Account model lists](#account-model-lists). | From your account's model list |
| **Usage reset** (log only) | A quota window rolled over at its scheduled reset. | The previous poll's `resetsAt` has passed and the new poll reports a reset time more than 60 s later. | From the vendor's usage endpoint |

Usage reset is routine (every five hours for some vendors), so it never takes the popover's row or a banner here; it stays in the log, in **History → Events** and on the timeline, and has its own per-vendor opt-in under **Reset alerts**.

`new_model` and `price_change` rows recorded by earlier versions from the OpenRouter catalog and vendor news feeds stay on disk but are never shown or announced: a launch post or a catalog listing is not a model you can pick yet.

### What is deliberately not inferred

- **A lost reading is not a drop to zero.** Reset, restore and credit detection all need both polls to be `.measured`. A 401 or a timeout never produces a "usage restored" banner.
- **A restore is not a reset.** Once the vendor's reset time has passed, a drop is a Usage reset; while it is still ahead, a drop is a Usage restored.
- **A vendor reset is the vendor's word, not your account's figure.** It records that the vendor announced a reset for a scope ("everyone", "Max", "Pro, Max + Team") and links the post. Whether your own window moved is what Usage restored measures.
- **Only the past.** The trackers also publish next-reset forecasts and probabilities. They are never read: a guess about tomorrow is not an observation.
- **Minor incidents are not outages.** Statuspage's `minor` covers a slow console or one model's latency and is filed several times a week; only `major` and `critical` are recorded.
- **A model is new once.** Each account's first list seeds silently, and a model that drops out of the list and returns is not announced again.
- **Anthropic reset grants are parsed but currently empty.** The OAuth usage endpoint answers a CLI login with `eligible: false, ineligible_reason: "surface"`, so the Claude row shows no reset-credit figure. Claude's banked resets still appear as Vendor reset events from the tracker.

## Where the evidence comes from

All outbound sources are switched by one toggle, **Preferences → General → AI events → Track resets, outages and new models** (on by default), and are read only for vendors you have configured.

### Status pages

Official Statuspage incident history (`/api/v2/incidents.json`, the newest 50 incidents), polled every **10 minutes**. No credential.

| Page | Vendor row | Incidents that count |
|---|---|---|
| `status.claude.com` | Claude | Components Claude Code, Claude API, claude.ai, or none listed (Anthropic files platform-wide failures with no component) |
| `status.openai.com` | OpenAI | The page lists no components: the incident name mentions Codex, or the impact is critical |
| `www.githubstatus.com` | GitHub Copilot | Components Copilot or Copilot AI Model Providers |

OpenRouter and xAI answer the incident API with 403. Google (Gemini), Kiro, OpenCode, Cline, Command Code and LLM Gateway publish no machine-readable status history.

### Reset trackers

No vendor publishes bonus resets anywhere a program can read; they are announced on X. Two community trackers keep a curated, dated record with links to the posts. Polled every **hour**. No credential.

| Tracker | Vendors | Read | Not read |
|---|---|---|---|
| `claude-resets.com/api/resets` | Claude (from @ClaudeDevs and Anthropic staff), Codex (from @thsottiaux) | `kind: "reset"` entries; `resetType: "banked"` and `usableUntil` for banked resets | `kind: "policy"` entries (limit changes), ids in `meta.provisionalEventIds` (not yet verified) |
| `whenreset.dev/api/resets` | Grok | `type: "reset"` and `type: "card"` (banked) with a `landedAt` | The `watch` block (scheduled and expected resets), forecasts, every other vendor |

Each vendor comes from exactly one tracker, so a reset is never recorded twice from two posts. codex-reset.com was evaluated and left out: its timeline classifies posts automatically and files non-resets under `type: "reset"`, and its `/api/forecast` is a self-described experimental model.

### Account model lists

Each subscription's own model list, fetched with the credential its quota already uses, polled every **hour**.

| Subscription | Request | Selectable means | Checked live |
|---|---|---|---|
| Codex | `GET chatgpt.com/backend-api/codex/models?client_version=<latest>` | `visibility == "list"`. The list is gated on `client_version`, so FrugalBar sends the latest Codex CLI release (from npm, falling back to `~/.codex/models_cache.json`): a model that appears is one the current release can select, not one revealed because a version number moved | Yes |
| Claude | `GET api.anthropic.com/api/claude_cli/bootstrap` (Claude Code's own bootstrap) | `model_access[].entitled == true` | No: read from the Claude Code binary; the token is in the Keychain |
| Gemini | `POST cloudcode-pa…/v1internal:fetchAvailableModels` for the `loadCodeAssist` project | Every model id except internal helpers (`chat_`, `tab_`, `rev_`, image, mquery, lite) | No: local tokens had expired |
| GitHub Copilot | `GET api.githubcopilot.com/models` | `model_picker_enabled`, `capabilities.type == "chat"`, `policy.state` not `disabled` | Yes |
| OpenCode Go | `GET opencode.ai/zen/go/v1/models` (always authenticated: the list is filtered to the workspace) | Every id | Yes |
| Kiro | `POST` `AmazonCodeWhispererService.ListAvailableModels` with `origin: KIRO_CLI` | Every `modelId` | Yes |
| Grok | `GET cli-chat-proxy.grok.com/v1/models` | Every id | Yes |
| DevPass | `GET api.llmgateway.io/v1/models` (scoped to the key) | Every id without `deactivated_at` | Yes |
| ClinePass | `GET api.cline.bot/api/v1/ai/cline/recommended-models`, a plan catalogue | `clinePass[]`, and only when `/users/me/plan` reports `cline_pass.enabled` | Yes |

Command Code has no model list (its CLI decides access from a table compiled into the client), and OpenRouter is pay-as-you-go with ~460 models from every lab, so neither is read. A list that cannot be read, or comes back empty, changes nothing.

## Deduplication

Every candidate goes through one call, `QuotaHistoryStore.recordEvents`, which inserts each `id` once and returns only the newly inserted events. Notifications are driven by that return value and nothing else, so a restart, a repeated poll or a source that re-serves history cannot post twice. That is also why the status pages and trackers need no checkpoint: re-reading their whole history every poll is harmless.

| Kind | Id components (`AIEvent.makeID`: kind, vendor, then these) |
|---|---|
| Usage reset | window label, new reset time (epoch s) |
| Usage restored | window label, published reset time, before %, after % |
| Reset credit | previous count, new count, poll time |
| Vendor reset | the announcing post's id |
| Outage / Outage resolved | status page name, the vendor's incident id |
| New model | `account`, the model id |

## Notifications

Banners are posted with `osascript` `display notification`. FrugalBar ships as a bare executable with no bundle id, so macOS attributes the banner to the process that runs it.

| Rule | Behaviour |
|---|---|
| Per-kind toggles | **Preferences → General → AI events → Notify about.** Every kind above except Usage reset, all on by default. The preference stores the kinds you switched *off*, so a kind added later notifies by default; a choice saved by an older version is honoured for the kinds it offered. |
| Usage reset | Per vendor under **Preferences → General → Reset alerts**, off by default. |
| Age cutoff | An event whose `occurredAt` is older than **48 hours** is recorded but never announced. This is what keeps the first poll's backfill of months of resets and outages silent. |
| Wording | A banner is the event's title ("Codex reset for everyone", "GPT-6.2 now available in Codex"); outage banners lead with the vendor, since incident names often don't say it. Several events of one kind in one poll become "3 new models" with the titles in the body. |

## Where events appear

| Place | What you see |
|---|---|
| Popover | A "Latest event" card with the newest surfaced event and a "See all" link. Hidden when there are none. The row shows the vendor's logo, the title, its age and source. |
| History → Events tab | Every listed event grouped by day. Filters: vendor, time range (24 Hours / 7 Days / 30 Days / All Time, default 7 Days), and kind chips for the kinds above (all on). Each row has a detail line and a link to the post, incident or vendor page (http/https only). Sample mode shows a note: the fixture records no events. A read failure shows an error card, never an empty list. |
| History → timeline | Dashed vertical markers for Usage reset, Usage restored, Reset credit and Vendor reset on the vendor you are viewing. Outages and models say nothing about the allowance the chart plots, so they are never markers. |
| Inspector | "Recent events" for that vendor (the newest five surfaced). See [inspector.md](inspector.md). |

Rows carry no kind symbol: every title says what happened in words ("Outage: …", "Resolved: …", "Claude banked reset for Pro, Max + Team"). The spoken label also names the kind: "Vendor reset, Claude: Claude reset for everyone, 3 hours ago, via claude-resets.com (community tracker)".

## Data and retention

Two tables, both additive (`CREATE TABLE IF NOT EXISTS` on every open) in the same SQLite file as quota history:

| Table | Holds | Retention |
|---|---|---|
| `event` | The log. Primary key `id`. | **365 days**, pruned every 6 hours whether or not tracking is on. |
| `account_model` | Every model each account's list has carried: `(vendor, model_id)`, display name, `first_seen`, `last_seen`. | Not pruned, so a returning model is never new |

The retired `catalog_model` and `feed_item` tables are no longer created; databases that already have them keep them untouched. The schema version was **not** bumped: a bump drops user data. See `AGENTS.md`.

## For maintainers

`AIEventKind` and `AIEventSource` raw values are persisted, so never rename a case; add one. `AIEventKind.surfaced` is the list the popover, notifications and History use; `AIEvent.isSurfaced` additionally requires a new model to come from `.accountModels`.

**Add a status page.** Append a `StatusPage` to `StatusPage.all` in `StatusIncidentWatcher.swift` with a `Relevance` that names the components (or, for a page without components, the product words). Keep the `name` stable: it is in every event id and source.

**Add a reset tracker.** Append a `ResetTracker` with the vendors it is trusted for (one tracker per vendor) and a parser that reads only landed resets. Fixtures go in `ResetTrackerWatcherTests`, including an entry that must be dropped.

**Add an account model list.** Add the vendor to `AccountModelLister.supportedVendors` and a case to `AccountModelLister.live` that reads the endpoint the vendor's own CLI uses for its model picker, with the provider's existing credential. Return nil for anything other than a clean, account-scoped answer.

**Add a poll detector.** Write a pure `enum` that takes `previous` and `current` snapshot dictionaries and an explicit `now`, requires both polls `.measured`, and treats a missing figure as no event. Add the `AIEventKind` case (`title`, `symbolName`, `pluralTitle`, `notificationCaption`, `surfaced`), build the event in `AIEventEngine` with `AIEvent.makeID`, route it through `QuotaNotificationObserver.observeTransitions` and `AIEventEngine.recordPollEvents`, and show the test fails when the guard is removed (see `UsageRestoreDetectorTests`).

Tests: `ResetTrackerWatcherTests`, `StatusIncidentWatcherTests`, `AccountModelWatcherTests`, `AIEventEngineTests`, `AIEventStoreTests`, `PendingPollTests`, `UsageRestoreDetectorTests`, `EventsPresentationTests`.
