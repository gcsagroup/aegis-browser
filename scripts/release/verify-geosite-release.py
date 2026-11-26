#!/usr/bin/env python3
"""Check the iOS bundle against the current official GitHub release."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


IOS = Path(__file__).resolve().parents[2] / "apps/ios"
SOURCE = IOS / "AegisApp/GeoSite"
NAMES = {"geosite.dat": "geosite.dat", "geosite.dat.sha256sum": "geosite-checksum.txt"}
RELEASE_FIELDS = ("id", "tag_name", "published_at", "url", "html_url")
ASSET_FIELDS = ("name", "id", "size", "state", "digest", "url", "browser_download_url")


def assets(release):
    selected = [item for item in release["assets"] if item["name"] in NAMES]
    if len(selected) != len(NAMES) or {item["name"] for item in selected} != NAMES.keys():
        raise ValueError("Expected exactly one standard GeoSite DAT and its checksum")
    return {item["name"]: item for item in selected}


def verify(bundle, latest, directory):
    if any(release.get(flag) is not False for release in (bundle, latest) for flag in ("draft", "prerelease")):
        raise ValueError("GeoSite metadata must identify a published official release")
    if any(key not in bundle or bundle[key] != latest[key] for key in RELEASE_FIELDS):
        raise ValueError(f"Bundled GeoSite {bundle['tag_name']} differs from official release {latest['tag_name']}")
    if "assets_url" in bundle and bundle["assets_url"] != latest.get("assets_url"):
        raise ValueError("Bundled GeoSite assets URL differs from the official release")
    pinned, official = assets(bundle), assets(latest)
    for name, filename in NAMES.items():
        if any(key not in pinned[name] or pinned[name][key] != official[name][key] for key in ASSET_FIELDS):
            raise ValueError(f"Bundled metadata differs for {name}")
        expected = official[name]["size"]
        with (directory / filename).open("rb") as asset:
            data = asset.read(expected + 1)
        if len(data) != expected or "sha256:" + hashlib.sha256(data).hexdigest() != official[name]["digest"]:
            raise ValueError(f"Bundled bytes differ for {name}")
    return bundle["tag_name"]


def verify_app(app):
    """Run the same admission code as iOS against the archive's resources."""
    metadata = "geosite-release.json"
    tag = verify(json.loads((app / metadata).read_text()), json.loads((SOURCE / metadata).read_text()), app)
    with tempfile.TemporaryDirectory(prefix="aegis-geosite-verify-") as temporary:
        work = Path(temporary)
        psl = app / "Frameworks/AegisPolicyKit.framework/public_suffix_list.dat"
        shutil.copyfile(psl, work / psl.name)
        policy = work / "libAegisPolicyKit.a"
        swift = ["xcrun", "--sdk", "macosx", "swiftc"]
        subprocess.run([*swift, "-emit-module", "-emit-library", "-static", "-module-name", "AegisPolicyKit",
                        str(IOS / "AegisPolicyKit/RegisteredDomain.swift"), "-o", str(policy)], check=True, timeout=90)
        access = IOS / "AccessKit"
        tool = work / "verify-bundled-geosite"
        sources = ["AccessGeoSiteAdmission.swift", "AccessGeoSiteCatalogue.swift", "AccessOverseasCatalogue.swift",
                   "AccessHostRoutingPolicy.swift", "AccessSiteIntent.swift", "AccessSiteIntentError.swift"]
        subprocess.run([*swift, "-I", str(work), str(policy),
                        *(str(access / source) for source in sources),
                        str(Path(__file__).with_name("verify-bundled-geosite.swift")), "-o", str(tool)],
                       check=True, timeout=90)
        subprocess.run([str(tool), str(app), tag], check=True, timeout=30)
    return tag


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--latest", type=Path, help="Response from GitHub releases/latest")
    mode.add_argument("--app", type=Path, help="Aegis.app inside the Xcode archive")
    args = parser.parse_args()
    try:
        if args.app:
            tag = verify_app(args.app)
        else:
            tag = verify(json.loads((SOURCE / "geosite-release.json").read_text()),
                         json.loads(args.latest.read_text()), SOURCE)
    except (KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"GeoSite release check: {error}\n")
    print(f"Bundled GeoSite matches official release {tag}")


if __name__ == "__main__":
    main()
