"""The XML must preserve LLVM's measured line identities and counts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("export_swift_coverage", Path(__file__).with_name("export-swift-coverage.py"))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ExportTests(unittest.TestCase):
    def test_preserves_covered_uncovered_and_multiple_execution_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            lcov = f"SF:{root}/Sources/Core.swift\nDA:3,0\nDA:5,7\nLF:2\nLH:1\nend_of_record\n"
            xml, lines, covered = exporter.convert_verified(lcov, root)
            self.assertEqual((lines, covered), (2, 1))
            self.assertIn('filename="Sources/Core.swift"', xml)
            self.assertIn('number="5" hits="7"', xml)
            self.assertIn('<source>.</source>', xml)

    def test_rejects_test_sources(self):
        with self.assertRaisesRegex(ValueError, "Non-application"):
            exporter.convert_verified("SF:/tmp/Tests/Test.swift\nDA:1,1\nend_of_record\n", Path('/tmp'))

    def test_rejects_empty_measurement(self):
        with self.assertRaisesRegex(ValueError, "executable"):
            exporter.convert_verified("", Path('/tmp'))


if __name__ == '__main__':
    unittest.main()
