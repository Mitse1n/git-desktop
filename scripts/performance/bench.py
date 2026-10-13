#!/usr/bin/env python3
"""Dependency-free, local-only GitDesk performance fixtures and measurements."""
import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess as sp
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[2]
SCHEMA = 1
TOOL_HASHES = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
               for p in [Path(__file__).resolve(), Path(__file__).with_name("main.swift")]}
SPECS = {
    "small": (100, 20, 5, 0, 5, 0),
    "medium": (10000, 1000, 100, 0, 30, 0),
    "history100k": (100000, 100, 10, 0, 30, 0),
    "dirty": (1000, 10000, 2000, 10000, 30, 0),
    "refs1000": (10000, 100, 10, 0, 1000, 0),
    "wide200": (10000, 100, 10, 0, 200, 200),
}
DIFFS = ["sparse1000", "sparse5000", "whitespace5000", "replace1000", "replace5000",
         "replace10000", "bytes-limit", "lines-limit", "binary"]


def run(args, **kw):
    return sp.check_output([str(x) for x in args], text=True, **kw).strip()


def metadata(source_root=None):
    def optional(args):
        try:
            return run(args, stderr=sp.DEVNULL)
        except (OSError, sp.CalledProcessError):
            return None
    source_root = source_root or PROJECT / "Sources"
    sources = sorted(source_root.rglob("*.swift"))
    digest = hashlib.sha256()
    for file in sources:
        digest.update(str(Path("Sources") / file.relative_to(source_root)).encode()); digest.update(file.read_bytes())
    idea = Path("/Applications/IntelliJ IDEA.app/Contents/Resources/product-info.json")
    product = json.loads(idea.read_text()) if idea.exists() else {}
    return {"schema": SCHEMA, "tool_sha256": TOOL_HASHES, "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
            "system": platform.platform(), "chip": optional(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "ram_bytes": optional(["sysctl", "-n", "hw.memsize"]), "git": optional(["git", "--version"]),
            "swift": optional(["swift", "--version"]), "head": optional(["git", "-C", PROJECT, "rev-parse", "HEAD"]),
            "dirty": optional(["git", "-C", PROJECT, "status", "--short"]), "source_sha256": digest.hexdigest(),
            "idea_version": product.get("version"), "idea_build": product.get("buildNumber")}


def fixtures(base):
    base.mkdir(parents=True, exist_ok=True)
    for name, spec in SPECS.items():
        dest = base / name
        expected = {"schema": SCHEMA, "spec": list(spec)}
        marker = dest / ".git" / "gitdesk-benchmark.json"
        if dest.exists():
            if marker.exists() and json.loads(marker.read_text()) == expected:
                print("reuse", dest, flush=True); continue
            raise SystemExit(f"Refusing to overwrite existing directory: {dest}; choose a fresh --fixtures path")
        dest.mkdir()
        commits, files, modified, untracked, refs, wide = spec
        run(["git", "init", "-b", "main", dest])
        for key, value in [("user.name", "Benchmark"), ("user.email", "bench@example.test"),
                           ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("gc.auto", "0")]:
            run(["git", "-C", dest, "config", key, value])
        stream = dest / ".git" / "fixture-import"
        with stream.open("wb") as out:
            def write(s): out.write(s.encode())
            def blob(mark, data):
                write(f"blob\nmark :{mark}\ndata {len(data)}\n"); out.write(data); write("\n")
            blob(1, b"original\n")
            blob(2, b"".join(f"line {i} value = {i}\n".encode() for i in range(1000)))
            def commit(mark, parent, message, commands="", ref="refs/heads/main"):
                stamp = 1700000000 + mark
                write(f"commit {ref}\nmark :{mark}\nauthor Benchmark <bench@example.test> {stamp} +0000\n"
                      f"committer Benchmark <bench@example.test> {stamp} +0000\ndata {len(message.encode())}\n{message}\n")
                if parent: write(f"from :{parent}\n")
                write(commands + "\n")
            cmds = "M 100644 :2 diff.txt\n" + "".join(f"M 100644 :1 src/d{i//100:03}/f{i:05}.txt\n" for i in range(files))
            commit(10, None, "initial needle", cmds)
            for i in range(1, commits):
                commit(i + 10, i + 9, f"commit {i}" + (" needle" if i % 100 == 0 else ""))
            for i in range(wide):
                parent = 10 + min(1000, commits - 1)
                for j in range(5):
                    mark = commits + 10 + i * 5 + j
                    commit(mark, parent, f"branch {i} commit {j}", ref=f"refs/heads/feature/b{i:04}")
                    parent = mark
            if not wide:
                for i in range(refs):
                    write(f"reset refs/heads/feature/b{i:04}\nfrom :{10 + max(0, commits - 1 - i % min(commits, 5000))}\n\n")
            write("done\n")
        with stream.open("rb") as source:
            sp.run(["git", "-C", str(dest), "fast-import", "--quiet", "--date-format=raw", "--done"], stdin=source, check=True)
        stream.unlink()
        run(["git", "-C", dest, "reset", "--hard", "main"])
        run(["git", "-C", dest, "repack", "-adq"])
        for i in range(modified):
            (dest / f"src/d{i//100:03}/f{i:05}.txt").write_text("modified\n")
        if untracked:
            (dest / "untracked").mkdir()
            for i in range(untracked): (dest / "untracked" / f"u{i:05}.txt").write_text("untracked\n")
        diff = dest / "diff.txt"
        diff.write_text(diff.read_text().replace("line 500 ", "line CHANGED "))
        marker.write_text(json.dumps(expected, indent=2))
        print("created", dest, flush=True)


def build(before_sources=None):
    temporary = tempfile.TemporaryDirectory(prefix="gitdesk-perf-frozen-") if before_sources else None
    package = Path(temporary.name) if temporary else PROJECT
    if temporary:
        shutil.copytree(before_sources, package / "Sources")
        shutil.copy2(PROJECT / "Package.swift", package / "Package.swift")
        tests = package / "Tests/GitDeskCoreTests"
        tests.mkdir(parents=True)
        (tests / "main.swift").write_text('print("unused test target")\n')
    sp.run(["swift", "build", "-c", "release", "--product", "GitDesk"], cwd=package, check=True)
    bindir = Path(run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=package))
    probe = bindir / "GitDeskPerfProbe"
    ui = sorted(p for p in (package / "Sources/GitDesk").glob("*.swift") if p.name != "main.swift")
    objects = sorted((bindir / "GitDeskCore.build").glob("*.o"))
    sp.run(["swiftc", "-O", "-I", str(bindir / "Modules"), *map(str, objects), *map(str, ui),
            str(PROJECT / "scripts/performance/main.swift"), "-o", str(probe)], cwd=PROJECT, check=True)
    return probe, temporary


def fingerprint(directory):
    digest = hashlib.sha256()
    digest.update(run(["git", "-C", directory, "show-ref"]).encode())
    for file in sorted(directory.rglob("*")):
        relative = file.relative_to(directory)
        if ".git" in relative.parts or ".idea" in relative.parts or file.name == ".DS_Store": continue
        if file.is_file():
            digest.update(str(relative).encode()); digest.update(file.read_bytes())
    return digest.hexdigest()


def summarize(rows):
    groups = {}
    for row in rows:
        if "ms" in row and not row.get("warmup"):
            groups.setdefault((row["scenario"], row["metric"]), []).append(row)
    result = []
    for (scenario, metric), values in groups.items():
        ms = sorted(v["ms"] for v in values)
        result.append({"scenario": scenario, "metric": metric, "n": len(ms),
            "median_ms": statistics.median(ms), "p95_ms": ms[math.ceil(.95 * len(ms)) - 1],
            "min_ms": ms[0], "max_ms": ms[-1],
            "rss_mib_max_after": max(v["memory"]["rss_mib"] for v in values),
            "footprint_mib_max_after": max(v["memory"].get("footprint_mib", -1) for v in values),
            "process_peak_footprint_mib": max(v["memory"].get("process_peak_footprint_mib", -1) for v in values),
            "process_peak_rss_mib": max(v["memory"]["process_peak_rss_mib"] for v in values)})
    return result


def benchmarks(args):
    if args.iterations < 1: raise SystemExit("--iterations must be positive")
    fixtures(args.fixtures)
    probe, temporary = build(args.before_sources)
    args.out.mkdir(parents=True, exist_ok=False)
    # Freeze the measured executable: later builds cannot change a running suite.
    frozen_probe = args.out / "GitDeskPerfProbe"
    shutil.copy2(probe, frozen_probe)
    probe = frozen_probe.resolve()
    if temporary: temporary.cleanup()
    source_root = args.before_sources.resolve() if args.before_sources else PROJECT / "Sources"
    shutil.copytree(source_root, args.out / "Sources")
    shutil.copy2(PROJECT / "Package.swift", args.out / "Package.swift")
    info = metadata(source_root); info["iterations"] = args.iterations; info["fixtures"] = str(args.fixtures.resolve())
    info["source_override"] = str(source_root) if args.before_sources else None
    info["viewport"] = [1440, 850]
    info["probe_sha256"] = hashlib.sha256(probe.read_bytes()).hexdigest()
    info["fixture_specs"] = SPECS
    info["fixture_fingerprints"] = {name: fingerprint(args.fixtures / name) for name in args.scenarios}
    rows, errors = [], []
    modes = [mode for mode in args.modes if mode != "diff"]
    info["modes"] = args.modes
    (args.out / "metadata.json").write_text(json.dumps(info, indent=2, ensure_ascii=False))
    cases = [(name, args.fixtures / name, mode) for name in args.scenarios for mode in modes]
    if args.real_repo:
        cases += [("real-repo", args.real_repo.resolve(), mode) for mode in modes]
    if "diff" in args.modes: cases += [(name, args.fixtures / name, "diff") for name in DIFFS]
    with (args.out / "raw.jsonl").open("w") as raw:
        for name, path, mode in cases:
            print(f"measuring {name}/{mode}", flush=True)
            try:
                completed = sp.run([str(probe), str(path), str(args.iterations), mode], text=True,
                    stdout=sp.PIPE, stderr=sp.PIPE, timeout=args.timeout)
                (args.out / f"{name}-{mode}.stderr.txt").write_text(completed.stderr)
                for line in completed.stdout.splitlines():
                    if not line.startswith("{"): continue
                    row = json.loads(line); row["scenario"] = name
                    raw.write(json.dumps(row) + "\n"); raw.flush(); rows.append(row)
                if completed.returncode: errors.append({"scenario": name, "mode": mode, "exit": completed.returncode})
            except sp.TimeoutExpired as exc:
                # Preserve completed measurements before a pathological case times out.
                output = exc.stdout or b""
                if isinstance(output, bytes): output = output.decode(errors="replace")
                for line in output.splitlines():
                    try: row = json.loads(line)
                    except ValueError: continue
                    row["scenario"] = name; raw.write(json.dumps(row) + "\n"); rows.append(row)
                errors.append({"scenario": name, "mode": mode, "timeout_seconds": args.timeout})
    summary = summarize(rows)
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2))
    with (args.out / "summary.csv").open("w") as file:
        if summary:
            writer = csv.DictWriter(file, fieldnames=list(summary[0])); writer.writeheader(); writer.writerows(summary)
    (args.out / "errors.json").write_text(json.dumps(errors, indent=2))
    print(f"Saved {len(rows)} raw observations to {args.out}; errors={errors}")
    if errors: raise SystemExit(1)


def process_table():
    result = {}
    for line in run(["ps", "-axo", "pid=,ppid=,rss=,time=,comm="]).splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) != 5: continue
        pid, parent, rss, cpu, command = parts
        fields = cpu.replace("-", ":").split(":")
        seconds = 0.
        for value in fields: seconds = seconds * 60 + float(value)
        result[int(pid)] = (int(parent), int(rss), seconds, command)
    return result


def sample(args):
    if args.seconds <= 0 or args.interval <= 0: raise SystemExit("seconds and interval must be positive")
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / "metadata.json").write_text(json.dumps(metadata(), indent=2, ensure_ascii=False))
    initial = process_table()
    roots = args.pid or [pid for pid, (_, _, _, cmd) in initial.items()
                        if cmd.endswith("/Contents/MacOS/idea") or cmd.endswith("/Contents/MacOS/GitDesk")]
    if not roots: raise SystemExit("No app process found; supply --pid")
    previous, previous_time = {}, time.monotonic()
    records, inventory = [], {}
    deadline = previous_time + args.seconds
    with (args.out / "samples.csv").open("w") as file:
        fields = ["timestamp", "elapsed_s", "label", "root_pid", "root_alive", "root_rss_mib", "tree_rss_mib",
                  "tree_cpu_percent", "process_count"]
        writer = csv.DictWriter(file, fieldnames=fields); writer.writeheader()
        start = previous_time
        while True:
            current_time = time.monotonic(); table = process_table()
            for root in roots:
                members = {root} if root in table else set()
                while True:
                    expanded = members | {p for p, value in table.items() if value[0] in members}
                    if expanded == members: break
                    members = expanded
                cpu = sum(max(0, table[p][2] - previous.get(p, table[p][2])) for p in members)
                row = {"timestamp": dt.datetime.now(dt.timezone.utc).isoformat(), "elapsed_s": current_time - start,
                    "label": args.label, "root_pid": root, "root_alive": root in table,
                    "root_rss_mib": table.get(root, (0, 0, 0, ""))[1] / 1024,
                    "tree_rss_mib": sum(table[p][1] for p in members) / 1024,
                    "tree_cpu_percent": cpu / (current_time - previous_time) * 100 if previous else "",
                    "process_count": len(members)}
                writer.writerow(row); records.append(row)
                for p in members: inventory[str(p)] = {"root": root, "ppid": table[p][0], "command": table[p][3]}
            file.flush(); previous = {p: v[2] for p, v in table.items()}; previous_time = current_time
            if current_time >= deadline: break
            time.sleep(min(args.interval, max(0, deadline - time.monotonic())))
    (args.out / "processes.json").write_text(json.dumps(inventory, indent=2))
    summary = []
    for root in roots:
        values = [r for r in records if r["root_pid"] == root and r["root_alive"]]
        if not values: continue
        item = {"root_pid": root, "label": args.label, "samples": len(values)}
        for metric in ["root_rss_mib", "tree_rss_mib", "tree_cpu_percent"]:
            nums = [r[metric] for r in values if r[metric] != ""]
            if nums:
                item[metric + "_median"] = statistics.median(nums)
                item[metric + "_max"] = max(nums)
        summary.append(item)
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2))
    if args.footprint:
        footprints = []
        for root in roots:
            if root not in process_table(): continue
            completed = sp.run(["vmmap", "-summary", str(root)], capture_output=True, text=True, timeout=30)
            (args.out / f"vmmap-{root}.txt").write_text(completed.stdout + completed.stderr)
            fields = re.findall(r"^(Physical footprint(?: \(peak\))?):\s+(\S+)", completed.stdout, re.M)
            footprints.append({"pid": root, "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                               "fields": dict(fields), "exit": completed.returncode})
        (args.out / "footprints.json").write_text(json.dumps(footprints, indent=2))
    print(json.dumps(summary, indent=2))


def compare(args):
    baseline_meta = json.loads((args.baseline / "metadata.json").read_text())
    candidate_meta = json.loads((args.candidate / "metadata.json").read_text())
    for label in ["system", "chip", "ram_bytes", "fixture_specs", "fixture_fingerprints", "iterations", "modes", "tool_sha256", "viewport"]:
        if baseline_meta.get(label) != candidate_meta.get(label):
            print(f"WARNING: metadata differs: {label}", file=sys.stderr)
    old = {(r["scenario"], r["metric"]): r for r in json.loads((args.baseline / "summary.json").read_text())}
    new = json.loads((args.candidate / "summary.json").read_text())
    print("scenario,metric,old_median_ms,new_median_ms,median_change_percent,old_p95_ms,new_p95_ms,"
          "old_footprint_mib_max_after,new_footprint_mib_max_after,footprint_change_percent,"
          "old_process_peak_rss_mib,new_process_peak_rss_mib")
    for row in new:
        prior = old.get((row["scenario"], row["metric"]))
        if not prior: continue
        percent = (row["median_ms"] / prior["median_ms"] - 1) * 100
        old_memory = prior.get("footprint_mib_max_after", -1)
        new_memory = row.get("footprint_mib_max_after", -1)
        memory_change = f'{(new_memory / old_memory - 1) * 100:.1f}' if old_memory > 0 and new_memory >= 0 else ""
        print(f'{row["scenario"]},{row["metric"]},{prior["median_ms"]:.3f},{row["median_ms"]:.3f},'
              f'{percent:.1f},{prior["p95_ms"]:.3f},{row["p95_ms"]:.3f},'
              f'{old_memory:.3f},{new_memory:.3f},{memory_change},'
              f'{prior["process_peak_rss_mib"]:.3f},{row["process_peak_rss_mib"]:.3f}')


def ui_template(args):
    operations = ["launch_to_window", "open_to_log", "refresh", "search_recent", "search_old",
                  "commit_details", "diff_small", "diff_replace5000", "scroll_log", "switch_branch"]
    fields = ["app", "version", "scenario", "phase", "operation", "iteration", "start_ms", "ready_ms", "correct", "notes"]
    with args.out.open("x", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields); writer.writeheader()
        for app in ["GitDesk", "IDEA"]:
            for scenario in SPECS:
                for operation in operations:
                    for i in range(1, args.iterations + 1):
                        writer.writerow({"app": app, "scenario": scenario, "phase": "warm",
                                         "operation": operation, "iteration": i})
    print(args.out)


def diff_fixtures(base):
    base.mkdir(parents=True, exist_ok=True)
    for name in DIFFS:
        dest = base / name
        if dest.exists(): raise SystemExit(f"Refusing to overwrite {dest}; choose a fresh path")
        dest.mkdir()
        run(["git", "init", "-b", "main", dest])
        for key, value in [("user.name", "Benchmark"), ("user.email", "bench@example.test"),
                           ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")]:
            run(["git", "-C", dest, "config", key, value])
        lines = 10000 if "10000" in name else 5000 if "5000" in name else 1000
        before = "".join(f"original line {i} value = {i}\n" for i in range(lines)).encode()
        if "replace" in name: after = "".join(f"replacement {i} completely different\n" for i in range(lines)).encode()
        elif "whitespace" in name: after = before.replace(b" = ", b"    = ")
        elif name == "binary": after = bytes([0, 1, 2, 3])
        elif name == "bytes-limit": after = b"A" * 2000001
        elif name == "lines-limit": after = b"x\n" * 20001
        else: after = before.replace(b"line 500 ", b"line CHANGED ")
        file = dest / "sample.txt"; file.write_bytes(before)
        run(["git", "-C", dest, "add", "sample.txt"])
        env = dict(os.environ, GIT_AUTHOR_DATE="1700000000 +0000", GIT_COMMITTER_DATE="1700000000 +0000")
        run(["git", "-C", dest, "commit", "-m", "Diff baseline"], env=env)
        file.write_bytes(after)
        print(dest)


def ui_summary(args):
    groups = {}
    with args.input.open(newline="") as file:
        for row in csv.DictReader(file):
            if not row["start_ms"] and not row["ready_ms"] and not row["correct"]: continue
            key = tuple(row[k] for k in ["app", "version", "scenario", "phase", "operation"])
            group = groups.setdefault(key, {"ok": [], "invalid_or_failed": 0})
            try:
                elapsed = float(row["ready_ms"]) - float(row["start_ms"])
                if not math.isfinite(elapsed) or elapsed < 0 or row["correct"].lower() != "yes": raise ValueError()
            except ValueError:
                group["invalid_or_failed"] += 1; continue
            group["ok"].append(elapsed)
    print("app,version,scenario,phase,operation,n,median_ms,p95_ms,invalid_or_failed")
    for key, group in groups.items():
        values = sorted(group["ok"])
        print(",".join(key) + f',{len(values)},' +
              (f'{statistics.median(values):.3f},{values[math.ceil(.95*len(values))-1]:.3f}' if values else ",") +
              f',{group["invalid_or_failed"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    fixture = sub.add_parser("fixtures"); fixture.add_argument("--fixtures", type=Path, required=True)
    diff_fixture = sub.add_parser("diff-fixtures"); diff_fixture.add_argument("--fixtures", type=Path, required=True)
    bench = sub.add_parser("run")
    bench.add_argument("--fixtures", type=Path, required=True); bench.add_argument("--out", type=Path, required=True)
    bench.add_argument("--iterations", type=int, default=20); bench.add_argument("--timeout", type=float, default=180)
    bench.add_argument("--scenarios", nargs="+", choices=list(SPECS), default=list(SPECS))
    bench.add_argument("--modes", nargs="+", choices=["core", "ui", "diff"], default=["core", "ui", "diff"])
    bench.add_argument("--real-repo", type=Path)
    bench.add_argument("--before-sources", type=Path, help="build a frozen Sources snapshot with the current measurement harness")
    sampler = sub.add_parser("sample")
    sampler.add_argument("--pid", type=int, action="append"); sampler.add_argument("--seconds", type=float, default=60)
    sampler.add_argument("--interval", type=float, default=.2); sampler.add_argument("--out", type=Path, required=True)
    sampler.add_argument("--label", default="idle")
    sampler.add_argument("--footprint", action="store_true", help="save a main-process vmmap snapshot after sampling")
    comparison = sub.add_parser("compare")
    comparison.add_argument("baseline", type=Path); comparison.add_argument("candidate", type=Path)
    template = sub.add_parser("ui-template")
    template.add_argument("--out", type=Path, required=True); template.add_argument("--iterations", type=int, default=20)
    ui_results = sub.add_parser("ui-summary"); ui_results.add_argument("input", type=Path)
    args = parser.parse_args()
    if args.command == "fixtures": fixtures(args.fixtures)
    elif args.command == "diff-fixtures": diff_fixtures(args.fixtures)
    elif args.command == "run": benchmarks(args)
    elif args.command == "sample": sample(args)
    elif args.command == "ui-template": ui_template(args)
    elif args.command == "ui-summary": ui_summary(args)
    else: compare(args)


if __name__ == "__main__": main()
