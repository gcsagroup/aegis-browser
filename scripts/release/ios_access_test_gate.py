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


def expected_cases(roots: list[Path]) -> set[tuple[str, str]]:
    found: set[tuple[str, str]] = set()
    current = ""
    class_re = re.compile(r"^(?:final )?class ([A-Za-z0-9_]+)\b")
    paths: list[Path] = []
    for root in roots:
        if root.is_file():
            paths.append(root)
        else:
            paths.extend(sorted(root.rglob("*.swift")))
    for path in paths:
        current = ""
        for line in path.read_text(encoding="utf-8").splitlines():
                class_match = class_re.match(line)
                if class_match:
                    current = class_match.group(1)
                    continue
                func_match = FUNC_RE.match(line)
                if func_match and current:
                    found.add((current, func_match.group(1)))
    return found


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
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--status", type=int, required=True)
    parser.add_argument("--root", type=Path, action="append", required=True)
    parser.add_argument("--class", dest="classes", action="append")
    args = parser.parse_args()
    log_text = args.log.read_text(encoding="utf-8", errors="replace")
    expected = expected_cases(args.root)
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
