#!/usr/bin/env python3
"""Reject stale private test assets in a reused normal build output."""

import argparse
from pathlib import Path


def verify(output: Path) -> None:
    candidates = [output / "AegisAlphaAccess"]
    candidates.extend(output.glob("*.framework/Resources/AegisAlphaAccess"))
    candidates.extend(output.glob(
        "*.app/Contents/Frameworks/*.framework/Resources/AegisAlphaAccess"))
    if any(path.exists() for path in candidates):
        raise ValueError("Normal output contains private test assets")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--stamp", required=True, type=Path)
    args = parser.parse_args()
    try:
        verify(args.output_dir)
    except ValueError:
        parser.exit(1, "Normal output contains private test assets; use a normal output directory.\n")
    args.stamp.parent.mkdir(parents=True, exist_ok=True)
    args.stamp.write_text("private test resources absent\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
