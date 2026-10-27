"""Profiling must preserve compilation and disclose failures and artifact limits."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("codeql_profile", Path(__file__).with_name("codeql-profile.py"))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileTests(unittest.TestCase):
    def test_instruments_each_parallel_batch_and_merge_with_distinct_outputs(self):
        batches = [{"module": f"Core_part_{n}", "sources": [str(n)], "argv": ["swift-frontend", str(n)]}
                   for n in range(3)]
        prepared = {"commands": [{"module": "Core", "sources": ["0", "1", "2"],
                                 "batches": batches, "argv": ["swift-frontend", "-merge-modules"]}]}
        with tempfile.TemporaryDirectory() as directory:
            measured = profile.instrument(prepared, Path(directory))["commands"][0]
            steps = [*measured["batches"], measured]
            originals = [*batches, prepared["commands"][0]]
            self.assertEqual(len({step["argv"][3] for step in steps}), 4)
            for step, original in zip(steps, originals):
                self.assertEqual(step["argv"][0], "/usr/bin/time")
                self.assertEqual(step["argv"][4:-3], original["argv"])
                self.assertEqual(step["sources"], original["sources"])
            self.assertEqual(len(list(Path(directory).glob("*-stats"))), 4)

    def test_instrumentation_preserves_full_ordered_commands(self):
        prepared = {"root": "/repo", "commands": [
            {"module": name, "sources": [f"Sources/{name}.swift"], "argv": [
                "swift-frontend", "-frontend", "-emit-module", f"Sources/{name}.swift",
                "-module-cache-path", "same-cache", "-o", f"{name}.swiftmodule"]}
            for name in ["Core", "UI", "App"]]}
        with tempfile.TemporaryDirectory() as directory:
            measured = profile.instrument(prepared, Path(directory))
            self.assertEqual(measured["root"], prepared["root"])
            self.assertEqual([c["module"] for c in measured["commands"]], ["Core", "UI", "App"])
            for original, instrumented in zip(prepared["commands"], measured["commands"]):
                argv = instrumented["argv"]
                self.assertEqual(argv[:4], ["/usr/bin/time", "-l", "-o", str(Path(directory) / f'{original["module"]}-time.txt')])
                self.assertEqual(argv[4:-3], original["argv"])
                self.assertEqual(argv[-3::2], ["-stats-output-dir", "-Rmodule-interface-rebuild"])
                self.assertEqual(instrumented["sources"], original["sources"])

    def test_failed_compilation_is_returned_and_receipted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan = root / "plan.json"
            plan.write_text(json.dumps({"root": str(root), "commands": []}))
            with patch.object(profile.subprocess, "run", return_value=subprocess.CompletedProcess([], 37)) as run:
                self.assertEqual(profile.run_phase(plan, root, "traced"), 37)
            self.assertIn("compile", run.call_args.args[0])
            result = json.loads((root / "traced" / "result.json").read_text())
            self.assertEqual(result["exit_code"], 37)
            self.assertIn("different extraction compiler", result["comparison_limits"])
            # Reusing a destination cannot overwrite the earlier evidence.
            with self.assertRaises(FileExistsError):
                profile.run_phase(plan, root, "traced")

    def test_process_samples_exclude_other_jobs_and_other_users(self):
        uid = os.getuid()
        rows = f"10 1 {uid} shell\n11 10 {uid} python\n12 11 {uid} frontend\n13 12 {uid + 1} foreign\n99 1 {uid} unrelated\n"
        self.assertEqual([p["pid"] for p in profile.owned_tree(10, rows)], [10, 11, 12])

    def test_sample_denial_is_retained_without_retry_or_signals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "trace-root").write_text("10")
            def finish(_):
                (root / "trace-done").touch()
            with patch.object(profile.subprocess, "check_output", return_value=f"10 1 {os.getuid()} shell"), \
                 patch.object(profile.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "permission denied")) as sample, \
                 patch.object(profile.time, "sleep", side_effect=finish):
                profile.monitor(root)
            self.assertEqual(sample.call_count, 1)
            self.assertEqual(sample.call_args.args[0][1], "10")
            self.assertIn("permission denied", (root / "processes.jsonl").read_text())
            self.assertFalse(json.loads((root / "monitor-result.json").read_text())["sample_allowed"])

    def test_pack_bounds_bytes_and_discloses_unfiltered_error_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = root / "raw"
            raw.mkdir()
            (raw / "compiler.log").write_bytes(b"ERRO compiler\n" * 20)
            (raw / "link").symlink_to(raw / "compiler.log")
            profile.pack(raw, root / "db", root / "upload", limit=17)
            manifest = json.loads((root / "upload" / "files.json").read_text())
            self.assertEqual(len(manifest["files"]), 1)
            record = manifest["files"][0]
            self.assertTrue(record["truncated"])
            self.assertEqual(record["retained_bytes"], 17)
            self.assertEqual((root / "upload/profile/compiler.log").read_bytes(), b"ERRO compiler\nERR")


if __name__ == "__main__":
    unittest.main()
