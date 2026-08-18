# frugalbar — track AI usage & dev limits

A native macOS menu bar app that shows how much headroom you have left across
AI and developer services.

The Swift app lives in [`QuotaBar/`](QuotaBar/). `prototype/` holds an earlier
React/Vite mock-up, kept for reference only.

## Quick start

```bash
cd QuotaBar && swift run
```

Add credentials via **Preferences → API Keys**. GitHub, OpenRouter and Gemini
keys are exercised against the vendor when you save, so a bad paste fails there
rather than showing up later as an unexplained blank row. OpenCode has no
endpoint to check against, so it reports "Saved — cannot be verified".

## Build & test

```bash
cd QuotaBar && swift build -Xswiftc -warnings-as-errors && swift test -c debug --parallel
```

That is exactly what CI runs.

## What it can actually measure

Not every vendor publishes usage data. Where one doesn't, the row says so
instead of showing an estimate — a number you can't trust is worse than no
number in a tool you use to decide whether to start a long job.

| Provider | Source | What you get |
|---|---|---|
| GitHub REST | `GET https://api.github.com/rate_limit` → `resources.core` | Live gauge — requests/hour remaining, with reset time |
| GitHub GraphQL | same call, `resources.graphql` | Live gauge — points/hour remaining, with reset time |
| OpenRouter | `GET https://openrouter.ai/api/v1/auth/key` | Live gauge **if the key has a spend cap**; otherwise all-time spend with no gauge |
| GitHub Copilot | `GET https://api.github.com/user` | Account confirmed. No gauge — GitHub publishes no individual quota API |
| Gemini | `GET .../v1beta/models` | Key validated. No gauge — Google publishes no per-key usage API |
| OpenCode | credential presence only | No gauge — OpenCode publishes no usage API |
| Claude | — | No gauge — Anthropic publishes no subscription quota API |

Two providers give a real gauge on a default install; OpenRouter makes a third
when its key has a spend cap, which is not the default. The rest are shown so
you know they're configured, not so you can read a quota off them.

**Why OpenRouter is conditional:** `/auth/key` returns `limit`, which is the
spend cap *on that key* and is `null` when the key is uncapped. It is not your
account balance, and `usage` is cumulative since the key was created rather
than a billing-period figure. With a cap there is a real denominator and a real
gauge; without one there isn't, so the app reports spend and draws no bar.

## Credentials

Keys are stored in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
never synced to iCloud). One GitHub PAT covers REST, GraphQL and Copilot.

Reading credentials from local CLI tools — `gh auth token`, `~/.local/share/opencode/auth.json` —
is **off by default** and opt-in under **Preferences → General**. It reads
credentials you haven't explicitly handed the app, so it shouldn't be silent,
and it is incompatible with the App Sandbox.

## Requirements

- macOS 15+
- Swift 6.0+ (Xcode 16+)

## Status

Prototype. `swift run` produces a bare executable, not a signed `.app` — there
is no bundling, code-signing, notarisation or update mechanism yet, and no
threshold notifications. See the PR discussion for the roadmap.

CI runs `swift build -Xswiftc -warnings-as-errors` and the test suite twice (to
catch flakes) on GitHub-hosted macOS runners.
