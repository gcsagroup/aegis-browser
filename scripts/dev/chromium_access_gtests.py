#!/usr/bin/env python3
"""Run the Access GTest targets in a fixed, patched Chromium checkout."""

from __future__ import annotations

import argparse
import datetime as dt
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
BROWSER = ROOT / "apps" / "browser"
ARGS_FILE = BROWSER / "args" / "aegis.gn"
COMMIT_FILE = BROWSER / "CHROMIUM_COMMIT"
VERSION_FILE = BROWSER / "CHROMIUM_VERSION"
PATCH_DIR = BROWSER / "patches"
V8_PATCH_DIR = PATCH_DIR / "v8"
OVERLAY_DIR = BROWSER / "overlay"

TARGETS = (
    ("//components/aegis_access:access_identity_generation_state_unittests",
     "components/aegis_access:access_identity_generation_state_unittests",
     "access_identity_generation_state_unittests"),
    ("//components/aegis_access:access_proxy_selection_generation_state_unittests",
     "components/aegis_access:access_proxy_selection_generation_state_unittests",
     "access_proxy_selection_generation_state_unittests"),
    ("//components/aegis_access:access_base_proxy_config_generation_state_unittests",
     "components/aegis_access:access_base_proxy_config_generation_state_unittests",
     "access_base_proxy_config_generation_state_unittests"),
    ("//components/aegis_access:request_generation_tuple_builder_unittests",
     "components/aegis_access:request_generation_tuple_builder_unittests",
     "request_generation_tuple_builder_unittests"),
    ("//components/aegis_access:browser_request_metadata_seed_unittests",
     "components/aegis_access:browser_request_metadata_seed_unittests",
     "browser_request_metadata_seed_unittests"),
    ("//components/aegis_access:request_ownership_registry_unittests",
     "components/aegis_access:request_ownership_registry_unittests",
     "request_ownership_registry_unittests"),
    ("//components/aegis_access:policy_publication_ack_tracker_unittests",
     "components/aegis_access:policy_publication_ack_tracker_unittests",
     "policy_publication_ack_tracker_unittests"),
    ("//components/aegis_access:request_dispatch_gate_unittests",
     "components/aegis_access:request_dispatch_gate_unittests",
     "request_dispatch_gate_unittests"),
    ("//components/aegis_access:aegis_access_unittests",
     "components/aegis_access:aegis_access_unittests",
     "aegis_access_unittests"),
    ("//chrome/browser/aegis/access:access_service_coordinator_unittests",
     "chrome/browser/aegis/access:access_service_coordinator_unittests",
     "access_service_coordinator_unittests"),
    ("//chrome/browser/aegis/access:access_browser_request_adapter_unittests",
     "chrome/browser/aegis/access:access_browser_request_adapter_unittests",
     "access_browser_request_adapter_unittests"),
    ("//chrome/browser/aegis/access:access_request_dispatch_state_unittests",
     "chrome/browser/aegis/access:access_request_dispatch_state_unittests",
     "access_request_dispatch_state_unittests"),
    ("//chrome/browser/aegis/access:access_identity_generation_source_unittests",
     "chrome/browser/aegis/access:access_identity_generation_source_unittests",
     "access_identity_generation_source_unittests"),
    ("//chrome/browser/aegis/access:access_proxy_selection_generation_source_unittests",
     "chrome/browser/aegis/access:access_proxy_selection_generation_source_unittests",
     "access_proxy_selection_generation_source_unittests"),
    ("//chrome/browser/aegis/access:access_network_context_transport_unittests",
     "chrome/browser/aegis/access:access_network_context_transport_unittests",
     "access_network_context_transport_unittests"),
    ("//chrome/browser/aegis/access:access_rule_store_unittests",
     "chrome/browser/aegis/access:access_rule_store_unittests",
     "access_rule_store_unittests"),
    ("//chrome/browser/aegis/access:access_published_request_runtime_unittests",
     "chrome/browser/aegis/access:access_published_request_runtime_unittests",
     "access_published_request_runtime_unittests"),
)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def read_pin(path: Path) -> str:
    for raw in path.read_text(encoding="utf-8").splitlines():
        value = raw.strip()
        if value and not value.startswith("#"):
            return value
    raise ValueError(f"pin file is empty: {path}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def tool(name: str, env: dict[str, str] | None = None) -> str:
    search_path = env.get("PATH") if env else None
    found = shutil.which(name, path=search_path)
    if not found:
        raise ValueError(f"required tool is missing: {name}")
    return str(Path(found).resolve(strict=True))


def command_argv(command: Iterable[str]) -> list[str]:
    if isinstance(command, (str, bytes)):
        raise ValueError("commands must be an argv sequence, never a shell string")
    argv = list(command)
    if not argv or any(not isinstance(arg, str) or "\0" in arg for arg in argv):
        raise ValueError("command arguments must be non-NUL strings")
    executable = Path(argv[0])
    if not executable.is_absolute():
        raise ValueError("command executable must be an absolute path")
    resolved = executable.resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError(f"command is not executable: {resolved}")
    return [str(resolved), *argv[1:]]


def run_process(command: Iterable[str], *, cwd=None, env=None,
                output=subprocess.PIPE, input_text=None, check=True):
    """Execute developer-selected tools, never shell text or untrusted tool choices."""
    argv = command_argv(command)
    # PATH/DEPOT_TOOLS_DIR and explicit GN/Ninja paths are trusted local configuration.
    # command_argv validates an absolute executable and literal non-NUL arguments;
    # the real-process regression proves shell metacharacters stay literal. Quoting
    # argv elements would corrupt them. Review: 7805e05, B603 and the exact rule below.
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
    return subprocess.run(argv, cwd=cwd, env=env, input=input_text, stdout=output,  # nosec B603
                          stderr=subprocess.STDOUT, text=True, shell=False, check=check)


def git(repo: Path, *args: str, env: dict[str, str] | None = None) -> str:
    env = env if env is not None else execution_env()
    return run_process([tool("git", env), "-C", str(repo), *args], env=env).stdout.strip()


def is_ancestor(repo: Path, base: str, head: str) -> bool:
    env = execution_env()
    result = run_process(
        [tool("git", env), "-C", str(repo), "merge-base", "--is-ancestor", base, head],
        env=env, check=False,
    )
    if result.returncode not in (0, 1):
        result.check_returncode()
    return result.returncode == 0


def series(directory: Path) -> list[str]:
    path = directory / "series"
    names = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not names or len(names) != len(set(names)):
        raise ValueError(f"patch series is empty or duplicated: {path}")
    for name in names:
        if Path(name).name != name or ".." in name or "\\" in name:
            raise ValueError(f"unsafe patch path: {name}")
        if not (directory / name).is_file():
            raise ValueError(f"patch is missing: {directory / name}")
    return names


def require_clean(repo: Path, label: str, *, ignore_submodules: bool = False) -> None:
    args = ["status", "--porcelain"]
    if ignore_submodules:
        args.append("--ignore-submodules=all")
    if git(repo, *args):
        raise ValueError(f"{label} checkout is dirty: {repo}")


def overlay_entry(repo: Path, overlay: Path, path: Path, gitlinks: set[str]) -> str:
    if path.is_symlink():
        raise ValueError(f"overlay symlinks are not supported: {path}")
    if not path.is_file():
        return ""
    relative = path.relative_to(overlay).as_posix()
    if ".git" in path.relative_to(overlay).parts:
        raise ValueError(f"unsafe overlay path: {relative}")
    for link in gitlinks:
        if relative == link or relative.startswith(link + "/"):
            if relative.startswith("v8/"):
                return ""  # Verified independently in the V8 repository.
            raise ValueError(f"overlay maps into an unsupported submodule: {relative}")
    blob = git(repo, "hash-object", "-w", "--", str(path))
    mode = "100755" if path.stat().st_mode & 0o111 else "100644"
    return f"{mode} {blob}\t{relative}\0"


def apply_overlay(repo: Path, overlay: Path, env: dict[str, str]) -> None:
    gitlinks = {row.split("\t", 1)[1] for row in git(repo, "ls-files", "--stage", env=env).splitlines()
                if row.startswith("160000 ")}
    entries = (overlay_entry(repo, overlay, path, gitlinks) for path in sorted(overlay.rglob("*")))
    run_process([tool("git", env), "-C", str(repo), "update-index", "-z", "--index-info"],
                env=env, input_text="".join(entries))


def replay_tree(repo: Path, base: str, patches: Path, overlay: Path | None = None) -> str:
    fd, index_name = tempfile.mkstemp(prefix="aegis-access-tree-")
    os.close(fd)
    index = Path(index_name)
    index.unlink()
    env = dict(execution_env(), GIT_INDEX_FILE=str(index))
    try:
        git(repo, "read-tree", base, env=env)
        for name in series(patches):
            git(
                repo,
                "apply",
                "--cached",
                "--whitespace=nowarn",
                str(patches / name),
                env=env,
            )
        if overlay is not None:
            apply_overlay(repo, overlay, env)
        return git(repo, "write-tree", env=env)
    finally:
        index.unlink(missing_ok=True)


def verify_tree(repo: Path, base: str, patches: Path, overlay: Path | None = None) -> str:
    expected = replay_tree(repo, base, patches, overlay)
    actual = git(repo, "rev-parse", "HEAD^{tree}")
    if expected != actual:
        raise ValueError(
            f"patched source tree does not match the current patch series/overlay: {repo}"
        )
    return actual


def gtest_names(output: str) -> list[str]:
    names = []
    suite = ""
    for line in output.splitlines():
        value = line.split("#", 1)[0].strip()
        if not line.startswith(" ") and value.endswith("."):
            suite = value
        elif line.startswith("  ") and value and suite:
            names.append(suite + value)
    return names


def count_gtests(output: str) -> int:
    return len(gtest_names(output))


def runtime_test_count(summary: Path, expected: list[str]) -> int:
    """Require a fresh Chromium launcher receipt for every enabled listed test."""
    data = json.loads(summary.read_text(encoding="utf-8"))
    iterations = data.get("per_iteration_data")
    if not isinstance(iterations, list) or len(iterations) != 1:
        raise ValueError("GTest runtime must report exactly one iteration")
    results = iterations[0]
    if not isinstance(results, dict) or not results or set(results) != set(expected):
        raise ValueError("GTest runtime does not match the nonzero listed test set")
    for name, attempts in results.items():
        if (not isinstance(attempts, list) or len(attempts) != 1
                or not isinstance(attempts[0], dict)
                or attempts[0].get("status") != "SUCCESS"):
            raise ValueError(f"GTest did not execute successfully exactly once: {name}")
    if set(data.get("global_tags", [])) & {
            "EARLY_SUMMARY", "CAUGHT_TERMINATION_SIGNAL", "BROKEN_TEST_EARLY_EXIT"}:
        raise ValueError("GTest runtime receipt is incomplete")
    return len(results)


def run_logged(
    command: Iterable[str],
    *,
    cwd: Path,
    env: dict[str, str],
    log: Path,
) -> None:
    argv = list(command)
    started = now()
    with log.open("w", encoding="utf-8") as stream:
        completed = run_process(argv, cwd=cwd, env=env, output=stream, check=False)
    write_json(log.with_suffix(log.suffix + ".json"), {
        "command": argv, "cwd": str(cwd), "startedAt": started,
        "finishedAt": now(), "exitCode": completed.returncode,
    })
    completed.check_returncode()


@dataclass
class TargetContext:
    src: Path
    out: Path
    report: Path
    env: dict[str, str]
    ninja: str
    jobs: int
    build_jobs: int = 4


def build_target(target, context: TargetContext, row, save) -> Path:
    label, ninja_target, binary_name = target
    row.update(label=label, ninjaTarget=ninja_target, binary=binary_name,
               build="RUNNING", listing="NOT_RUN", runtime="NOT_RUN")
    save()
    log = context.report / f"{binary_name}.build.log"
    run_logged([context.ninja, "-C", str(context.out), f"-j{context.build_jobs}", ninja_target],
               cwd=context.src, env=context.env, log=log)
    binary = context.out / binary_name
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"compiled GTest binary is missing: {binary}")
    row.update(build="PASS", binarySha256=sha256(binary), buildLog=log.name)
    return binary


def list_target(binary: Path, context: TargetContext, row, save) -> None:
    row["listing"] = "RUNNING"
    save()
    log = context.report / f"{binary.name}.list.log"
    run_logged([str(binary), "--gtest_list_tests", "--gtest_filter=*"],
               cwd=context.src, env=context.env, log=log)
    names = gtest_names(log.read_text(encoding="utf-8"))
    enabled = [name for name in names
               if not any(part.startswith("DISABLED_") for part in name.replace("/", ".").split("."))]
    if not enabled:
        raise ValueError(f"GTest target reported zero tests: {row['label']}")
    if len(names) != len(set(names)):
        raise ValueError(f"GTest listing contains duplicate tests: {row['label']}")
    row.update(listing="PASS", listedTests=len(names), expectedTests=enabled, listLog=log.name)


def run_target(target, context: TargetContext, evidence=None, save=None) -> dict[str, object]:
    row = evidence if evidence is not None else {}
    persist = save if save is not None else lambda: None
    binary = build_target(target, context, row, persist)
    list_target(binary, context, row, persist)
    row["runtime"] = "RUNNING"
    persist()
    log = context.report / f"{binary.name}.test.log"
    summary = context.report / f"{binary.name}.runtime.json"
    summary.unlink(missing_ok=True)  # A zero-exit early return must not reuse an old receipt.
    run_logged([str(binary), f"--test-launcher-jobs={context.jobs}",
                "--test-launcher-retry-limit=0", "--test-launcher-print-test-stdio=always",
                "--test-launcher-total-shards=1", "--test-launcher-shard-index=0",
                "--gtest_filter=*", "--gtest_repeat=1", "--gtest_also_run_disabled_tests=0",
                f"--test-launcher-summary-output={summary}"],
               cwd=context.src, env=context.env, log=log)
    tests = runtime_test_count(summary, row["expectedTests"])
    if sha256(binary) != row["binarySha256"]:
        raise ValueError(f"test binary changed during execution: {binary}")
    row.update(runtime="PASS", result="PASS", tests=tests, testLog=log.name,
               runtimeSummary=summary.name, runtimeSummarySha256=sha256(summary))
    return row


def resolve_chromium_root() -> Path:
    explicit = os.environ.get("CHROMIUM_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    marker = BROWSER / ".chromium-root"
    if marker.is_file():
        return Path(marker.read_text(encoding="utf-8").strip()).expanduser().resolve()
    return (Path.home() / "Projects" / "GCSA-aegis-chromium").resolve()


def execution_env() -> dict[str, str]:
    env = dict(os.environ)
    depot = Path(
        os.environ.get("DEPOT_TOOLS_DIR", str(Path.home() / "depot_tools"))
    ).expanduser()
    if depot.is_dir():
        env["PATH"] = str(depot.resolve()) + os.pathsep + env.get("PATH", "")
    env.setdefault("DEPOT_TOOLS_UPDATE", "0")
    return env


def acquire_lock(src: Path) -> Path:
    parent = src.parent
    legacy_lock = parent / ".aegis-access-gtest-lock"
    if legacy_lock.exists():
        raise ValueError(f"an older Access GTest run is already active: {legacy_lock}")
    # Use the same atomic lock as apps/browser/scripts/ci/candidate.py, in both
    # launch orders. Checking its existence while acquiring a different lock races.
    lock = parent / ".aegis-ci-lock"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError(f"Chromium candidate build or Access GTest run is already active: {lock}") from error
    return lock


def write_summary(result: dict[str, object], report: Path) -> None:
    lines = [
        "# Fixed Chromium Access GTest evidence",
        "",
        f"- Result: {result.get('status')}",
        f"- Product HEAD: {result.get('productHead')}",
        f"- Chromium: {result.get('chromiumVersion')} ({result.get('chromiumPin')})",
        f"- Chromium HEAD: {result.get('chromiumHead')}",
        f"- V8 base: {result.get('v8Base')}",
        f"- Targets: {result.get('targetCount', 0)}",
        f"- Tests: {result.get('testCount', 0)}",
        "",
        "| Target | Tests | Result |",
        "| --- | ---: | --- |",
    ]
    for item in result.get("targets", []):
        lines.append(f"| {item['label']} | {item['tests']} | {item['result']} |")
    if result.get("error"):
        lines += ["", f"Failure: {result['error']}"]
    (report / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def record_error(error: Exception, path: Path) -> None:
    parts = [str(error)]
    for attr in ("output", "stderr"):
        value = getattr(error, attr, None)
        if value:
            parts.append(value.decode(errors="replace") if isinstance(value, bytes) else str(value))
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")
    write_json(path.with_suffix(path.suffix + ".json"), {
        "command": getattr(error, "cmd", None),
        "exitCode": getattr(error, "returncode", None),
    })


def verify_stable(sources: list[tuple[Path, str, str]], args_file: Path, args_hash: str) -> None:
    for repo, label, head in sources:
        require_clean(repo, label, ignore_submodules=True)
        if git(repo, "rev-parse", "HEAD") != head:
            raise ValueError(f"{label} HEAD changed during execution")
    if sha256(args_file) != args_hash:
        raise ValueError("GN arguments changed during execution")


def verify_sources(src: Path) -> dict[str, object]:
    require_clean(ROOT, "product", ignore_submodules=True)
    product_head = git(ROOT, "rev-parse", "HEAD")
    product_tree = git(ROOT, "rev-parse", product_head + "^{tree}")
    require_clean(src, "Chromium", ignore_submodules=True)
    pin = read_pin(COMMIT_FILE)
    head = git(src, "rev-parse", "HEAD")
    if not is_ancestor(src, pin, head):
        raise ValueError("pinned Chromium commit is not an ancestor of the checkout")
    tree = verify_tree(src, pin, PATCH_DIR, OVERLAY_DIR)
    v8 = src / "v8"
    v8_base = git(src, "rev-parse", pin + ":v8")
    require_clean(v8, "V8", ignore_submodules=True)
    v8_head = git(v8, "rev-parse", "HEAD")
    if not is_ancestor(v8, v8_base, v8_head):
        raise ValueError("pinned V8 commit is not an ancestor of the checkout")
    v8_tree = verify_tree(v8, v8_base, V8_PATCH_DIR, OVERLAY_DIR / "v8")
    require_clean(ROOT, "product", ignore_submodules=True)
    if git(ROOT, "rev-parse", "HEAD") != product_head:
        raise ValueError("product HEAD changed during source admission")
    return {"productHead": product_head, "productTree": product_tree,
            "chromiumVersion": read_pin(VERSION_FILE), "chromiumPin": pin,
            "chromiumHead": head, "chromiumTree": tree,
            "sourceComposition": "pinned base + ordered patches + exact product overlay",
            "v8Base": v8_base, "v8Head": v8_head, "v8Tree": v8_tree}


def prepare_build(options, src: Path, report: Path, result):
    result.update(verify_sources(src))
    out = Path(options.out).expanduser().resolve() if options.out else src / "out" / "AegisAccessTests"
    if not out.is_relative_to(src / "out"):
        raise ValueError("output must be inside this candidate's src/out")
    args_file = Path(options.args_file).expanduser().resolve() if options.args_file else ARGS_FILE
    args_text = args_file.read_text(encoding="utf-8")
    args_hash = sha256(args_file)
    (report / "args.gn").write_text(args_text, encoding="utf-8")
    free_gib = shutil.disk_usage(src).free / 1024**3
    if free_gib < options.min_free_gib:
        raise ValueError(f"not enough free space: {free_gib:.1f} GiB")
    env = execution_env()
    gn = tool(options.gn or "gn", env)
    ninja = tool(options.ninja or "autoninja", env)
    result.update(argsFile=str(args_file), argsSha256=args_hash,
                  productArgsSha256=sha256(ARGS_FILE), outDir=str(out),
                  tools={"gn": {"path": gn, "sha256": sha256(Path(gn))},
                         "build": {"path": ninja, "sha256": sha256(Path(ninja))}},
                  freeGiBAtStart=round(free_gib, 2), inputs=input_hashes(), status="generating")
    sources = [(ROOT, "product", result["productHead"]),
               (src, "Chromium", result["chromiumHead"]), (src / "v8", "V8", result["v8Head"])]
    context = TargetContext(src, out, report, env, ninja, options.jobs, options.build_jobs)
    return context, (sources, args_file, args_hash), [gn, "gen", str(out), f"--args={args_text}", "--check"]


def input_hashes() -> dict[str, str]:
    return {str(path.relative_to(BROWSER)): sha256(path)
            for directory in (PATCH_DIR, OVERLAY_DIR)
            for path in sorted(directory.rglob("*")) if path.is_file()}


def run_targets(context, targets, selected, result, state) -> None:
    result["status"] = "testing"
    for target, row in zip(targets, result["targets"]):
        if target[2] not in selected:
            continue
        row["result"] = "BUILDING"
        write_json(state, result)
        try:
            run_target(target, context, row, lambda: write_json(state, result))
        except Exception as error:
            row.update(result="FAIL", error=str(error))
            for stage in ("build", "listing", "runtime"):
                if row.get(stage) == "RUNNING":
                    row[stage] = "FAIL"
            raise
        result["targetCount"] += 1
        result["testCount"] += row["tests"]
        write_json(state, result)
    result["status"] = "PASS" if len(selected) == len(TARGETS) else "PARTIAL_PASS"


def finish_run(result, stable_inputs, report, state) -> None:
    primary_failed = "error" in result
    stability_error = None
    if stable_inputs is not None:
        try:
            verify_stable(*stable_inputs)
            result["sourceStable"] = True
        except Exception as error:
            stability_error = error
            result.update(sourceStable=False, status="FAIL", stabilityError=str(error))
            record_error(error, report / "source-stability.log")
    result["finishedAt"] = now()
    write_json(state, result)
    write_summary(result, report)
    if stability_error is not None and not primary_failed:
        raise stability_error


def execute(options: argparse.Namespace) -> Path:
    src = resolve_chromium_root() / "src"
    if not (src / "BUILD.gn").is_file():
        raise ValueError(f"fixed Chromium src is missing: {src}")
    report = (Path(options.report_dir).expanduser().resolve() if options.report_dir
              else ROOT / ".artifacts" / "chromium-native" / dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    report.mkdir(parents=True, exist_ok=True)
    state = report / "result.json"
    selected = set(options.target or [t[2] for t in TARGETS])
    targets = sorted(TARGETS, key=lambda t: t[2] != "access_service_coordinator_unittests")
    rows = [{"label": t[0], "binary": t[2], "tests": None,
             "binarySha256": None, "result": "NOT_RUN"} for t in targets]
    result = {"startedAt": now(), "status": "preflight", "targets": rows,
              "targetCount": 0, "testCount": 0, "selectedTargets": sorted(selected)}
    lock = acquire_lock(src)
    stable_inputs = None
    try:
        write_json(state, result)
        context, stable_inputs, command = prepare_build(options, src, report, result)
        write_json(state, result)
        run_logged(command, cwd=src, env=context.env, log=report / "gn.log")
        run_targets(context, targets, selected, result, state)
        return report
    except Exception as error:
        result.update(status="FAIL", error=str(error))
        record_error(error, report / "failure.log")
        raise
    finally:
        try:
            finish_run(result, stable_inputs, report, state)
        finally:
            lock.rmdir()


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--out", help="isolated Chromium output directory")
    value.add_argument("--gn", help="explicit executable GN path, e.g. candidate buildtools/mac/gn")
    value.add_argument("--ninja", help="explicit executable Ninja path; default uses autoninja")
    value.add_argument("--args-file", help="explicit local GN args; recorded separately from product args")
    value.add_argument("--target", action="append", choices=[t[2] for t in TARGETS],
                       help="run selected executables; omitted targets stay NOT_RUN")
    value.add_argument("--build-jobs", type=int, default=4, help="bounded Ninja parallelism")
    value.add_argument("--report-dir", help="evidence output directory")
    value.add_argument(
        "--jobs",
        type=int,
        default=int(os.environ.get("AEGIS_CHROMIUM_TEST_JOBS", "2")),
        help="Chromium test launcher jobs",
    )
    value.add_argument(
        "--min-free-gib",
        type=int,
        default=int(os.environ.get("AEGIS_CHROMIUM_MIN_FREE_GIB", "30")),
        help="minimum free GiB required before building",
    )
    return value


def main() -> int:
    options = parser().parse_args()
    if options.jobs <= 0 or options.build_jobs <= 0 or options.min_free_gib <= 0:
        raise SystemExit("--jobs and --min-free-gib must be positive")
    try:
        report = execute(options)
    except Exception as error:
        print(f"FAIL: {error}", file=os.sys.stderr)
        return 1
    print(f"{json.loads((report / 'result.json').read_text())['status']}: fixed Chromium Access GTests; evidence: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
