#!/usr/bin/env python3
"""Fail closed unless the expected AegisTests Access cases actually ran."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CASE_PATTERNS = (
    re.compile(
        r"Test Case '-\[AegisTests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped)"
    ),
    re.compile(
        r"Test case '([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\(\)' (passed|failed|skipped)"
    ),
)
FUNC_RE = re.compile(r"^\s+func (test[A-Za-z0-9_]+)\(")
CLASS_RE = re.compile(r"^(?:final )?class ([A-Za-z0-9_]+)\b")
OPERATOR_CLASSES = {"AccessEmbeddedCoreLiveTests", "AccessTestNodeDeviceTests", "AccessPhysicalSOCKSAdmissionTests",
                    "AccessAccountAlphaLiveTests"}
# These cases belong to the separately provisioned account and relay harnesses.
OPERATOR_METHODS = {
    "AccessAccountRefreshTests": {"testQuotaRefreshCannotCancelQueuedProxySelection",
                                  "testSignOutAndRebindCannotReviveQueuedProxySelection"},
    "AccessAccountSessionTests": {
        "testSimulatorProductEntryAgainstProvisionedAccountService", "testReplacedSheetRefusesTransferAfterAsyncIssuance",
        "testDelayedIssuanceCannotRevokeReplacement", "testManagedRegularAndExplicitPrivateDownloadAndLiveLogout",
        "testSignedOutQuotaPollingPreservesIndependentPrivateDownload", "testQueuedProtectedDownloadsKeepOnlyTheirLiveAuthorization",
        "testSlowProtectedDownloadExtendsOnlyItsActiveLease", "testDeniedRenewalStopsSlowProtectedDownloadAtOriginalDeadline",
        "testClosingWindowRevokesLivePaidDownloadWhileDisposingWebKitTab",
    },
    "AccessSubscriptionUsageTests": {"testAuthorizedSharedAccountFetchesNodesAndDrivesRealCore"},
}


def source_cases(roots: list[Path]):
    paths: list[Path] = []
    for root in roots:
        if root.is_file():
            paths.append(root)
        else:
            paths.extend(sorted(root.rglob("*.swift")))
    for path in paths:
        current = ""
        for line in path.read_text(encoding="utf-8").splitlines():
            class_match = CLASS_RE.match(line)
            if class_match:
                current = class_match.group(1)
                continue
            func_match = FUNC_RE.match(line)
            if func_match and current:
                yield path, current, func_match.group(1)


def expected_cases(roots: list[Path]) -> set[tuple[str, str]]:
    return {(cls, method) for _, cls, method in source_cases(roots)}


def select_cases(roots: list[Path], requested: str):
    suites = {}
    for path, cls, method in source_cases(roots):
        if cls.startswith("Access") or "Access" in path.name:
            suites.setdefault(cls, set()).add(method)
    classes = (dict.fromkeys(cls.strip() for cls in requested.split(",") if cls.strip()) if requested
               else [cls for cls in suites if cls not in OPERATOR_CLASSES])
    selectors, expected = [], set()
    for cls in classes:
        if cls not in suites:
            raise ValueError(f"unknown Access test class: {cls}")
        all_methods = suites[cls]
        active = all_methods if requested else all_methods - OPERATOR_METHODS.get(cls, set())
        if active == all_methods:
            selectors.append(cls)
        else:
            selectors.extend(f"{cls}/{method}" for method in sorted(active))
        expected.update((cls, method) for method in active)
    if not expected:
        raise ValueError("Access test case list is empty")
    return selectors, expected


def observed_cases(log_text: str) -> dict[tuple[str, str], str]:
    observed: dict[tuple[str, str], str] = {}
    for pattern in CASE_PATTERNS:
        for match in pattern.finditer(log_text):
            observed[(match.group(1), match.group(2))] = match.group(3)
    return observed


def evaluate(expected: set[tuple[str, str]], observed: dict[tuple[str, str], str], status: int) -> list[str]:
    errors: list[str] = []
    if status != 0:
        errors.append(f"xcodebuild exit {status}")
    if not expected:
        errors.append("expected test list is empty")
    missing = sorted(expected - observed.keys())
    failed = sorted(key for key, outcome in observed.items() if outcome == "failed" and key in expected)
    skipped = sorted(key for key, outcome in observed.items() if outcome == "skipped" and key in expected)
    if missing:
        errors.append("missing: " + ", ".join(f"{cls}/{method}" for cls, method in missing))
    if failed:
        errors.append("failed: " + ", ".join(f"{cls}/{method}" for cls, method in failed))
    if skipped:
        errors.append("skipped: " + ", ".join(f"{cls}/{method}" for cls, method in skipped))
    if not observed:
        errors.append("log recorded zero Access test cases")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path)
    parser.add_argument("--status", type=int)
    parser.add_argument("--root", type=Path, action="append", required=True)
    parser.add_argument("--class", dest="classes", action="append")
    parser.add_argument("--selection", metavar="CLASS_FILTER")
    args = parser.parse_args()
    selected = None
    if args.selection is not None:
        if args.classes:
            parser.error("--selection and --class are mutually exclusive")
        try:
            selectors, selected = select_cases(args.root, args.selection)
        except ValueError as error:
            parser.error(str(error))
        if args.log is None and args.status is None:
            print("\n".join(selectors))
            return 0
    if args.log is None or args.status is None:
        parser.error("result verification requires --log and --status")
    log_text = args.log.read_text(encoding="utf-8", errors="replace")
    expected = selected if selected is not None else expected_cases(args.root)
    if args.classes:
        expected = {case for case in expected if case[0] in args.classes}
    errors = evaluate(expected, observed_cases(log_text), args.status)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"access test gate passed ({len(expected)} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
