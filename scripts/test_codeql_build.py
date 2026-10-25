"""Direct compilation must cover every source even when all objects are warm."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("codeql_build", Path(__file__).with_name("codeql-build.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class CompilerPlanTests(unittest.TestCase):
    def test_extracted_files_must_include_every_application_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "Sources").mkdir()
            source = root / "Sources" / "Core.swift"
            source.touch()
            decoded = root / "extracted.json"
            for label in [str(source), "Sources/Core.swift", "Tests/Core.swift"]:
                decoded.write_text(json.dumps({"#select": {"tuples": [[{"label": label}, "extracted"]]}}))
                result = subprocess.run([sys.executable, str(Path(builder.__file__).resolve()), "coverage", str(decoded)],
                                        cwd=root, capture_output=True)
                self.assertEqual(result.returncode == 0, label != "Tests/Core.swift", result.stderr)

    def test_forces_all_sources_and_orders_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            files = [root / "Sources" / f"{name}.swift" for name in ["Core", "App"]]
            for path in files:
                path.touch()
            def command(name, source):
                return {"moduleName": name, "sources": [str(source)], "executable": "swiftc",
                        "otherArguments": ["-incremental", "-Onone", "-swift-version", "6"],
                        "moduleOutputPath": f"{name}.swiftmodule", "outputFileMapPath": f"{name}.json",
                        "importPath": "Modules", "isLibrary": name == "Core"}
            description = {"swiftCommands": {"App": command("App", files[1]), "Core": command("Core", files[0])},
                           "targetDependencyMap": {"App": ["Core"], "Core": []}}
            commands = builder.compiler_commands(description, root)
            self.assertEqual([c["module"] for c in commands], ["Core", "App"])
            for c in commands:
                self.assertNotIn("-incremental", c["argv"])
                self.assertIn("-c", c["argv"])
                self.assertEqual(c["argv"][-2:], ["-driver-batch-count", "1"])
                self.assertIn(c["sources"][0], c["argv"])
            for fault in ["missing", "duplicate", "foreign"]:
                changed = {**description, "swiftCommands": dict(description["swiftCommands"])}
                if fault == "missing":
                    del changed["swiftCommands"]["Core"]
                elif fault == "duplicate":
                    changed["swiftCommands"]["Duplicate"] = command("Core", files[0])
                else:
                    changed["swiftCommands"]["Core"] = command("Core", root / "Tests.swift")
                with self.assertRaises(ValueError):
                    builder.compiler_commands(changed, root)


if __name__ == "__main__":
    unittest.main()
