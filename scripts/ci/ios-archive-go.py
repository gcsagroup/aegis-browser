"""Install the exact EmbeddedCore Go release in supervised job scratch."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess  # nosec B404 - supervised, argument-list commands only.
import sys


RELEASES = "https://go.dev/dl/?mode=json&include=all"
DOWNLOADS = "https://dl.google.com/go/"


def download(url, path, limit):
    # Use the runner's HTTPS proxy and trust store, with a fixed HTTPS origin
    # and curl's configuration-file overrides disabled.
    subprocess.run(  # nosec B603, B607 - curl on runner PATH, fixed options and HTTPS origins.
        ["curl", "--disable", "--proto", "=https", "--fail", "--silent", "--show-error",
         "--max-time", "180", "--max-filesize", str(limit), "--output", str(path), url], check=True)


def release_file(catalog, version, arch):
    filename = f"go{version}.darwin-{arch}.tar.gz"
    matches = [entry for release in catalog if release["version"] == f"go{version}"
               for entry in release["files"] if entry["filename"] == filename]
    if len(matches) != 1:
        raise ValueError("Go release has no unique pinned archive")
    entry = matches[0]
    if (entry["version"] != f"go{version}" or entry["os"] != "darwin" or entry["arch"] != arch
            or entry["kind"] != "archive" or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
            or type(entry["size"]) is not int or not 0 < entry["size"] <= 256 * 2**20):
        raise ValueError("unexpected Go release metadata")
    return filename, entry["size"], entry["sha256"]


def install(lock, scratch):
    version = json.loads(lock.read_bytes())["toolchain"]["go"]
    arch = {"arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    if sys.platform != "darwin" or arch is None or not re.fullmatch(r"1\.[0-9]+\.[0-9]+", version):
        raise ValueError("unsupported Go release or runner architecture")
    catalog = scratch / "go-releases.json"
    limit = 8 * 2**20
    download(RELEASES, catalog, limit)
    if catalog.stat().st_size > limit:
        raise ValueError("Go release catalog exceeds its byte bound")
    filename, size, sha256 = release_file(json.loads(catalog.read_bytes()), version, arch)
    archive = scratch / filename
    download(DOWNLOADS + filename, archive, size)
    if archive.stat().st_size != size:
        raise ValueError("Go archive differs from the published size")
    with archive.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != sha256:
        raise ValueError("Go archive differs from the published digest")
    subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(scratch)], check=True)  # nosec B603
    go = scratch / "go/bin/go"
    # The executable is from the size- and SHA-256-verified Go release in job-private scratch.
    # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args
    output = subprocess.check_output([str(go), "version"], shell=False,  # nosec B603
                                     env=dict(os.environ, GOROOT=str(go.parent.parent), GOTOOLCHAIN="local"))
    if output != f"go version go{version} darwin/{arch}\n".encode("ascii"):
        raise ValueError("installed Go identity differs from the source lock")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lock", type=Path)
    parser.add_argument("scratch", type=Path)
    args = parser.parse_args()
    try:
        install(args.lock, args.scratch)
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode >= 0 else 128 - error.returncode
    except (KeyError, OSError, TypeError, ValueError):
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
