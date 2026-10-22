# Gemini quota scoping regression

## Follow-up: CLI request identity

On 22 October 2026 (Australia/Sydney), a live comparison reproduced a further
source difference after the project-scoping repair. With the same access token,
host, selected project and request body, `User-Agent: antigravity` returned only
the Claude/GPT group. `antigravity/cli` without a version did the same.
`antigravity/cli/1.4.3` returned both groups, with Gemini weekly remaining 0%
and its five-hour bucket disabled, matching the new `agy` screenshot. The
Claude/GPT weekly fraction was 0.5519576 in both responses. Both production
hosts reproduced this difference. A separate comparison using the local CLI's
renewed credential also reproduced it. Tokens were renewed in memory for these
read-only requests; credential files were not changed.

The provider now sends the verified versioned CLI identity on project lookup
and quota requests. It still reads only Gemini's group and excludes disabled
buckets. Changing client identity, rather than choosing a higher fraction from
another pool, exposed the measured Gemini quota. The earlier project repair
remains in place. The historical investigation below did not test this identity
difference and did not establish the cause of this later report.

`antigravity/cli/1.4.3` is a pinned compatibility header, not FrugalBar's version
or a promise that Google will continue accepting it. Recheck the same-account
response comparison if Google's client routing changes. These probes did not
compare CLI version 1.4.2 with 1.4.3 and do not establish a minimum accepted
version.

The account model watcher intentionally retains `User-Agent: antigravity`. It reads
`fetchAvailableModels`, not `retrieveUserQuotaSummary`; this investigation did
not compare that endpoint's catalogs across headers. Changing that independent
model-discovery path would need its own evidence and regression coverage.

`ProviderHTTPTests/geminiCLIRequestIdentity` models the observed header-dependent
response on each host. It requires a critical weekly bar at 100% used, the
published reset, no five-hour bar, a project-scoped request and the CLI identity
on both requests. Fixtures use an artificial project and future reset date.
The mutation proof independently restores the old header at each call site.
The project mutant must fail the project request's explicit header assertion;
no header-dependent project response is claimed or invented. The quota mutant
must fail the quota request's explicit header assertion and the snapshot
assertions, because the fixture omits Gemini with the old quota header.
Swift execution and assertion-red mutation proof require macOS; local Python
checks validate only proof bookkeeping. The `verify-gemini-mutations` label opts
a same-repository PR into proof on opening, reopening and every subsequent push
(`synchronize`) while that label remains present. Do not remove/reapply it after
each push. Adding a label alone does not start or cancel CI; to prove an existing
head immediately, dispatch `quotabar-ci.yml` on its branch with
`verify_gemini_mutations: true`. Removing the label opts subsequent PR runs out
of this optional proof. Check the successful proof run's head before using it as
evidence. The label remains available after this branch is gone.

This proves the remote request difference, not which credential, API override
or cached reading the installed Mac build used. The corrected Mac build still
needs to be built, tested and refreshed before claiming live UI acceptance.

## Original project-scoping investigation

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

## Request deadlines and cancellation

The project-first repair added two requests per host, so relying on the shared
four-second URLSession request timeout could spend sixteen seconds within the
engine's ten-second provider deadline. Each Gemini project lookup and scoped
quota request now has its own two-second `withDeadline` bound. Four sequential
requests have an eight-second request budget, leaving two seconds for setup,
decoding and scheduling. Credential resolution still shares the engine's overall
deadline; this budget does not promise a reading when credential refresh itself
consumes that time. The shared provider timeout and deadline suite are unchanged.

The bound cancels the losing URLSession task. Two cancellation checks, before
each bounded request and after bounded work, prevent a cancelled fetch from
starting another host request or accepting a late response. The existing deadline
helper uses unstructured work, so parent cancellation is observed by the provider
at the next request boundary, at most one request budget later. Original transport
errors remain intact through the bound; local deadline expiry throws a timeout.
The loop-top and catch checks were redundant and masked one another in the
original cancellation test; they have been removed.

Two hermetic tests suspend a stubbed daily-host request indefinitely, once in
project lookup and once in scoped quota, and require the plain host to supply its
scoped weekly reading. Task-local test budgets shorten waits to 0.2 seconds; a
separate five-second outer deadline turns removal of the bound into a normal
assertion failure. Neither test asserts an elapsed duration derived from `Date()`.
The proof adds `unbounded-project` and `unbounded-quota` cases that remove the
bound and require assertion failures. The stalled-request cancellation test still
requires one request only, and a budget test pins production headroom.

Three controlled cancellation tests exercise the injected HTTP session. The first
cancels before entering the provider and requires `CancellationError` with zero
requests. The other two hold a successful project response or a valid scoped
weekly quota response in the URLProtocol stub, cancel the caller, then release
the response. They require `CancellationError`, exactly one or two daily-host
requests respectively, and no later requests or accepted reading. Gates determine
the ordering; these tests do not sleep to arrange a race. Their 30-second request
budget separates cancellation behavior from the timeout tests' 0.2-second budget.
The `cancelled-request-starts` mutation removes only the pre-request check and
must fail the zero-request assertion. The `cancelled-quota-accepted` mutation
removes only the post-response check and must fail by accepting the late scoped
quota. Each retained check therefore has its own independent mutation proof.
Hosted execution is required before treating Swift tests or mutations as passing.

If no host supplies a reading, a saved transport error takes precedence over a
content-less answer. A credential rejection overrides that error and ends the
host walk. `geminiContentLessAnswerDoesNotMaskTransportFailure` checks the exact
timeout error and the three requests to the expected hosts.

## Proof completion and retention

Proof manifests start `incomplete` before setup and identify all fourteen expected
cases. They checkpoint each phase, record an error on abort, verify source
restoration independently and become `succeeded` only after the full roster and
final Git diff check. Consumers must require `is_complete(manifest)`, including
the case/phase roster, exit codes and restored source hash. A new invocation
invalidates an old successful manifest and clears prior logs before setup checks.
An uncatchable process termination can leave an `incomplete` manifest and pending
restoration, never a completed proof. Directory/storage failures can prevent an
artifact from being written and remain process failures.

`python3 scripts/test_verify_gemini_regression.py` exercises this bookkeeping
offline without running or pretending to prove Swift behavior. It covers aborted
baseline/mutant/restored phases, missing original revision, invalid mutation
target, dirty checkout with stale logs, final-diff failure, interruption,
in-progress status and restoration failure.

The Gemini proof step precedes rendering, and artifact upload has `if: always()`.
A failed render fails the job while retaining existing proof logs. A failure
before the proof script starts can leave no proof output; the upload reports
that absence.

## Superseded tests

The prior tests that expected no project lookup for populated buckets, or
preservation of an unscoped response after a failed project retry, described the
unsafe fallback. They are replaced with project-required and scoped-failure
behaviour. Missing plan metadata still has its own passing-quota test.

## Verification and delivery limits

Linux local execution cannot establish Swift/macOS results: `swift` is absent.
Hosted run/head/artifact references belong in the implementation handoff after
execution. Release, tag, tap publication and the owner's Homebrew upgrade follow
code evaluation; this code change does not complete those delivery stages.
