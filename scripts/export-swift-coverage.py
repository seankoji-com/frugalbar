#!/usr/bin/env python3
"""Export official LLVM LCOV, convert to Cobertura, and verify every line count.

Requires lcov-cobertura==2.1.1 and a completed instrumented Swift test run.
Only application sources in the test executable are measured; test/generated
sources are not. Sources absent from its LLVM map are outside this report.
"""
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from lcov_cobertura import LcovCobertura

ROOT = Path(__file__).resolve().parents[1]


def convert_verified(lcov, root):
    root = root.resolve()
    expected = {}
    current = None
    for line in lcov.splitlines():
        if line.startswith("SF:"):
            current = Path(line[3:]).resolve().relative_to(root).as_posix()
            if not current.startswith("Sources/"):
                raise ValueError(f"Non-application source in coverage: {current}")
            expected.setdefault(current, {})
        elif line.startswith("DA:"):
            if current is None:
                raise ValueError("DA record before SF record in LCOV")
            number, hits, *_ = line[3:].split(",")
            expected[current][int(number)] = int(hits)
    if not expected or not any(expected.values()):
        raise ValueError("LLVM did not report executable application lines")
    xml = LcovCobertura(lcov, base_dir=str(root)).convert()
    document = ET.fromstring(xml)
    actual = {}
    for cls in document.findall(".//class"):
        actual[cls.attrib["filename"]] = {
            int(line.attrib["number"]): int(line.attrib["hits"])
            for line in cls.findall("./lines/line")
        }
    if actual != expected:
        raise ValueError("Cobertura line identities/counts differ from LLVM LCOV")
    lines = sum(len(counts) for counts in expected.values())
    covered = sum(hits > 0 for counts in expected.values() for hits in counts.values())
    if int(document.attrib["lines-valid"]) != lines or int(document.attrib["lines-covered"]) != covered:
        raise ValueError("Cobertura totals differ from LLVM line records")
    # Checkout-relative source resolution works on machines other than this runner.
    source_elem = document.find("sources/source")
    if source_elem is not None:
        source_elem.text = "."
    return ET.tostring(document, encoding="unicode"), lines, covered


def main():
    binary_dir = Path(subprocess.check_output(["swift", "build", "-c", "debug", "--show-bin-path"], cwd=ROOT, text=True).strip())
    binaries = [bundle / "Contents" / "MacOS" / bundle.stem
                for bundle in sorted(binary_dir.glob("*.xctest"))
                if (bundle / "Contents" / "MacOS" / bundle.stem).is_file()]
    if not binaries:
        raise RuntimeError("Expected at least one Swift test executable, found 0")
    profile = binary_dir / "codecov" / "default.profdata"
    if not profile.is_file():
        raise RuntimeError(f"Coverage profile not found at {profile}. Run tests with --enable-code-coverage first.")
    sources = sorted(str(p) for p in (ROOT / "Sources").rglob("*.swift"))
    cmd = ["xcrun", "llvm-cov", "export", str(binaries[0])]
    for binary in binaries[1:]:
        cmd.append(f"-object={binary}")
    cmd.extend(["-format=lcov", f"-instr-profile={profile}", *sources])
    lcov = subprocess.check_output(cmd, cwd=ROOT, text=True)
    xml, lines, covered = convert_verified(lcov, ROOT)
    output = ROOT / "coverage"
    output.mkdir(exist_ok=True)
    (output / "swift.lcov").write_text(lcov)
    (output / "coverage.xml").write_text(xml + "\n")
    print(f"Verified Cobertura against LLVM LCOV: {covered}/{lines} application lines covered")


if __name__ == "__main__":
    main()
