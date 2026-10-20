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


def main():
    if subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "Sources", "Tests"], cwd=ROOT).strip():
        raise RuntimeError("Refusing to mutate a checkout with source/test edits")
    spec = importlib.util.spec_from_file_location("proof", ROOT / "scripts/verify-regression-mutations.py")
    proof = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proof)
    proof.LOGS = LOGS
    LOGS.mkdir(parents=True, exist_ok=True)
    source = ROOT / SOURCE
    fixed = source.read_bytes()
    original = subprocess.check_output(["git", "show", f"{ORIGINAL_REVISION}:{SOURCE}"], cwd=ROOT)
    text = fixed.decode()
    mutations = [
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
    ]
    manifest = {
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "original_revision": ORIGINAL_REVISION,
        "original_provider_sha256": hashlib.sha256(original).hexdigest(),
        "fixed_provider_sha256": hashlib.sha256(fixed).hexdigest(),
        "cases": [],
    }
    try:
        for name, mutant, selector, display in mutations:
            case = {"name": name, "selector": selector, "mutant_sha256": hashlib.sha256(mutant).hexdigest(), "phases": []}
            manifest["cases"].append(case)
            try:
                for phase, contents in [("baseline", fixed), ("mutant", mutant), ("restored", fixed)]:
                    source.write_bytes(contents)
                    result = proof.run_test(name, phase, selector, display)
                    case["phases"].append({"phase": phase, **result})
            finally:
                source.write_bytes(fixed)
            print(f"PROVED {name}: baseline passed, mutant assertion failed, restored passed", flush=True)
        subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", "Sources", "Tests"], cwd=ROOT, check=True)
    finally:
        source.write_bytes(fixed)
        manifest["logs"] = [
            {"path": p.name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted(LOGS.glob("*.log"))
        ]
        (LOGS / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def replace_once(text, needle, replacement):
    if text.count(needle) != 1:
        raise RuntimeError(f"Mutation target is not unique: {needle}")
    return text.replace(needle, replacement, 1).encode()


if __name__ == "__main__":
    main()
