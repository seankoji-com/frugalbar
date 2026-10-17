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

**One credential's failure is not another's verdict, and a vendor's `Retry-After`
is an instruction.** Claude and Codex each read two independent credentials: the
CLI Proxy's account token and this Mac's own (Claude Code / `~/.codex`) token.
A failure through the proxy — 429 included — goes to the direct token before the
row gives up, because Anthropic throttles the usage endpoint per account token
and the proxy's could sit at 429 for a day while the local one answered 200; the
row read "Rate limited" for that whole day. Report the proxy's reason only when
the direct token cannot answer either. A 429 that carried `Retry-After` keeps it
(`QuotaHTTP.retryAfterDate`), names the window in `remedy`, and holds back the
*automatic* poll for that long (`CacheEntry.vendorRetryAfter`) while the user's ⟳
still goes out — swallowing their click is the dead-button bug #90 fixed.

**Claude's usage endpoint is read under Claude Code's policy, not the API-key
one.** `QuotaHTTP.failureReason` is right for a key surface, where 401 and 403
both mean "fix the credential". Anthropic's OAuth usage endpoint instead uses
403 as a throttle, and — because `QuotaManager` exempts `credentialRejected`
from the poll floor — reading one as a bad credential re-asked the throttling
vendor every cycle *and* told the user to check a key that was working. So
401 is `credentialRejected` and 403/429 are `rateLimited` there. Anthropic
serves its throttle with `Retry-After: 0`, which `retryAfterDate` reads as "no
instruction", so the row then carried no instant at all and the 120 s loop kept
re-asking through the whole ~40-minute window; the cooldown is therefore
`min(vendor's figure, 1 h)` when the vendor named a positive interval, and a
**5-minute cooldown** when it named nothing — which is exactly the policy Claude
Code applies to the same endpoint. Use the vendor's figure when it is smaller: a
`Retry-After: 30` buys 30 s, not the floor. That lives in
`CLIProxyClient.claudeUsageCooldown`/`claudeUsageFailureReason` and is used on
both Claude paths, direct and relayed, because it is Anthropic's answer either
way. `retryAfterDate` itself accepts only ASCII-digit delay-seconds and caps
them at a day (`maximumRetryAfter`): `TimeInterval("inf")` parses, and an
infinite or 21-digit wait parked the automatic poll for good and trapped
`remedy`'s `Int(_:)` conversion.

**Neither Cloud Code host is authoritative for Antigravity's Gemini windows.**
`GeminiQuotaProvider` walks `productionAPIHosts` — `daily-` first, then the
plain host, the order `agy` and T3 Code's Antigravity probe use — and takes the
first summary that yields a Gemini window. The account this was diagnosed on got
`200` with only a "Claude and GPT models" group from `daily-` and both groups
from the plain host, so a single hard-coded host reported "Antigravity reported
no Gemini quota" while the windows were there to be read. A credential rejection
ends the walk (the same token would be rejected identically), a transport
failure is rethrown for the engine to map, and every other failure — 404, 5xx,
429 — falls through to the next host, which may simply not be the one in
trouble. A bucket the vendor marked `disabled` is not a reading: it keeps its
last published fraction, and drawing it would report a window nothing is
metered against. A configured `FRUGALBAR_GEMINI_API_BASE` is the operator's
answer and is asked alone, so its failure stays this provider's answer.

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

**A balance series is charted, never summed, and never a quota.**
`balance_reading` holds the figures a vendor published across polls that are not
quotas — an account credit, a key's remaining cap, a prepaid pool, a count of
credits a vendor meters. They have no window and no fraction, so they go in their
own table (as `event`, `catalog_model`, `feed_item` and `account_model` did),
written inside `record(_:now:)`'s own transaction so a balance and the poll's
readings can never disagree about which poll they came from. `value` is exact
decimal text, not `REAL`: a money figure round-trips as itself.

The series is `<source>|<unit>` (`BalanceSeries.id`), where the unit carries the
currency code or the vendor's own unit word. Two currencies of one account, and a
credit count beside money, are separate series and must never be drawn as one
line. A figure is recorded only when its poll **measured** and the metric
actually carries a balance: a failed poll records nothing (a synthesised 0 is a
real and frightening balance), and a `CurrencyBasis.lifetimeSpend` figure is
excluded outright because a cumulative spend total charted under a balance
heading asserts the wrong thing. A pool the vendor declares unlimited
(`.credits(remaining: nil)`) has no figure to chart either.

That freshness test is `BalanceSeries.isCurrent`, and it must ask about
`staleReading` as well as `confidence`. A failed poll keeps the previous
figures and keeps `confidence == .measured` — deliberately, so the last known
pressure still drives the menu bar icon — so confidence alone calls a
carried-over figure this poll's reading, and an outage lands in history as a
fresh balance. `BalanceSeries.of(_:)` is the *identity* of a series and says
nothing about freshness: a stale snapshot must still name its series, because
the row keeps drawing the trend it already had and simply gains no new point.
Gating the read instead of the write makes an outage erase the user's history.

The popover's inline strip and the inspector's balance card both draw from
`BalanceSparklinePresentation.make`, which returns nil below two readings — one
observation is not a trend — and centres a flat series rather than pinning it to
an edge, where it would read as a reserve that emptied. The inspector's empty
states say *why* there is no line (no readings, one reading, or a failed read),
never a blank axis. Its caption takes its direction from
`BalanceSparklinePresentation.Trend.of(change:)`, not from the sign of a
comparison: a series can move and come back — 5, 1, 5 is not flat, its range is
4, and its net change is zero — and choosing the arrow from `change >= 0`
printed "▲ 0" for one of those, claiming a rise that did not happen.

**The inspector's balance card is drawn for a snapshot that *publishes* a
series, never for one whose read succeeded.** `MetricDetailModalView.balanceReads`
records one entry per published series and keeps a failed read as that series'
outcome (`points` nil); `BalanceCardState.of(isLoading:read:)` then says
`.readFailed` for it. Both halves matter and each masks the other: skipping the
failed read leaves the card with no series to draw, so a failure to read renders
as "this provider publishes no balance" and the failure branch is unreachable —
which is what shipped, and why the gate alone cannot be caught by a test.
`QuotaStore.balancePoints` keeps the same three-way distinction (nil = no loader
or a failed read, `[]` = read but no readings, points = history). The pass bails
on `Task.isCancelled` before each series: a non-throwing `await` does not stop on
cancellation, so a dismissed modal would otherwise read every remaining series to
completion and discard the lot.

**`balance_reading` carries no secondary index.** The `WITHOUT ROWID` table's
primary key on `(series_id, measured_at)` is already its clustering b-tree, so an
index on the same columns would be a second copy of the same keys — dead storage,
and one more b-tree write on every poll. Neither read could use it either. The
same rule applies to any future `WITHOUT ROWID` table added here.

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

**A prepaid API credit balance rides the snapshot that already read it, and is
never a quota.** `QuotaSnapshot.apiCredits` holds `APICreditEntry` values —
deliberately *not* snapshots — so no balance can reach `consumptionFraction`,
the urgency bands, exhaustion sorting, `displayBars`, the advice engine, the
history recorder or the widget's average, all of which read snapshots. That is
the structural half of "balances stay out of quota maths". The other half is
that the figure arrives in a response the snapshot already made (OpenAI's
`credits` block, Anthropic's `spend`/`extra_usage`/`iguana_necktie`), so a
provider of its own would duplicate the request and a second cache key would
split one reading in two. An entry yields no fraction: `MetricType.credits`
returns nil from `consumptionFraction`, because a count of credits has no cap to
be a fraction *of*. The popover draws the entries in one card of their own
(`APICreditSectionView`); the card is absent when nobody published one.

**A unit is never converted across, and a scale is never guessed upward.**
OpenAI's `credits.balance` is a **count of credits** — the unit its own console
prints ("62,500 credits remaining") — so it is shown as credits and never as
money. Anthropic's legacy `extra_usage` amounts are **minor units**, scaled by
its own `decimal_places` and by 2 when it states none (cents is what two
independent clients shipped against real payloads; a `$200` monthly limit read
as `$20,000` is the failure this guards); the newer `spend` block declares its
own `exponent` per amount and is never scaled by a default; `iguana_necktie`'s
`*_dollars` are already dollars and are never divided. A pool that publishes
**no limit and no balance** yields **no entry**: its only figure is what was
*used*, and `MetricType.currency` has one place for a number — a balance — so
printing it would be the wrong-label defect again (one figure under one label;
OpenRouter's balance row sets `spent: nil` for the same reason). A published
*balance* on its own is enough, which is how Anthropic's promo credit is drawn
from `remaining_dollars` with no `limit_dollars`, and a pool that did publish a
limit is drawn even with nothing left in it: `remaining` is nil exactly when
`used` has passed `limit`, and the entry reports zero rather than vanishing,
floored the same way OpenRouter's credit subtraction is (`max(published −
used, 0)`) because a balance has no negative form. A `has_credits: false`, a
disabled `is_enabled`, an unparseable figure or a missing block all yield
nothing, never a 0 — the only zero drawn is the pool above, floored at it
because it has passed its own measured limit, not a stand-in for a figure nobody
sent.

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

**An empty activity table is not an empty week.** The table is empty on a first
run, stale after every restart until a pass finishes, and short while an input
cannot be read. `ActivityIngestionEngine.Status` says which, from this process's
own passes only: never a flag remembered from an earlier run, which would vouch
for a table nothing has caught up (that was tried, and over-claimed). Adapters
must report an input they cannot read in `ActivityIngestResult.skipped` and leave
it without a watermark so it is retried; returning success with it missing makes
every total quietly short, and recording its new size and mtime made the Claude
adapter never look at it again. A read that fails part-way counts too: ending a
row loop on any `sqlite3_step` result but `SQLITE_DONE` turns a failed read into
a short or empty week (the OpenCode adapter and the token query both did; the
query now throws and the adapter reports the input skipped). The Tokens layout
says it is still reading, or could not read everything, and shows "No token
activity" only once a clean pass has finished this run. Read the status before
the data, and treat an unknown status as not complete.

**A hidden provider is not polled, not counted, and not remembered.**
`QuotaManager` reads `ProviderDisplayPreferences` once per poll, skips hidden
vendors' fetches and removes their cache entries, so they vanish from the
summary, advice, history recorder and widget, and a vendor shown again is
fetched at once instead of waiting out `minPollInterval`. `sortedSnapshots()`
also drops them on read. A `.custom` order is the user's list verbatim, with
one exception: the exhausted drop to the bottom as a block and everything live
keeps the user's relative order. "Exhausted" there is `sortBand == 2` — for a
single-instance vendor that is `isQuotaExhausted`, deliberately *any* spent or
blocked window rather than every one; a multi-instance vendor's block moves
only when every workspace is spent, because the test is the `min()` of its
instances' bands. Tests inject
`displayPreferences:` and never touch the real preference store.

**The poll floor has two clocks, and a forced refresh uses the user's.** A
`CacheEntry` carries both `fetchedAt` (any fetch) and `lastUserFetchAt` (a
user-initiated one). An automatic poll is measured from `fetchedAt`; a
`forceRefresh()` is measured from `lastUserFetchAt`. Measuring both from one
instant made the ⟳ button dead exactly when it gets pressed: opening the
popover runs a load, that load's fetch armed the floor, and the ⟳ clicked a
moment later was served from cache with no request issued — the icon spun and
every number stayed put. A poll nobody asked for must not swallow the click
somebody did. Mashing is still bounded, because each forced fetch re-arms the
user clock. The `notConfigured`/`credentialRejected` exemption survives on
both paths.

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

A row's banked reset credits draw as one `ticket` glyph per credit
(`MetricRowPresentation.ResetCredits`), capped at `maxTickets` with an exact
`+n` for the remainder, on a line of their own under the row. The glyph strip
carries no accessibility label — the row is one accessibility element
(`children: .ignore`), so a label on a child is never announced; the count is
spoken by `combinedAccessibilityLabel` instead. A vendor that published no
figure and a vendor that published zero both draw nothing.

**One money rule, and it is `MoneyText.format`.** `.formatted(.currency(code:))`
and `NumberFormatter` both consult the *process* locale, so the same USD figure
read "$179.50" on one Mac and "USD 179.50" on another — and a money row printed
"$179.50" in its subtitle directly beside "USD 179.50" in its own value chip,
because one went through `MoneyText` and the other through the locale. A balance
is a fact about a vendor account, not about the reader, so `MoneyText` chooses
the symbol deterministically (AUD → "A$", USD → "$", anything else stated with
its code). Provider balance subtitles, the row's value chip
(`MetricRowPresentation.currency`), the inspector's currency block and the
API-credit card all go through it. Do not add a second money formatting rule
anywhere: `.formatted(.currency(code:))` is a bug in this codebase.

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
