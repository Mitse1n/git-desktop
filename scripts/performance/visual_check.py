#!/usr/bin/env python3
"""Compare four themes of AppKit Log/Diff views, plus optional syntax.swift Diff views."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess as sp
import tempfile

PROJECT = Path(__file__).resolve().parents[2]


def render(package, sources, output, executable):
    sp.run(["swift", "build", "-c", "release", "--product", "GitDesk"], cwd=package, check=True)
    bin_dir = Path(sp.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=package, text=True).strip())
    ui = sorted(p for p in (sources / "GitDesk").glob("*.swift") if p.name != "main.swift")
    sp.run(["swiftc", "-O", "-I", str(bin_dir / "Modules"),
            *map(str, sorted((bin_dir / "GitDeskCore.build").glob("*.o"))), *map(str, ui),
            str(PROJECT / "scripts/performance/VisualChecks/main.swift"), "-o", str(executable)], check=True)
    combined = []
    # Isolate each palette from previous windows/appearance caches, as a fresh
    # application launch. Still compare the exact same lifecycle in both builds.
    for theme in ["islandDark", "islandLight", "light", "dark"]:
        sp.run([str(executable), str(ARGS.repository.resolve()), str(output), theme], check=True, timeout=180)
        combined += json.loads((output / "manifest.json").read_text())
    (output / "manifest.json").write_text(json.dumps(combined, indent=2))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--before-sources", type=Path, required=True, help="snapshot of the Sources directory")
parser.add_argument("--repository", type=Path, required=True, help="fixed fixture containing diff.txt")
parser.add_argument("--out", type=Path, required=True)
ARGS = parser.parse_args()
ARGS.out = ARGS.out.resolve()
ARGS.out.mkdir(parents=True, exist_ok=False)
with tempfile.TemporaryDirectory(prefix="gitdesk-visual-before-") as temporary:
    package = Path(temporary)
    shutil.copytree(ARGS.before_sources, package / "Sources")
    shutil.copy2(PROJECT / "Package.swift", package / "Package.swift")
    tests = package / "Tests/GitDeskCoreTests"
    tests.mkdir(parents=True)
    (tests / "main.swift").write_text('print("unused test target")\n')
    render(package, package / "Sources", ARGS.out / "before", ARGS.out / "BeforeRenderer")
render(PROJECT, PROJECT / "Sources", ARGS.out / "after", ARGS.out / "AfterRenderer")
before = {row["name"]: row for row in json.loads((ARGS.out / "before/manifest.json").read_text())}
after = {row["name"]: row for row in json.loads((ARGS.out / "after/manifest.json").read_text())}
comparison = [{"name": name, "identical": before.get(name) == after.get(name)} for name in sorted(before.keys() | after.keys())]
(ARGS.out / "comparison.json").write_text(json.dumps(comparison, indent=2))
print(json.dumps(comparison, indent=2))
if not all(row["identical"] for row in comparison): raise SystemExit(1)
