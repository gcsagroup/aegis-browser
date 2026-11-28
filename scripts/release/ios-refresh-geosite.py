#!/usr/bin/env python3
"""Prepare a verified update to the bundled iOS GeoSite snapshot."""

import argparse
import base64
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("apps/ios/AegisApp/GeoSite")
METADATA = SOURCE / "geosite-release.json"
COMPILER = Path("scripts/dev/compile-geosite.mjs")
COMPILER_TEST = Path("scripts/dev/tests/compile-geosite.test.mjs")
CATALOGUE = Path("apps/ios/AccessKit/AccessGeoSiteCatalogue.swift")
SELECTION_TEST = Path("apps/ios/Tests/AegisTests/AccessGeoSiteSelectionTests.swift")
NOTICES = Path("scripts/licenses/third_party_notices.py")
NOTICES_TEST = Path("scripts/licenses/test_third_party_notices.py")
NOTICES_OUTPUT = Path("apps/ios/AegisApp/ThirdPartyNotices.txt")
REPO = "XTLS/Xray-rules-dat"
API = f"https://api.github.com/repos/{REPO}"
WEB = f"https://github.com/{REPO}"
GROUPS = ("DEBIAN", "DOUBAN", "MEITUAN")
LIMITS = {"geosite.dat": 16 * 1024 * 1024, "geosite.dat.sha256sum": 4096}
TAG = re.compile(r"[0-9]{14}")
COMMIT = re.compile(r"[0-9a-f]{40}")
VERIFIER = runpy.run_path(str(Path(__file__).with_name("verify-geosite-release.py")))
PATHS = (
    METADATA, *(SOURCE / name for name in VERIFIER["NAMES"].values()),
    COMPILER, COMPILER_TEST, CATALOGUE, SELECTION_TEST, NOTICES, NOTICES_TEST, NOTICES_OUTPUT,
)


def command(*arguments, cwd=ROOT):
    return subprocess.check_output(arguments, cwd=cwd, timeout=120)


def api(path):
    return json.loads(command("gh", "api", f"repos/{REPO}/{path}"))


def download(url, limit, destination):
    command("curl", "--disable", "--fail", "--silent", "--show-error", "--location",
            "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "3",
            "--connect-timeout", "10", "--max-time", "35", "--retry", "2", "--retry-max-time", "65",
            "--max-filesize", str(limit),
            "--output", str(destination), url)
    with destination.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Download exceeds {limit} bytes")
    return data


def tag_time(tag):
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        raise ValueError("Expected a GeoSite tag in YYYYMMDDHHMMSS format")
    return datetime.strptime(tag, "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)


def release_metadata(release, tag):
    released_at = VERIFIER["published"](release)
    release_id = release["id"]
    if (release["tag_name"] != tag or not timedelta(0) <= released_at - tag_time(tag) <= timedelta(days=1)
            or type(release_id) is not int or release_id <= 0
            or release["draft"] is not False or release["prerelease"] is not False
            or release["url"] != f"{API}/releases/{release_id}"
            or release["html_url"] != f"{WEB}/releases/tag/{tag}"
            or release["assets_url"] != f"{API}/releases/{release_id}/assets"):
        raise ValueError(f"Invalid official GeoSite release {tag}")
    assets = VERIFIER["assets"](release)
    for name, asset in assets.items():
        asset_id = asset["id"]
        size = asset["size"]
        if (type(asset_id) is not int or asset_id <= 0 or type(size) is not int or not 0 < size <= LIMITS[name]
                or asset["state"] != "uploaded" or not re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"] or "")
                or asset["url"] != f"{API}/releases/assets/{asset_id}"
                or asset["browser_download_url"] != f"{WEB}/releases/download/{tag}/{name}"):
            raise ValueError(f"Invalid official GeoSite asset {name} in {tag}")
    if len({asset["id"] for asset in assets.values()}) != len(assets):
        raise ValueError(f"Duplicate official GeoSite asset ID in {tag}")
    fields = (*VERIFIER["RELEASE_FIELDS"][:2], "draft", "prerelease", *VERIFIER["RELEASE_FIELDS"][2:], "assets_url")
    return {**{key: release[key] for key in fields},
            "assets": [{key: assets[name][key] for key in VERIFIER["ASSET_FIELDS"]} for name in LIMITS]}


def provenance(release, tag):
    commits = re.findall(r"\bGeoSite source: ([0-9a-f]{40})\.", release.get("body") or "")
    if len(commits) != 1 or api(f"git/commits/{commits[0]}")["sha"] != commits[0]:
        raise ValueError(f"Missing or ambiguous GeoSite source commit for {tag}")
    tag_commit = api(f"commits/refs%2Ftags%2F{tag}")["sha"]
    if not COMMIT.fullmatch(tag_commit):
        raise ValueError(f"Cannot resolve the commit of GeoSite tag {tag}")
    return commits[0], tag_commit


def pin(source, block, field):
    section = re.search(rf"(?m)^const {block} = \{{\n(.*?)^\}};", source, re.DOTALL)
    fields = re.findall(rf"(?m)^  {field}: '([^'\n]+)',$", section[1]) if section else []
    if len(fields) != 1:
        raise ValueError(f"Cannot read {block}.{field} from {COMPILER}")
    return fields[0]


def replace(path, text, replacements):
    counts = {before: 0 for before in replacements}

    def substitute(match):
        before = match[0]
        counts[before] += 1
        return replacements[before][0]

    result = re.sub("|".join(re.escape(before) for before in replacements), substitute, text)
    for before, (_, expected) in replacements.items():
        if counts[before] != expected:
            raise ValueError(f"{path} has {counts[before]} occurrences of {before!r}, expected {expected}")
    return result.encode("utf-8")


def update_pins(originals, current, candidate, source_commit, tag_commit):
    old_tag, new_tag = current["tag_name"], candidate["tag_name"]
    old_date, new_date = current["published_at"], candidate["published_at"]
    old_id, new_id = current["id"], candidate["id"]
    old_dat, new_dat = (VERIFIER["assets"](release)["geosite.dat"] for release in (current, candidate))
    old_sha, new_sha = (asset["digest"].removeprefix("sha256:") for asset in (old_dat, new_dat))
    old_size, new_size = old_dat["size"], new_dat["size"]
    compiler = originals[COMPILER].decode("utf-8")
    old_source = pin(compiler, "XTLS", "commit")
    old_tag_commit = pin(compiler, "XTLS", "tagCommit")
    if not COMMIT.fullmatch(old_source) or not COMMIT.fullmatch(old_tag_commit):
        raise ValueError("Invalid XTLS commit pins")
    old_license = old_source + r"\/LICENSE-inherited"
    if old_license.encode() not in originals[COMPILER_TEST]:
        old_license = old_source[:7] + r"[0-9a-f]+\/LICENSE-inherited"
    changes = {
        COMPILER: {
            old_tag: (new_tag, 2),
            f"  commit: '{old_source}',": (f"  commit: '{source_commit}',", 1),
            f"  tagCommit: '{old_tag_commit}',": (f"  tagCommit: '{tag_commit}',", 1),
            f"/blob/{old_source}/": (f"/blob/{source_commit}/", 2),
            f"bytes: {old_size:_},": (f"bytes: {new_size:_},", 1),
            old_sha: (new_sha, 1),
        },
        COMPILER_TEST: {
            old_tag: (new_tag, 1),
            f".commit, '{old_source}'": (f".commit, '{source_commit}'", 1),
            f".tagCommit, '{old_tag_commit}'": (f".tagCommit, '{tag_commit}'", 1),
            old_license: (source_commit + r"\/LICENSE-inherited", 1),
            f"regular file of {old_size} bytes": (f"regular file of {new_size} bytes", 1),
        },
        CATALOGUE: {
            old_tag: (new_tag, 2), old_date: (new_date, 1), old_sha: (new_sha, 1),
            f"({old_id}), GeoSite source {old_source}.": (f"({new_id}), GeoSite source {source_commit}.", 1),
        },
        SELECTION_TEST: {old_tag: (new_tag, 1), old_date: (new_date, 1), old_sha: (new_sha, 1)},
        NOTICES: {old_tag: (new_tag, 2), old_source: (source_commit, 2)},
        NOTICES_TEST: {old_tag: (new_tag, 1), old_source: (source_commit, 1)},
    }
    return {path: replace(path, originals[path].decode("utf-8"), replacements)
            for path, replacements in changes.items()}


def validate_rules(work, compiler):
    suffix_url = pin(compiler, "PSL", "url")
    if not suffix_url.startswith("https://chromium.googlesource.com/chromium/src/+/"):
        raise ValueError("Expected the pinned public suffix list URL")
    psl = work / "effective_tld_names.dat"
    encoded = download(suffix_url + "?format=TEXT", 1024 * 1024, work / "psl.base64")
    psl.write_bytes(base64.b64decode(encoded.rstrip(), validate=True))
    script = work / COMPILER.name
    script.write_text(compiler, encoding="utf-8")
    if sys.platform == "darwin":
        (work / "read-macos-acl.rb").write_bytes((ROOT / "scripts/dev/read-macos-acl.rb").read_bytes())
    for group in GROUPS:
        result = subprocess.run(
            ["node", str(script), "--dat", str(work / "geosite.dat"), "--psl", str(psl),
             "--group", group, "--output", str(work / f"{group}.json")],
            capture_output=True, text=True, timeout=90, check=False,
        )
        if result.returncode != 0:
            diagnostic = result.stderr.strip()
            if "Compiled rule payload SHA-256 does not match the pin" in diagnostic:
                raise ValueError(f"{group} rules changed and require scope review") from None
            raise ValueError(f"{group} compiler validation failed: {diagnostic}")


def publish(originals, updates):
    with tempfile.TemporaryDirectory(dir=ROOT, prefix=".geosite-refresh-") as directory:
        stage = Path(directory)
        pending = {}
        for index, (path, data) in enumerate(updates.items()):
            if data == originals[path]:
                continue
            target = ROOT / path
            replacement = stage / str(index)
            replacement.write_bytes(data)
            replacement.chmod(target.stat().st_mode & 0o777)
            backup = stage / f"{index}.previous"
            os.link(target, backup)
            pending[target] = (replacement, backup)
        if any((ROOT / path).read_bytes() != data for path, data in originals.items()):
            raise ValueError("Bundled GeoSite inputs changed during validation")
        replaced = []
        try:
            for target, (replacement, backup) in pending.items():
                os.replace(replacement, target)
                replaced.append((target, backup))
        except BaseException:
            for target, backup in reversed(replaced):
                os.replace(backup, target)
            raise


def refresh(tag, dry_run):
    if command("git", "status", "--porcelain", "--", *(str(path) for path in PATHS)):
        raise ValueError("Commit or stash edits to GeoSite refresh files before running")
    if any((ROOT / path).is_symlink() for path in PATHS):
        raise ValueError("Expected regular GeoSite refresh files")
    originals = {path: (ROOT / path).read_bytes() for path in PATHS}
    current = json.loads(originals[METADATA])
    current_time = tag_time(current["tag_name"])
    if tag is None:
        tag = api("releases/latest")["tag_name"]
    if tag_time(tag) < current_time:
        raise ValueError(f"GeoSite {tag} predates bundled tag {current['tag_name']}")
    release = api(f"releases/tags/{tag}")
    candidate = release_metadata(release, tag)
    if tag == current["tag_name"]:
        VERIFIER["verify"](current, candidate, ROOT / SOURCE)
        print(f"Bundled GeoSite {tag} is already current")
        return
    if VERIFIER["published"](candidate) < VERIFIER["published"](current):
        raise ValueError(f"GeoSite {tag} was published before the bundled release")
    source_commit, tag_commit = provenance(release, tag)
    with tempfile.TemporaryDirectory(prefix="aegis-geosite-refresh-") as directory:
        work = Path(directory)
        updates = {}
        for name, asset in VERIFIER["assets"](candidate).items():
            local_name = VERIFIER["NAMES"][name]
            updates[SOURCE / local_name] = download(asset["browser_download_url"], asset["size"], work / local_name)
        VERIFIER["verify"](candidate, release, work)
        database_sha = VERIFIER["assets"](candidate)["geosite.dat"]["digest"].removeprefix("sha256:")
        checksum = updates[SOURCE / "geosite-checksum.txt"]
        if not re.fullmatch(rb"%s [ *]geosite\.dat(?:\r?\n)?" % database_sha.encode("ascii"), checksum):
            raise ValueError("Official GeoSite checksum does not match the DAT digest")
        updates[METADATA] = (json.dumps(candidate, indent=2) + "\n").encode("utf-8")
        updates.update(update_pins(originals, current, candidate, source_commit, tag_commit))
        validate_rules(work, updates[COMPILER].decode("utf-8"))
        generator = work / NOTICES.name
        generator.write_bytes(updates[NOTICES])
        updates[NOTICES_OUTPUT] = runpy.run_path(str(generator))["render"]("ios", root=ROOT)
        if not dry_run:
            publish(originals, updates)
    print(f"GeoSite {current['tag_name']} → {tag}: {'verified' if dry_run else 'refreshed'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Use the specified official tag (default: latest)")
    parser.add_argument("--dry-run", action="store_true", help="Verify the candidate and generated updates without writing")
    arguments = parser.parse_args()
    try:
        lock_path = command("git", "rev-parse", "--git-path", "ios-geosite-refresh.lock").decode().strip()
        with (ROOT / lock_path).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            refresh(arguments.tag, arguments.dry_run)
    except BlockingIOError:
        parser.exit(1, "Another GeoSite refresh is running\n")
    except (KeyError, OSError, TypeError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"GeoSite refresh: {error}\n")


if __name__ == "__main__":
    main()
