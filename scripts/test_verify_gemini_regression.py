"""Exercise proof bookkeeping offline. These tests never substitute Swift proof."""
from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("verify-gemini-regression.py")
spec = importlib.util.spec_from_file_location("gemini_proof", SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
REAL_ROOT = SCRIPT.resolve().parents[1]


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gemini-proof-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.source = self.root / verifier.SOURCE
        self.source.parent.mkdir(parents=True)
        self.fixed = (REAL_ROOT / verifier.SOURCE).read_bytes()
        self.source.write_bytes(self.fixed)
        self.failure = None
        self.dirty = False
        self.original_missing = False
        self.calls = []
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for name, value in [("ROOT", self.root), ("LOGS", self.logs)]:
            self.stack.enter_context(patch.object(verifier, name, value))
        # Patch the module loader as well as processes so the previous harness
        # can run these failure tests unchanged in a disposable copy.
        proof = SimpleNamespace(run_test=self.run_test)
        self.stack.enter_context(patch.object(verifier.importlib.util, "spec_from_file_location",
            return_value=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))))
        self.stack.enter_context(patch.object(verifier.importlib.util, "module_from_spec", return_value=proof))
        self.stack.enter_context(patch.object(verifier.subprocess, "check_output", side_effect=self.git_output))
        self.git_guard = self.stack.enter_context(patch.object(verifier.subprocess, "run"))

    def git_output(self, argv, **kwargs):
        if argv[1] == "diff":
            return b"Sources/dirty.swift\n" if self.dirty else b""
        if argv[1] == "show":
            if self.original_missing:
                raise subprocess.CalledProcessError(128, argv, output=b"missing original")
            return b"original provider fixture"
        return "f" * 40

    def run_test(self, name, phase, selector, display):
        self.calls.append((name, phase))
        (self.logs / f"{name}-{phase}.log").write_text(f"offline injection {name}/{phase}\n")
        if self.failure == (name, phase):
            raise RuntimeError(f"injected {name}/{phase} failure")
        return {"argv": ["swift", "test", "--filter", selector], "cwd": str(self.root),
                "exit_code": 1 if phase == "mutant" else 0}

    def manifest(self):
        return json.loads((self.logs / "manifest.json").read_text())

    def run_main(self):
        with redirect_stdout(io.StringIO()):
            verifier.main()

    def assert_failed(self, message, restored):
        manifest = self.manifest()
        self.assertEqual(manifest.get("status"), "failed")
        self.assertIn(message, manifest.get("error", ""))
        self.assertEqual(manifest.get("expected_cases"), verifier.EXPECTED_CASES)
        self.assertEqual(manifest["restoration"]["status"], restored)
        self.assertEqual(self.source.read_bytes(), self.fixed)
        self.assertFalse(verifier.is_complete(manifest))

    def test_success_requires_entire_roster_and_three_phases(self):
        self.run_main()
        manifest = self.manifest()
        self.assertTrue(verifier.is_complete(manifest))
        self.assertEqual(len(self.calls), 3 * len(verifier.EXPECTED_CASES))
        for field in ["status", "expected_cases", "restoration"]:
            damaged = dict(manifest)
            damaged.pop(field)
            self.assertFalse(verifier.is_complete(damaged))
        for damage in [lambda m: m["cases"].pop(),
                       lambda m: m["cases"][0]["phases"].pop(),
                       lambda m: m["cases"][0]["phases"][1].update(exit_code=0),
                       lambda m: m["cases"][0]["phases"][1].update(status="incomplete"),
                       lambda m: m["restoration"].update(sha256="wrong")]:
            damaged = json.loads(json.dumps(manifest))
            damage(damaged)
            self.assertFalse(verifier.is_complete(damaged))

    def test_failures_in_baseline_mutant_and_restored_are_not_complete(self):
        for phase in ["baseline", "mutant", "restored"]:
            with self.subTest(phase=phase):
                self.failure = ("project-body", phase)
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    self.run_main()
                self.assert_failed(f"project-body/{phase}", "restored")
                manifest = self.manifest()
                self.assertEqual(manifest["cases"][0]["status"], "succeeded")
                self.assertEqual(manifest["cases"][-1]["phases"][-1]["status"], "incomplete")

    def test_dirty_checkout_invalidates_stale_success_without_writing_source(self):
        self.run_main()
        self.source.write_bytes(b"unrelated source edit")
        self.fixed = b"unrelated source edit"
        (self.logs / "stale.log").write_text("old proof")
        self.dirty = True
        with self.assertRaisesRegex(RuntimeError, "source/test edits"):
            self.run_main()
        self.assert_failed("source/test edits", "not_needed")
        self.assertEqual(self.manifest()["logs"], [])
        self.assertEqual(self.manifest()["cases"], [])

    def test_missing_original_is_an_explicit_setup_failure(self):
        self.original_missing = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_main()
        self.assert_failed("CalledProcessError", "not_needed")
        self.assertEqual(self.manifest()["cases"], [])
        self.assertEqual(self.calls, [])

    def test_bad_mutation_target_is_an_explicit_preloop_failure(self):
        self.fixed = self.fixed.replace(b"let used = 1 - remaining", b"let used = remaining")
        self.source.write_bytes(self.fixed)
        with self.assertRaisesRegex(RuntimeError, "not unique"):
            self.run_main()
        self.assert_failed("not unique", "not_needed")
        self.assertEqual(self.calls, [])

    def test_final_diff_failure_retains_logs_and_is_not_complete(self):
        self.git_guard.side_effect = subprocess.CalledProcessError(1, ["git", "diff"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_main()
        self.assert_failed("CalledProcessError", "restored")
        self.assertEqual(len(self.manifest()["logs"]), len(verifier.EXPECTED_CASES) * 3)

    def test_interruption_records_failure_and_restores_source(self):
        original = self.run_test

        def interrupt(name, phase, *args):
            result = original(name, phase, *args)
            if phase == "mutant":
                raise KeyboardInterrupt("injected interrupt")
            return result

        self.run_test = interrupt
        # The loader captures the bound callable during setUp.
        verifier.importlib.util.module_from_spec.return_value.run_test = interrupt
        with self.assertRaises(KeyboardInterrupt):
            self.run_main()
        self.assert_failed("KeyboardInterrupt", "restored")

    def test_progress_is_incomplete_while_mutant_runs(self):
        original = self.run_test

        def observe(name, phase, *args):
            if phase == "mutant":
                manifest = self.manifest()
                self.assertEqual(manifest["status"], "incomplete")
                self.assertEqual(manifest["restoration"]["status"], "pending")
                self.assertFalse(verifier.is_complete(manifest))
            return original(name, phase, *args)

        verifier.importlib.util.module_from_spec.return_value.run_test = observe
        self.run_main()

    def test_restoration_failure_is_explicit_and_process_still_fails(self):
        original = Path.write_bytes

        def fail_restore(path, contents):
            if path == self.source and contents == self.fixed and self.calls and self.calls[-1][1] == "mutant":
                raise OSError("injected restoration failure")
            return original(path, contents)

        self.failure = ("original-provider", "mutant")
        with patch.object(Path, "write_bytes", fail_restore):
            with self.assertRaisesRegex(OSError, "restoration failure"):
                self.run_main()
        manifest = self.manifest()
        self.assertEqual(manifest["status"], "failed")
        self.assertEqual(manifest["restoration"]["status"], "failed")
        self.assertIn("restoration failure", manifest["error"])
        self.assertFalse(verifier.is_complete(manifest))
        self.assertNotEqual(self.source.read_bytes(), self.fixed)


if __name__ == "__main__":
    unittest.main()
