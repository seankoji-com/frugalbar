# Agent notes — frugalbar

Swift package at repository root.

Structure and type names are discoverable with `ls` and `grep`, so they aren't
repeated here. What follows is only what you can't derive from the tree, and
what has actually gone wrong before.

## Commands

```bash
swift build -Xswiftc -warnings-as-errors && scripts/run-swift-tests.sh
```

CI runs exactly this, then re-runs the tests once more to catch flakes. That
whole-suite CI re-run includes the deadline suite; do not add a per-suite retry. The
script is `swift test -c debug --parallel` split in two: the real-clock
`DeadlineUncancellableTests` suite runs in its own invocation and the rest
runs in parallel as before. The suite missed its deadline in the full parallel
run on hosted CI; the logs are consistent with its timeout task queueing behind
other tests for the concurrency pool, though host contention has not been ruled
out. The script confirms the isolated suite still appears in the test list. The
matching `--filter` and `--skip` expressions divide the suite between the two
successful invocations. Their summary counts cannot be compared with the test
list because parameterized cases are counted differently. Don't
fold the suite back into the parallel run, and don't add a retry or loosen its
timing to get it green there.

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

**A missing Claude Code session is not a vendor-payload verdict.** The CLI
keeps the credential item after a session ends, writing `loginEnded` (observed
as `"time_limit"`) and blanking the tokens. `claudeOAuthToken` correctly withholds
that token, but a read the provider still attempted then reported
`.badResponse` — "Unexpected response · Vendor returned unexpected data" — which
sent the owner looking for a data problem on a Mac whose only real state was
"sign in again" (26 Nov 2026). `KeychainManager.claudeLoginEnded(from:)` reads
`loginEnded` (inside `claudeAiOauth`, and at the top level for the same fact) and
a **present but blank** `accessToken`; a missing field is not this state (the CLI
may have renamed it, written a partial item, or stored the token elsewhere), and
an *expired* non-blank token is not either, because it may still be refreshable.
`claudeLoginEndedAsync()` reads the same cached blob on the credential queue and
respects CLI discovery. It is **cache-only**: a cold miss is "cannot say", never
"ended", so a status check never opens another app's Keychain item. It also
deliberately does not fall back to a second store (the macOS login item beside an
older on-disk copy): the fact must describe the credential the request actually
used, and two blobs are not evidence of one login.
When a direct Claude read fails with `.badResponse` or `.notConfigured` and that
fact is true, `ClaudeQuotaProvider.sessionFailureReason` reports
`.credentialRejected`, whose remedy now says "Sign in again, or check the
credential in Settings". The fact is consulted only when the direct credential
is the CLI login (`directCredentialIsCLI`, false when FrugalBar holds a saved
key): a token typed into this app is a different credential, so its failure
keeps its own reason. `hasSavedCredentialAsync` answers `Bool?`: a locked or
unreadable vault — and a test host that did not inject provenance — is "cannot
say", which also keeps the credential's own reason rather than guessing. A
proxy's own reason also stands even when the local login has ended — one
credential's failure is not another's verdict — and the proxy's
auth files publish no session state to read. `ClaudeAccountDiscovery` applies
the same mapping to the unavailable-binding it keeps for a previously verified
direct row whose identity read fails, because that path never reaches the
provider's read; when the login ended and its token is gone, that route is
retained (it is not dropped just because a proxy account keeps the list
nonempty), so the row and its history survive with the sign-in remedy. Retention
requires the stored binding's `fromCLI` evidence: a saved key that was deleted
is a real deletion, not an ended session, and its row must go. The
identity read's own reason is kept separately (`identityFailure`): a timeout is
not a payload problem and must not become sign-in advice. A 401/403/429 or a
transport failure the vendor actually produced is likewise more useful than a
generic sign-in, and a healthy login leaves `.badResponse` alone. The Settings
row already names the service ("Claude Code"), so the remedy does not repeat it.

**A carried-over reading still says why the newest poll failed.** `QuotaManager`
keeps the last figures and records the failed read in `staleReading`, which is
the ordinary path for "signed in yesterday, session ended today".
`ProviderConnectionPresentation` therefore reports a measured snapshot with
`staleReading` as its reason and remedy (normally "Connected"), the popover's
stale note carries the remedy instead of only "refresh failed", and the
inspector's carried-over note names both the reason and its remedy. The popover
also draws an unreadable row's remedy beneath its headline; previous wording
made the owner open Settings to discover the next step.

**Antigravity's ended session is only visible where the provider owns it.**
`GeminiQuotaProvider` maps this Mac's primary row's `.notConfigured` to
`.credentialRejected` when `GeminiOAuthSession.storedSessionEnded` says a Google
session is stored but can never authenticate — no refresh token and a spent or
blank access token. The flag is `isLocalSession`, threaded from discovery as the
account's `isPrimary`, because discovery builds even the local row as an
account-carrying provider (`account == nil` alone would miss production). A
vault with no client configured is not evidence of an ended session: that needs
configuration, not a sign-in, and the same holds when the client secret is
missing (`isClientConfigured`), because Settings cannot open a sign-in without
both halves. Once both are configured, a stored session belonging to a different
client is ended regardless of its refresh token — it can never authenticate, so
the answer is a re-sign-in. A same-client session with a refresh token is not
"ended" even after a failed renewal, because that failure may be the network's,
and an absent session stays "Not configured". A named account's route, proxy or
direct-with-its-own-token, is never relabelled from this app's session: the
proxy publishes no session state, so its own reason is the honest one.

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

**Argon is retired only when Antigravity states the merge.** The vendor used to
meter it as a separate weekly pool ("Gemini 4 Argon · Separate on Pro"). On some
accounts that group is gone and the `Gemini Models` group's own description
names Argon among the models it covers. Then Argon is metered by Gemini's
windows, so `GeminiQuotaProvider` reports `argonMeteredWithGeminiReason` and
every `QuotaManager` read filters the pool out. A summary that omits the Argon
group without stating that merge, or whose group inventory could not be read,
keeps the unavailable row: absence alone is not a statement that the pool is
gone. The entry stays in the cache only so the poll floor and a vendor's backoff
still apply to it; deleting it made every manual refresh re-hit the vendor for a
pool nobody can see. Never draw Gemini's windows under an Argon label: two pools
with one allowance would double its headroom in Use now and the widget.

A published Argon group — including one whose buckets are all disabled, and one
whose buckets only the lenient identity scan can read — keeps its own row. A
host's 429, rejection, unparseable body or transient failure outranks
retirement, and retirement requires every verified route to agree: a second
route that publishes an Argon group, refuses the credential or fails outright
must not be hidden by the first route's merge verdict.

**OpenDesign is read through its web sign-in, not an API key.** An OpenDesign
inference key gets `401 unauthenticated` from the usage endpoints (checked with
a real key on 22 November 2026 AEDT, 21 November UTC), so there is no key slot. `OpenDesignWebSession`
is an in-app WebKit sign-in; the provider's two GETs
(`/api/v1/workspaces/current`, then `/{id}/billing/coding-plan-usage` with
`X-Vela-Workspace-Id`) run inside that page, and only the status and JSON body
reach Swift. Windows are chosen by `durationSeconds` (18000 → 5H, 604800 → WK,
28–31 days → MO), never by order, and MO is drawn only when published. A
mismatched workspace id, a duplicate window, or a zero or unparseable limit
fails the read rather than drawing a bar, and so does a figure that is not a
finite count (a 400-digit string parses to infinity, and a ratio of two traps
the percentage's `Int` conversion). A reading is filed under its workspace
(`OpenDesignQuotaProvider.seriesID`), and a failure under the bare vendor id;
`QuotaManager` retains figures only within one series, so a workspace switch
or a failed poll never shows another workspace's quota, and a switch never
reads as a usage drop to the event detectors. History finds every workspace
key by the `opendesign:` prefix (`vendorClause`, `Subject.keyPrefix`,
`vendor(forInstanceKey:)`); the one OpenDesign History subject draws them as a
single line, so a workspace switch shows as a step there. Both GETs carry one
connection generation. Disconnect bumps it (an in-flight read is discarded),
drops the cached reading without running the history recorder, and a pass
already in flight drops OpenDesign's result at commit (`forgetReadings`). The payload contract comes from
token-monitor PR 1366's synthetic fixtures and has not been checked against a
captured response.

**`consumptionFraction` is `Double?` and nil means "no denominator."** Never
coerce it to 0 or 1 — those read as "plenty left" and "exhausted".

**A model-scoped window is drawn on its own line, never ranked as the plan.**
Anthropic moved the per-model weekly caps out of `seven_day_opus` /
`seven_day_sonnet` (both now `null`) and into the usage endpoint's `limits[]`
array: `kind: "weekly_scoped"`, `percent` 0…100, `resets_at`, and the model's
name in `scope.model.display_name` (currently "Fable"). `ClaudeQuotaProvider`
puts those in `QuotaSnapshot.scopedBars`, which is deliberately outside `bars`:
a scoped cap only blocks one model, while every `bars` consumer reads a window
as plan-wide (exhaustion sorting, the advice engine's worst bar, the menu bar,
the widget's story, `displayBars`' collapse). Subscriptions draws each on its
own line under its Claude account row, with its own percentage and reset, while
the pool is usable (`ProviderGridPresentation`'s extra bars). A spent or blocked
plan window hides them. `percent` is a percentage, so it is
divided by 100 directly — running it through the flat windows'
fraction-or-percentage heuristic would turn 1% into 100%.

**Urgency and confidence are separate axes.** `Urgency` is quota pressure;
`Confidence` (did we get a reading) is a decoration. An unreadable provider
must never outrank a critical quota — that inversion made the icon a permanent
grey error triangle for every user. The menu-bar title no longer shows worst
pressure. It shows the suggested pool (see *The glance* below). The popover
shows the individual pools and their reset times.

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
and are served **only** when the request identifies as the Claude Code CLI
(`CLIProxyClient.claudeCLIUserAgent`); without that user agent the same account
answers `eligible: false, ineligible_reason: "surface"`, which decodes to `nil`,
never 0. The grant variant is throttled when polled, so it is asked for at most
hourly (`ClaudeGrantSchedule`) and the plain read in between still carries every
quota window — but no `cedar_ember` block, so the last published grant figure is
cached per credential and re-applied to those plain reads. Without that carry-
forward the tickets (and the reset-credit detector's stable baseline) vanished
for the fifty-eight minutes between grant reads. A malformed or absent grant
block yields no figure; guessing one would be a synthesised number.

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

**The desktop widget tells one pool's story or stacks tokens; it never totals
quota.** Its two layouts are Story (one pool, `ProviderStoryPresentation`,
following the Use-now pick unless the user chose a pool) and Tokens (see token
totals below). The Chart and Overview layouts were removed; a stored `chart` or `overview` choice is an unknown value that `WidgetFilters`
decodes as Story, keeping the rest of the saved filters. Keep windows from
different vendors apart: vendors meter different things over different
windows, so no "total" or "combined" quota figure belongs on any layout. The
widget is an app-owned `NSPanel`, not WidgetKit, because there is no `.app`
bundle.

**A prepaid API credit balance rides the snapshot that already read it, and is
never a quota.** `QuotaSnapshot.apiCredits` holds `APICreditEntry` values —
deliberately *not* snapshots — so no balance can reach `consumptionFraction`,
the urgency bands, exhaustion sorting, `displayBars`, the advice engine, the
history recorder or the widget's story, all of which read snapshots. That is
the structural half of "balances stay out of quota maths". The other half is
that the figure arrives in a response the snapshot already made (OpenAI's
`credits` block, Anthropic's `spend`/`extra_usage`/`iguana_necktie`), so a
provider of its own would duplicate the request and a second cache key would
split one reading in two. An entry yields no fraction: `MetricType.credits`
returns nil from `consumptionFraction`, because a count of credits has no cap to
be a fraction *of*. The popover draws the entries in the Wallet; the Wallet is
absent when nobody published a credit or balance.

**A configured credit is not a measurement, and Google's AI Studio credit
cannot be measured.** The Prepay balance and monthly Google Developer Program
credit on the Cloud Billing account behind a paid-tier Gemini API key are
reported only in AI Studio's Billing tab. The balance is account-wide, shared
by every project and key on it. The Gemini API
(`generativelanguage.googleapis.com`) has no billing operation and
an API key carries no billing IAM scope, so no documented API returns them —
`GeminiAPICredit` is therefore the user's own figure, never a vendor reading.
Each Google account's AI Studio key bills to its own Cloud Billing account, so
each account has its own credit (owner, 24 Nov 2026): `GeminiAPICreditStore`
keeps one per Antigravity account id (`accountsDefaultsKey`), and the older
single credit (`defaultsKey`) reads as the primary account's until the primary
saves its own; removing the primary's also removes the older one, so it cannot
return through that fallback. A credit saved under an id discovery later folds
into an account (`AntigravityAccount.historyAliases`) is still that account's
(`GeminiAPICreditStore.credit(for:aliases:in:)`), and the next save moves it to
the current id. Settings has one editor per account. Each is
drawn in the Wallet as its own "Gemini API cap · <account>" line (the title
names the figure for what it is), once per account however many routes read it,
with an
elapsed-month meter ("MO 63%" and the countdown beneath). The prepaid balance and
monthly grant stay in Settings and are not drawn. The line always says
*configured* and the date it was saved in its tooltip. Its fill is **elapsed
calendar time**, never spend: no documented API returns an API key's spend, and
dividing the prepaid balance into the cap would mix a prepaid pool with a spend
limit. The line shows "MO 63%", and its tooltip and spoken label say "63% of
the calendar month elapsed". It uses the informational colour, draws no quota
pace marker, and takes no part in quota maths. The balance may be negative:
Google documents a billing lag that overdraws it, and `MoneyText` prints the
sign outside the symbol. It is
deliberately **not** an `APICreditEntry`: that rides a
snapshot's measured fetch and `BalanceSeries` charts every entry, so carrying it
there would record a typed number as balance history. Amount fields accept one
whole number only (`GeminiAPICredit.amount(from:)`): `Decimal(string:)` reads a
prefix, so "1,234.50" and "30abc" would have saved 1 and 30. It lives in its own
snapshot field, attached on read from `GeminiAPICreditStore` rather than stored
in the poll cache — so a failed Antigravity poll neither erases nor stales it,
a change takes effect without a poll, and only a Gemini snapshot ever carries
it (Argon and the shared Claude/GPT pool are separate allowances), each account's
on that account's Gemini snapshot. Read it on read:
`QuotaManager.attachingGeminiCredit` is applied in `visibleCache` and
`sortedSnapshots`, not in the fetch path. Saving from Settings replaces the
snapshot list (`QuotaStore.reloadConfiguredCredit`): it never force-repolls a
vendor and never runs the history recorder, because a typed figure is not a
poll.

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
also drops them on read. A `.custom` order preserves the user's relative order,
except that visible Antigravity pools form one service block anchored at the
first visible nonempty member, with stable order inside it. The block moves
last only when every visible pool has a spent or blocked window. Other exhausted
vendors also drop to the bottom as blocks. "Exhausted" there is `sortBand == 2` — for a
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

**Preferences live in an explicit suite, not `UserDefaults.standard`.** Before
the executable embedded an Info.plist, `.standard` used its *process name*.
The release installs as `frugalbar` and the SwiftPM product builds as `QuotaBar`,
so `.standard` gave them separate stores:
opting into CLI discovery under one name left the other reporting every
provider "Not configured", with nothing on screen to explain it. The Mach-O
Info.plist now embeds `CFBundleIdentifier` `frugalbar` to preserve the legacy
WebKit namespace across renames; preferences deliberately stay in
`com.quotabar.app` to preserve their historical identity. Read and write through
`CredentialStore.preferences`, including `@AppStorage(_, store:)`.

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

**The glance.** The popover answers "which pool do I use now, and when do the
spent ones come back?" (owner, 23 Nov 2026). The 420pt popover shows
Subscriptions (the provider grid, titled so on 24 Nov 2026), Wallet and a
footer. Subscriptions expands one group at a time. Claude combines
Claude Code with Antigravity Claude/GPT. Gemini holds Gemini and Argon, and
each Antigravity row names its model and the route that read it ("AGY" for
this Mac's Google sign-in, "CLI Proxy"), from the reading's `cliSource` before
the account's `sourceLabel`. DeepSeek groups OpenCode Go, Command Code and
OpenDesign. Direct balances (OpenRouter, DeepSeek's own API credit) are Wallet
entries only, never Subscriptions rows (owner, 24 Nov 2026). The Wallet
(`WalletPresentation`) is a flat list, one line per credit with no group
headers and no subtitle (owner, 24 Nov 2026), and its section header carries no
note (owner, 26 Nov 2026: "credits and balances · never in rankings" was cut,
the section title says enough). A row's title names the provider, and the
account when the reading carries a named one ("ChatGPT API", "ChatGPT bonus",
"Claude · Primary", "Claude Fable · Primary"). The Console is where Claude's
monthly credit is read, not a second service, so it is not in the title; a
model ticket is named for its model ("Claude Fable") rather than "Claude Fable
reset ticket", because the gold ticket glyph already says what it is and the
reset has a line of its own. A carried-over reading wears a small LAST READING
tag; a figure the user typed carries no CONFIGURED tag any more (owner, 26 Nov
2026) — that line is only ever drawn for a typed figure, so the tag
distinguished it from nothing, and the tooltip still says so. The figure is the amount alone (owner, 26 Nov 2026): the
role word ("left", "grant", "credit", "cap" — `Row.figureRole`) is no longer
drawn as a caption under it, because a second 9.5pt line on every row made the
Wallet read as a stack of captions. The role still reaches the spoken label and
the tooltip (`row.spoken`, `spokenLabel`), so a remaining count, a monthly grant
and a cap can still be told apart without being printed twice. No figure carries
a "/mo" either (owner, 26 Nov 2026): the meter under it is the billing month and
the spoken label says monthly. A credit count over ten thousand is shortened for
the glance — "60k credits", not "60,085 credits" (`CreditText.compact`; the
inspector keeps the exact count through `CreditText.format`). On a line with a
meter the figure moves onto the meter's own caption, in that caption's size,
between the used share and the countdown, and the track then runs through the
vacated figure column to the card's edge (owner, 26 Nov 2026); an 84pt stub
could not show a window's shape. Lines without a meter keep the figure
right-aligned in the shared figure column. Every meter is normalised (owner, 26 Nov 2026): one
informational blue fill, one "MO 14%" label with no "used" suffix, the calendar
token, the figure in the middle and the countdown at the right, and an even-use
tick on every bar. A spent credit keeps `SpentTrack` and its red label — an
exhausted allowance must not render as a calm blue bar. A time-only meter publishes no
spend, so it draws no fill — an empty tinted track would read as "nothing
used" — and only its even-use mark at the elapsed share, built from the cycle
it was measured in because `evenPace` refuses a position with nothing behind
it. The label still says "MO 48%" and no "month elapsed" line sits under it. Opening a line passes
its balance series to the inspector, whose card for that series comes first.
When the title needs the room, the tag shrinks to its
glyph (pencil, clock) rather than cutting the account name; the tooltip and
spoken label still say the word. A line is LAST READING by the read that
produced it: the ChatGPT API grant and the Console credit have their own billing
reads, so a quota outage does not tag them and their own failed read does. A
direct balance whose read failed is still a Wallet line that says why
(`GlancePresentation` admits every `isDirectBalance` snapshot): it is in
Subscriptions nowhere, so dropping it would hide the failure from both. Clicking
a line opens the inspector of the snapshot it came from (`Row.snapshotID`).
ChatGPT has two lines: the monthly API credit grant and
the bonus credit count. Each Google account's configured Gemini API credit is
its own "Gemini API cap · <account>" line in the Wallet, never under an
Antigravity row in Subscriptions. The amount there is the **cap the user
configured**, not a balance: Google publishes no spend and no credit-remaining
for an API key, so the line can never say how close the project is to its cap,
and a project at its cap answers `429` while credit remains. A model's reset
tickets (Fable) sit beside that model's line in its Claude account's Subscriptions
row (`ModelTicketsBadge`); only plan-wide tickets, and a model ticket with no
model line to sit beside, are Wallet lines. The Wallet is a `Grid`: a fixed
meter column and a figure column as wide as the widest figure, so every bar
starts and ends in the same place (a fixed figure width let "60,085 credits"
push its bar out of line). A line with neither a meter nor a trend draws
nothing there and gives that column to its name instead: reserving it empty
squeezed "Claude Fable reset ticket · Primary" into three lines (owner, 26 Nov
2026). Only the figure column is shared, so amounts still end together. A
credit that expires and publishes what was used
draws the Subscriptions bar (`Meter.credit`, through `UsageBar`): % used and the
countdown beneath, the same colours, and the even-use tick only where the
credit's period is known. The ChatGPT API credit and Claude usage credits pass
the promo's own `barMetrics`. ChatGPT bonus credits come from the account
holder's saved grant (`OpenAICreditGrant`: total, expiry, and optionally the
date it was granted); OpenAI's usage payload publishes only the balance. The
bar draws its even-use tick only when both the grant date and the expiry were
saved (`periodLength`), paced over that period and never a calendar month.
Without a grant date it is a bar to the expiry with no tick. Time-only
credits (Claude Console, configured Gemini) draw an informational "MO 63%"
elapsed meter (`Meter.elapsed`) in `Theme.primary`, never a quota colour. A
balance (OpenRouter, DeepSeek, any `APICreditEntry` with a series) draws its
recorded trend through `BalanceSparklinePresentation.make`, which draws nothing
below two readings.
The group
averages use only fresh figures in the same window and are drawn as bars, not
as percentages (owner, 26 Nov 2026): an averaged column draws the same
`UsageBar` a pool row draws, with one dot per pool underneath — green where
that pool reported this window, red where it did not — in place of the old
"avg · 2/4" caption. Nothing on the card explains the dots or the ticks any
more (owner, 26 Nov 2026): the row's spoken label says what each mark means, and
the drawn legend made the card taller for a sentence nobody reads twice. The
group's status counts ("2 usable · 3 blocked · 2 spent") are spoken, not drawn
either: the dots already say which pools answered. A group that
publishes only one column draws that bar across the whole grid rather than
leaving two columns of dashes. Each pool keeps its service identity and opens
its own inspector.
- Use now ranks by **headroom at risk**: remaining share ÷ share of the window
  still to run, on long windows (≥ 7 days, or WK/MO) only. Soonest-reset
  ranking was tried on real data and picked a nearly drained pool over a full
  one a day later. A long window under 20% left vetoes a pick; a 5H window sets
  no floor and only gates when spent or blocked.
- A pool is one `QuotaSnapshot`. It is spent when a plan window is spent or
  blocked, or the vendor blocked the account on its badge (Command Code's
  `limited`). A spent pool's badge uses the latest reset among its spent
  windows if they all publish one. A group window turns red only if every
  pool reports that window spent. Its countdown uses the earliest published
  reset for that window.
- `DualBarMetrics.allowanceRole` defaults to `.plan`. Kiro `BN` is `.bonus`;
  Kiro `OV` and Grok `OD` are `.paidOverage`. Supplementary pools never make a
  pool spent and are never a pick's headroom; paid overage is never a pick,
  because using it spends money. Classify by role, never by label: labels are
  open-ended (OpenAI emits `nM`/`nH`/`nD`/`PLAN`, Gemini any token).
- Never a pick: stale readings, Fable and other `scopedBars` (excluded
  totally: not a candidate, not a veto, not a note), billing cycles,
  balance-only vendors, developer limits. When nothing qualifies, the best
  usable pool is shown as a caveat pick in amber.
- The menu-bar title's colour describes the pick: normal, amber for a caveat
  pick, red only when no pool is usable, each with a glyph. "All spent" is
  claimed only when every pool is confirmed spent; spent plus unreadable reads
  "None confirmed usable".
- Bars show **% used** (`UsageBar`, owner, 24 Nov 2026): empty when nothing
  is used, full when spent, so the fill reads the way vendors' consoles and the
  red spent "100%" read. A full bar for an unused window was read as
  exhausted. The figure under the bar is always printed, 0% included, and the
  header, group averages, inspector (its burndown caption included), the
  menu-bar title ("Primary · 55% WK used · 3d", rounded as the pick's cell
  rounds) and spoken labels say "used" too. The tick is where an even pace
  would be (`paceMarker`), drawn only when `paceMarker` is. Text that names its
  direction ("12% WK left" in a pick reason and the title's spoken label, the
  widget's story, the "% left over time" charts in History and the inspector)
  is unchanged.
- Use one unit per countdown. Subscriptions uses `ResetCountdownBadge.compact`
  so the badge and cell both switch to days at 24 hours, and the inspector
  opened from it says the same (`compactDescription`, `spanSpoken`). The menu
  bar and Story use `GlancePresentation.countdown`, which switches at 48 hours.
- A measured exhausted month fills the quota lane. A measured exhausted week
  can fill it when neither an exhausted 5H window nor a monthly reading
  needs its own column. Simultaneously exhausted 5H and WK windows show their
  own red used percentages. Unpublished cells stay blank.
- The Wallet builds each line from the existing credit presentations
  (`APICreditEntryPresentation`, `OpenAIUsageCreditPresentation`,
  `MonthlyPromoCreditPresentation`, `MonthlyCreditBarPresentation`,
  `GeminiAPICreditPresentation`, `MetricRowPresentation.ResetCredits`), so
  every credit rule below still governs its figures.

The legacy provider row (`MetricRowView`) is drawn only by the popover's
developer-limits card (GitHub REST, shown while it is near its limit). It has
no grouping, credits, tickets or model-scoped lines; those live in
Subscriptions and the Wallet. It keeps the constraints below, and its fallback
bar shows % used like every other bar.

Legacy rows are 384pt wide (`Theme.popoverWidth`); with the 12pt edge margin and 14pt card padding a row
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
vendor blocked but still reports a percentage for (OpenCode Go) wears the same
spent red as an exhausted window, and a `BlockedGlyph` (`nosign`) sits beside
its figure everywhere it is drawn and the spoken label says "blocked", so
blocked and spent stay distinguishable without colour. Without a percentage the
cell already says "Blocked" in words and draws a dashed placeholder.

**An exhausted or blocked row draws one red: `Theme.errorBold`.** Its bars, the
figures under them, the reset countdown and fallback text, and the avatar's
ring and tag all use it. `DualBarProgressView.stateColor` ignores a vendor's
`blockedColor`: OpenCode Go once passed `#ffb4ab` (`Theme.error`, the pale text
coral), and its workspaces drew pink hatching beside Command Code's deep red.
`Theme.error` stays for text that is critically low but not spent. An exhausted
avatar in the popover is the logo in greyscale at 55% opacity inside a 1.5pt
red ring, with the countdown (or `nosign` when no reset was published) in a red
capsule on the top-left corner, so the logo stays recognisable. The ring and
tag draw outside the 28pt frame and do not move it. The inspector and widget
keep the struck-through mark. In Subscriptions, spent *text* (the caption under
a striped bar and the "Blocked" fallback) is `Theme.error`: errorBold as 10–11pt
text measures 4.08:1 on the row and 3.58:1 hovered, under AA. errorBold stays
the fill, stripes, ring and tag.

**Each glance verdict has one definition; surfaces word it, never re-derive it.**
A run-out forecast is `RunOutVerdict` (total over reset × rate × projected
run-out, including a run-out already due between polls); an account-level block
is `QuotaSnapshot.isAccountBlocked`, read through `GlancePresentation.Pool.isBlocked`
and into the grid pool's windows; a used share is `GlancePresentation.usedPercentText`
(never "100%" under the spent threshold, "<1%" for a sliver); a countdown that
has passed is "due", never "now". Each of these was once derived locally and
drifted, one surface per review round, until it was moved to one place.
A return hint ("Back soonest", the menu bar's "next …") is
`GlancePresentation.soonestReturn`: never a stale pool's old reset, and never
for an account blocked on its badge whose block nothing dates: its windows'
resets say when each window turns over, not when the block lifts, so its return
is "not published" and the grid's cells show the block with no countdown. A
block the vendor dates is the exception (`QuotaSnapshot.accountBlockResetIsTheBlocksEnd`,
read through `accountBlockEnd` / `accountBlockHasPublishedReturn`), and it is
dated per bar, never for the whole account: `accountBlockDatedByBarLabel` names
the bar whose exhaustion raised the block — Command Code's `limited` is its
monthly credit pool running out, and the vendor documents that "your request
budget refreshes at the start of every billing cycle", so that row's published
cycle end is the block's end — or the vendor blocked the window itself and
still published when it frees, which is OpenCode Go's `rate-limited` month
beside its percentage. Only those bars keep a reset and a countdown; every
other window the badge merely blocked stays without one, so a sibling that
resets in an hour is never read as an unblock date by the grid, Back soon
(which names the dating window), the inspector (whose focus is that bar) or the
Story (which tells it). The dating bar must be a **plan** window, chosen once by
`accountBlockDatedBar` and read by both `accountBlockEnd` and
`accountBlockDatedWindowLabel`: a bonus or overage allowance is not the plan
that was stopped, so its expiry can never date the block, and the date and the
window's name can never come from different bars. Back soon additionally takes
both from a window the pool actually draws (`GlancePresentation.pool`).
Whether a pool's figures describe now is `GlancePresentation.Freshness`
(current, stale, or awaitingReset when a window's published reset has passed
with no reading since). Only a current pool is a pick; the grid notes
"Window reset · awaiting a reading"; the inspector leads with
`.awaitingReading`, never "Healthy"; and the burndown keeps its recorded
projection only while the live snapshot shows the same usable window: a
current, usable pool whose window is unspent and unblocked and whose reset
agrees with the recorded one (`Burndown.current(for:now:)`,
`InspectorRunOut.resetsAgree`).

Time is one clock too. The menu-bar title, the popover's sections and footer,
an open inspector and the widget's Story re-derive on the same whole-30-second
boundaries (`GlanceClock`, `.glanceTicks`, `GlanceClock.ticks()`), so a reset
that passes between polls turns every surface on the same tick. Each surface
used to run a timer from when it opened, and the inspector and the Story read
the time only on a data load, so they kept forecasting a window the popover
already called "due" (the Story's load is keyed on the poll attempt, which a
poll served from cache leaves unchanged). A load never moves a surface's time
backwards (`GlanceClock.displayTime`): it may finish after a tick already set a
later one, so the Story merges its load time in before awaiting any read. The
inspector's loop and the Story's stream both report the newest boundary
already passed when a tick wakes late (`GlanceClock.reportedTick`), not the one
they slept for, and ticks the Story missed collapse into the newest. `StoryClockTests` hosts the Story with
a fixed wall clock and an injected tick, and asserts what its body drew
(`ProviderStoryView.Drawn`), because a test of the helper alone stays green when
the view's wiring is removed (#218).

Every row needs an `accessibilityLabel`, and status needs a non-colour channel
(SF Symbol shape). Colour alone fails WCAG 1.4.1, and "glance to know" is the
entire product.

Banked reset credits draw as gold `ticket.fill` glyphs (`GoldenTicketView`,
from `MetricRowPresentation.ResetCredits`), capped at
`ResetCreditTicketLimit.maxCount` per scope group, with an exact `+n` for the
remainder. Claude splits the grant set by the allowance it resets: a plan-wide
ticket is a Wallet line of its own, with the credit's visible expiry as its
figure ("20d remaining"), and a model's tickets sit beside that model's line in
Subscriptions (`ModelTicketsBadge`), which a spent or blocked plan window hides.
A model ticket with no model line to sit beside is a Wallet line too, and that
includes one whose line a spent or blocked plan hides. `unmatchedResetCredits`
decides only by the labels its caller actually draws; also filtering on
`hidesModelWindows` there dropped those tickets from both sections. An expiry
the vendor did not publish says "Expiry not published" rather than borrowing
the reset window's date.

The grant **id** names the model first: an id containing Fable is
model-scoped even when it also clears a shared plan window
(`seven_day_overage_included`). If the id does not name a model, `clears`
decides: any plan window (`five_hour`, `seven_day`,
`seven_day_overage_included`) makes it the plan ticket, and a Fable-only clear
makes it the model ticket. The label is the fallback only when neither the id
nor `clears` is present. The split is never inferred from ticket order or a
"one general, three Fable" count; a grant missing `resets_left` yields no
split. A payload with no per-grant scope (OpenAI, or an older Claude read)
keeps the flat strip.

The model badge speaks its count, scope and every expiry in one label
(`ResetCredits.spoken`); a Wallet ticket line speaks its own. Each glyph
carries a `.help` tooltip with that credit's absolute published expiry. Glints are staggered and disabled under Reduce Motion. A
vendor that published no figure and a vendor that published zero both draw
nothing.

**Credit counts are shown rounded to the nearest whole credit.** `CreditText.format`
rounds for display; the exact `Decimal` stays on the metric, in the history
table and in the sync export. A figure like "60,085.422977 credits" is noise at
a glance and implies a precision the vendor's own console does not show. The
rounding is display-only: no balance, series or quota figure is altered.

**The Claude promo credit is drawn in the window anatomy.** It has a published
limit, so its Wallet line draws the Subscriptions bar from
`MonthlyPromoCreditPresentation.barMetrics`: % used, the day countdown beneath
and the promo's own pace tick, with the amount as the line's figure ("$200.00/mo").
It is still not quota: no snapshot fraction, urgency, sorting or advice reads
it. The compact countdown is the only reset-style figure drawn;
`MonthlyPromoCreditPresentation.resetText` remains populated and is read by
`spoken` (the line's VoiceOver label and tooltip). Both the countdown and the promo's reset text come from the promo's
own published period end (`monthlyPeriodEnd`); never substitute the subscription
renewal or a hardcoded day count.

**The linked Console organisation's monthly credit is its own line.** It is the
`monthly_credit_usd` / `next_grant_at` entitlement read by the opt-in Claude
billing web session (`ClaudeMonthlyCredit`), not the promo/usage-credit pool
above and not a balance or quota. The billing client reads that amount with
`Number(value)`, so the decoder accepts both a JSON number and a numeric string;
accepting only `String?` silently dropped a live entitlement. It is the
"Claude Console" Wallet line, its amount as the figure (through
`MoneyText.format`, so a whole USD amount keeps its cents) beside an `MO` meter.

**The credit belongs to one named row, chosen by identity.** With multi-account
discovery every Claude row is a named account, and named rows used to drop the
credit outright, so the line disappeared for everyone with discovered accounts.
The credit's identity is the signed-in claude.ai account (read in the page from
`/api/account`, projected to its UUID only) paired with the organisation the
billing query itself names (`organization_uuid`), hashed exactly as discovery
hashes an OAuth profile (`account|<uuid>|<org>`). Never match against the
account's other memberships: billing open for organisation B would then put
B's credit on organisation A's row. Separate billing and account requests can
authenticate as different people (a sign-out and sign-in to the same
organisation leaves the query unchanged), so FrugalBar's own read is one page
evaluation: account, billing, account. The credit is attributed
(`verifiedAccount`) only when both account reads name the same account. A
credit the page fetched by itself has no account reads around it and stays
unattributed until the next read verifies it (that read skips the five-minute
throttle once). A failed billing read keeps the earlier credit, marked stale,
and keeps its attribution unless an account read in that evaluation names a
different account or says no one is signed in (`contradicts`). An account read
that got no answer, or a whole evaluation that timed out, is not evidence of a
change: dropping the attribution then hid the line until a later read happened
to succeed. Once dropped, only a fresh verified credit restores it. `read` takes the credit and its identity from the
state at one instant, and rows asking while a read is in flight share it
(`CoalescedRead`). Rows still read one after another, so `QuotaManager`
enforces the invariant at commit: at most one Claude row carries the credit,
the latest observation in the order the session accepted billing results
(`ClaudeMonthlyCredit.observation`, `keepOneClaudeMonthlyCredit`), never by
`measuredAt`, which is when a provider started. A tie keeps none.
Settings says "Shown under" only from the snapshots the popover is
displaying, never from the session alone. `scripts/test-claude-monthly-credit-scripts.mjs`
runs the page scripts offline in CI; update it with any change to them. The named row waits at most four seconds for this
optional enrichment so it cannot push a measured usage read past the
provider deadline. When the wait runs out it takes the session's last
completed read (`lastRead`, with that read's identity, still bound by
`resolve`) rather than nothing, marked stale because it is an earlier
observation; returning nil dropped the line for the whole poll whenever
claude.ai was slow. Because that copy can outlive a sign-in change the session
sees before the pass commits, `keepOneClaudeMonthlyCredit` first clears any
named row (by its `claude-account:` id, since a deadline placeholder keeps the
credit but not the account) whose credit's identity is not the session's
current attribution, including when the session has none. The attribution is
sampled on the main actor and the cache is written on the manager's, so a
sign-in change landing between the two can survive one pass; the next poll
clears it. FrugalBar's own billing fetch carries
`frugalbarOwnRead`, so the page's fetch observer does not report it as the
page's own fetch and clear the verification the read is establishing.
`ClaudeMonthlyCreditBinding.resolve` attaches the credit only when exactly one
shown row's verified identity matches. No match, or an unverified row,
attaches it nowhere, and Settings says why. Email, nickname and row order are
never evidence.

**That meter is billing-cycle progress, never API spend.** The linked payload
publishes no used or remaining figure, so `MonthlyCreditBarPresentation` fills
the bar with the elapsed share of the calendar month ending at `next_grant_at`
and prints "MO 87%" (plus the compact countdown); the tooltip and spoken label
say "87% of the billing month elapsed". It uses the
informational `Theme.primary`, not a quota state colour, and takes no part in
`consumptionFraction`, urgency, sorting, advice, history or the menu-bar icon.
When `next_grant_at` is absent, or the date is outside the current cycle, the
bar, percentage and countdown are omitted; never fill the track with an
invented 0% or a made-up spend, and never pin a passed date to 100%. Do not drop the line when no
promo credit is published, and do not fold it into the promo row: they describe
different pools.

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

## Notifications

**A banner is drawn by the application that posts it.** When the executable
runs from a `.app`, `NotificationDelivery` posts through
`UNUserNotificationCenter`: macOS shows FrugalBar's name, and a click opens the
event's page. An unbundled binary has no notification application — the
embedded `CFBundleIdentifier` is not enough — so it keeps the `osascript`
`display notification` path, where macOS attributes the banner to Script
Editor and the click opens it. Do not "simplify" the bundled path back to one
AppleScript call for both; that is exactly the Script Editor banner this
replaced. Delivery branches on `LocalNotificationIdentity.isAppBundle`, which
asks whether `Bundle.main` is a `.app` — not whether a bundle identifier
exists, which a bare binary also has.

**The title is a phrase; the detail goes in the subtitle or body.** A
status-page incident name set as the title filled four bold lines on macOS and
buried the body. Outage banners are `"Claude outage"` with the vendor's own
incident name as the subtitle. A single-event banner carries the event's link
in `AIEventBanner.url`; a consolidated banner carries none, because there is no
one page to promise.

**A denied permission must not look like an enabled toggle.** macOS asks once,
at launch, when any banner kind is on. `Preferences → Notifications` reads the
real `UNAuthorizationStatus` and says when FrugalBar is turned off in System
Settings, rather than leaving every toggle on with nothing arriving.

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
