"""Direct compilation must cover every source even when all objects are warm."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("codeql_build", Path(__file__).with_name("codeql-build.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class CompilerPlanTests(unittest.TestCase):
    def test_prepare_only_plans_and_keeps_auxiliary_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            binary = root / 'debug'
            binary.mkdir()
            (binary / 'description.json').write_text('{}')
            auxiliary = root / 'outputs.json'
            auxiliary.write_text('{"output": "module"}')
            commands = [{'module': 'Core', 'sources': [], 'argv': [
                'swift-frontend', '-supplementary-output-file-map', str(auxiliary)]}]
            with patch.object(builder.subprocess, 'run') as run, \
                    patch.object(builder.subprocess, 'check_output', return_value=str(binary)), \
                    patch.object(builder, 'compiler_commands', return_value=[]), \
                    patch.object(builder, 'frontend_commands', return_value=commands), \
                    patch.object(builder, 'partial_module_commands', side_effect=lambda command, plan: command):
                builder.prepare_plan(root, root / 'plan.json')
            run.assert_called_once_with(['swift', 'build', '--build-system', 'native', '-c', 'debug',
                                         '--print-manifest-job-graph'], check=True, stdout=subprocess.DEVNULL)
            prepared = json.loads((root / 'plan.json').read_text())
            retained = Path(prepared['commands'][0]['argv'][-1])
            self.assertEqual(retained.read_bytes(), auxiliary.read_bytes())
            self.assertNotEqual(retained, auxiliary)

    def test_partial_modules_cover_every_body_without_shared_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = [str(root / f"dir {n}" / "File.swift") for n in range(7)]
            output_map = root / "outputs.json"
            output_map.write_text(json.dumps({sources[0]: {"swiftdoc": "Core.swiftdoc"}}))
            original = {"module": "Core", "sources": sources, "argv": [
                "swift-frontend", "-frontend", "-emit-module", *sources,
                "-target", "arm64-apple-macosx15.0", "-sdk", "/sdk", "-I", "/modules",
                "-module-name", "Core", "-parse-as-library", "-swift-version", "6",
                "-supplementary-output-file-map", str(output_map),
                "-emit-module-source-info-path", "Core.swiftsourceinfo", "-emit-abi-descriptor-path", "Core.abi.json",
                "-o", "Core.swiftmodule"]}
            command = builder.partial_module_commands(original, root / "plan.json")
            primaries, outputs = [], []
            for batch in command["batches"]:
                argv = batch["argv"]
                self.assertTrue(batch["module"].isidentifier())
                self.assertIn("-emit-module", argv)
                self.assertNotIn("-merge-modules", argv)
                self.assertFalse(any("skip" in arg and "function-bodies" in arg for arg in argv))
                self.assertEqual([arg for arg in argv if arg.endswith(".swift")], sources)
                primary = [argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == "-primary-file"]
                output = [argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == "-o"]
                self.assertEqual(primary, batch["sources"])
                self.assertEqual(len(primary), len(output))
                self.assertLessEqual(len(primary), 3)
                self.assertEqual(argv[argv.index("-module-name") + 1], "Core")
                self.assertEqual(argv[argv.index("-sdk") + 1], "/sdk")
                self.assertEqual(argv[argv.index("-I") + 1], "/modules")
                for shared in [str(output_map), "Core.swiftdoc", "Core.swiftsourceinfo", "Core.abi.json", "Core.swiftmodule"]:
                    self.assertNotIn(shared, argv)
                primaries.extend(primary)
                outputs.extend(output)
            self.assertEqual(len(command["batches"]), 3)
            self.assertEqual(primaries, sources)
            self.assertEqual(len(outputs), len(set(outputs)))
            merge = command["argv"]
            self.assertIn("-merge-modules", merge)
            self.assertTrue(all(output in merge for output in outputs))
            self.assertFalse(any(source in merge for source in sources))
            rewritten = Path(merge[merge.index("-supplementary-output-file-map") + 1])
            self.assertNotEqual(rewritten, output_map)
            self.assertEqual(json.loads(rewritten.read_text()), {outputs[0]: {"swiftdoc": "Core.swiftdoc"}})
            self.assertEqual(json.loads(output_map.read_text()), {sources[0]: {"swiftdoc": "Core.swiftdoc"}})
            self.assertIn("Core.swiftsourceinfo", merge)
            self.assertIn("Core.abi.json", merge)
            self.assertIn("Core.swiftmodule", merge)
            self.assertEqual(command["sources"], sources)

    def test_native_partial_merge_preserves_outputs_and_dependency_imports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = [root / f"File{n}.swift" for n in range(4)]
            for n, source in enumerate(sources):
                value = f"f{n + 1}()" if n < 3 else "3"
                source.write_text(f"public func f{n}() -> Int {{ {value} }}\n")
            command = {"module": "Core", "sources": list(map(str, sources)), "argv": [
                "swiftc", "-emit-module", "-whole-module-optimization", "-module-name", "Core",
                "-parse-as-library", *map(str, sources), "-emit-module-path", str(root / "Core.swiftmodule")]}
            frontend = builder.frontend_commands([command])[0]
            # Exercise the actual driver's source-keyed auxiliary output map.
            self.assertIn("-supplementary-output-file-map", frontend["argv"])
            dependent = root / "Dependent.swift"
            dependent.write_text("import Core\npublic func useCore() -> Int { f0() }\n")
            for dialect in ["driver", "legacy"]:
                argv = list(frontend["argv"])
                outputs = {"swiftdoc": str(root / "Core.swiftdoc"),
                           "swiftsourceinfo": str(root / "Core.swiftsourceinfo")}
                if dialect == "legacy":
                    legacy = root / "legacy.map"
                    outputs = {"swiftdoc": str(root / 'Doc "quoted".swiftdoc'),
                               "swiftsourceinfo": str(root / "Info: é.swiftsourceinfo")}
                    legacy.write_text(json.dumps(str(sources[0])) + ":\n" + "".join(
                        f"  {kind}: {json.dumps(path)}\n" for kind, path in outputs.items()))
                    argv[argv.index("-supplementary-output-file-map") + 1] = str(legacy)
                prepared = builder.partial_module_commands({**frontend, "argv": argv}, root / f"{dialect}.json")
                (root / "Core.swiftmodule").unlink(missing_ok=True)
                builder.compile_commands([prepared])
                self.assertTrue((root / "Core.swiftmodule").is_file())
                for output in outputs.values():
                    self.assertTrue(Path(output).is_file(), output)
                subprocess.run(["swiftc", "-typecheck", "-I", str(root), str(dependent)], check=True, capture_output=True)

    def test_legacy_driver_yaml_preserves_every_output_and_escaped_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = str(root / 'Source "quoted".swift')
            output_map = root / "legacy.map"
            # Swift 6.1 ArgsResolver.createFileList emits this implicit YAML
            # mapping with double-quoted paths, not OutputFileMap.store's JSON.
            outputs = {"swiftdoc": 'Doc "quoted".swiftdoc', "swiftsourceinfo": "Info: é.swiftsourceinfo"}
            payload = json.dumps(source) + ":\n" + "".join(
                f"  {kind}: {json.dumps(path, ensure_ascii=False)}\n" for kind, path in outputs.items())
            output_map.write_text(payload)
            command = {"module": "Core", "sources": [source], "argv": [
                "swift-frontend", "-frontend", "-emit-module", source,
                "-supplementary-output-file-map", str(output_map), "-o", "Core.swiftmodule"]}
            prepared = builder.partial_module_commands(command, root / "plan.json")
            merge = prepared["argv"]
            remapped = Path(merge[merge.index("-supplementary-output-file-map") + 1]).read_text()
            first_partial = next(arg for arg in merge if arg.endswith("/0.swiftmodule"))
            self.assertEqual(remapped, json.dumps(first_partial, ensure_ascii=False) + payload[payload.index(':\n'):])
            self.assertEqual(output_map.read_text(), payload)

    def test_output_map_rekey_rejects_multiple_or_unrecognised_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "original.map"
            for payload in ['{}', '{"a": {}, "b": {}}', '"a": {}\n"b": {}\n', 'unquoted: {}\n']:
                original.write_text(payload)
                with self.assertRaises(ValueError):
                    builder.rekey_output_map(original, root / "merge.map", "partial.swiftmodule")

    def test_parallel_batches_join_before_merge_and_dependent_module(self):
        for fail in [False, True]:
            barrier = threading.Barrier(3)
            completed = []
            invoked = []
            batches = [{"module": f"Core_part_{n}", "sources": [str(n)], "argv": [str(n)]} for n in range(3)]
            commands = [{"module": "Core", "sources": ["0", "1", "2"], "batches": batches, "argv": ["merge"]},
                        {"module": "App", "sources": ["App"], "argv": ["app"]}]
            def compiler(argv, check):
                self.assertTrue(check)
                invoked.append(argv[0])
                if argv[0] in {"0", "1", "2"}:
                    barrier.wait(timeout=5)
                    completed.append(argv[0])
                    if fail and argv == ["1"]:
                        raise subprocess.CalledProcessError(1, argv)
                else:
                    self.assertCountEqual(completed, ["0", "1", "2"])
            with patch.object(builder.subprocess, "run", side_effect=compiler):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):
                        builder.compile_commands(commands)
                else:
                    builder.compile_commands(commands)
            self.assertCountEqual(invoked[:3], ["0", "1", "2"])
            self.assertEqual(invoked[3:], [] if fail else ["merge", "app"])

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
