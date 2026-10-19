"""Verify mutation selection offline, without substituting Swift results."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "verify_regression_mutations", Path(__file__).with_name("verify-regression-mutations.py")
)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class PartitionTests(unittest.TestCase):
    def test_two_shards_cover_all_48_cases_once(self):
        cases = verifier.CASES
        self.assertEqual(len(cases), 48)
        self.assertEqual(len({case[0] for case in cases}), 48)
        shards = [verifier.partition_cases(cases, index, 2) for index in range(2)]
        self.assertEqual([len(shard) for shard in shards], [24, 24])
        names = [case[0] for shard in shards for case in shard]
        self.assertCountEqual(names, [case[0] for case in cases])
        self.assertEqual(len(names), len(set(names)))

    def test_default_preserves_full_inventory_and_order(self):
        self.assertEqual(verifier.partition_cases(verifier.CASES), verifier.CASES)

    def test_every_supported_count_has_nonempty_complete_partition(self):
        for count in range(1, len(verifier.CASES) + 1):
            with self.subTest(count=count):
                shards = [verifier.partition_cases(verifier.CASES, index, count) for index in range(count)]
                self.assertTrue(all(shards))
                self.assertCountEqual(
                    [case for shard in shards for case in shard], verifier.CASES
                )

    def test_invalid_arguments_fail_before_any_process_launch(self):
        invalid = [
            ["--shard-count", "0"], ["--shard-count", "-1"],
            ["--shard-count", "49"], ["--shard-index", "-1"],
            ["--shard-index", "2", "--shard-count", "2"],
            ["--shard-index", "1"], ["--shard-count", "two"],
            ["--shard-index", "0.5"],
        ]
        with patch.object(verifier.subprocess, "run") as run, patch.object(
            verifier.subprocess, "check_output"
        ) as check_output:
            for args in invalid:
                with self.subTest(args=args), redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        verifier.main(args)
                    self.assertEqual(error.exception.code, 2)
            run.assert_not_called()
            check_output.assert_not_called()

    def test_list_reports_exact_selection_without_processes_or_writes(self):
        for index, count in [(0, 1), (0, 2), (1, 2)]:
            with self.subTest(index=index, count=count), patch.object(
                verifier.subprocess, "run"
            ) as run, patch.object(verifier.subprocess, "check_output") as check_output, patch.object(
                verifier.Path, "mkdir"
            ) as mkdir, redirect_stdout(io.StringIO()) as output:
                verifier.main(["--list", "--shard-index", str(index), "--shard-count", str(count)])
                self.assertEqual(output.getvalue().splitlines(), [
                    case[0] for case in verifier.partition_cases(verifier.CASES, index, count)
                ])
                run.assert_not_called()
                check_output.assert_not_called()
                mkdir.assert_not_called()


if __name__ == "__main__":
    unittest.main()
