# Agent notes — frugalbar

Swift package at repository root.

Structure and type names are discoverable with `ls` and `grep`, so they aren't
repeated here. What follows is only what you can't derive from the tree, and
what has actually gone wrong before.

## Commands

```bash
swift build -Xswiftc -warnings-as-errors && swift test -c debug --parallel
```

CI runs exactly this, then re-runs the tests once more to catch flakes.

## Invariants

**Never synthesise a quota, limit, or balance.** No `?? 500`, no `?? 20.0`, no
inferring usage from unrelated data. If a vendor doesn't publish a figure, the
provider returns `.unavailable(_)` and the UI draws no bar and no percentage.
A wrong number is worse than no number here: people use this to decide whether
to start a long job.

**The rule covers geometry and labels, not just numbers.** A pace marker
placed at a constant, a plan tier defaulted to the vendor's name, a balance
printed under a "spent" label — each asserts something nobody measured, and
each shipped here. If a figure was not received, draw nothing and say nothing:
`expectedPaceFraction`, `planName` and `spent` are all optional for that
reason. There is deliberately no debug affordance that writes a synthetic
fraction into a live snapshot; one existed, and it fed the advice engine and
the menu bar icon.

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

**Events are observations, never inferences.** An `AIEvent` records something a
vendor published or a source FrugalBar fetched: a reset time that passed, a
consumed fraction that fell before the published reset, a model id in the
catalog, a price on both sides of a change. Never create one from silence, from
a drop alone, or from a reading that was lost (`nil` is not 0, and treating it as
0 turns every outage into a "usage restored" banner). Detectors need both polls
`.measured`. Event ids are built from the facts (`AIEvent.makeID`), never a UUID
or prose, because `recordEvents` dedups on the id and notifications fire only on
what it reports as new. Anthropic reset grants are requested (`?cedar_ember=1`)
but the OAuth surface answers `ineligible_reason: "surface"` with no grants;
that decodes to `nil`, never 0, and guessing them would be a synthesised figure.

**External event sources record the past, never the future.** Status pages,
community reset trackers and account model lists are read for what already
happened: an incident the vendor opened or resolved, a reset that landed, a
model the account now serves. Trackers also publish forecasts and "reset
expected" windows (codex-reset.com's `/api/forecast` labels itself
experimental); those are never decoded. A "new model" is a model on the
account's own list (`AccountModelWatcher`), never a launch post or a catalog
listing: the question is whether the user can select it right now.

**History tables are additive only; do not bump `HistorySchema.version`.** A
bump drops the table set, which deletes the user's readings. New tables go in
`createTablesSQL` as `CREATE TABLE IF NOT EXISTS` (as `event`, `catalog_model`
and `feed_item` did). A change to an existing table's shape needs a real
migration, not a version bump.

**The desktop widget's average is not a quota.** It is the mean of real
readings from the selected windows, labelled with how many contributed
(`sampleCount`, never padded), and it appears only with two or more windows.
Don't add, normalise or sum windows across vendors into a "total" or "combined"
figure: vendors meter different things over different windows. The widget's Overview layout is per-provider tiles only: it carries no
total, and a configured-but-unreadable provider keeps its tile. The widget is an
app-owned `NSPanel`, not WidgetKit, because there is no `.app` bundle.

**Token totals are observations, and summing them is allowed only because tokens
share a unit.** The Tokens layout stacks locally recorded tokens (the `activity`
table, summed in SQL by `fetchTokenUsage`) for the providers with an adapter
(`AttributionEngine.localSourceIdentifiers`). Every other provider is named under
the chart, never drawn as a zero layer. A record whose total is `NULL` is counted
as uncounted and said so, never summed as 0. Keep it apart from quota: no
percentage, no "remaining", no division by an allowance. Codex records one
cumulative total per session at its last turn, and the chart says so rather than
spreading it. Cache tokens are included as each tool reports them. Whether a tool's
input figure already contains its cached input is unverified, so there is no
"without cache" mode until that is established per tool.

**A hidden provider is not polled, not counted, and not remembered.**
`QuotaManager` reads `ProviderDisplayPreferences` once per poll, skips hidden
vendors' fetches and removes their cache entries, so they vanish from the
summary, advice, history recorder and widget, and a vendor shown again is
fetched at once instead of waiting out `minPollInterval`. `sortedSnapshots()`
also drops them on read. A `.custom` order is the user's list verbatim: no
band, deadline or exhaustion moves a row. Tests inject
`displayPreferences:` and never touch the real preference store.

**Credentials never reach user-facing or persisted fields.** Send keys in
headers, never query strings. Never put `error.localizedDescription` in a
`QuotaSnapshot` — `URLError`'s description carries the request URL. Map errors
to `UnavailableReason` instead.

**Preferences live in an explicit suite, not `UserDefaults.standard`.** An
unbundled executable keys `.standard` off its *process name* — `Info.plist`
applies only inside a real `.app`. The release installs as `frugalbar` and the
SwiftPM product builds as `QuotaBar`, so `.standard` gave them separate stores:
opting into CLI discovery under one name left the other reporting every
provider "Not configured", with nothing on screen to explain it. Read and write
through `CredentialStore.preferences`, including `@AppStorage(_, store:)`.

**Test-host detection cannot rely on XCTest.** Under `swift test` with
swift-testing, `XCTestCase` is not loaded and no `XCTest*` / `SWIFT_TESTING_*`
variable is set — only `ProcessInfo.processName` identifies the runner. Both
safety nets that depend on it (no real network, no writes to the user's real
preference file) failed open for as long as they were written that way. Use
`TestHost.isActive`.

**Tests must be hermetic.** Inject providers via `QuotaManager(providerFactory:)`;
never use `QuotaManager.shared`. Stub HTTP with `QuotaHTTP.$session.withValue(_:)`.
Assert your stub was actually hit — a previous mock was never wired up and
every "provider test" silently passed without exercising any parsing.

**Tests must never write to a production credential label.** A test that
called `saveClientConfiguration` against the real `gemini.oauth.*` labels
deleted a working Google client secret on its first run. Keychain tests use a
randomised label; anything that needs the store/clear *decision* tests the pure
function (`secretToStore`, `clientIDToStore`) instead of round-tripping through
the labels the running app reads. For the same reason `GeminiQuotaProvider`
and `CLIProxyClient.discoverConfig()` skip ambient credential and proxy lookup
under `TestHost.isActive` — otherwise tests depend on whether the developer
happens to be signed in or running a local proxy hub.

**Never assert on a duration derived from `Date()`.** Pass an explicit `now`.
`Int(179.97 / 60)` is 2, which made one test fail ~25% of runs.

**Don't add Keychain attributes that need entitlements.** `kSecUseDataProtectionKeychain`
returns -34018 from `swift run`, silently breaking every credential path. It can
only go in alongside a signed, entitled `.app`.

## UI constraints

Popover is 384pt wide; with the 12pt edge margin and 14pt card padding a row
has **332pt**: avatar 28 + 8 + name 112 + 8 + a 176pt grid of three window
columns (5H / WK / MO, 8pt apart). Use flexible widths inside the grid, not
fixed ones — an earlier layout summed past its budget and clipped on launch.
A provider's bar goes in the column its token names (`WindowColumn`), so new
providers must use the standard tokens `5H`, `WK`, `MO` for those windows;
anything else (`BN`, `OV`, `OD`, `SP`, `1D`, `PLAN`, `CYCLE`) is drawn on its
own line under the row.

A window cell is one bar, one fill colour and one marker. The fill is the
state colour (`DualBarProgressView.stateColor`, shared with the percentage under
it) and the single tick is where an even pace would be, drawn only when the
vendor published a window length and reset, and never on a spent window.
`DualBarMetrics.paceMarker` is the one definition of that, read by the tick, the
"even pace" legend, the amber colour, the tooltip and the spoken label, so none
can claim a pace the others would not draw: `expectedPaceFraction` alone, with no
reset or window length behind it, is not a pace. Countdowns in a row (the cell's
compact text, the spoken label, the forecast) all read `WindowGridPresentation.now`,
never their own `Date()`, so they cannot straddle a rounding boundary. Don't
add a second marker or extra over/under-pace segments: three colours and two
triangles per bar made the card unreadable. A column the vendor does not publish
shows a faint dash, never a track, which would read as 0% used. A window the
vendor blocked but still reports a percentage for (OpenCode Go) wears the
vendor's blocked colour, which sits too close to amber to tell apart, so a
`BlockedGlyph` (`nosign`) sits beside its figure everywhere it is drawn and the
spoken label says "blocked". Without a percentage the cell already says
"Blocked" in words and draws a dashed placeholder.

Every row needs an `accessibilityLabel`, and status needs a non-colour channel
(SF Symbol shape). Colour alone fails WCAG 1.4.1, and "glance to know" is the
entire product.

## Regression tests must be shown to fail

A test that passes proves nothing about a bug it was written for. Reintroduce
the defect and confirm the test goes red, then revert. Doing this over today's
fixes found three tests that could not detect their own regression: two were
masked by a *second* guard elsewhere (each alone sufficed, so mutating one
changed nothing), and one asserted `preferences !== .standard`, which stayed
true under the test-host override no matter what the production path did.
That one is now behavioural — it writes through `preferences` and checks the
value lands in the named suite and not in `.standard`.

## Before claiming done

Run the build and the tests. Don't tick an acceptance box you haven't executed
— every defect in this project's history traces back to that.
