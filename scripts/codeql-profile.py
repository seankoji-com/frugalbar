#!/usr/bin/env python3
"""One opt-in diagnostic comparison; never evidence of the normal job budget."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def instrument(prepared, directory):
    """Keep the original compiler, cache, outputs, source bodies and order."""
    def instrument_command(command):
        module = command["module"]
        if not module.isidentifier():
            raise ValueError("Unexpected module name")
        stats = directory / f"{module}-stats"
        stats.mkdir()
        measured = {**command, "argv": [
            "/usr/bin/time", "-l", "-o", str(directory / f"{module}-time.txt"),
            *command["argv"], "-stats-output-dir", str(stats), "-Rmodule-interface-rebuild",
        ]}
        if "batches" in command:
            measured["batches"] = [instrument_command(batch) for batch in command["batches"]]
        return measured
    return {**prepared, "commands": [instrument_command(command) for command in prepared["commands"]]}


def run_phase(plan, directory, phase):
    destination = directory / phase
    destination.mkdir()
    prepared = json.loads(plan.read_text())
    measured = instrument(prepared, destination)
    measured_path = destination / "plan.json"
    write_json(measured_path, measured)
    receipt = {"phase": phase, "started_at": now(), "plan_sha256": hashlib.sha256(plan.read_bytes()).hexdigest(),
               "comparison_limits": "Same native compiler argv and module cache, untraced first (warm). "
               "CodeQL may use a different extraction compiler/remapped modules. "
               "Stats paths differ by phase. This cannot isolate compiler/cache/tracing causality alone.",
               "developer_dir": os.environ.get("DEVELOPER_DIR"),
               "tracer_diagnostics_dir": os.environ.get("CODEQL_TRACER_DIAGNOSTICS_DIR"),
               "tracing_paths": {key: os.environ.get(key) for key in ["CODEQL_DIST", "CODEQL_TRACER_LOG",
                   "CODEQL_EXTRACTOR_SWIFT_ROOT", "CODEQL_EXTRACTOR_SWIFT_LOG_DIR", "SEMMLE_COPY_EXECUTABLES_ROOT"]},
               "commands": prepared["commands"]}
    started = time.monotonic()
    try:
        # Use the normal helper's validation, batch joins and dependency order.
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("codeql-build.py")),
                                 "compile", str(measured_path)])
        receipt["exit_code"] = result.returncode
        return result.returncode
    finally:
        receipt.update(completed_at=now(), seconds=time.monotonic() - started)
        write_json(destination / "result.json", receipt)


def owned_tree(root, rows):
    """Only descendants of this build step's recorded shell, with matching UID."""
    own = {root}
    records = []
    for line in rows.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, parent, uid, executable = fields
            records.append((int(pid), int(parent), int(uid), executable))
    while True:
        children = {pid for pid, parent, uid, _ in records if parent in own and uid == os.getuid()}
        if children <= own:
            break
        own.update(children)
    return [{"pid": pid, "parent": parent, "executable": exe}
            for pid, parent, uid, exe in records if pid in own and uid == os.getuid()]


def monitor(directory):
    # Starts BEFORE CodeQL init, so its Python interpreter is not traced. It can
    # observe the later shell's Python signing/startup and extractor/TRAP gaps.
    # No name matching, sudo, signals to other processes or policy changes.
    started = time.monotonic()
    samples = 0
    next_sample = 0
    sample_allowed = True
    with (directory / "processes.jsonl").open("x") as stream:
        while time.monotonic() - started < 1500 and not (directory / "trace-done").exists():
            root_file = directory / "trace-root"
            if root_file.exists():
                root = int(root_file.read_text())
                rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,uid=,comm="], text=True)
                tree = owned_tree(root, rows)
                event = {"at": now(), "tree": tree}
                # One second at 10ms, at most 30 samples. sample can legitimately
                # deny attachment; retain that failure and stop requesting it.
                if tree and sample_allowed and samples < 30 and time.monotonic() >= next_sample:
                    target = tree[0 if samples % 3 == 0 else -1]["pid"]
                    output = directory / f"sample-{samples:02d}.txt"
                    try:
                        result = subprocess.run(["/usr/bin/sample", str(target), "1", "10", "-file", str(output)],
                                                capture_output=True, text=True, timeout=5)
                        event["sample"] = {"pid": target, "exit_code": result.returncode,
                                           "output": result.stdout + result.stderr}
                        sample_allowed = result.returncode == 0
                    except subprocess.TimeoutExpired:
                        # subprocess stops only the sample PID it launched.
                        event["sample"] = {"pid": target, "timeout_seconds": 5}
                        sample_allowed = False
                    samples += 1
                    next_sample = time.monotonic() + 40
                stream.write(json.dumps(event) + "\n")
                stream.flush()
            time.sleep(20)
    write_json(directory / "monitor-result.json", {"completed_at": now(), "samples": samples,
               "sample_allowed": sample_allowed, "maximum_seconds": 1500})


def pack(directory, database, output, limit=64 * 1024 * 1024):
    """Bound uploaded bytes; disclose every truncation, never filter errors."""
    output.mkdir()
    records = []
    remaining = limit
    for prefix, root in [("profile", directory), ("database-log", database / "log"),
                         ("database-diagnostic", database / "diagnostic"),
                         ("swift-log", database / "swift" / "log"),
                         ("swift-diagnostic", database / "swift" / "diagnostic")]:
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            size = path.stat().st_size
            keep = min(size, remaining, 4 * 1024 * 1024)
            target = output / prefix / path.relative_to(root)
            digest = hashlib.sha256()
            retained_digest = hashlib.sha256()
            # Copy only a bounded prefix, but hash the whole original stream.
            if keep:
                target.parent.mkdir(parents=True, exist_ok=True)
            with path.open("rb") as source:
                with target.open("xb") if keep else open(os.devnull, "wb") as destination:
                    copied = 0
                    for chunk in iter(lambda: source.read(65536), b""):
                        digest.update(chunk)
                        part = chunk[:max(0, keep - copied)]
                        destination.write(part)
                        retained_digest.update(part)
                        copied += len(part)
            remaining -= keep
            records.append({"path": f"{prefix}/{path.relative_to(root)}", "bytes": size,
                            "sha256": digest.hexdigest(), "retained_bytes": keep,
                            "retained_sha256": retained_digest.hexdigest(), "truncated": keep < size})
    write_json(output / "files.json", {"maximum_payload_bytes": limit, "files": records,
               "note": "Prefixes only when limited. Full compiler-error gate reads original logs. "
               "GitHub step logs and post-action times remain separate whole-job evidence."})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["untraced", "traced", "start", "monitor", "pack"])
    parser.add_argument("directory", type=Path)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--database", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.mode in {"untraced", "traced"}:
        if args.plan is None:
            parser.error("--plan is required")
        raise SystemExit(run_phase(args.plan, args.directory, args.mode))
    if args.mode == "start":
        with (args.directory / "monitor.log").open("x") as log:
            child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "monitor", str(args.directory)],
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        write_json(args.directory / "monitor-pid.json", {"pid": child.pid, "started_at": now()})
    elif args.mode == "monitor":
        monitor(args.directory)
    else:
        if args.database is None or args.output is None:
            parser.error("--database and --output are required")
        args.directory.mkdir(exist_ok=True)
        (args.directory / "trace-done").touch()
        # The monitor stops itself. Wait at most one sampling interval plus a
        # sample timeout before copying files it may still be writing.
        if (args.directory / "monitor-pid.json").exists():
            for _ in range(26):
                if (args.directory / "monitor-result.json").exists():
                    break
                time.sleep(1)
            else:
                raise RuntimeError("Bounded monitor did not stop; retain workflow logs")
        pack(args.directory, args.database, args.output)


if __name__ == "__main__":
    main()
