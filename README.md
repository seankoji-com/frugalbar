# frugalbar — track AI usage & dev limits

<p align="center">
  <img width="652" height="1280" alt="image" src="https://github.com/user-attachments/assets/35c85ad5-6832-4095-a8d6-c6eaa5d505fa" />
</p>


A native macOS menu bar app that shows how much headroom you have left across AI subscriptions, API spend caps, and developer rate limits.

Each subscription's windows line up in **5H / WK / MO** columns, with the share used under each bar; hover a row for its recent-pace forecast. Click a provider row to open its inspector: a Burndown | History chart, the vendor's recent events and any banked reset credits. An ideal-pace line appears only when the vendor publishes a window length and reset, and a projection only from a measured recent pace. See [docs/inspector.md](docs/inspector.md).

---

## Why FrugalBar?

Modern engineering workflows rely on many AI models and developer platforms (Claude, OpenAI, Gemini, GitHub Copilot, OpenRouter, DeepSeek, Grok, Kiro, OpenCode, DevPass, Command Code, ClinePass, Muse and the GitHub APIs). However:

- **Surprise quota exhaustion**: Running multi-step autonomous agent runs or code generation tasks often grinds to a halt midway through a long job because a hidden rate limit or budget cap was breached.
- **Scattered dashboards**: Checking balances requires navigating half a dozen provider dashboards, consoles, and billing portals.
- **Inaccurate estimations**: Many tools guess or synthesize quotas. **FrugalBar never fakes a quota** — if a vendor publishes actual limit telemetry, it draws a real gauge; if not, it reports verified key status honestly without fabricated percentages.
- **Glanceable decision making**: With a discreet menu bar indicator and responsive dark popover, you know immediately whether you have enough headroom to kick off your next agent workflow or batch job.

---

## Installation & Distribution

### Homebrew (Recommended)

Install `frugalbar` in a single command:

```bash
brew install seankoji-com/tap/frugalbar
```

*(Or tap the repository first: `brew tap seankoji-com/tap && brew install frugalbar`)*

To start FrugalBar and have it launch automatically at login:
```bash
brew services start frugalbar
```

To override the Gemini API endpoint for the Homebrew service (defaults to
`https://daily-cloudcode-pa.googleapis.com`), set the launchd environment before starting it:

```bash
launchctl setenv FRUGALBAR_GEMINI_API_BASE https://daily-cloudcode-pa.googleapis.com
brew services restart frugalbar
```

Remove the override with `launchctl unsetenv FRUGALBAR_GEMINI_API_BASE` and
restart the service to return to the default endpoint.

To stop it and remove it from login items:
```bash
brew services stop frugalbar
```

Or run it directly:
```bash
frugalbar &
```

### Direct Download & Swift Package

You can download prebuilt release binaries from [GitHub Releases](https://github.com/seankoji-com/frugalbar/releases) or run from source:

```bash
# Clone and run from source
git clone https://github.com/seankoji-com/frugalbar.git
cd frugalbar
swift run
```

---

## Quick Start & Configuration

1. Launch `frugalbar` or click the menu bar status icon.
2. Open **Preferences → API Keys** (gear icon).
3. Add your provider credentials:
   - **GitHub**: One PAT covers REST, GraphQL rate limits, and Copilot subscription status.
   - **OpenRouter**: Use an API key. With a provisioning key, FrugalBar shows the live account credit balance. Otherwise it reports that key's own spend: against its spend cap when the key has one, and as lifetime spend when it has none — the case for a key created without a cap. The per-window spend columns are gone — the balance or the key's spend is the one figure the row reports.
   - **DeepSeek**: Paste a `sk-…` API key, or set `DEEPSEEK_API_KEY` / enable CLI discovery to read the OpenCode auth.json entry, to show the prepaid credit balance.
   - **Antigravity**: Connect Google OAuth once for Gemini, Argon and "Claude/GPT (shared)". These independent allowances share one service heading, each with its own row and visibility control. Argon uses only its published quota group, never Gemini's windows; the shared Claude/GPT pool is independent of direct Claude Code. All three rows reuse each host's project-scoped response within a refresh, and each falls through to the alternate host when its own pool is absent or disabled. A missing or malformed pool stays unavailable.
   - **Anthropic Claude**: Sign in with the Claude Code CLI or connect a CLI Proxy hub; enable CLI discovery and FrugalBar reads that active OAuth session.
   - **OpenAI / ChatGPT**: Sign in with the Codex CLI or connect a CLI Proxy hub; enable CLI discovery and FrugalBar reads that session.
   - **OpenCode Go**: Configure a token under Preferences → OpenCode Go. Add a row per subscription workspace and arrange them in the order you want them listed; each named workspace is fetched with its own key and shown as its own rolling / weekly / monthly reading. The original workspace keeps your existing key and the CLI `auth.json` fallback, wherever you move it in the list.
   - **Grok**: Sign in with the Grok CLI (`grok login`); enable CLI discovery and FrugalBar reads `~/.grok/auth.json`.
   - **Kiro**: Sign in with the Kiro CLI or IDE; enable CLI discovery and FrugalBar reads the CLI's own state database.
   - **DevPass**: Paste an `llmgtwy_…` key from the LLM Gateway dashboard.
   - **Command Code**: Sign in with the `cmd` CLI (`cmd login`); enable CLI discovery and FrugalBar reads `~/.commandcode/auth.json`. A `user_…` API key can also be pasted directly, or set `COMMAND_CODE_API_KEY` / `COMMANDCODE_API_KEY`.
   - **ClinePass**: Sign in with the Cline CLI (`cline auth`) or the Cline extension; enable CLI discovery and FrugalBar reads `~/.cline/data/settings/providers.json` (or `$CLINE_DATA_DIR`). A Cline API key from app.cline.bot can also be pasted directly, or set `CLINE_API_KEY` / `CLINEPASS_API_KEY`.
   - **Muse**: Sign in with the Muse Code CLI (`muse login`); enable CLI discovery and FrugalBar reads that login from the macOS Keychain. Paste the OAuth access token to skip discovery — the minted `api_key` is **not** accepted and answers 401. When the CLI response omits usage, connect the read-only portal session under **Settings → API Keys → Muse portal quota** and select the team holding your subscription.

Credentials are validated against live vendor endpoints upon saving to immediately catch typos or permission issues.

---

## Preferences

Gear menu → **Settings…** (⌘,) has a sidebar of sections:

| Section | What it does |
|---|---|
| **Providers** | Each provider's connection state from the last poll (a symbol, the reason, and what to do about it), whether it is shown, and its order. Antigravity's independent pools form one service block, anchored at its first visible pool in the saved order, with stable pool order inside it. *Soonest deadline first* (default) places blocks by the soonest longest-window reset among their usable members; *Custom order* keeps the saved block order. A block moves to the bottom only when every member has a spent or blocked window. OpenCode Go workspaces likewise stay together in their saved order. A hidden provider is **not polled** and is absent from the popover, menu bar, advice, desktop widget and notifications. Its key stays put, so showing it again is instant |
| **API Keys** | Credentials per provider, where each one is coming from, and CLI discovery |
| **OpenCode Go** | One row per subscription workspace: name, key, monitoring, and order (drag a row or use its arrows) |
| **Display** | Desktop widget position, and a key to the popover's symbols |
| **Notifications** | Quota-recovery notifications, reset alerts, and which AI events notify |
| **Billing Cycles** | Renewal dates for vendors that publish no billing period |
| **History & Data** | AI event tracking, and where quota history is kept |
| **About** | Version and links |

The running version is shown in the popover footer ("v1.4.2", or "dev" for a local build) and in **About**.

The popover groups Gemini, Argon and the shared Claude/GPT pool under one **Antigravity** heading, with separate **Claude** (Claude Code) and **ChatGPT** (Codex) headings. Each pool keeps its own bars, resets, plan and inspector identity. A spent pool stays inside its service block while another pool remains usable. Grouping changes no stored preferences and combines no quota figures.

---

## What It Can Actually Measure

Not every vendor publishes usage telemetry. Where a vendor doesn't provide real consumption numbers, FrugalBar states so explicitly instead of fabricating an estimate:

| Provider | Source | Telemetry Provided |
|---|---|---|
| **GitHub REST** | `GET https://api.github.com/rate_limit` → `resources.core` | Live gauge: requests/hour remaining with reset countdown |
| **GitHub GraphQL** | `GET https://api.github.com/rate_limit` → `resources.graphql` | Live gauge: points/hour remaining with reset countdown |
| **OpenRouter** | `GET https://openrouter.ai/api/v1/auth/key`, then `GET https://openrouter.ai/api/v1/credits` | Live account credit balance in USD when the key may read it; otherwise that key's spend — against its cap, or as lifetime spend when the key has no cap. One figure per row: the per-window spend columns (`usage_daily` / `usage_monthly`) were removed, since they are UTC-calendar-aligned with no reset timestamp and read as spend that vanished. `usage_weekly` is still decoded: where the payload carries it, the row captions that key's spend with its week figure |
| **DeepSeek** | `GET https://api.deepseek.com/user/balance` with the DeepSeek API key | Live prepaid account credit balance in the account's own currency (USD or CNY), with the granted and topped-up split. DeepSeek publishes no spend window and no cap, so this is a balance and never a gauge; the vendor's `is_available` flag carries the critical band |
| **OpenAI / ChatGPT** | `GET https://chatgpt.com/backend-api/wham/usage` via the Codex session or CLI Proxy hub | Live 5-hour and weekly subscription windows, each labelled from the window length OpenAI reports. Also the count of banked reset credits (`rate_limit_reset_credits`) when OpenAI reports one, and the API credit balance (`credits.balance`) as **credits** — the unit OpenAI's own console prints — on the OpenAI subscription entry, with no expiry or monthly cap, never as money |
| **GitHub Copilot** | `GET https://api.github.com/copilot_internal/user` with the GitHub OAuth token | Live gauge: premium-interaction and chat allowances, with reset date. Plans billed by token publish no window and say so |
| **Google Gemini** | `POST daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, falling back to `cloudcode-pa.googleapis.com/v1internal:` (Google OAuth; `User-Agent: antigravity/cli/1.4.3`) | Project-scoped five-hour and weekly Antigravity windows, plus the paid subscription tier. The User-Agent is a pinned compatibility identity, not FrugalBar's app version; bare `antigravity` and unversioned `antigravity/cli` headers can omit Gemini entirely. Revalidate the pin if Google changes its client routing; the live comparison and limits are recorded in [the investigation](docs/gemini-quota-investigation.md). The first host whose summary yields a Gemini window is used, and disabled buckets are not drawn. Failures remain unavailable rather than substituting another quota pool |
| **OpenCode Go** | `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key of each named workspace | Live gauge per workspace: rolling, weekly and monthly Go windows, each with the reset time and whether it is currently blocking |
| **Anthropic Claude** | OAuth usage endpoint (`GET https://api.anthropic.com/api/oauth/usage`), via CLI Proxy or directly | Live 5-hour and 7-day quota from the active CLI Proxy or Claude Code OAuth session. When the same payload carries a credit pool (`spend` or the older `extra_usage`), its monthly limit and remaining balance appear as an **Extra usage** entry in the API Spend & Credits card; the promo / cloud-session credit (`iguana_necktie`) appears as its own entry, with its expiry stated as a date. A monthly pool (`spend` or `extra_usage`) that publishes no limit yields no entry even when it reports a spend figure, because a balance row must never print what was used; the promo credit is shown whenever the payload published its own remaining balance |
| **Grok** | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the Grok CLI's token | Live gauge: percentage of the plan's credit allowance used, plus the billing period xAI names (weekly or monthly) and its reset. On-demand spend appears as a second bar once enabled |
| **Kiro** | `POST https://codewhisperer.us-east-1.amazonaws.com/` (`AmazonCodeWhispererService.GetUsageLimits`) with the Kiro CLI's token | Live gauge: plan credits used against the monthly allowance with reset date, plus separate bars for bonus credits (with expiry) and for overage once the account has it switched on |
| **DevPass** | `GET https://api.llmgateway.io/v1/key` with the LLM Gateway API key | Live gauge: plan credits used against the fixed monthly allowance — DevPass is a monthly product and that is all FrugalBar tracks for it |
| **Command Code** | `GET https://api.commandcode.ai/alpha/billing/credits` with the `cmd` CLI's API key | Live gauges: the 5-hour and weekly windows with their caps, usage and reset times, plus the plan's monthly credits measured against the allowance Command Code publishes for the plan. A plan id FrugalBar does not recognise gets no credit gauge rather than a guessed denominator |
| **ClinePass** | `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits` with the Cline API key or account token | Live gauges: the 5-hour, weekly and monthly ClinePass windows as percentages with reset times. The account's credit balance is deliberately not shown: the API's unit for it is undocumented. HTTP 404 means the account has no ClinePass subscription, and is reported as such |
| **Muse** | `POST https://api.meta.ai/muse-code/key` with the Muse Code CLI's OAuth session token; optional read-only `dev.meta.ai` portal session | The mint's `subs_usage` stays primary. When an active subscription omits it, **Settings → API Keys → Muse portal quota** offers an in-app sign-in and explicit team picker. Every quota read rechecks account email, team membership and published plan before drawing published used/limit pairs. Idle, expired or unknown windows stay absent. Opt-in and team selection survive restart; WebKit retains this app's Meta sign-in in a dedicated store. The executable embeds the legacy WebKit identifier `frugalbar`, preserving existing Claude website data and the dedicated Muse store across the `QuotaBar`/`frugalbar` rename without copying either store. Any local `.app` wrapper must use exactly `frugalbar` as its bundle identifier; preferences remain in the separate `com.quotabar.app` suite. **Disconnect** disables portal reads, clears the team and that store, and rejects in-flight results without touching other website sessions. Browser cookies are never imported or credential strings extracted. Missing usage retains the published plan and explains the absent window. Payment requirements remain visible. FrugalBar never makes a model call to obtain usage |

### Caveats worth knowing

Two of these readings carry a cost or routing characteristic the table can't show:

- **Linked Claude Console credits**: Settings → API Keys → Claude monthly API credit opens a Claude sign-in in the app's WebKit session. Open Billing for the organisation you want to show. FrugalBar observes that page's `GET /api/quirky-lollipop/link-state?organization_uuid=…&include_candidates=false`, then refreshes the same query at most once every five minutes. The Claude row shows `monthly_credit_usd` as a monthly entitlement and `next_grant_at` as a local calendar date when published. It never treats `granted_total_usd`, grant count or this allowance as a remaining balance, usage or quota fraction. An unlinked account, an ended programme, or a missing amount draws no line. A failed billing refresh keeps the last published monthly figure and marks it stale. A healthy cached reading is not marked stale merely because it is five minutes old. A valid response reporting no entitlement removes the line. Billing and quota reads are independent, so a failed quota request can still show a freshly read monthly entitlement. The billing refresh aborts its fetch after four seconds and releases its native caller after five seconds, even if WebKit stops responding. Disconnecting or reconnecting invalidates pending results, including a reconnect to the same organisation. Disconnect stops these reads; sign out inside the connection window to end the WebKit login. No browser cookies or tokens are exported or copied from your other browsers. This connection can be a different account from Claude Code or the proxy, so choose its organisation deliberately. The endpoint and fields come from [Claude's billing client](https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/85a848491939469c3c08f28472869296d3011fe6def69eb0-BJZmUjmc.js); [Anthropic documents the monthly entitlement separately](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans).
- **Claude quota querying**: FrugalBar reads Anthropic's OAuth usage endpoint by one of two paths, and neither sends a model request, so polling does not spend the quota it reports. FrugalBar tries the CLI Proxy management API first, whether you configured it or FrugalBar discovered it from `~/.t3/userdata`. When that path fails — a rejected credential, a 429, a connection error, or a malformed response — the Claude OAuth token FrugalBar reads directly (from its Keychain or, with CLI discovery on, from Claude Code) is tried before the row gives up. The two are independent credentials, so a proxy that is throttled, or holding a dead token, does not blank a row the direct token can still fill. The proxy's own failure is what the row shows only when the direct token cannot answer either, and a 429 that carried a `Retry-After` names the vendor's window in the note (`Vendor throttling — retry in N min`), which is also the window automatic polling waits out before re-asking; your own ⟳ is not held back by it. Anthropic actually serves a bare `Retry-After: 0`, which is no usable instruction, so a window-less throttle is held off for five minutes — the same cooldown Claude Code applies to this endpoint, capped at an hour — and a 403 from it is read as a throttle as well, because Anthropic uses 403 alongside 429 there while a credential it refuses comes back as 401. The direct token can belong to a different Anthropic account than the proxy's, so the row may describe a different quota pool. The source line under the row (`CLI Proxy (host)` or `Claude OAuth usage endpoint`) tells you which one you are looking at. A successful direct fallback keeps the proxy's throttle in memory, so automatic passes skip that proxy until its cooldown ends while continuing to read the direct token. A manual refresh can probe the proxy again. Concurrent manual requests share one fetch. A manual request during an automatic pass queues one user-initiated follow-up for providers that were skipped or failed; providers just read successfully are not asked again. A failed manual proxy probe preserves an earlier throttle. Each direct token also keeps its own cooldown, so an earlier proxy retry cannot re-ask a still-throttled direct token.
- **Grok and Kiro tokens expire, and FrugalBar will not refresh them.** Both CLIs mint short-lived tokens (Grok's last about six hours) and refresh them on their own schedule. Writing a new token behind a CLI's back risks invalidating the session you are working in, so FrugalBar only ever reads. An expired token shows as "Credential rejected"; running `grok` or opening Kiro clears it.
- **Gemini needs a first-party OAuth client, which FrugalBar does not ship.** The Antigravity quota API is served by two Google Cloud Code hosts, and neither publishes Gemini's windows for every account: one may return only a "Claude and GPT models" group while the other returns both. So FrugalBar asks `daily-cloudcode-pa.googleapis.com` first and falls through to `cloudcode-pa.googleapis.com` — the same pair, in the same order, that `agy` walks — and takes the first project-scoped summary that carries a Gemini window. On each host it first resolves `cloudaicompanionProject` with `loadCodeAssist`, then sends that exact project with the quota request. A missing project or a failed scoped request never falls back to a populated project-less pool. A host that refuses the credential ends the walk, since the same token goes to both. Setting `FRUGALBAR_GEMINI_API_BASE` replaces that pair with a single ring of your choosing, which is then asked alone: FrugalBar does not substitute another Google quota pool for a configured endpoint that fails or reports no Gemini group, because a valid response from another ring can still describe a different allowance. The override must be an `https://*.googleapis.com` URL and is read once per process on the first refresh. If a refresh fails after a prior measured read, the UI may retain that last reading until a successful refresh. When CLI discovery is enabled, FrugalBar can also use an unexpired session from `antigravity-usage`; otherwise it reads the client configured in its own Keychain. The API is private and Google allowlists it to its own projects: a client you create cannot call it, `gcloud services enable` refuses the service even to a project Owner, and it is not listed among a project's available services at all. FrugalBar therefore asks you to supply a client that *is* allowlisted — in practice the pair the `antigravity-usage` CLI publishes in its `OAUTH_CONFIG`. Those values are deliberately not committed here: they are another product's credentials, and GitHub's push protection rejects them. Set them in Settings → Keys → Gemini, or via `FRUGALBAR_GEMINI_CLIENT_ID` and `FRUGALBAR_GEMINI_CLIENT_SECRET`; they are stored in the Keychain. Expect the consent screen to name whichever product owns the client, not FrugalBar. Without this, Gemini reports "Not configured" once no valid session remains.

Polling bounds with the default policy, per process and unchanged credentials: the timer alone permits at most 30 OAuth usage attempts per hour per credential before backoff. Popover loads and sync callbacks all use `refresh()` and share its 30-second cache/floor, so any number of automatic triggers permits at most 120 attempts/hour. Interleaved manual and automatic passes can reach 240/hour because a person's refresh has a separate 30-second clock; manual requests alone are bounded at 120/hour. These bounds cover measured and transient-failure states, not rejected/missing credentials, which remain exempt so saving a credential takes effect immediately. A positive vendor cooldown blocks automatic requests until its deadline; without one, Claude's five-minute fallback allows at most 12 automatic probes/hour per throttled credential (10 with only the 120-second timer). A proxy success does not require the direct request. Backoff is in memory and resets on process restart or credential change. These are source-derived bounds and tested request scenarios, not a captured trace of a particular user's rate limits.

---

## Subscription cycles

Some vendors meter usage but never say when the billing period turns over. Rather than guess one, **Preferences → Billing Cycles** lets you record the renewal date yourself for any provider.

A recorded cycle adds a `CYCLE` bar showing how many days of the period you have paid for remain, with the pro-rata marker set from the real calendar month rather than a 30-day constant. It reports **no usage** — only elapsed time against the date you entered — and is labelled separately so a vendor's own window is never confused with one typed in by hand. A vendor-published window always wins: the cycle bar only ever fills a slot the vendor left empty. It also attaches to providers FrugalBar cannot read at all, which is the case a renewal countdown is most useful for.

Optionally record the cost per period and it appears alongside the countdown.

---

## Events & notifications

FrugalBar keeps a log of three things on the platforms you use, all of them things that already happened: **resets** (a vendor reset everyone's usage or granted a banked reset, your own window was restored early, or OpenAI granted your account a reset credit), **outages** (a major or critical incident on the vendor's official status page, and its recovery), and **new models** that became selectable on your own subscription. Forecasts, launch posts and catalog listings are never read.

Outages come from the official status pages for Claude, OpenAI (Codex) and GitHub Copilot, polled every 10 minutes. Vendor resets come from the community trackers claude-resets.com (Claude, Codex) and whenreset.dev (Grok), hourly, and are captioned as community-sourced. New models come from each subscription's own model list, read hourly with the credential its quota already uses. Everything can be switched off under **Preferences → History & Data → AI events**, and each kind has its own notification toggle under **Preferences → Notifications**. The newest event shows in the popover; all of them are in **History → Events**, as timeline markers and in the inspector, and are kept for 365 days. Details: [docs/events.md](docs/events.md).

---

## Desktop widget

**Gear menu → Desktop Widget** (⌘D) opens a small panel with three layouts: a stacked **Tokens** chart (the default) of raw token consumption across the providers FrugalBar can count (Claude Code, Codex, OpenCode), a **Chart** of your usage windows with current headroom beneath, or an **Overview** with one tile per provider. Filter by vendor, window, range (24h / 7d / 30d) and used or remaining. The Tokens view is what local tools recorded, cache included, and is never a quota; providers with no token counts are named, not drawn as zero. The dashed average line is a mean of real readings from the windows you selected, never a combined quota. Pin it under your desktop icons or float it above windows in **Preferences → Display**. It is a panel FrugalBar owns, not a WidgetKit widget, because the app ships as a bare binary with no `.app` bundle. Details: [docs/desktop-widget.md](docs/desktop-widget.md).

---

## Security & Keychain Architecture

- **macOS Keychain Storage**: Keys are stored locally in the secure Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced to iCloud or external clouds).
- **No In-URL Token Leaks**: API credentials are sent strictly in HTTP request headers, never query parameters.
- **Event sources**: the status pages (`status.claude.com`, `status.openai.com`, `www.githubstatus.com`) and reset trackers (`claude-resets.com`, `whenreset.dev`) are public and get no credential. Account model lists go to each vendor's own API with the credential that vendor's quota already uses, and nowhere else; the Codex list also reads the latest Codex CLI version from `registry.npmjs.org`, without a credential. Switch all of them off under **Preferences → History & Data → AI events**.
- **Local CLI Discovery (Opt-in)**: Auto-detecting credentials from local developer tools — `gh auth token`, CLI Proxy hubs (`~/.t3/userdata/settings.json`, `~/.t3/userdata/secrets`, `CLIPROXY_*` environment variables), `~/.local/share/opencode/auth.json` (OpenCode, Copilot, OpenRouter, DeepSeek), the `OPENROUTER_API_KEY` / `DEEPSEEK_API_KEY` environment variables, `~/.codex/auth.json`, the Claude Code login Keychain item, the Muse Code login Keychain item (`ai.meta.dev.credentials`), `~/.claude/.credentials.json`, `~/.config/github-copilot/hosts.json`, `~/.grok/auth.json`, `~/Library/Application Support/kiro-cli/data.sqlite3` (opened read-only), `~/.commandcode/auth.json` (and the `COMMAND_CODE_API_KEY` / `COMMANDCODE_API_KEY` environment variables), and `~/.cline/data/settings/providers.json` (under `$CLINE_DATA_DIR` when set; legacy `secrets.json`; and the `CLINE_API_KEY` / `CLINEPASS_API_KEY` environment variables) — is **disabled by default** and can be enabled under **Preferences → API Keys → Credential discovery**.

---

## Development & Testing

```bash
# Build with zero-warning tolerance
swift build -Xswiftc -warnings-as-errors

# Run full test suite (the real-clock deadline suite alone, the rest in parallel)
scripts/run-swift-tests.sh
```

CI runs on GitHub-hosted `macos-15` (Apple Silicon) with Xcode 16.

---

## Requirements

- macOS 15.0+ (Sequoia)
- Swift 6.0+ (Xcode 16+)
- Apple Silicon
