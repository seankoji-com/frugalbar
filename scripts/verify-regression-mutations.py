#!/usr/bin/env python3
"""Prove each scheduler/OAuth regression test rejects its defect, then restore.

Run only in a clean disposable checkout. Every edit is reverted in a finally
block, and a passing control run follows every rejected mutation. A compiler
failure or a filter that selects zero tests never counts as proof.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "coverage" / "mutations"
SCHEDULER = "Sources/QuotaBarCore/Engine/BackgroundScheduler.swift"
OAUTH = "Sources/QuotaBarCore/Providers/GeminiOAuthLogin.swift"
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
]


def run_test(name, phase, selector, display):
    proc = subprocess.run(
        ["swift", "test", "-c", "debug", "--filter", selector],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180,
    )
    (LOGS / f"{name}-{phase}.log").write_text(proc.stdout)
    expected = "failed" if phase == "mutant" else "passed"
    if not re.search(rf"Test run with 1 test {expected}", proc.stdout) or display not in proc.stdout:
        raise RuntimeError(f"{name}/{phase}: expected exactly one named test to {expected}; see log")
    if (proc.returncode != 0) != (phase == "mutant"):
        raise RuntimeError(f"{name}/{phase}: unexpected test exit status {proc.returncode}")
    if phase == "mutant" and "recorded an issue" not in proc.stdout:
        raise RuntimeError(f"{name}: process failure is not an assertion failure")


def main():
    if subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "Sources", "Tests"], cwd=ROOT).strip():
        raise RuntimeError("Refusing to mutate a checkout with source/test edits")
    LOGS.mkdir(parents=True, exist_ok=True)
    for name, relative, needle, selector, display in CASES:
        source = ROOT / relative
        original = source.read_bytes()
        text = original.decode()
        if text.count(needle) != 1:
            raise RuntimeError(f"{name}: mutation target is not unique")
        run_test(name, "baseline", selector, display)
        try:
            source.write_text(text.replace(needle, "", 1))
            run_test(name, "mutant", selector, display)
        finally:
            source.write_bytes(original)
        run_test(name, "restored", selector, display)
        print(f"PROVED {name}: baseline passed, mutant assertion failed, restored passed", flush=True)
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", "Sources", "Tests"], cwd=ROOT, check=True)
    print("All six independent mutations rejected; production sources restored.")


if __name__ == "__main__":
    main()
