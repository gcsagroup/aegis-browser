#!/usr/bin/env python3
"""Stage private Access inputs without printing node values."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile


def stage(source: Path, output: Path, channel: str) -> None:
    if channel not in ("alpha", "beta"):
        raise ValueError("Test resources are restricted to Alpha and Beta")
    manifest_bytes = (source / "core-manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    if (manifest.get("schemaVersion") != 1 or manifest.get("channel") != channel
            or manifest.get("binaryRelativePath") != "xray"
            or manifest.get("nodeConfigRelativePath") != "node.json"):
        raise ValueError("Invalid private resource manifest")
    binary = (source / "xray").read_bytes()
    node_bytes = (source / "node.json").read_bytes()
    if (hashlib.sha256(binary).hexdigest() != manifest.get("binarySha256")
            or hashlib.sha256(node_bytes).hexdigest() != manifest.get("nodeConfigSha256")):
        raise ValueError("Private resource pin mismatch")
    node = json.loads(node_bytes)
    outbound = node.get("outbounds", [None])[0]
    if (not isinstance(outbound, dict) or outbound.get("protocol") != "vless"
            or outbound.get("streamSettings", {}).get("network") != "tcp"
            or outbound.get("streamSettings", {}).get("security") != "reality"):
        raise ValueError("Unsupported private test transport")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output, 0o700)
    # Replace inodes, so an already assembled/running immutable candidate
    # cannot be changed through a hardlinked build resource.
    for name, data, mode in (("core-manifest.json", manifest_bytes, 0o600),
                             ("node.json", node_bytes, 0o600),
                             ("xray", binary, 0o700)):
        descriptor, temporary = tempfile.mkstemp(dir=output, prefix=".private-")
        try:
            with os.fdopen(descriptor, "wb") as stream:
                os.fchmod(stream.fileno(), mode)
                stream.write(data)
            os.replace(temporary, output / name)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        stage(args.source_dir, args.output_dir, args.channel)
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        # Private input values and exception payloads never enter build logs.
        parser.exit(1, "Cannot prepare validated private test resources.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
