#!/usr/bin/env python3
"""Prepare SwiftPM outside tracing, then force compilation of every source directly."""
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys


def compiler_commands(description, root):
    expected = set(root.glob("Sources/**/*.swift"))
    commands = []
    seen = []
    for command in description["swiftCommands"].values():
        sources = [Path(p) for p in command["sources"]]
        if not sources or not any(p in expected for p in sources):
            continue
        if not all(p in expected for p in sources):
            raise ValueError("Application command contains unexpected sources")
        seen.extend(sources)
        # No incremental flag: even a warm object must be compiled under tracing.
        arguments = []
        original = iter(command["otherArguments"])
        for argument in original:
            if argument == "-emit-objc-header-path":
                next(original)  # This header was emitted by the preparation build.
            elif argument not in {"-incremental", "-emit-objc-header"}:
                arguments.append(argument)
        # The untraced build already emitted dependency modules. Emitting them
        # again makes CodeQL extract every source twice (object + module pass).
        # Only object outputs are replayed, so module inputs remain immutable.
        argv = [command["executable"], "-module-name", command["moduleName"], "-emit-dependencies",
                "-output-file-map", command["outputFileMapPath"], "-I", command["importPath"]]
        if command["isLibrary"]:
            argv.append("-parse-as-library")
        argv += ["-c", *map(str, sources), *arguments, "-driver-batch-count", "1"]
        commands.append({"module": command["moduleName"], "sources": list(map(str, sources)), "argv": argv})
    if not expected or set(seen) != expected or len(seen) != len(expected):
        raise ValueError("SwiftPM commands must cover every Sources file exactly once")
    # Retain deterministic plan order; prepared module inputs need no replay.
    dependencies = description["targetDependencyMap"]
    return sorted(commands, key=lambda c: (len(dependencies[c["module"]]), c["module"]))


def compile_commands(commands):
    # Every module reads the prebuilt modules and writes separate object paths.
    # Bound concurrency to the same three workers as the preparation build.
    def compile_one(command):
        print(f'Forcing compilation of {command["module"]}: {len(command["sources"])} sources', flush=True)
        subprocess.run(command["argv"], check=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(compile_one, commands))


def main():
    mode, filename = sys.argv[1:]
    root = Path.cwd().resolve()
    plan = Path(filename)
    if mode == "prepare":
        # SwiftPM startup under CodeQL took 540s before any application compilation.
        # Warm SDK/modules and resolve the full compiler plan without tracing SwiftPM.
        build = ["swift", "build", "--build-system", "native", "-c", "debug"]
        subprocess.run([*build, "--jobs", "3"], check=True)
        binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
        commands = compiler_commands(json.loads((binary / "description.json").read_text()), root)
        plan.write_text(json.dumps({"root": str(root), "commands": commands}, indent=2) + "\n")
    elif mode == "compile":
        prepared = json.loads(plan.read_text())
        if prepared["root"] != str(root):
            raise ValueError("Compiler plan belongs to another checkout")
        sources = [Path(p) for c in prepared["commands"] for p in c["sources"]]
        if set(sources) != set(root.glob("Sources/**/*.swift")) or len(sources) != len(set(sources)):
            raise ValueError("Compiler plan no longer covers every application source")
        compile_commands(prepared["commands"])
    elif mode == "coverage":
        # ExtractedFiles.ql selects (File, message). BQRS JSON labels are source paths.
        decoded = json.loads(plan.read_text())
        labels = {cell["label"] for row in decoded["#select"]["tuples"] for cell in row if isinstance(cell, dict) and "label" in cell}
        missing = [str(p.relative_to(root)) for p in root.glob("Sources/**/*.swift")
                   if str(p) not in labels and str(p.relative_to(root)) not in labels]
        if missing:
            raise ValueError(f"CodeQL did not extract application sources: {missing}")
        print(f'CodeQL extracted all {len(list(root.glob("Sources/**/*.swift")))} application sources')
    else:
        raise ValueError("Use prepare, compile or coverage")


if __name__ == "__main__":
    main()
