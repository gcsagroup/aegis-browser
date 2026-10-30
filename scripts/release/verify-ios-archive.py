#!/usr/bin/env python3
"""Verify a diagnostic archive; this does not qualify an IPA or TestFlight upload."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
from safari_manifest import verify as verify_safari_manifest


def verify(archive: Path, version: str, build: str) -> dict:
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version):
        raise ValueError("Invalid marketing version")
    if not re.fullmatch(r"[1-9]\d{0,9}", build):
        raise ValueError("Invalid build")
    applications = archive / "Products/Applications"
    apps = list(applications.glob("*.app"))
    if len(apps) != 1 or apps[0].name != "Aegis.app":
        raise ValueError("Expected exactly one Aegis.app")
    bundles = [apps[0], *sorted((apps[0] / "PlugIns").glob("*.appex"))]
    expected = {"Aegis.app": "com.gcsa.aegis", "SafariWebExtension.appex": "com.gcsa.aegis.safari",
                "ShareExtension.appex": "com.gcsa.aegis.share"}
    if {p.name for p in bundles} != set(expected):
        raise ValueError("Missing or unexpected app extensions")
    entries = []
    for bundle in bundles:
        with (bundle / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        identity = {key: info.get(key) for key in
                    ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]}
        if list(identity.values()) != [expected[bundle.name], version, build]:
            raise ValueError(f"Archive identity mismatch: {bundle.name}")
        entries.append(identity)
    safari = apps[0] / "PlugIns/SafariWebExtension.appex"
    verify_safari_manifest(lambda name: (safari / name).read_bytes())
    return {"status": "unsigned_archive_verified", "applications": entries,
            "signing": "disabled", "IPA": False, "TestFlight": False, "releaseReady": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("version")
    parser.add_argument("build")
    args = parser.parse_args()
    result = verify(args.archive, args.version, args.build)
    result["source"] = {key: subprocess.check_output(["git", "rev-parse", ref], text=True).strip()
                        for key, ref in [("sha", "HEAD"), ("tree", "HEAD^{tree}")]}
    print(json.dumps(result, indent=2))
