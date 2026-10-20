#!/usr/bin/env python3
"""Prove the Gemini regression against the original provider and focused defects.

Run in a clean disposable macOS checkout with the original revision available.
Every mutant must compile and fail the named behavioural assertion. Sources are
restored in finally, followed by a passing control. No real credentials are read.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "Sources/QuotaBarCore/Providers/GeminiQuotaProvider.swift"
ORIGINAL_REVISION = "3cdfedfcb3bd6b9fe00f2d02c9291dc01a33ba2b"
LOGS = ROOT / "coverage" / "gemini-mutations"
SELECTOR = "ProviderHTTPTests/geminiScopesPopulatedSummary"
DISPLAY = "Gemini scopes a populated summary before reporting the screenshot's exhausted weekly quota"
# Include context unique to the quota-response branch, leaving project-lookup
# rejection intact so it cannot mask either scoped-response regression.
SCOPED_REJECTION = """                        // — so a re-sign-in would not even take effect at once.
                        transportFailure = nil
                        break"""


# This roster is written before setup, so an early failure cannot masquerade
# as a smaller, complete proof. Consumers must require is_complete(manifest).
EXPECTED_CASES = [
    "original-provider", "project-body", "disabled-bucket", "remaining-inversion",
    "scoped-transport", "original-provider-lower-usage",
    "scoped-rejection-continues", "scoped-rejection-keeps-timeout",
    "unbounded-project", "unbounded-quota",
    "cancelled-request-starts", "cancelled-quota-accepted",
]


def unbounded_request(text):
    mutant = replace_once(
        text,
        "        let outcome = await withDeadline(seconds: GeminiRequestBudget.seconds) {",
        "        let outcome: DeadlineOutcome<Result<(Data, HTTPURLResponse), any Error>> = .success(await {",
    )
    return replace_once(
        mutant.decode(),
        "        }\n        // withDeadline cancels its request task on expiry.",
        "        }())\n        // withDeadline cancels its request task on expiry.",
    )


def mutations(text, original):
    return [
        ("original-provider", original, SELECTOR, DISPLAY),
        ("project-body", replace_once(text, 'let body = try JSONEncoder().encode(["project": project])',
                                      'let body = Data("{}".utf8)'), SELECTOR, DISPLAY),
        ("disabled-bucket", replace_once(text, "        guard bucket.disabled != true else { return nil }\n", ""), SELECTOR, DISPLAY),
        ("remaining-inversion", replace_once(text, "let used = 1 - remaining", "let used = remaining"), SELECTOR, DISPLAY),
        ("scoped-transport", replace_once(text, "                transportFailure = error\n", "                transportFailure = nil\n"),
         "ProviderHTTPTests/geminiScopedTransportFailureIsRethrown",
         "Gemini preserves scoped quota transport failures for the engine"),
        ("original-provider-lower-usage", original,
         "ProviderHTTPTests/geminiScopedQuotaIsNotMaximumAcrossPools",
         "Gemini uses the scoped quota even when an unscoped or other-host pool is more consumed"),
        ("scoped-rejection-continues", replace_once(text, SCOPED_REJECTION,
                                                   SCOPED_REJECTION.replace("break", "continue")),
         "ProviderHTTPTests/geminiScopedRejectionEndsHostWalk",
         "Gemini scoped quota credential rejection ends the default host walk"),
        ("scoped-rejection-keeps-timeout", replace_once(text, SCOPED_REJECTION,
                                                       SCOPED_REJECTION.replace("                        transportFailure = nil\n", "")),
         "ProviderHTTPTests/geminiScopedRejectionOutranksStaleTransportFailure",
         "Gemini scoped quota credential rejection clears an earlier host timeout"),
        ("unbounded-project", unbounded_request(text),
         "ProviderHTTPTests/geminiBoundsProjectLookup",
         "Gemini bounds project lookup so the alternate host can answer"),
        ("unbounded-quota", unbounded_request(text),
         "ProviderHTTPTests/geminiBoundsScopedQuota",
         "Gemini bounds scoped quota so the alternate host can answer"),
        ("cancelled-request-starts", replace_once(text,
            "        try Task.checkCancellation()\n        // Preserve the original transport error",
            "        // Preserve the original transport error"),
         "ProviderHTTPTests/geminiCancellationBeforeRequest",
         "Gemini cancellation before fetching starts no HTTP request"),
        ("cancelled-quota-accepted", replace_once(text,
            "        try Task.checkCancellation()\n        switch outcome {",
            "        switch outcome {"),
         "ProviderHTTPTests/geminiCancellationRejectsLateQuota",
         "Gemini cancellation rejects a late scoped quota reading"),
    ]


def load_proof():
    spec = importlib.util.spec_from_file_location("proof", ROOT / "scripts/verify-regression-mutations.py")
    proof = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proof)
    proof.LOGS = LOGS
    return proof


def is_complete(manifest):
    return (
        manifest.get("status") == "succeeded"
        and manifest.get("expected_cases") == EXPECTED_CASES
        and [case["name"] for case in manifest.get("cases", [])] == EXPECTED_CASES
        and manifest.get("restoration", {}).get("status") == "restored"
        and manifest["restoration"].get("sha256") == manifest.get("fixed_provider_sha256")
        and all(
            case.get("status") == "succeeded"
            and [phase.get("phase") for phase in case["phases"]] == ["baseline", "mutant", "restored"]
            and [phase.get("exit_code") for phase in case["phases"]] == [0, 1, 0]
            and all(phase.get("status") == "succeeded" for phase in case["phases"])
            for case in manifest["cases"]
        )
    )


def main():
    LOGS.mkdir(parents=True, exist_ok=True)
    manifest = {
        "status": "incomplete", "expected_cases": EXPECTED_CASES,
        "original_revision": ORIGINAL_REVISION, "cases": [],
        "restoration": {"status": "not_needed"},
    }
    manifest_path = LOGS / "manifest.json"

    def checkpoint():
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    # Invalidate a prior successful run before *any* setup which can fail.
    checkpoint()
    source = ROOT / SOURCE
    fixed = None
    touched = False
    try:
        # Only this invocation's logs may be claimed in its manifest.
        for log in LOGS.glob("*.log"):
            log.unlink()
        if subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "Sources", "Tests"], cwd=ROOT).strip():
            raise RuntimeError("Refusing to mutate a checkout with source/test edits")
        manifest["head"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        fixed = source.read_bytes()
        original = subprocess.check_output(["git", "show", f"{ORIGINAL_REVISION}:{SOURCE}"], cwd=ROOT)
        manifest["original_provider_sha256"] = hashlib.sha256(original).hexdigest()
        manifest["fixed_provider_sha256"] = hashlib.sha256(fixed).hexdigest()
        proof = load_proof()
        selected = mutations(fixed.decode(), original)
        if [case[0] for case in selected] != EXPECTED_CASES:
            raise RuntimeError("Mutation roster differs from expected_cases")
        for name, mutant, selector, display in selected:
            case = {"name": name, "selector": selector, "mutant_sha256": hashlib.sha256(mutant).hexdigest(),
                    "status": "incomplete", "phases": []}
            manifest["cases"].append(case)
            for phase, contents in [("baseline", fixed), ("mutant", mutant), ("restored", fixed)]:
                entry = {"phase": phase, "status": "incomplete"}
                case["phases"].append(entry)
                manifest["restoration"] = {"status": "pending"}
                checkpoint()
                touched = True
                source.write_bytes(contents)
                result = proof.run_test(name, phase, selector, display)
                entry.update(result, status="succeeded")
                checkpoint()
            case["status"] = "succeeded"
            print(f"PROVED {name}: baseline passed, mutant assertion failed, restored passed", flush=True)
        subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", "Sources", "Tests"], cwd=ROOT, check=True)
        manifest["status"] = "succeeded"
    except BaseException as error:
        manifest.update(status="failed", error=f"{type(error).__name__}: {error}")
        raise
    finally:
        try:
            if touched:
                source.write_bytes(fixed)
                restored = source.read_bytes()
                if restored != fixed:
                    raise RuntimeError("Source restoration did not match fixed provider")
                manifest["restoration"] = {"status": "restored", "sha256": hashlib.sha256(restored).hexdigest()}
        except BaseException as error:
            manifest.update(status="failed", error=f"{type(error).__name__}: {error}")
            manifest["restoration"] = {"status": "failed"}
            raise
        finally:
            # A consistency failure is not a restoration failure. Preserve the
            # independently verified restoration outcome for forensic use.
            incomplete = manifest["status"] == "succeeded" and not is_complete(manifest)
            if incomplete:
                manifest.update(status="failed", error="Proof did not complete the expected case/phase roster")
            manifest["logs"] = [
                {"path": p.name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                for p in sorted(LOGS.glob("*.log"))
            ]
            checkpoint()
            if incomplete:
                raise RuntimeError(manifest["error"])


def replace_once(text, needle, replacement):
    if text.count(needle) != 1:
        raise RuntimeError(f"Mutation target is not unique: {needle}")
    return text.replace(needle, replacement, 1).encode()


if __name__ == "__main__":
    main()
