#!/usr/bin/env python3
"""Place unsigned iOS CI data on enrolled storage; retain source-bound evidence."""
import argparse
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import pwd
import re
import stat
import subprocess  # nosec B404 - fixed absolute executables, with no shell, are audited at each call.
import sys
import tempfile
import unicodedata
import uuid

MIN_FREE_BYTES = 20 * 2**30
CONFIG = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/gcsa-ci/aegis-volume-identity.json"
GLOB_META = frozenset("*?[]{}()!") | {chr(92)}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def literal_artifact_path(path):
    require(not any(ord(character) < 32 for character in str(path)), "storage path contains control characters")
    require(not set(str(path)).intersection(GLOB_META), "storage path contains unsupported artifact-glob characters")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate storage configuration field")
        result[key] = value
    return result


def acl_entries(path):
    if sys.platform != "darwin":
        return []
    # The fixed ls operation treats the path after -- as one literal operand.
    listing = subprocess.check_output(  # nosec B603
        ["/bin/ls", "-lde", "--", str(path)], shell=False, text=True, timeout=10)
    return [line for line in listing.splitlines()[1:] if re.match(r"\s*\d+:\s", line)]


def ordinary_directory(path):
    info = path.lstat()
    require(not stat.S_ISLNK(info.st_mode), "storage path contains a symlink")
    require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0, os.getuid())
            and not info.st_mode & 0o022, "unsafe storage directory")
    entries = "\n".join(acl_entries(path))
    require(not re.search(r"\ballow\b.*\b(add_file|add_subdirectory|delete|delete_child|write|append|writeattr|writeextattr|writesecurity|chown)\b",
                          entries), "storage directory ACL grants mutation")
    require(not re.search(r"\b(file_inherit|directory_inherit)\b", entries),
            "storage directory ACL would be inherited by private job data")


def private_json(path):
    for parent in reversed(path.parents):
        ordinary_directory(parent)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ValueError("private storage configuration cannot be opened without symlinks") from error
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1
                and info.st_size <= 16384, "storage configuration must be private and owner-controlled")
        require(not acl_entries(path), "storage configuration ACL is not allowed")
        raw = stream.read(16385)
    require(len(raw) <= 16384, "storage configuration exceeds its bound")
    return json.loads(raw, object_pairs_hook=unique_object), hashlib.sha256(raw).hexdigest()


def seed_artifacts(base, cache, volume):
    seed = base / "artifact-seed-v1"
    if not seed.exists() and not seed.is_symlink():
        return None, 0
    artifacts = seed / "artifacts"
    for directory in (seed, artifacts):
        ordinary_directory(directory)
        require(directory.stat().st_dev == volume.stat().st_dev, "artifact snapshot is on another device")
    catalog, digest = private_json(seed / "manifest.json")
    require(isinstance(catalog, dict) and set(catalog) == {"schema_version", "artifacts"}
            and type(catalog["schema_version"]) is int and catalog["schema_version"] == 1,
            "invalid artifact snapshot schema")
    entries = catalog["artifacts"]
    require(isinstance(entries, list) and 0 < len(entries) <= 64, "invalid artifact snapshot count")
    names, total = set(), 0
    for entry in entries:
        require(isinstance(entry, dict) and set(entry) == {"name", "bytes", "sha256"}, "invalid artifact snapshot entry")
        name, size, checksum = entry["name"], entry["bytes"], entry["sha256"]
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,199}", name)
                and name not in names, "unsafe or duplicate artifact snapshot name")
        require(type(size) is int and 0 < size <= 256 * 2**20, "invalid artifact snapshot size")
        require(isinstance(checksum, str) and re.fullmatch(r"[0-9a-f]{64}", checksum), "invalid artifact snapshot digest")
        names.add(name)
        total += size
    require(total <= 512 * 2**20, "artifact snapshot exceeds its byte bound")
    observed = set()
    for path in artifacts.iterdir():
        require(len(observed) < 64 and path.name in names, "artifact snapshot has unlisted payloads")
        observed.add(path.name)
    require(observed == names, "artifact snapshot is missing payloads")
    destination = None if cache is None else cache / "artifacts"
    if destination is not None:
        destination.mkdir(mode=0o700)
    for entry in entries:
        path = artifacts / entry["name"]
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError as error:
            raise ValueError("artifact snapshot payload cannot be opened safely") from error
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                    and stat.S_IMODE(info.st_mode) == 0o400 and info.st_size == entry["bytes"]
                    and info.st_dev == volume.stat().st_dev and not acl_entries(path),
                    "artifact snapshot payload identity or permissions differ")
            content = hashlib.sha256()
            copied = 0
            output = (nullcontext(None) if destination is None else os.fdopen(os.open(
                destination / entry["name"], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb"))
            with output as target:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    copied += len(chunk)
                    require(copied <= entry["bytes"], "artifact snapshot grew during copy")
                    content.update(chunk)
                    if target is not None:
                        target.write(chunk)
            after = os.fstat(stream.fileno())
            fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
            require(all(getattr(info, key) == getattr(after, key) for key in fields)
                    and copied == entry["bytes"] and content.hexdigest() == entry["sha256"],
                    "artifact snapshot bytes changed or digest differs")
    return digest, len(entries)


def volume_info(path):
    require(sys.platform == "darwin", "self-hosted iOS storage requires macOS")
    require(Path(path).is_absolute(), "diskutil requires an absolute volume path")
    # Fixed read-only operation; the absolute path cannot become an option.
    raw = subprocess.check_output(  # nosec B603
        ["/usr/sbin/diskutil", "info", "-plist", str(path)], shell=False, timeout=10)
    return plistlib.loads(raw)


def available_bytes(path):
    info = os.statvfs(path)
    return info.f_bavail * info.f_frsize


def host_storage(runner_name, config_path):
    value, digest = private_json(config_path)
    require(isinstance(value, dict) and set(value) == {"schema_version", "mount_point", "volume_uuid", "runner_roots"}
            and type(value["schema_version"]) is int and value["schema_version"] == 1,
            "unknown storage configuration schema")
    mount_text = value["mount_point"]
    require(isinstance(mount_text, str) and mount_text.startswith("/")
            and not any(ord(c) < 32 for c in mount_text), "invalid storage mount")
    literal_artifact_path(mount_text)
    mount = Path(mount_text)
    require(str(mount) == mount_text and mount != Path("/"), "noncanonical storage mount")
    for path in reversed((mount, *mount.parents)):
        ordinary_directory(path)
    info = volume_info(mount)
    require(isinstance(value["volume_uuid"], str), "invalid enrolled UUID")
    expected_uuid = uuid.UUID(value["volume_uuid"])
    require(info.get("MountPoint") == str(mount) and uuid.UUID(info.get("VolumeUUID", "")) == expected_uuid
            and str(info.get("FilesystemType", "")).lower() == "apfs"
            and info.get("Internal") is False and info.get("Writable") is True
            and info.get("GlobalPermissionsEnabled") is True,
            "enrolled external APFS identity, ownership or writable state changed")
    roots = value["runner_roots"]
    require(isinstance(roots, dict) and runner_name in roots, "runner has no enrolled storage root")
    parts = []
    for name, relative in roots.items():
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]+", name)
                and isinstance(relative, str) and not any(ord(c) < 32 for c in relative), "invalid runner storage root")
        literal_artifact_path(relative)
        path = PurePosixPath(relative)
        require(not path.is_absolute() and len(path.parts) >= 2 and ".." not in path.parts
                and "\\" not in relative and str(path) == relative, "runner storage root escapes its volume")
        # Be conservative on both case-sensitive and case-insensitive APFS,
        # including canonically equivalent Unicode names.
        normalized = PurePosixPath(unicodedata.normalize("NFD", relative).casefold())
        require(all(not normalized.is_relative_to(previous) and not previous.is_relative_to(normalized) for previous in parts),
                "runner storage roots overlap")
        parts.append(normalized)
    root = mount / roots[runner_name]
    probe = mount
    for part in PurePosixPath(roots[runner_name]).parts:
        probe = probe / part
        if probe.exists() or probe.is_symlink():
            ordinary_directory(probe)
    return root, mount, digest


def source_metadata(environment):
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        require(re.fullmatch(r"[1-9][0-9]*", environment.get(key, "")), "invalid CI run metadata")
    require(re.fullmatch(r"[A-Za-z0-9_-]+", environment.get("GITHUB_JOB", "")), "invalid CI job metadata")
    source = environment.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", source), "invalid CI source SHA")
    workspace_text = environment["GITHUB_WORKSPACE"]
    require(isinstance(workspace_text, str) and not any(ord(c) < 32 for c in workspace_text),
            "invalid source workspace")
    workspace = Path(workspace_text)
    require(workspace.is_absolute() and str(workspace) == workspace_text
            and workspace.resolve(strict=True) == workspace and workspace.is_dir(),
            "source workspace must be an absolute canonical directory")
    git_env = dict({key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
                   GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_CONFIG_NOSYSTEM="1",
                   GIT_CONFIG_GLOBAL=os.devnull, GIT_ATTR_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    # Each Git argv is literal and uses the verified directory only as cwd.
    # Disable inherited configuration and repository-local command execution.
    head = subprocess.check_output(  # nosec B603
        ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false", "rev-parse", "HEAD^{commit}"],
        cwd=workspace, env=git_env, shell=False, text=True, timeout=10).strip()
    tree = subprocess.check_output(  # nosec B603
        ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false", "rev-parse", "HEAD^{tree}"],
        cwd=workspace, env=git_env, shell=False, text=True, timeout=10).strip()
    require(head == source, "actual checkout source differs from CI source")
    clean = subprocess.run(  # nosec B603 - fixed Git operation, external diff/textconv and fsmonitor disabled.
        ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false",
         "diff", "--no-ext-diff", "--no-textconv", "--quiet", "HEAD", "--"],
        cwd=workspace, env=git_env, shell=False, timeout=10).returncode
    require(clean == 0, "actual checkout source has tracked changes")
    untracked = subprocess.check_output(  # nosec B603 - fixed Git inventory, configuration isolated above.
        ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false",
         "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=workspace, env=git_env, shell=False, timeout=10)
    require(not untracked, "actual checkout source has untracked inputs")
    # Xcode copies these source/resource folders, so ignored files there also
    # affect the product. Generated .artifacts/node_modules outside them remain
    # outside this source claim and are not swept or removed.
    ignored_inputs = subprocess.check_output(  # nosec B603 - fixed Git inventory and literal source paths.
        ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false",
         "ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--", "apps/ios", "apps/browser/overlay"],
        cwd=workspace, env=git_env, shell=False, timeout=10)
    require(not ignored_inputs, "actual checkout source has ignored build inputs")
    return dict(source_sha=head, source_tree=tree, run_id=environment["GITHUB_RUN_ID"],
                run_attempt=environment["GITHUB_RUN_ATTEMPT"], job=environment["GITHUB_JOB"])


def write_json(path, document):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(document, stream, indent=2)
        stream.write("\n")


def prepare(environment, runner_environment, runner_name, *, config_path=CONFIG):
    metadata = source_metadata(environment)
    require(runner_environment in ("self-hosted", "github-hosted"), "unknown runner environment")
    if runner_environment == "self-hosted":
        base, volume, enrollment = host_storage(runner_name, config_path)
        placement = "enrolled-external-apfs"
        require(available_bytes(volume) >= MIN_FREE_BYTES, "unsigned iOS CI storage capacity is below 20 GiB")
    else:
        base = Path(environment["RUNNER_TEMP"]).resolve(strict=True) / "aegis-ios-ci"
        volume, enrollment, placement = base.parent, None, "hosted-ephemeral"
    literal_artifact_path(base)
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    ordinary_directory(base)
    require(base.stat().st_dev == volume.stat().st_dev, "cache backing differs from its admitted volume")
    jobs = base / "jobs"
    jobs.mkdir(mode=0o700, exist_ok=True)
    ordinary_directory(jobs)
    require(jobs.stat().st_dev == volume.stat().st_dev, "jobs backing differs from its admitted volume")
    root = Path(tempfile.mkdtemp(prefix=f"{metadata['run_id']}-{metadata['run_attempt']}-{metadata['job']}-", dir=jobs))
    ordinary_directory(root)
    require(root.stat().st_dev == volume.stat().st_dev, "job backing differs from its admitted volume")
    require(not acl_entries(root), "new private job directory has an ACL")
    for name in ("tmp", "DerivedData", "SourcePackages", "PackageCache", "ModuleCache"):
        (root / name).mkdir(mode=0o700)
    seed_digest, seed_count = (seed_artifacts(base, root / "PackageCache", volume)
                               if runner_environment == "self-hosted" else (None, 0))
    if runner_environment == "self-hosted":
        require(available_bytes(volume) >= MIN_FREE_BYTES, "unsigned iOS CI storage capacity is below 20 GiB")
    receipt = dict(schema_version=1, **metadata, placement=placement,
                   runner_name=runner_name, enrollment_sha256=enrollment,
                   artifact_seed_sha256=seed_digest, seed_artifact_count=seed_count)
    write_json(root / "storage-receipt.json", receipt)
    # Local state stays private; the uploaded receipt never contains host paths or UUIDs.
    write_json(root / ".storage-state.json", dict(receipt, root=str(root), device=root.stat().st_dev,
                inode=root.stat().st_ino, config_path=str(config_path)))
    return root


def seal(root, environment):
    root = Path(root)
    ordinary_directory(root)
    state, _ = private_json(root / ".storage-state.json")
    metadata = source_metadata(environment)
    require(all(state[key] == value for key, value in metadata.items()), "prepared source or CI run changed")
    require(str(root) == state["root"] and (root.stat().st_dev, root.stat().st_ino) == (state["device"], state["inode"]),
            "prepared storage directory identity changed")
    if state["placement"] == "enrolled-external-apfs":
        _, volume, enrollment = host_storage(state["runner_name"], Path(state["config_path"]))
        require(enrollment == state["enrollment_sha256"] and volume.stat().st_dev == root.stat().st_dev,
                "enrolled storage changed during archive")
    archive = root / "Aegis.xcarchive"
    ordinary_directory(archive)
    for directory, directories, files in os.walk(archive, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            require(not path.is_symlink() or path.resolve().is_relative_to(archive), "archive symlink escapes its root")
    embedded_core = None
    workspace = Path(environment["GITHUB_WORKSPACE"])
    source_lock = workspace / "apps/ios/EmbeddedCore/embedded-core-lock.json"
    if source_lock.is_file():
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "release"))
        import ios_embedded_core as verifier
        embedded_core = verifier.verify(workspace, source_lock, root / "EmbeddedCore")
        embedded_core.update(verifier.verify_bundle(archive / "Products/Applications/Aegis.app", root / "EmbeddedCore",
                                                    root / "DerivedData", "device"))
    target = root / "Aegis.xcarchive.zip"
    require(not target.exists() and not target.is_symlink(), "archive evidence already exists")
    # Fixed archiver operation; both operands are absolute paths inside the revalidated job root.
    subprocess.run(  # nosec B603
        ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(archive), str(target)], shell=False, check=True)
    digest = hashlib.sha256()
    with target.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    write_json(root / "unsigned-artifact.json", dict(schema_version=1, **metadata, archive="Aegis.xcarchive.zip",
               archive_sha256=digest.hexdigest(), archive_bytes=target.stat().st_size, signed=False, embedded_core=embedded_core,
               acceptance="unsigned archive verification only; no device, signing or release acceptance"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--runner-environment", required=True, choices=("self-hosted", "github-hosted"))
    prepare_parser.add_argument("--runner-name", required=True)
    seal_parser = sub.add_parser("seal")
    seal_parser.add_argument("--root", required=True, type=Path)
    doctor_parser = sub.add_parser("doctor")
    doctor_parser.add_argument("--runner-name", required=True)
    args = parser.parse_args()
    if args.operation == "prepare":
        root = prepare(os.environ, args.runner_environment, args.runner_name)
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"root={root}\n")
    elif args.operation == "seal":
        seal(args.root, os.environ)
    else:
        root, volume, enrollment = host_storage(args.runner_name, CONFIG)
        require(available_bytes(volume) >= MIN_FREE_BYTES, "unsigned iOS CI storage capacity is below 20 GiB")
        seed_digest, seed_count = seed_artifacts(root, None, volume)
        print(json.dumps(dict(root=str(root), volume=str(volume), enrollment_sha256=enrollment,
                              available_bytes=available_bytes(volume), artifact_seed_sha256=seed_digest,
                              seed_artifact_count=seed_count)))


if __name__ == "__main__":
    main()
