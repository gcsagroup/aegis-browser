#!/usr/bin/env python3
"""Check the iOS bundle against its tagged official GitHub release and bound how far it trails latest."""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


IOS = Path(__file__).resolve().parents[2] / "apps/ios"
SOURCE = IOS / "AegisApp/GeoSite"
NAMES = {"geosite.dat": "geosite.dat", "geosite.dat.sha256sum": "geosite-checksum.txt"}
RELEASE_FIELDS = ("id", "tag_name", "published_at", "url", "html_url")
ASSET_FIELDS = ("name", "id", "size", "state", "digest", "url", "browser_download_url")
TAG = re.compile(r"\d{14}")
FRESHNESS = timedelta(days=14)


def assets(release):
    selected = [item for item in release["assets"] if item["name"] in NAMES]
    if len(selected) != len(NAMES) or {item["name"] for item in selected} != NAMES.keys():
        raise ValueError("Expected exactly one standard GeoSite DAT and its checksum")
    return {item["name"]: item for item in selected}


def published(release):
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        raise ValueError(f"Invalid GeoSite release tag {tag!r}")
    return datetime.strptime(release["published_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def verify(bundle, official, directory):
    """Require the bundle to match the official release of its own tag, byte for byte."""
    if any(release.get(flag) is not False for release in (bundle, official) for flag in ("draft", "prerelease")):
        raise ValueError("GeoSite metadata must identify a published official release")
    if any(key not in bundle or bundle[key] != official[key] for key in RELEASE_FIELDS):
        raise ValueError(f"Bundled GeoSite {bundle['tag_name']} differs from official release {official['tag_name']}")
    if "assets_url" in bundle and bundle["assets_url"] != official.get("assets_url"):
        raise ValueError("Bundled GeoSite assets URL differs from the official release")
    pinned, released = assets(bundle), assets(official)
    for name, filename in NAMES.items():
        if any(key not in pinned[name] or pinned[name][key] != released[name][key] for key in ASSET_FIELDS):
            raise ValueError(f"Bundled metadata differs for {name}")
        expected = released[name]["size"]
        with (directory / filename).open("rb") as asset:
            data = asset.read(expected + 1)
        if len(data) != expected or "sha256:" + hashlib.sha256(data).hexdigest() != released[name]["digest"]:
            raise ValueError(f"Bundled bytes differ for {name}")
    return bundle["tag_name"]


def check_freshness(bundle, latest):
    """Return how far the bundle trails latest, measured between the two publications."""
    if any(latest.get(flag) is not False for flag in ("draft", "prerelease")):
        raise ValueError("Latest GeoSite metadata must identify a published official release")
    lag = published(latest) - published(bundle)
    if bundle["tag_name"] > latest["tag_name"] or lag < timedelta(0):
        raise ValueError(f"Bundled GeoSite {bundle['tag_name']} is newer than official latest {latest['tag_name']}")
    if lag > FRESHNESS:
        raise ValueError(f"Bundled GeoSite {bundle['tag_name']} trails official latest {latest['tag_name']} "
                         f"by more than {FRESHNESS.days} days")
    return lag


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
    mode.add_argument("--official", type=Path, help="Response from GitHub releases/tags/<bundled tag>")
    mode.add_argument("--app", type=Path, help="Aegis.app inside the Xcode archive")
    parser.add_argument("--latest", type=Path, help="Response from GitHub releases/latest, required with --official")
    args = parser.parse_args()
    if bool(args.official) != bool(args.latest):
        parser.error("--official and --latest are used together")
    try:
        if args.app:
            tag = verify_app(args.app)
        else:
            bundle = json.loads((SOURCE / "geosite-release.json").read_text())
            tag = verify(bundle, json.loads(args.official.read_text()), SOURCE)
            latest = json.loads(args.latest.read_text())
            lag = check_freshness(bundle, latest)
            if lag:
                print(f"::warning::Bundled GeoSite {tag} trails official latest {latest['tag_name']} by {lag}; "
                      f"refresh it within the {FRESHNESS.days}-day limit")
    except (KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"GeoSite release check: {error}\n")
    print(f"Bundled GeoSite matches official release {tag}")


if __name__ == "__main__":
    main()
