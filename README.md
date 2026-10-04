# frugalbar — track AI usage & dev limits

<p align="center">
  <img width="652" height="1280" alt="image" src="https://github.com/user-attachments/assets/35c85ad5-6832-4095-a8d6-c6eaa5d505fa" />
</p>


A native macOS menu bar app that shows how much headroom you have left across AI subscriptions, API spend caps, and developer rate limits.

Each subscription's windows line up in **5H / WK / MO** columns, with the share used under each bar; hover a row for its recent-pace forecast. Click a provider row to open its inspector: a Burndown | History chart, the vendor's recent events and any banked reset credits. An ideal-pace line appears only when the vendor publishes a window length and reset, and a projection only from a measured recent pace. See [docs/inspector.md](docs/inspector.md).

---

## Why FrugalBar?

Modern engineering workflows rely on many AI models and developer platforms (Claude, OpenAI, Gemini, GitHub Copilot, OpenRouter, Grok, Kiro, OpenCode, DevPass, Command Code, ClinePass and the GitHub APIs). However:

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
   - **OpenRouter**: Use a spend-capped API key to display live balance, budget, and spend telemetry.
   - **Google Gemini**: Connect Google OAuth for Antigravity subscription quota.
   - **Anthropic Claude**: Sign in with the Claude Code CLI or connect a CLI Proxy hub; enable CLI discovery and FrugalBar reads that active OAuth session.
   - **OpenAI / ChatGPT**: Sign in with the Codex CLI or connect a CLI Proxy hub; enable CLI discovery and FrugalBar reads that session.
   - **OpenCode**: Configure a token; usage appears once OpenCode has written its own telemetry.
   - **Grok**: Sign in with the Grok CLI (`grok login`); enable CLI discovery and FrugalBar reads `~/.grok/auth.json`.
   - **Kiro**: Sign in with the Kiro CLI or IDE; enable CLI discovery and FrugalBar reads the CLI's own state database.
   - **DevPass**: Paste an `llmgtwy_…` key from the LLM Gateway dashboard.
   - **Command Code**: Sign in with the `cmd` CLI (`cmd login`); enable CLI discovery and FrugalBar reads `~/.commandcode/auth.json`. A `user_…` API key can also be pasted directly, or set `COMMAND_CODE_API_KEY` / `COMMANDCODE_API_KEY`.
   - **ClinePass**: Sign in with the Cline CLI (`cline auth`) or the Cline extension; enable CLI discovery and FrugalBar reads `~/.cline/data/settings/providers.json` (or `$CLINE_DATA_DIR`). A Cline API key from app.cline.bot can also be pasted directly, or set `CLINE_API_KEY` / `CLINEPASS_API_KEY`.

Credentials are validated against live vendor endpoints upon saving to immediately catch typos or permission issues.

---

## Preferences

Gear menu → **Settings…** (⌘,) has four tabs:

| Tab | What it does |
|---|---|
| **API Keys** | Credentials per provider, and where each one is coming from |
| **Providers** | Show or hide each provider, and choose the order. *Soonest deadline first* (default) puts the provider whose longest window turns over soonest at the top and a spent one last; *Custom order* shows exactly the list you arrange with the up and down buttons. A hidden provider is **not polled** and is absent from the popover, menu bar, advice, desktop widget and notifications. Its key stays put, so showing it again is instant |
| **Cycles** | Renewal dates for vendors that publish no billing period |
| **General** | CLI discovery, notifications, AI events, desktop widget position |

The running version is shown in the popover footer ("v1.4.2", or "dev" for a local build) and in **About**.

---

## What It Can Actually Measure

Not every vendor publishes usage telemetry. Where a vendor doesn't provide real consumption numbers, FrugalBar states so explicitly instead of fabricating an estimate:

| Provider | Source | Telemetry Provided |
|---|---|---|
| **GitHub REST** | `GET https://api.github.com/rate_limit` → `resources.core` | Live gauge: requests/hour remaining with reset countdown |
| **GitHub GraphQL** | `GET https://api.github.com/rate_limit` → `resources.graphql` | Live gauge: points/hour remaining with reset countdown |
| **OpenRouter** | `GET https://openrouter.ai/api/v1/auth/key`, then `GET https://openrouter.ai/api/v1/credits` | Live account credit balance in USD when the key may read it; otherwise that key's USD spend cap |
| **OpenAI / ChatGPT** | `GET https://chatgpt.com/backend-api/wham/usage` via the Codex session or CLI Proxy hub | Live 5-hour and weekly subscription windows, each labelled from the window length OpenAI reports. Also the count of banked reset credits (`rate_limit_reset_credits`) when OpenAI reports one; `credits.balance` is not shown because its unit is unverified |
| **GitHub Copilot** | `GET https://api.github.com/copilot_internal/user` with the GitHub OAuth token | Live gauge: premium-interaction and chat allowances, with reset date. Plans billed by token publish no window and say so |
| **Google Gemini** | `POST daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` (Google OAuth) | Live five-hour and weekly Antigravity windows, plus the paid subscription tier; failures remain unavailable rather than substituting another quota pool |
| **OpenCode** | `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key | Live gauge: rolling, weekly and monthly Go windows, each with the reset time and whether it is currently blocking |
| **Anthropic Claude** | OAuth usage endpoint (`GET https://api.anthropic.com/api/oauth/usage`), via CLI Proxy or directly | Live 5-hour and 7-day quota from the active CLI Proxy or Claude Code OAuth session |
| **Grok** | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the Grok CLI's token | Live gauge: percentage of the plan's credit allowance used, plus the billing period xAI names (weekly or monthly) and its reset. On-demand spend appears as a second bar once enabled |
| **Kiro** | `POST https://codewhisperer.us-east-1.amazonaws.com/` (`AmazonCodeWhispererService.GetUsageLimits`) with the Kiro CLI's token | Live gauge: plan credits used against the monthly allowance with reset date, plus separate bars for bonus credits (with expiry) and for overage once the account has it switched on |
| **DevPass** | `GET https://api.llmgateway.io/v1/key` with the LLM Gateway API key | Live gauge: plan credits used against the fixed monthly allowance — DevPass is a monthly product and that is all FrugalBar tracks for it |
| **Command Code** | `GET https://api.commandcode.ai/alpha/billing/credits` with the `cmd` CLI's API key | Live gauges: the 5-hour and weekly windows with their caps, usage and reset times, plus the plan's monthly credits measured against the allowance Command Code publishes for the plan. A plan id FrugalBar does not recognise gets no credit gauge rather than a guessed denominator |
| **ClinePass** | `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits` with the Cline API key or account token | Live gauges: the 5-hour, weekly and monthly ClinePass windows as percentages with reset times. The account's credit balance is deliberately not shown: the API's unit for it is undocumented. HTTP 404 means the account has no ClinePass subscription, and is reported as such |

### Caveats worth knowing

Two of these readings carry a cost or routing characteristic the table can't show:

- **Claude quota querying**: FrugalBar reads Anthropic's OAuth usage endpoint by one of two paths, and neither sends a model request, so polling does not spend the quota it reports. FrugalBar tries the CLI Proxy management API first, whether you configured it or FrugalBar discovered it from `~/.t3/userdata`. If the proxy rejects the credential or is rate limited, Claude shows that state. Any other proxy failure, such as a connection error or a malformed response, falls through to the Claude OAuth token FrugalBar reads directly (from its Keychain or, with CLI discovery on, from Claude Code). That token can belong to a different Anthropic account than the proxy's, so the row may then describe a different quota pool. The source line under the row (`CLI Proxy (host)` or `Claude OAuth usage endpoint`) tells you which one you are looking at.
- **Grok and Kiro tokens expire, and FrugalBar will not refresh them.** Both CLIs mint short-lived tokens (Grok's last about six hours) and refresh them on their own schedule. Writing a new token behind a CLI's back risks invalidating the session you are working in, so FrugalBar only ever reads. An expired token shows as "Credential rejected"; running `grok` or opening Kiro clears it.
- **Gemini needs a first-party OAuth client, which FrugalBar does not ship.** The Antigravity quota API defaults to `daily-cloudcode-pa.googleapis.com` (matching `agy`); `FRUGALBAR_GEMINI_API_BASE` can select an alternate Google API ring. FrugalBar does not substitute another Google quota pool when the selected endpoint fails or reports no Gemini group, because a valid response from another ring can still describe a different allowance. The override must be an `https://*.googleapis.com` URL and is read once per process on the first refresh. If a refresh fails after a prior measured read, the UI may retain that last reading until a successful refresh. When CLI discovery is enabled, FrugalBar can also use an unexpired session from `antigravity-usage`; otherwise it reads the client configured in its own Keychain. The API is private and Google allowlists it to its own projects: a client you create cannot call it, `gcloud services enable` refuses the service even to a project Owner, and it is not listed among a project's available services at all. FrugalBar therefore asks you to supply a client that *is* allowlisted — in practice the pair the `antigravity-usage` CLI publishes in its `OAUTH_CONFIG`. Those values are deliberately not committed here: they are another product's credentials, and GitHub's push protection rejects them. Set them in Settings → Keys → Gemini, or via `FRUGALBAR_GEMINI_CLIENT_ID` and `FRUGALBAR_GEMINI_CLIENT_SECRET`; they are stored in the Keychain. Expect the consent screen to name whichever product owns the client, not FrugalBar. Without this, Gemini reports "Not configured" once no valid session remains.

---

## Subscription cycles

Some vendors meter usage but never say when the billing period turns over. Rather than guess one, **Preferences → Cycles** lets you record the renewal date yourself for any provider.

A recorded cycle adds a `CYCLE` bar showing how many days of the period you have paid for remain, with the pro-rata marker set from the real calendar month rather than a 30-day constant. It reports **no usage** — only elapsed time against the date you entered — and is labelled separately so a vendor's own window is never confused with one typed in by hand. A vendor-published window always wins: the cycle bar only ever fills a slot the vendor left empty. It also attaches to providers FrugalBar cannot read at all, which is the case a renewal countdown is most useful for.

Optionally record the cost per period and it appears alongside the countdown.

---

## Events & notifications

FrugalBar keeps a log of three things on the platforms you use, all of them things that already happened: **resets** (a vendor reset everyone's usage or granted a banked reset, your own window was restored early, or OpenAI granted your account a reset credit), **outages** (a major or critical incident on the vendor's official status page, and its recovery), and **new models** that became selectable on your own subscription. Forecasts, launch posts and catalog listings are never read.

Outages come from the official status pages for Claude, OpenAI (Codex) and GitHub Copilot, polled every 10 minutes. Vendor resets come from the community trackers claude-resets.com (Claude, Codex) and whenreset.dev (Grok), hourly, and are captioned as community-sourced. New models come from each subscription's own model list, read hourly with the credential its quota already uses. Everything can be switched off under **Preferences → General → AI events**, where each kind also has its own notification toggle. The newest event shows in the popover; all of them are in **History → Events**, as timeline markers and in the inspector, and are kept for 365 days. Details: [docs/events.md](docs/events.md).

---

## Desktop widget

**Gear menu → Desktop Widget** (⌘D) opens a small panel with three layouts: a stacked **Tokens** chart (the default) of raw token consumption across the providers FrugalBar can count (Claude Code, Codex, OpenCode), a **Chart** of your usage windows with current headroom beneath, or an **Overview** with one tile per provider. Filter by vendor, window, range (24h / 7d / 30d) and used or remaining. The Tokens view is what local tools recorded, cache included, and is never a quota; providers with no token counts are named, not drawn as zero. The dashed average line is a mean of real readings from the windows you selected, never a combined quota. Pin it under your desktop icons or float it above windows in **Preferences → General**. It is a panel FrugalBar owns, not a WidgetKit widget, because the app ships as a bare binary with no `.app` bundle. Details: [docs/desktop-widget.md](docs/desktop-widget.md).

---

## Security & Keychain Architecture

- **macOS Keychain Storage**: Keys are stored locally in the secure Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced to iCloud or external clouds).
- **No In-URL Token Leaks**: API credentials are sent strictly in HTTP request headers, never query parameters.
- **Event sources**: the status pages (`status.claude.com`, `status.openai.com`, `www.githubstatus.com`) and reset trackers (`claude-resets.com`, `whenreset.dev`) are public and get no credential. Account model lists go to each vendor's own API with the credential that vendor's quota already uses, and nowhere else; the Codex list also reads the latest Codex CLI version from `registry.npmjs.org`, without a credential. Switch all of them off under **Preferences → General → AI events**.
- **Local CLI Discovery (Opt-in)**: Auto-detecting credentials from local developer tools — `gh auth token`, CLI Proxy hubs (`~/.t3/userdata/settings.json`, `~/.t3/userdata/secrets`, `CLIPROXY_*` environment variables), `~/.local/share/opencode/auth.json` (OpenCode, Copilot, OpenRouter), the `OPENROUTER_API_KEY` environment variable, `~/.codex/auth.json`, the Claude Code login Keychain item, `~/.claude/.credentials.json`, `~/.config/github-copilot/hosts.json`, `~/.grok/auth.json`, `~/Library/Application Support/kiro-cli/data.sqlite3` (opened read-only), `~/.commandcode/auth.json` (and the `COMMAND_CODE_API_KEY` / `COMMANDCODE_API_KEY` environment variables), and `~/.cline/data/settings/providers.json` (under `$CLINE_DATA_DIR` when set; legacy `secrets.json`; and the `CLINE_API_KEY` / `CLINEPASS_API_KEY` environment variables) — is **disabled by default** and can be enabled under **Preferences → General**.

---

## Development & Testing

```bash
# Build with zero-warning tolerance
swift build -Xswiftc -warnings-as-errors

# Run full test suite in parallel
swift test -c debug --parallel
```

CI runs on GitHub-hosted `macos-15` (Apple Silicon) with Xcode 16.

---

## Requirements

- macOS 15.0+ (Sequoia)
- Swift 6.0+ (Xcode 16+)
- Apple Silicon
