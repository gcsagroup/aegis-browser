#!/usr/bin/env python3
"""Generate the explicitly private Windows installer's resource manifest."""

import argparse
from pathlib import Path


def prepare(source: Path, output: Path, channel: str) -> None:
    if channel not in ("alpha", "beta"):
        raise ValueError("Private installer requires Alpha or Beta")
    template = source.read_text(encoding="utf-8")
    marker = "\n[HIDPI]\n"
    if (template.count("[GENERAL]\n") != 1 or template.count(marker) != 1
            or "aegisalphaaccess" in template.lower()):
        raise ValueError("Unexpected installer manifest")
    # DIR_ASSETS resolves to the chrome.dll directory on an installed browser.
    # Only this generated manifest carries private resources; chrome.release
    # remains unchanged for ordinary builds, including reused output trees.
    resources = "\n# Explicitly enabled private Access test resources.\n"
    for name in ("core-manifest.json", "node.json", "xray.exe"):
        resources += f"AegisAlphaAccess\\{name}: %(VersionDir)s\\AegisAlphaAccess\\\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(template.replace(marker, resources + marker), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", required=True, choices=("alpha", "beta"))
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(args.source, args.output, args.channel)
    except (OSError, ValueError):
        parser.exit(1, "Cannot prepare private Access installer manifest.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
