#!/usr/bin/env python3
"""Plan SwiftPM outside tracing, then compile every source in dependency order."""
import heapq
import json
import re
from concurrent.futures import ThreadPoolExecutor
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


def rekey_output_map(source, destination, first_input):
    contents = source.read_text()
    if contents.lstrip().startswith("{"):
        entries = json.loads(contents)
        if len(entries) != 1:
            raise ValueError("Expected one whole-module supplementary output entry")
        rewritten = json.dumps({first_input: next(iter(entries.values()))}, indent=2) + "\n"
    else:
        # Swift 6.1 ArgsResolver emits implicit YAML with quoted keys. Preserve
        # its values and escaping verbatim; the frontend remains their parser.
        lines = contents.splitlines(keepends=True)
        headers = [i for i, line in enumerate(lines) if line.strip() and not line[0].isspace()]
        match = re.fullmatch(r'"(?:[^"\\\r\n]|\\.)*"(:[ \t]*(?:\{\})?[ \t]*(?:\r?\n)?)', lines[headers[0]]) if len(headers) == 1 else None
        if match is None:
            raise ValueError("Expected one quoted Swift driver output-map key")
        lines[headers[0]] = json.dumps(first_input, ensure_ascii=False) + match[1]
        rewritten = "".join(lines)
    destination.write_text(rewritten)


def partial_module_commands(command, plan):
    # CodeQL supports primary-file module emission and a subsequent traced
    # -merge-modules invocation. Every batch sees the entire module, but only
    # its primary bodies are extracted. Never import untraced dependency modules.
    sources = command["sources"]
    directory = plan.with_name(f'{plan.stem}-{command["module"]}-partials').resolve()
    directory.mkdir(exist_ok=True)
    outputs = [str(directory / f"{index}.swiftmodule") for index in range(len(sources))]
    options = []
    original = iter(command["argv"])
    for argument in original:
        if argument in {"-o", "-supplementary-output-file-map", "-emit-module-doc-path",
                        "-emit-module-source-info-path", "-emit-abi-descriptor-path"}:
            next(original)
        elif argument not in sources:
            options.append(argument)
    batches = []
    # Contiguous filename ranges can concentrate large SwiftUI bodies in one
    # worker. Keep three workers, assigning the largest sources to the lightest.
    groups = [[] for _ in range(min(3, len(sources)))]
    loads = [0] * len(groups)
    for source in sorted(sources, key=lambda path: (-Path(path).stat().st_size, path)):
        index = min(range(len(groups)), key=lambda i: (loads[i], i))
        groups[index].append(source)
        loads[index] += max(1, Path(source).stat().st_size)
    for group in groups:
        primary = [source for source in sources if source in group]
        inputs = [argument for source in sources
                  for argument in (["-primary-file", source] if source in primary else [source])]
        output_arguments = [argument for source, output in zip(sources, outputs)
                            if source in group for argument in ["-o", output]]
        batches.append({"module": f'{command["module"]}_part_{len(batches)}', "sources": primary,
                        "argv": [*options, *inputs, *output_arguments]})
    # The merge's first input replaces the original source as the map key.
    # Keep all output kinds/paths, including those in older YAML driver maps.
    merge = []
    original = iter(command["argv"])
    for argument in original:
        if argument == "-supplementary-output-file-map":
            output_map = plan.with_name(f'{plan.stem}-{command["module"]}-merge-outputs.map').resolve()
            rekey_output_map(Path(next(original)), output_map, outputs[0])
            merge.extend([argument, str(output_map)])
        elif argument not in sources:
            merge.append(argument)
    return {**command, "batches": batches, "argv": [*merge, "-merge-modules", *outputs]}


def compile_commands(commands):
    def compile_one(command):
        print(f'Forcing compilation of {command["module"]}: {len(command["sources"])} sources', flush=True)
        subprocess.run(command["argv"], check=True)
    # The macOS tracer copies/signs a compiler on first use. Concurrent cold
    # launches duplicate that work. A serial info query primes the same binary
    # without -frontend, so CodeQL does not treat it as an extraction command.
    frontends = set()
    for command in commands:
        for batch in command.get("batches", []):
            argv = batch["argv"]
            if "-frontend" in argv:
                frontends.add(argv[argv.index("-frontend") - 1])
    for frontend in sorted(frontends):
        subprocess.run([frontend, "-version"], check=True)
    for command in commands:
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(compile_one, command.get("batches", [])))
        compile_one(command)


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
    commands = [partial_module_commands(command, plan) for command in commands]
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
