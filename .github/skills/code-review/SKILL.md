---
name: code-review
description: Review priorities for frugalbar pull requests, what deserves real scrutiny versus what to skip. Use for every PR review.
---

# Review priorities

frugalbar's entire value proposition is that every number it shows is real.
AGENTS.md documents the incidents below as things that actually shipped —
treat them as the review checklist, not hypotheticals.

## Spend real attention here

- **Synthesized quotas.** Any change in `Sources/QuotaBarCore/Providers/`
  that fills a missing value instead of returning `.unavailable`/nil —
  `?? 500`, a hardcoded pace marker, a plan name defaulted to the vendor's
  name, a balance shown under a "spent" label nobody measured.
  `consumptionFraction`, `expectedPaceFraction`, `planName`, and `spent`
  must stay optional all the way through.
- **HTTP status before decode.** A response handler that parses JSON
  without checking `http.statusCode` first — 404 must map to `.badResponse`,
  429 must map to `.rateLimited`, never render as a full or critical bar.
- **New `ProviderStatus` / `UnavailableReason` cases** (`MetricTypes.swift`).
  These compile fine and silently fall into an existing `Urgency`/
  `Confidence` bucket if not mapped on purpose — check both axes are set
  deliberately, and that a new `UnavailableReason` also updates `headline`,
  `remedy`, and `SettingsView.verify`.
- **Credential handling.** Keys sent as query params instead of headers;
  `error.localizedDescription` or any raw `URLError` landing in a
  persisted or user-facing `QuotaSnapshot` field (it carries the request
  URL).
- **Preferences reads/writes.** Anything touching `UserDefaults.standard`
  instead of `CredentialStore.preferences` — the bundled app and the
  SwiftPM binary have different process names and silently get separate
  stores.
- **New or changed tests.** Must inject `QuotaManager(providerFactory:)`
  (never `.shared`), stub HTTP via `QuotaHTTP.$session`, assert the stub
  was actually hit, use a randomized Keychain label, and pass an explicit
  `now` rather than deriving assertions from `Date()`.

## Do not spend attention here

- `docs/`, `README.md`, `CONTRIBUTING.md` — prose and screenshots.
- `packaging/frugalbar.rb.tmpl` — templated Homebrew formula.
- Compiler warnings or formatting nits — CI builds with
  `-Xswiftc -warnings-as-errors`, so any warning already fails the build.
- Generic injection/taint patterns — `codeql.yml` already scans every PR.
- `.claude/imps/` — agent scratch notes, not shipped code.

## Comment style

- One comment per real issue, not one per file it repeats in.
- Skip restating what CI, CodeQL, or the compiler already flags.
