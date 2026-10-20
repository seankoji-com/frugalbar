# Gemini quota scoping regression

Investigation date: 20 October 2026 (Australia/Sydney).

At the screenshot capture, Antigravity CLI 1.4.2 showed Gemini weekly remaining
0%, refreshing in 85h12m, with its five-hour bucket disabled. The separately
metered Claude/GPT group had 55.20% weekly and 100% five-hour remaining.
FrugalBar v0.19.0 showed Gemini at 23% weekly used and 0% five-hour used.
These are historical observations, not current account readings.

## Supported failure mechanism

At `3cdfedfcb3bd6b9fe00f2d02c9291dc01a33ba2b`, `GeminiQuotaProvider` sent `{}` to
`retrieveUserQuotaSummary`. It resolved `cloudaicompanionProject` only if that
response had no Gemini buckets. A populated response therefore suppressed
project selection, even when it described a different quota pool. Fraction
inversion and disabled-bucket filtering were already correct.

Project-first requests are supported by primary client sources:

- [UsageBar's provider documentation](https://github.com/luisleineweber/usagebar-fork-archive/blob/main/docs/providers/antigravity.md#cloud-code-api-primary)
  requires the account project before reading quota and explicitly rejects
  project-less readings. Inspected documentation blob:
  `e14a5c7f02c3c9218d2bb8f67ce34ef378027e5e`.
- [CodexBar's provider documentation](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md#when-the-antigravity-app-is-closed)
  describes a summary request scoped to the selected account's project.
- The installed official `agy` binary contains
  `RetrieveUserQuotaSummaryRequest.GetProject`, consistent with that protocol.
  This establishes the field, not an observed request or its requiredness.

The repair resolves the project on each host before requesting its quota. The
same token and host supply project, quota and optional plan. There is no
cross-account fallback, comparison of conflicting hosts, or maximum chosen
across pools. No project means unavailable. Scoped HTTP, decoding and transport
failures retain the provider's existing failure policy. Neither credential
selection nor request identity was changed without live evidence to justify it.

## Live diagnosis limit

The only inspected local CLI session had an expired cached access token. A normal
`loadCodeAssist` request returned HTTP 401. No token was refreshed or written,
no configuration changed, and no prompt was sent. The Mac's FrugalBar Keychain
session and effective API override were unavailable from this Linux worktree.
Therefore this run establishes an unsafe source path and a supported repair,
not the exact account/project/host responsible for the two screenshot readings.
A fresh, authorized comparison on the owner's Mac remains needed for that
attribution and live acceptance. No private raw response or credential is stored
in this repository or the CI artifacts.

## Behaviour and proof

`ProviderHTTPTests/geminiScopesPopulatedSummary` supplies a plausible populated
unscoped response and a separate scoped representative of the screenshot. It
checks the actual provider through `QuotaHTTP.$session`, asserts the requests,
and requires 100% weekly used, the published reset, critical urgency and no
five-hour bar. Dates and project IDs are test fixtures. A second test reverses
the pressure relationship, proving the scoped pool wins even when it has less
usage. Other cases cover missing projects, scoped HTTP/decode/transport failures,
per-host project selection, separate model groups and disabled buckets.
Two default-host tests reach credential rejection from the scoped summary,
after a successful project lookup. One requires the walk to stop on the first
host; the other requires a later rejection to override an earlier timeout.

Run on a clean disposable macOS checkout:

```sh
swift build -Xswiftc -warnings-as-errors
scripts/run-swift-tests.sh
scripts/run-swift-tests.sh
swift build -c debug --build-tests
python3 scripts/verify-gemini-regression.py
```

The proof script restores the **entire original provider** from the pinned
revision and requires the named test to fail by assertion, after a green control
and before another green control. It also independently removes the project
body and disabled-bucket filter and reverses fraction inversion. Only the
scoped quota branch is mutated to continue after rejection or retain an earlier
timeout, with a separate behavioural test for each defect. Only the
intended Gemini cases run during mutation proof. It records revision, hashes,
command arguments, working directory, exit status and test logs in
`coverage/gemini-mutations/`. Compiler errors and empty selections do not count.
The optional `verify_gemini_mutations` input on `quotabar-ci.yml` runs this proof
and publishes `gemini-regression-proof`, including a production SwiftUI render
of the representative weekly-only output. That render is a visual fixture,
not a live or provider-parsing claim.

The prior tests that expected no project lookup for populated buckets, or
preservation of an unscoped response after a failed project retry, described the
unsafe fallback. They are replaced with project-required and scoped-failure
behaviour. Missing plan metadata still has its own passing-quota test.

Linux local execution cannot establish Swift/macOS results: `swift` is absent.
Hosted run/head/artifact references belong in the implementation handoff after
execution. Release, tag, tap publication and the owner's Homebrew upgrade follow
code evaluation; this code change does not complete those delivery stages.
