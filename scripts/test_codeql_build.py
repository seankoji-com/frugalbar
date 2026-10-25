"""Direct compilation must cover every source even when all objects are warm."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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
                        "otherArguments": ["-incremental", "-Onone", "-swift-version", "6",
                                           "-emit-objc-header", "-emit-objc-header-path", f"{name}.h",
                                           "-index-store-path", "Index", "-index-system-modules", "-serialize-diagnostics"],
                        "moduleOutputPath": f"{name}.swiftmodule", "outputFileMapPath": f"{name}.json",
                        "importPath": "Modules", "isLibrary": name == "Core"}
            description = {"swiftCommands": {"App": command("App", files[1]), "Core": command("Core", files[0])},
                           "targetDependencyMap": {"App": ["Core"], "Core": []}}
            commands = builder.compiler_commands(description, root)
            self.assertEqual([c["module"] for c in commands], ["Core", "App"])
            for c in commands:
                self.assertNotIn("-incremental", c["argv"])
                self.assertNotIn("-c", c["argv"])
                self.assertIn(c["sources"][0], c["argv"])
                self.assertIn("-emit-module", c["argv"])
                self.assertIn("-emit-module-path", c["argv"])
                self.assertNotIn("-emit-objc-header", c["argv"])
                self.assertNotIn(f'{c["module"]}.h', c["argv"])
                self.assertNotIn("-index-store-path", c["argv"])
                self.assertNotIn("-index-system-modules", c["argv"])
                self.assertNotIn("-serialize-diagnostics", c["argv"])
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

    def test_orders_transitive_dependencies_topologically(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            modules = ["X", "Y", "Z1", "Z2"]
            commands = {}
            for module in modules:
                source = root / "Sources" / f"{module}.swift"
                source.touch()
                commands[module] = {
                    "moduleName": module, "sources": [str(source)], "executable": "swiftc",
                    "otherArguments": [], "moduleOutputPath": f"{module}.swiftmodule",
                    "importPath": "Modules", "isLibrary": True,
                }
            description = {
                "swiftCommands": commands,
                # Z2 is intentionally omitted: absent leaves have no dependencies.
                "targetDependencyMap": {"X": ["Y"], "Y": ["Z1", "Z2"], "Z1": []},
            }
            ordered = builder.compiler_commands(description, root)
            self.assertEqual([command["module"] for command in ordered], ["Z1", "Z2", "Y", "X"])

    def test_replays_dependencies_serially_and_stops_on_failure(self):
        commands = [{"module": str(n), "sources": [str(n)], "argv": [str(n)]} for n in range(3)]
        for fail in [False, True]:
            invoked = []
            def compiler(argv, check):
                invoked.append(argv[0])
                self.assertTrue(check)
                if fail and argv == ["1"]:
                    raise subprocess.CalledProcessError(1, argv)
            with patch.object(builder.subprocess, "run", side_effect=compiler):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):
                        builder.compile_commands(commands)
                else:
                    builder.compile_commands(commands)
            self.assertEqual(invoked, ["0", "1"] if fail else ["0", "1", "2"])

    def test_module_frontend_covers_every_source_and_keeps_bodies(self):
        sources = [f"/repo/Sources/File {n}.swift" for n in range(65)]
        command = {"module": "Core", "sources": sources, "argv": ["swiftc", "-emit-module", *sources]}
        def frontend(inputs):
            return shlex.join(["swift-frontend", "-frontend", "-emit-module", *inputs, "-o", "Core.swiftmodule"])
        valid = frontend(sources)
        with patch.object(builder.subprocess, "check_output", return_value=valid) as driver:
            batches = builder.frontend_commands([command])
            driver.assert_called_once_with([*command["argv"], "-driver-print-jobs"], text=True)
        self.assertEqual([len(b["sources"]) for b in batches], [65])
        self.assertEqual([p for b in batches for p in b["sources"]], sources)
        for invalid in ["", frontend(sources[:-1]), frontend(sources + [sources[0]]), valid + "\n" + valid,
                        valid.replace("-emit-module", "-c"), valid + " -primary-file " + shlex.quote(sources[0]),
                        valid + " -experimental-skip-non-inlinable-function-bodies-without-types"]:
            with patch.object(builder.subprocess, "check_output", return_value=invalid):
                with self.assertRaises(ValueError):
                    builder.frontend_commands([command])

        with patch.object(builder.subprocess, "check_output", return_value=valid):
            with self.assertRaises(ValueError):
                builder.frontend_commands([command, command])

    def test_extractor_compiler_errors_fail_even_when_sources_were_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            command = [sys.executable, str(Path(builder.__file__).resolve()), "diagnostics", str(logs)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            log = logs / "extractor.log"
            for message, ok in [("INFO [extractor/main] > Sources/Core.swift", True),
                                ("ERRO [extractor/compiler] module compiled with Swift 6.1 cannot be imported", False)]:
                log.write_text(message)
                self.assertEqual(subprocess.run(command, capture_output=True).returncode == 0, ok)


if __name__ == "__main__":
    unittest.main()
