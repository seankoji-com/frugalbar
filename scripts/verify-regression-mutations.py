#!/usr/bin/env python3
"""Prove regression tests reject independent defects, then restore.

Run only in a clean disposable checkout. Every edit is reverted in a finally
block, and a passing control run follows every rejected mutation. A compiler
failure or a filter that selects zero tests never counts as proof.
"""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "coverage" / "mutations"
SCHEDULER = "Sources/QuotaBarCore/Engine/BackgroundScheduler.swift"
OAUTH = "Sources/QuotaBarCore/Providers/GeminiOAuthLogin.swift"
QUOTA_MANAGER = "Sources/QuotaBarCore/Engine/QuotaManager.swift"
DEADLINE = "Sources/QuotaBarCore/Engine/Deadline.swift"
QUOTA_HTTP = "Sources/QuotaBarCore/Providers/QuotaProvider.swift"
GEMINI = "Sources/QuotaBarCore/Providers/GeminiQuotaProvider.swift"
MENU_BAR = "Sources/QuotaBarUI/MenuBar/MenuBarStatusView.swift"
CASES = [
    ("overlap-guard", SCHEDULER, "        guard !isRefreshing else { return }\n",
     "BackgroundSchedulerTests/refreshDoesNotOverlap", "an overlapping refresh is skipped and the next cycle still runs"),
    ("refresh-reset", SCHEDULER, "        defer { isRefreshing = false }\n",
     "BackgroundSchedulerTests/refreshRespectsRegistrations", "a refresh calls every registered handler and excludes removed handlers"),
    ("oauth-error", OAUTH, "error == nil, ",
     "GeminiOAuthCallbackOutcomeTests/errorWithCodeIsRejected", "an error takes precedence even when code and state are valid"),
    ("base64-plus", OAUTH, '            .replacingOccurrences(of: "+", with: "-")\n',
     "GeminiOAuthCallbackOutcomeTests/stateEncodingIsURLSafe", "OAuth state encoding uses URL-safe alphabet and removes both padding lengths"),
    ("base64-slash", OAUTH, '            .replacingOccurrences(of: "/", with: "_")\n',
     "GeminiOAuthCallbackOutcomeTests/stateEncodingIsURLSafe", "OAuth state encoding uses URL-safe alphabet and removes both padding lengths"),
    ("base64-padding", OAUTH, '            .replacingOccurrences(of: "=", with: "")\n',
     "GeminiOAuthCallbackOutcomeTests/stateEncodingIsURLSafe", "OAuth state encoding uses URL-safe alphabet and removes both padding lengths"),
    # A vendor's 429 asked for a window longer than the poll floor; dropping it
    # from the floor leaves a throttled vendor re-asked every two minutes.
    ("vendor-retry-after", QUOTA_MANAGER, " || withinVendorBackoff",
     "QuotaManagerTests/vendorRetryAfterGatesAutomaticPollOnly",
     "a vendor's Retry-After gates the automatic poll, not the user's ⟳"),
    ("failed-attempt-user-floor", QUOTA_MANAGER,
     "lastUserFetchAt: force ? now : previous?.lastUserFetchAt,",
     "QuotaManagerTests/minPollIntervalReArmsDuringOutage",
     "minPollInterval re-arms during an outage instead of re-hitting a failing vendor every cycle",
     "lastUserFetchAt: force && snap.status.confidence == .measured ? now : previous?.lastUserFetchAt,"),
    ("failed-attempt-automatic-floor", QUOTA_MANAGER,
     "                fetchedAt: now,",
     "QuotaManagerTests/minPollIntervalReArmsDuringOutage",
     "minPollInterval re-arms during an outage instead of re-hitting a failing vendor every cycle",
     "                fetchedAt: snap.status.confidence == .measured ? now : (previous?.fetchedAt ?? now),"),
    # Without the timeout's offer only the work can win the race, so a 0.2s
    # deadline waits out 3s of blocking work and returns its success instead.
    ("deadline-preempts", DEADLINE, "        await gate.offer(.failure(.timedOut))\n",
     "DeadlineUncancellableTests/timesOutUncancellableWork",
     "the deadline fires even though the operation ignores cancellation"),
    # `TimeInterval("inf")` parses; an infinite Retry-After parked the poll for
    # good and trapped the remedy's `Int(_:)` conversion.
    ("retry-after-digits", QUOTA_HTTP,
     '        guard text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }\n',
     "ProviderStatusTests/retryAfterDateRejectsNonDelaySeconds",
     "Retry-After accepts only delay-seconds digits, never inf, exponents or signs"),
    ("retry-after-cap", QUOTA_HTTP, "seconds > maximumRetryAfter ? maximumRetryAfter : ",
     "ProviderStatusTests/retryAfterDateClampsToADay",
     "a Retry-After longer than a day holds the automatic poll for a day, not forever"),
    ("gemini-retry-failure", GEMINI, "            return initial\n",
     "ProviderHTTPTests/geminiRetryFailurePreservesInitialSummary",
     "a throwing Gemini project retry preserves the initial summary",
     "            throw error\n"),
    ("gemini-populated-buckets", GEMINI, "(geminiGroup(in: summary)?.buckets?.isEmpty ?? true)",
     "ProviderHTTPTests/geminiPopulatedBucketsSkipProjectRetry",
     "disabled or invalid Gemini buckets do not trigger project discovery", "true"),
    ("tray-elapsed-window", MENU_BAR, "snapshot.quotaBars.compactMap",
     "MenuBarLimitingTests/ignoresUnreadableAndElapsed",
     "stale, unavailable and elapsed windows cannot supply the next limit", "snapshot.bars.compactMap"),
    ("tray-earliest-limit", MENU_BAR, "let projected = pool.filter { $0.limitAt != nil }.min",
     "MenuBarLimitingTests/earliestForecastWins",
     "the earliest projected limit wins over more used and untouched workspaces",
     "let projected = pool.filter { $0.limitAt != nil }.max"),
    ("footer-check-time", QUOTA_MANAGER, "snap.staleReading?.at ?? snap.lastUpdated",
     "SystemHealthSummaryTests/failedPollSeparatesCheckTimeFromReadingAge",
     "a failed poll updates the check time without changing the sixteen-hour-old reading", "snap.lastUpdated"),
    ("forced-refresh-dedup", QUOTA_MANAGER,
     "        // A forced refresh must join too.",
     "QuotaManagerTests/concurrentForcedRefreshesCollapseIntoOneFetch",
     "concurrent forced refreshes share a fetch before the cache floor is written",
     "        if force { activeTask?.cancel(); activeTask = nil }\n        // A forced refresh must join too."),
    ("joined-refresh-followup", QUOTA_MANAGER,
     "if self.forcedPassPending {",
     "QuotaManagerTests/forcedRefreshJoinsAutomaticFetch",
     "a queued manual refresh re-asks a vendor skipped under Retry-After with user intent",
     "if false {"),
    ("queued-ui-refresh", "Sources/QuotaBarUI/Popover/QuotaStore.swift",
     "if !(await manager.queueUserRefreshIfActive()) { forcedRefreshPending = true }",
     "QuotaStoreTests/queuedManualRefreshBypassesVendorBackoff",
     "a queued manual click bypasses the automatic floor and vendor backoff",
     ""),
    ("joined-ui-no-repeat", "Sources/QuotaBarUI/Popover/QuotaStore.swift",
     "if !(await manager.queueUserRefreshIfActive()) { forcedRefreshPending = true }",
     "QuotaStoreTests/overlappingRefreshesCollapse",
     "manual refresh during a successful poll shares its request",
     "forcedRefreshPending = true"),
    ("claude-proxy-backoff", "Sources/QuotaBarCore/Providers/ClaudeQuotaProvider.swift",
     "let until = await proxyBackoff.retryAfter(config: proxyConfig, now: now)",
     "ProviderHTTPTests/claudeProxyCooldownSurvivesDirectSuccess",
     "a direct success retains the proxy throttle across automatic provider rebuilds",
     "let until = Optional<Date>.none"),
    ("claude-refresh-intent", QUOTA_MANAGER,
     "QuotaFetchContext.$isUserInitiated.withValue(force)",
     "ProviderHTTPTests/claudeManagerPropagatesRefreshIntent",
     "manager automatic passes retain proxy backoff while manual refresh can probe it",
     "QuotaFetchContext.$isUserInitiated.withValue(true)"),
    ("claude-proxy-credential-boundary", "Sources/QuotaBarCore/Providers/ClaudeQuotaProvider.swift",
     "              configuration?.managementKey == config.managementKey,\n",
     "ProviderHTTPTests/claudeProxyCooldownConfigurationBoundary",
     "a proxy configuration change does not inherit another proxy's throttle"),
    ("claude-failed-probe", "Sources/QuotaBarCore/Providers/ClaudeQuotaProvider.swift",
     "} else if reason == nil {\n            // Only a success",
     "ProviderHTTPTests/claudeFailedProbeRetainsThrottle",
     "a failed manual proxy probe preserves the earlier throttle",
     "} else {\n            // Only a success"),
    ("claude-direct-backoff", "Sources/QuotaBarCore/Providers/ClaudeQuotaProvider.swift",
     "let until = await proxyBackoff.directRetryAfter(token: token, now: now)",
     "ProviderHTTPTests/claudeDirectCooldownIndependentOfProxy",
     "a direct throttle survives an earlier proxy retry deadline",
     "let until = Optional<Date>.none"),
    ("monthly-grant-amount", "Sources/QuotaBarCore/Models/ClaudeMonthlyCredit.swift",
     "Self(amountUSD: amount,",
     "ClaudeMonthlyCreditTests/publishedGrant",
     "monthly grant preserves entitlement and next date without inventing a balance",
     "Self(amountUSD: 0,"),
    ("monthly-grant-eligibility", "Sources/QuotaBarCore/Models/ClaudeMonthlyCredit.swift",
     'payload.status == "linked",',
     "ClaudeMonthlyCreditTests/absentGrant",
     "absent, unlinked, ended or invalid monthly grants yield no entitlement",
     "true,"),
    ("monthly-grant-placement", "Sources/QuotaBarUI/Popover/MetricRowPresentation.swift",
     "self.monthlyCreditLine = snapshot.monthlyAPICredit?.line",
     "SubscriptionCreditPlacementTests/monthlyEntitlementPlacement",
     "Claude monthly entitlement is a separate line with no balance or quota",
     "self.monthlyCreditLine = nil"),
    ("monthly-read-generation", "Sources/QuotaBarCore/Providers/ClaudeMonthlyCreditSession.swift",
     "self.generation == generation, self.query == query",
     "ClaudeMonthlyCreditTests/connectionGenerationRejectsOldRead",
     "reconnecting rejects an old monthly read even for the same query",
     "self.query == query"),
    ("monthly-read-failure", "Sources/QuotaBarCore/Providers/ClaudeMonthlyCreditSession.swift",
     'body["_retryAfter"] == nil, body["_failed"] == nil',
     "ClaudeMonthlyCreditTests/failedReadMarksMonthlyCreditStale",
     "failed billing reads retain a stale entitlement and keep Retry-After",
     'body["_retryAfter"] == nil || body["_failed"] == nil'),
    ("monthly-stale-only-on-failure", "Sources/QuotaBarCore/Models/ClaudeMonthlyCredit.swift",
     "if refreshFailed {",
     "ClaudeMonthlyCreditTests/publishedGrant",
     "monthly grant preserves entitlement and next date without inventing a balance",
     "if !refreshFailed {"),
    ("monthly-fractional-date", "Sources/QuotaBarCore/Models/ClaudeMonthlyCredit.swift",
     "fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)",
     "ClaudeMonthlyCreditTests/fractionalGrantDate",
     "fractional grant timestamps preserve the next credit date",
     "ISO8601DateFormatter().date(from: text)"),
    ("monthly-cycle-attach", QUOTA_MANAGER,
     "            rebuilt.monthlyAPICredit = updated.monthlyAPICredit\n",
     "QuotaManagerTests/monthlyCreditSurvivesCycleRebuilds",
     "cycle attachment and removal preserve monthly entitlements"),
    ("monthly-cycle-remove", QUOTA_MANAGER,
     "        rebuilt.apiCredits = updated.apiCredits\n        rebuilt.monthlyAPICredit = updated.monthlyAPICredit",
     "QuotaManagerTests/monthlyCreditSurvivesCycleRebuilds",
     "cycle attachment and removal preserve monthly entitlements",
     "        rebuilt.apiCredits = updated.apiCredits"),
    ("monthly-provider-deadline", QUOTA_MANAGER,
     "                snap.monthlyAPICredit = cache[id]?.snapshot.monthlyAPICredit\n",
     "QuotaManagerTests/monthlyCreditSurvivesProviderDeadline",
     "a whole-provider timeout retains the monthly entitlement as stale"),
    ("joined-refresh-no-repeat", QUOTA_MANAGER,
     "excluding: satisfied",
     "QuotaManagerTests/queuedManualRefreshExcludesSuccessfulReadWithoutFloor",
     "a queued manual refresh excludes successful automatic reads even with no poll floor",
     "excluding: []"),
    ("monthly-read-timeout", "Sources/QuotaBarCore/Providers/ClaudeMonthlyCreditSession.swift",
     "try await waitForTimeout(); self.finish(nil)",
     "ClaudeMonthlyCreditTests/webReadIsBounded",
     "a missing WebKit callback reaches the injected timeout and rejects late results",
     "try await waitForTimeout()"),
    ("monthly-read-cancellation", "Sources/QuotaBarCore/Providers/ClaudeMonthlyCreditSession.swift",
     "Task { @MainActor in self.finish(nil) }",
     "ClaudeMonthlyCreditTests/webReadCancellation",
     "cancelling a pending WebKit read releases its caller",
     ""),
    ("monthly-quota-retention", QUOTA_MANAGER,
     "                retained.monthlyAPICredit = snap.monthlyAPICredit\n",
     "QuotaManagerTests/monthlyCreditFreshnessIsIndependentOfQuotaFailure",
     "quota retention replaces monthly credit with its independent read outcome"),
    ("monthly-quota-transport", "Sources/QuotaBarCore/Providers/ClaudeQuotaProvider.swift",
     "snapshot.monthlyAPICredit = await credit",
     "ProviderHTTPTests/claudeMonthlyCreditSurvivesQuotaTransportFailure",
     "a quota transport failure preserves an independently read monthly entitlement",
     "_ = await credit"),
    ("monthly-spoken-label", "Sources/QuotaBarUI/Popover/MetricRowPresentation.swift",
     "        if let monthlyCreditLine {\n            parts.append(monthlyCreditLine)\n            if let monthlyCreditDetail { parts.append(monthlyCreditDetail) }\n        }\n",
     "SubscriptionCreditPlacementTests/monthlyCreditSpokenLabel",
     "the row speaks monthly allowance, next credit and failed refresh state"),
    ("monthly-disconnect-cache", QUOTA_MANAGER,
     "            snapshot.monthlyAPICredit = nil\n",
     "QuotaManagerTests/disconnectClearsCachedMonthlyCredit",
     "disconnect clears a fresh cached monthly credit without polling quota"),
    ("monthly-disconnect-pending", QUOTA_MANAGER,
     "            if !acceptsMonthlyCredit { snap.monthlyAPICredit = nil }\n",
     "QuotaManagerTests/disconnectRejectsPendingMonthlyCredit",
     "disconnect rejects pending monthly results and deadline carry-forward"),
    ("monthly-disconnect-generation", QUOTA_MANAGER,
     "creditConnection == currentCreditConnection",
     "QuotaManagerTests/disconnectRejectsPendingMonthlyCredit",
     "disconnect rejects pending monthly results and deadline carry-forward",
     "currentCreditConnection != nil"),
    ("monthly-disconnect-invalidation", QUOTA_MANAGER,
     "creditInvalidation == monthlyCreditInvalidation",
     "QuotaManagerTests/disconnectRejectsPendingMonthlyCredit",
     "disconnect rejects pending monthly results and deadline carry-forward",
     "creditInvalidation <= monthlyCreditInvalidation"),
    ("monthly-reopen-connection", "Sources/QuotaBarCore/Providers/ClaudeMonthlyCreditSession.swift",
     "if !alreadyEnabled { reset() }",
     "ClaudeMonthlyCreditTests/reopeningPreservesConnection",
     "opening an enabled billing connection preserves its reading and query",
     "reset()"),
    ("subscription-credit-placement", "Sources/QuotaBarCore/Models/APICreditEntry.swift",
     'vendorId == .openai && id == "openai.api-credits"',
     "SubscriptionCreditPlacementTests/creditsBelongToSubscription",
     "Codex usage credits stay with the plan and leave its quota figures unchanged", "false"),
]


def run_test(name, phase, selector, display):
    proc = subprocess.run(
        ["swift", "test", "-c", "debug", "--filter", selector],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180,
    )
    (LOGS / f"{name}-{phase}.log").write_text(proc.stdout)
    expected = "failed" if phase == "mutant" else "passed"
    if not re.search(rf"Test run with 1 test(?: in \d+ suites?)? {expected}", proc.stdout) or display not in proc.stdout:
        raise RuntimeError(f"{name}/{phase}: expected exactly one named test to {expected}; see log")
    if (proc.returncode != 0) != (phase == "mutant"):
        raise RuntimeError(f"{name}/{phase}: unexpected test exit status {proc.returncode}")
    if phase == "mutant" and "recorded an issue" not in proc.stdout:
        raise RuntimeError(f"{name}: process failure is not an assertion failure")


def partition_cases(cases, shard_index=0, shard_count=1):
    """Assign each case once, rejecting configurations with empty shards."""
    if not 1 <= shard_count <= len(cases):
        raise ValueError(f"shard count must be between 1 and {len(cases)}")
    if not 0 <= shard_index < shard_count:
        raise ValueError("shard index must be nonnegative and less than shard count")
    return cases[shard_index::shard_count]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard-index", type=int, default=0, help="zero-based shard index (default: 0)")
    parser.add_argument("--shard-count", type=int, default=1, help="number of nonempty shards (default: 1)")
    parser.add_argument("--list", action="store_true", help="list selected case names without launching Swift or editing files")
    args = parser.parse_args(argv)
    try:
        cases = partition_cases(CASES, args.shard_index, args.shard_count)
    except ValueError as error:
        parser.error(str(error))
    if args.list:
        print("\n".join(case[0] for case in cases))
        return
    if subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "Sources", "Tests"], cwd=ROOT).strip():
        raise RuntimeError("Refusing to mutate a checkout with source/test edits")
    LOGS.mkdir(parents=True, exist_ok=True)
    for name, relative, needle, selector, display, *replacement in cases:
        source = ROOT / relative
        original = source.read_bytes()
        text = original.decode()
        if text.count(needle) != 1:
            raise RuntimeError(f"{name}: mutation target is not unique")
        run_test(name, "baseline", selector, display)
        try:
            source.write_text(text.replace(needle, replacement[0] if replacement else "", 1))
            run_test(name, "mutant", selector, display)
        finally:
            source.write_bytes(original)
        run_test(name, "restored", selector, display)
        print(f"PROVED {name}: baseline passed, mutant assertion failed, restored passed", flush=True)
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", "Sources", "Tests"], cwd=ROOT, check=True)
    print(f"All {len(cases)} selected independent mutations rejected; production sources restored.")


if __name__ == "__main__":
    main()
