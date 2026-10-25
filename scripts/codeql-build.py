#!/usr/bin/env python3
"""Plan SwiftPM outside tracing, then compile every source in dependency order."""
import heapq
import json
from pathlib import Path
import shlex
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
            if argument in {"-emit-objc-header-path", "-index-store-path"}:
                # Header is already prepared; IDE index output is unrelated to analysis.
                next(original)
            elif argument not in {"-incremental", "-emit-objc-header", "-enable-batch-mode", "-index-system-modules", "-serialize-diagnostics"}:
                arguments.append(argument)
        # CodeQL uses its own Swift compiler. Re-emit modules under tracing in
        # dependency order so dependent extraction gets compatible modules.
        # A module-only frontend type-checks and extracts every source once.
        argv = [command["executable"], "-module-name", command["moduleName"], "-emit-module",
                "-emit-module-path", command["moduleOutputPath"], "-I", command["importPath"]]
        if command["isLibrary"]:
            argv.append("-parse-as-library")
        argv += [*map(str, sources), *arguments, "-whole-module-optimization"]
        commands.append({"module": command["moduleName"], "sources": list(map(str, sources)), "argv": argv})
    if not expected or set(seen) != expected or len(seen) != len(expected):
        raise ValueError("SwiftPM commands must cover every Sources file exactly once")
    # A dependency must finish emission before a dependent module is extracted.
    dependencies = description.get("targetDependencyMap", {})
    modules = {command["module"] for command in commands}
    dependents = {module: [] for module in modules}
    remaining = {module: set() for module in modules}
    for module in modules:
        # Some SwiftPM descriptions omit targets with no dependencies.
        for dependency in dependencies.get(module, []):
            if dependency in modules:
                remaining[module].add(dependency)
                dependents[dependency].append(module)

    ready = [module for module, required in remaining.items() if not required]
    heapq.heapify(ready)
    ordered = []
    by_module = {command["module"]: command for command in commands}
    while ready:
        module = heapq.heappop(ready)
        ordered.append(by_module[module])
        for dependent in sorted(dependents[module]):
            remaining[dependent].remove(module)
            if not remaining[dependent]:
                heapq.heappush(ready, dependent)

    if len(ordered) != len(commands):
        raise ValueError("Target dependency map contains a cycle")
    return ordered


def frontend_commands(commands):
    # Resolve the driver outside tracing. CI logs have multi-minute gaps before
    # swiftc/driver interception; this avoids replaying those extra processes.
    result = []
    outputs = []
    for command in commands:
        printed = subprocess.check_output([*command["argv"], "-driver-print-jobs"], text=True)
        jobs = [shlex.split(line) for line in printed.splitlines() if line.strip()]
        if len(jobs) != 1:
            raise ValueError("Expected one complete module frontend")
        argv = jobs[0]
        if "-frontend" not in argv or "-emit-module" not in argv or "-c" in argv or "-primary-file" in argv:
            raise ValueError("Expected whole-module emission with all source bodies")
        if any("skip" in arg and "function-bodies" in arg for arg in argv):
            raise ValueError("Source bodies must not be skipped during analysis")
        sources = [arg for arg in argv if arg.endswith(".swift")]
        output = [argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == "-o"]
        if sorted(sources) != sorted(command["sources"]) or len(output) != 1:
            raise ValueError("Frontend must emit one module covering every source exactly once")
        outputs.extend(output)
        result.append({"module": command["module"], "sources": sources, "argv": argv})
    if len(outputs) != len(set(outputs)):
        raise ValueError("Frontend module outputs must not overlap")
    return result


def compile_commands(commands):
    # Preserve CodeQL's dependency-module remapping. Concurrent object replay
    # imported incompatible untraced modules and took 1660s in CI.
    for command in commands:
        print(f'Forcing compilation of {command["module"]}: {len(command["sources"])} sources', flush=True)
        subprocess.run(command["argv"], check=True)


def prepare_plan(root, plan):
    # Planning writes description.json without compiling objects or linking the
    # app. Each replay emits its native module before CodeQL extracts it; later
    # replays therefore have both native and CodeQL-compatible dependencies.
    build = ["swift", "build", "--build-system", "native", "-c", "debug"]
    subprocess.run([*build, "--print-manifest-job-graph"], check=True, stdout=subprocess.DEVNULL)
    binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
    commands = frontend_commands(compiler_commands(json.loads((binary / "description.json").read_text()), root))
    for command in commands:
        argv = command["argv"]
        if "-supplementary-output-file-map" in argv:
            index = argv.index("-supplementary-output-file-map") + 1
            output_map = plan.with_name(f'{plan.stem}-{command["module"]}-outputs.json')
            output_map.write_bytes(Path(argv[index]).read_bytes())
            argv[index] = str(output_map.resolve())
    plan.write_text(json.dumps({"root": str(root), "commands": commands}, indent=2) + "\n")


def main():
    mode, filename = sys.argv[1:]
    root = Path.cwd().resolve()
    plan = Path(filename)
    if mode == "prepare":
        prepare_plan(root, plan)
    elif mode == "compile":
        prepared = json.loads(plan.read_text())
        if prepared["root"] != str(root):
            raise ValueError("Compiler plan belongs to another checkout")
        sources = [Path(p) for c in prepared["commands"] for p in c["sources"]]
        if set(sources) != set(root.glob("Sources/**/*.swift")) or len(sources) != len(set(sources)):
            raise ValueError("Compiler plan no longer covers every application source")
        compile_commands(prepared["commands"])
    elif mode == "diagnostics":
        logs = list(plan.glob("*.log"))
        if not logs:
            raise ValueError("No Swift extractor logs were produced")
        errors = [line for path in logs for line in path.read_text().splitlines()
                  if "ERRO [extractor/compiler]" in line]
        if errors:
            raise ValueError("Swift extraction compiler errors: " + "\n".join(errors))
        print(f'No Swift compiler errors in {len(logs)} extractor logs')
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
        raise ValueError("Use prepare, compile, diagnostics or coverage")


if __name__ == "__main__":
    main()
