# Agent notes — frugalbar

Swift package in `QuotaBar/`. Legacy React mock-up in `prototype/` — reference
only, don't extend it.

Structure and type names are discoverable with `ls` and `grep`, so they aren't
repeated here. What follows is only what you can't derive from the tree, and
what has actually gone wrong before.

## Commands

```bash
cd QuotaBar && swift build -Xswiftc -warnings-as-errors && swift test -c debug --parallel
```

CI runs exactly this, then re-runs the tests once more to catch flakes.

## Invariants

**Never synthesise a quota, limit, or balance.** No `?? 500`, no `?? 20.0`, no
inferring usage from unrelated data. If a vendor doesn't publish a figure, the
provider returns `.unavailable(_)` and the UI draws no bar and no percentage.
A wrong number is worse than no number here: people use this to decide whether
to start a long job.

**Failure must never render as health.** Check `http.statusCode` before
decoding, and treat a decode failure as `.badResponse`. A 404 that renders as a
full green bar is the specific bug this codebase shipped once already.

**`consumptionFraction` is `Double?` and nil means "no denominator."** Never
coerce it to 0 or 1 — those read as "plenty left" and "exhausted".

**Urgency and confidence are separate axes.** `Urgency` (quota pressure) drives
the menu bar icon. `Confidence` (did we get a reading) is a decoration. An
unreadable provider must never outrank a critical quota — that inversion made
the icon a permanent grey error triangle for every user.

Beware: the UI switches on `Urgency`/`Confidence`, **not** on `ProviderStatus`.
So adding a `ProviderStatus` case compiles everywhere and silently maps to an
existing bucket via `urgency`/`confidence` in `MetricTypes.swift` — that is
exactly how a 429 came to render as a critical quota. Adding a case means
deciding both axes there, deliberately.

Adding an `UnavailableReason` case *does* force updates: `headline`, `remedy`
(`MetricTypes.swift`), and `SettingsView.verify`.

**Credentials never reach user-facing or persisted fields.** Send keys in
headers, never query strings. Never put `error.localizedDescription` in a
`QuotaSnapshot` — `URLError`'s description carries the request URL. Map errors
to `UnavailableReason` instead.

**Tests must be hermetic.** Inject providers via `QuotaManager(providerFactory:)`;
never use `QuotaManager.shared`. Stub HTTP with `QuotaHTTP.$session.withValue(_:)`.
Assert your stub was actually hit — a previous mock was never wired up and
every "provider test" silently passed without exercising any parsing.

**Never assert on a duration derived from `Date()`.** Pass an explicit `now`.
`Int(179.97 / 60)` is 2, which made one test fail ~25% of runs.

**Don't add Keychain attributes that need entitlements.** `kSecUseDataProtectionKeychain`
returns -34018 from `swift run`, silently breaking every credential path. It can
only go in alongside a signed, entitled `.app`.

## UI constraints

Popover is 340pt wide; a row has 16pt horizontal padding, so row content must
fit **324pt**. Use flexible widths, not fixed ones — the previous layout summed
to 356pt and clipped on launch.

Every row needs an `accessibilityLabel`, and status needs a non-colour channel
(SF Symbol shape). Colour alone fails WCAG 1.4.1, and "glance to know" is the
entire product.

## Before claiming done

Run the build and the tests. Don't tick an acceptance box you haven't executed
— every defect in this project's history traces back to that.
