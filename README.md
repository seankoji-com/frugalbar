# frugalbar — track AI usage & dev limits

<p align="center">
  <img width="416" height="568" alt="image" src="https://github.com/user-attachments/assets/a6fed1ea-f879-4a98-828d-791f889221f8" />
</p>


A native macOS menu bar app that shows how much headroom you have left across AI subscriptions, API spend caps, and developer rate limits.

---

## Why FrugalBar?

Modern engineering workflows rely heavily on multiple AI models and developer platforms (Claude, OpenAI / OpenRouter, Google Gemini, GitHub Copilot, and GitHub APIs). However:

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
   - **Anthropic Claude**: Sign in with the Claude Code CLI; enable CLI discovery and FrugalBar reads that OAuth login.
   - **OpenCode**: Configure a token; usage appears once OpenCode has written its own telemetry.
   - **Grok**: Sign in with the Grok CLI (`grok login`); enable CLI discovery and FrugalBar reads `~/.grok/auth.json`.
   - **Kiro**: Sign in with the Kiro CLI or IDE; enable CLI discovery and FrugalBar reads the CLI's own state database.
   - **DevPass**: Paste an `llmgtwy_…` key from the LLM Gateway dashboard.

Credentials are validated against live vendor endpoints upon saving to immediately catch typos or permission issues.

---

## What It Can Actually Measure

Not every vendor publishes usage telemetry. Where a vendor doesn't provide real consumption numbers, FrugalBar states so explicitly instead of fabricating an estimate:

| Provider | Source | Telemetry Provided |
|---|---|---|
| **GitHub REST** | `GET https://api.github.com/rate_limit` → `resources.core` | Live gauge: requests/hour remaining with reset countdown |
| **GitHub GraphQL** | `GET https://api.github.com/rate_limit` → `resources.graphql` | Live gauge: points/hour remaining with reset countdown |
| **OpenRouter** | `GET https://openrouter.ai/api/v1/auth/key`, then `GET https://openrouter.ai/api/v1/credits` | Live account credit balance in USD when the key may read it; otherwise that key's USD spend cap |
| **OpenAI / ChatGPT** | `GET https://chatgpt.com/backend-api/wham/usage` via the Codex session | Live 5-hour and weekly subscription windows, each labelled from the window length OpenAI reports |
| **GitHub Copilot** | `GET https://api.github.com/copilot_internal/user` with the GitHub OAuth token | Live gauge: premium-interaction and chat allowances, with reset date. Plans billed by token publish no window and say so |
| **Google Gemini** | `POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` (Google OAuth) | Live five-hour and weekly Antigravity windows, plus the paid subscription tier; falls back to an unexpired `antigravity-usage` session when discovery is on |
| **OpenCode** | `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key | Live gauge: rolling, weekly and monthly Go windows, each with the reset time and whether it is currently blocking |
| **Anthropic Claude** | `anthropic-ratelimit-unified-*` response headers | Live 5-hour and 7-day quota from the Claude Code OAuth login |
| **Grok** | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the Grok CLI's token | Live gauge: percentage of the plan's credit allowance used, plus the billing period xAI names (weekly or monthly) and its reset. On-demand spend appears as a second bar once enabled |
| **Kiro** | `POST https://codewhisperer.us-east-1.amazonaws.com/` (`AmazonCodeWhispererService.GetUsageLimits`) with the Kiro CLI's token | Live gauge: plan credits used against the monthly allowance with reset date, plus separate bars for bonus credits (with expiry) and for overage once the account has it switched on |
| **DevPass** | `GET https://api.llmgateway.io/v1/key` with the LLM Gateway API key | Live gauge: plan credits used this cycle, and the weekly premium-model window with its reset. LLM Gateway publishes no monthly cycle date — see Subscription cycles below |

### Caveats worth knowing

Two of these readings carry a cost the table can't show:

- **Claude spends a little of the quota it reports.** Anthropic publishes the unified 5h/7d figures only as response headers, so FrugalBar issues the smallest possible real request (one Haiku call capped at a single output token) on each refresh. It is a rounding error against a subscription, but it is not free, and it is why the poll interval is two minutes rather than two seconds.
- **Grok and Kiro tokens expire, and FrugalBar will not refresh them.** Both CLIs mint short-lived tokens (Grok's last about six hours) and refresh them on their own schedule. Writing a new token behind a CLI's back risks invalidating the session you are working in, so FrugalBar only ever reads. An expired token shows as "Credential rejected"; running `grok` or opening Kiro clears it.
- **Gemini needs a first-party OAuth client, which FrugalBar does not ship.** `cloudcode-pa.googleapis.com` is a private API that Google allowlists to its own projects: a client you create cannot call it, `gcloud services enable` refuses the service even to a project Owner, and it is not listed among a project's available services at all. FrugalBar therefore asks you to supply a client that *is* allowlisted — in practice the pair the `antigravity-usage` CLI publishes in its `OAUTH_CONFIG`. Those values are deliberately not committed here: they are another product's credentials, and GitHub's push protection rejects them. Set them in Settings → Keys → Gemini, or via `FRUGALBAR_GEMINI_CLIENT_ID` and `FRUGALBAR_GEMINI_CLIENT_SECRET`; they are stored in the Keychain. Expect the consent screen to name whichever product owns the client, not FrugalBar. Without this, Gemini falls back to an unexpired session cached by `antigravity-usage` when local credential discovery is on, and reports "Not configured" once that hourly token lapses.

---

## Subscription cycles

Some vendors meter usage but never say when the billing period turns over — DevPass reports credits spent this cycle and a weekly premium reset, but no monthly renewal date. Rather than guess one, **Preferences → Cycles** lets you record the renewal date yourself for any provider.

A recorded cycle adds a `CYCLE` bar showing how many days of the period you have paid for remain, with the pro-rata marker set from the real calendar month rather than a 30-day constant. It reports **no usage** — only elapsed time against the date you entered — and is labelled separately so a vendor's own window is never confused with one typed in by hand. A vendor-published window always wins: the cycle bar only ever fills a slot the vendor left empty. It also attaches to providers FrugalBar cannot read at all, which is the case a renewal countdown is most useful for.

Optionally record the cost per period and it appears alongside the countdown.

---

## Security & Keychain Architecture

- **macOS Keychain Storage**: Keys are stored locally in the secure Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced to iCloud or external clouds).
- **No In-URL Token Leaks**: API credentials are sent strictly in HTTP request headers, never query parameters.
- **Local CLI Discovery (Opt-in)**: Auto-detecting credentials from local developer tools — `gh auth token`, `~/.local/share/opencode/auth.json` (OpenCode, Copilot, OpenRouter), the `OPENROUTER_API_KEY` environment variable, `~/.codex/auth.json`, the Claude Code login Keychain item, `~/.claude/.credentials.json`, `~/.config/github-copilot/hosts.json`, `~/.grok/auth.json`, and `~/Library/Application Support/kiro-cli/data.sqlite3` (opened read-only) — is **disabled by default** and can be enabled under **Preferences → General**.

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
