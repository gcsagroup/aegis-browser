#!/usr/bin/python3
import json
import os
import sys
import signal
import subprocess
import time
from pathlib import Path

# AEGIS_FORK_INTERNAL_ADMISSION
REPOSITORY = "quinn521/aegis-browser"
REPOSITORY_ID = 1363949860
WORKFLOW_FILES = {
    "quality.yml",
    "cpp-unit-tests.yml",
    "ios-release-validation.yml",
    "ios-delivery.yml",
    "ios-delivery-full.yml",
    "ios-fork-access.yml",
    "macos-delivery.yml",
}
IOS_JOBS = {
    "ios-archive",
    "cloud-poc",
    "ios-package",
    "store",
    "upload-new",
    "ios-draft",
}
TEST_JOBS = {"quality", "quality-summary", "c++-unit-tests"}
INTERNAL_WORKFLOW_FILES = {"ios-fork-access.yml", "macos-delivery.yml"}
INTERNAL_JOBS = {"simulator", "internal", "access-tests", "package", "internal-dmg"}
ALLOWED_BRANCH_REFS = {"refs/heads/main", "refs/heads/develop"}
DEVELOPMENT_REFS = ALLOWED_BRANCH_REFS | {"refs/heads/promote/ios-access-closed-loop-2cd7"}


def workflow_file_name(workflow_ref):
    if "/.github/workflows/" not in workflow_ref or "@" not in workflow_ref:
        return ""
    return workflow_ref.split("/.github/workflows/", 1)[1].split("@", 1)[0]


def repository_id(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return value


def check():
    if Path("/Users/quinn/actions-runner-aegis/evidence/admission-smoke-deny").exists():
        raise ValueError("controlled admission rejection smoke")
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError("repository mismatch")
    event = os.environ.get("GITHUB_EVENT_NAME")
    if event not in {"pull_request", "push", "workflow_dispatch"}:
        raise ValueError("unsupported event")
    workflow = os.environ.get("GITHUB_WORKFLOW_REF", "")
    file_name = workflow_file_name(workflow)
    if file_name not in WORKFLOW_FILES:
        raise ValueError("unsupported test workflow")
    job = os.environ.get("GITHUB_JOB")
    if file_name in {"quality.yml", "cpp-unit-tests.yml"}:
        if job not in TEST_JOBS:
            raise ValueError("unsupported test job")
    elif file_name in INTERNAL_WORKFLOW_FILES:
        if job not in INTERNAL_JOBS:
            raise ValueError("unsupported internal job")
    elif job not in IOS_JOBS:
        raise ValueError("unsupported ios job")
    payload = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repository = payload.get("repository", {})
    if repository_id(repository.get("id")) != REPOSITORY_ID or repository.get("full_name") != REPOSITORY:
        raise ValueError("event repository mismatch")
    ref = os.environ.get("GITHUB_REF")
    if event == "pull_request":
        head = payload.get("pull_request", {}).get("head", {}).get("repo", {})
        if repository_id(head.get("id")) != REPOSITORY_ID or head.get("full_name") != REPOSITORY:
            raise ValueError("external fork PR rejected")
        base = (payload.get("pull_request") or {}).get("base") or {}
        if base.get("ref") not in {"main", "develop"}:
            raise ValueError("unsupported pull_request base")
    elif event == "push" and isinstance(ref, str) and ref.startswith("refs/tags/candidate/ios/"):
        if file_name not in {"ios-delivery.yml", "ios-delivery-full.yml"}:
            raise ValueError("unsupported candidate tag workflow")
    elif file_name in INTERNAL_WORKFLOW_FILES or file_name in {"quality.yml", "cpp-unit-tests.yml"}:
        if ref not in DEVELOPMENT_REFS:
            raise ValueError("unsupported test branch")
    elif ref not in ALLOWED_BRANCH_REFS:
        raise ValueError("unsupported test branch")


def abort_worker(allowed=None):
    if allowed is None:
        allowed = {
            str((Path("/Users/quinn/actions-runner-aegis/slots") / slot / "bin/Runner.Worker").resolve())
            for slot in ("01", "02")
        }
    pid = os.getppid()
    for _ in range(8):
        if pid <= 1:
            break
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "ppid=,uid=,comm="],
            capture_output=True,
            text=True,
            check=True,
        )
        fields = result.stdout.strip().split(None, 2)
        if len(fields) != 3:
            break
        parent, uid, executable = fields
        if int(uid) != os.getuid():
            break
        if str(Path(executable).resolve()) in allowed:
            print(f"Aborting owning Runner.Worker {pid} before any workflow step", file=sys.stderr, flush=True)
            os.kill(pid, signal.SIGKILL)
            return
        pid = int(parent)
    raise RuntimeError("owning Runner.Worker could not be verified")


def main():
    try:
        check()
    except (KeyError, OSError, ValueError, TypeError, AttributeError) as exc:
        print(f"Aegis test runner admission rejected: {exc}", file=sys.stderr, flush=True)
        if sys.argv[1:] == ["--check-only"]:
            return 1
        try:
            abort_worker()
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as abort_error:
            print(f"Admission blocked pending service inspection: {abort_error}", file=sys.stderr, flush=True)
            while True:
                time.sleep(3600)
        return 1
    print("Aegis test runner admission passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
