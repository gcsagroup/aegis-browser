#!/usr/bin/env python3
"""Prepare an isolated Alpha device-test variant; never build, sign or install.

Uses installed PyYAML, or system Ruby safe_load. Output project.yml is JSON
(a YAML subset). Source files stay unchanged; overlays are explicitly receipted.
"""
import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
# Local tooling uses argument arrays with the shell disabled.
import subprocess  # nosec B404
import sys
import tarfile
from tempfile import TemporaryDirectory

APP = "com.gcsa.aegis.alpha.internal"
OLD_GROUP = "group.com.gcsa.aegis.ios.share-inbox"
GROUP = "group.com.gcsa.aegis.alpha.internal.share-inbox"
SCHEME = "gcsa-aegis-alpha-internal"
REPLACEMENTS = {
    "Shared/ShareInbox.swift": (OLD_GROUP, GROUP, 1),
    "Shared/MarkdownShareInbox.swift": (OLD_GROUP, GROUP, 1),
    "Shared/AppLocalization.swift": (OLD_GROUP, GROUP, 1),
    "Shared/ExternalPageLink.swift": ('"gcsa-aegis"', '"' + SCHEME + '"', 1),
    "SharedWebExtension/background.js": ('`gcsa-aegis://open?url=', '`' + SCHEME + '://open?url=', 1),
}
IDS = {"Aegis": "", "SafariWebExtension": ".safari", "ShareExtension": ".share",
       "BrowserKit": ".browserkit", "AegisPolicyKit": ".policykit", "AccessKit": ".accesskit",
       "AgentKit": ".agentkit", "AegisTests": ".tests", "AegisUITests": ".uitests"}
SNAPSHOT_PATHS = ("apps/ios", "apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared",
                  "packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json",
                  "scripts/release/ios_embedded_core.py")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_spec(path):
    try:
        import yaml
    except ImportError:
        code = 'require "yaml"; require "json"; puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), [], [], false))'
        # Fixed Ruby executable and YAML parser source; the project path is a separate argument.
        result = subprocess.run(["/usr/bin/ruby", "-e", code, str(path)],  # nosec B603
                                capture_output=True, text=True, check=False)
        if result.returncode:
            raise ValueError("installed safe YAML parser could not read project spec")
        return json.loads(result.stdout)
    return yaml.safe_load(path.read_text())


def private_path(path):
    path = Path(path).absolute()
    info = path.lstat()
    parent = path.parent.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
            or parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700):
        raise ValueError("node file requires a private regular file and parent")
    return str(path)


def source_git(root, arguments, *, input_data=None, check=True):
    # The root is the working directory. Callers supply fixed commands and validated object IDs.
    return subprocess.run(["/usr/bin/git", "--no-replace-objects", "--no-optional-locks", *arguments],
                          cwd=root, input=input_data, capture_output=True, check=check, shell=False)  # nosec B603


def prepared_source_commit(root):
    result = source_git(root, ("rev-parse", "--show-toplevel", "HEAD"), check=False)
    if result.returncode:
        return None
    lines = os.fsdecode(result.stdout).splitlines()
    if len(lines) != 2 or Path(lines[0]).resolve() != root or not re.fullmatch(r"[0-9a-f]{40}", lines[1]):
        return None
    status = source_git(root, ("-c", "core.fsmonitor=false", "status", "--porcelain",
                               "--untracked-files=normal", "--", "apps/ios"), check=False)
    return lines[1] if status.returncode == 0 and not status.stdout else None


def snapshot_path(name):
    path = PurePosixPath(name)
    if (path.is_absolute() or ".." in path.parts or not path.parts or path.as_posix() != name
            or "\\" in name or any(ord(char) < 32 for char in name)):
        raise ValueError("unsafe snapshot path")
    return path


def snapshot_blobs(root, blob_ids):
    batch = b"".join(blob + b"\n" for blob in blob_ids)
    result = source_git(root, ("cat-file", "--batch"), input_data=batch)
    contents = {}
    with io.BytesIO(result.stdout) as stream:
        for blob in blob_ids:
            fields = stream.readline().split()
            if len(fields) != 3 or fields[:2] != [blob, b"blob"] or not fields[2].isdigit():
                raise ValueError("unexpected Git object in Alpha source")
            size = int(fields[2])
            data = stream.read(size)
            if len(data) != size or stream.read(1) != b"\n":
                raise ValueError("incomplete Git blob in Alpha source")
            contents[blob] = data
        if stream.read(1):
            raise ValueError("unexpected Git object in Alpha source")
    return contents


def snapshot_source(root, commit, destination):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("invalid Alpha source commit")
    listing = source_git(root, ("ls-tree", "-r", "-z", "--full-tree", commit, "--", *SNAPSHOT_PATHS)).stdout
    expected = {}
    directories = set()
    for entry in listing.split(b"\0")[:-1]:
        header, name = entry.split(b"\t", 1)
        mode, kind, blob = header.split()
        if kind != b"blob" or mode not in (b"100644", b"100755") or not re.fullmatch(rb"[0-9a-f]{40}", blob):
            raise ValueError("unsupported Git tree entry in Alpha source")
        relative = snapshot_path(os.fsdecode(name))
        if relative in expected:
            raise ValueError("duplicate Git tree entry in Alpha source")
        expected[relative] = (mode == b"100755", blob)
        directories.update(parent for parent in relative.parents if parent.parts)

    # The tar digest alone cannot detect local export attributes that omit or
    # substitute files. Compare every member with its committed Git blob bytes.
    blobs = snapshot_blobs(root, dict.fromkeys(blob for _, blob in expected.values()))
    data = source_git(root, ("archive", "--format=tar", commit, "--", *SNAPSHOT_PATHS)).stdout
    seen_files, seen_dirs = set(), set()
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive:
            relative = snapshot_path(member.name)
            path = destination / relative
            if member.isdir():
                if relative not in directories or relative in seen_dirs:
                    raise ValueError("unexpected directory in Alpha source archive")
                path.mkdir()
                seen_dirs.add(relative)
            elif member.isfile():
                if relative not in expected or relative in seen_files:
                    raise ValueError("unexpected file in Alpha source archive")
                executable, blob = expected[relative]
                if bool(member.mode & 0o100) != executable:
                    raise ValueError("Alpha source archive changed a Git executable mode")
                if member.size != len(blobs[blob]):
                    raise ValueError("Alpha source archive changed Git blob contents")
                with archive.extractfile(member) as source, path.open("xb") as output:
                    contents = source.read()
                    if contents != blobs[blob]:
                        raise ValueError("Alpha source archive changed Git blob contents")
                    output.write(contents)
                path.chmod(0o755 if executable else 0o644)
                seen_files.add(relative)
            else:
                raise ValueError("non-regular snapshot input")
    if seen_files != set(expected) or seen_dirs != directories:
        raise ValueError("Alpha source archive omitted Git tree entries")
    if {PurePosixPath(path.relative_to(destination).as_posix()) for path in destination.rglob("*")} != set(expected) | directories:
        raise ValueError("Alpha source tree paths alias on the staging filesystem")
    return digest(data)


def make_read_only(directory):
    for root, _, files in os.walk(directory, topdown=False):
        for name in files:
            path = Path(root) / name
            path.chmod(0o555 if path.stat().st_mode & stat.S_IXUSR else 0o444)
        Path(root).chmod(0o555)


def prepare(source_root, output_dir, products, team_id, node_file=None):
    root = Path(source_root).resolve(strict=True)
    ios = root / "apps/ios"
    out = Path(output_dir).absolute()
    if out.exists() or out.is_symlink() or out.parent.resolve() != out.parent:
        raise ValueError("output must be a new directory under a canonical parent")
    if out == root or out in root.parents or out == ios or ios in out.parents:
        raise ValueError("output cannot replace source or sit inside iOS inputs")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("invalid team ID")
    products = Path(products).resolve(strict=True)
    if not (products / "AegisEmbeddedCore.xcframework").is_dir():
        raise ValueError("existing EmbeddedCore products required; run verify separately")
    node = private_path(node_file) if node_file else "/dev/null"
    # Paths are inserted inside quoted shell build scripts; reject shell syntax.
    if any(c in str(ios) + str(out) for c in ('"', '$', '`', '\\', '\n', '\r')):
        raise ValueError("source path cannot be represented safely in build scripts")
    source_commit = prepared_source_commit(root)
    with TemporaryDirectory(prefix="alpha-source-", dir=out.parent) as staging:
        snapshot = Path(staging) / "source"
        archive_digest = snapshot_source(root, source_commit, snapshot) if source_commit else None
        return prepare_variant(root, out, products, team_id, node, source_commit, snapshot, archive_digest)


def prepare_variant(root, out, products, team_id, node, source_commit, snapshot, archive_digest):
    ios = (snapshot if source_commit else root) / "apps/ios"
    build_ios = (out / "source" if source_commit else root) / "apps/ios"
    original = (ios / "project.yml").read_bytes()
    spec = copy.deepcopy(load_spec(ios / "project.yml"))
    if set(spec["targets"]) != set(IDS):
        raise ValueError("unexpected target topology; update isolation contract")
    expected_group = {name for name, rule in REPLACEMENTS.items() if rule[0] == OLD_GROUP}
    expected_group |= {"AegisApp/Aegis.entitlements", "ShareExtension/ShareExtension.entitlements"}
    found_group, found_scheme = set(), set()
    for folder in ("Shared", "SharedWebExtension", "AegisApp", "ShareExtension", "SafariWebExtension", "BrowserKit", "AgentKit", "AccessKit", "AegisPolicyKit"):
        for path in (ios / folder).rglob("*"):
            if path.suffix not in (".swift", ".js", ".plist", ".entitlements") or not path.is_file():
                continue
            text = path.read_text()
            rel = path.relative_to(ios).as_posix()
            if OLD_GROUP in text:
                found_group.add(rel)
            if 'gcsa-aegis://' in text or '"gcsa-aegis"' in text or '<string>gcsa-aegis</string>' in text:
                found_scheme.add(rel)
    if found_group != expected_group or found_scheme != {
            "Shared/ExternalPageLink.swift", "SharedWebExtension/background.js", "AegisApp/Info.plist"}:
        raise ValueError("unrecognized runtime AppGroup or external scheme reference")
    files, overlays = {}, []

    def overlay(rel, data, changes):
        before = (ios / rel).read_bytes()
        dest = out / "overlay" / rel
        files[dest] = data
        overlays.append(dict(path="overlay/" + rel, originalSha256=digest(before),
                             overlaySha256=digest(data), replacements=changes))
        return str(dest)

    mapping = {}
    for rel, (old, new, count) in REPLACEMENTS.items():
        text = (ios / rel).read_text()
        if text.count(old) != count:
            raise ValueError("runtime replacement count changed")
        mapping[rel] = overlay(rel, text.replace(old, new).encode(), {"runtimeIdentity": count})
    base = spec["settings"]["base"]
    base.update(DEVELOPMENT_TEAM=team_id, CODE_SIGN_STYLE="Automatic",
                AEGIS_EMBEDDED_CORE_PRODUCTS=str(products))
    for config in spec["settings"]["configs"].values():
        config["AEGIS_ACCESS_RELEASE_CHANNEL"] = "alpha"
        config["AEGIS_ACCESS_INTERNAL_OPTIONS"] = "YES"
    spec["options"]["bundleIdPrefix"] = APP
    # Sources intentionally live outside this generated project. Intermediate
    # parent groups for absolute paths can make XcodeGen traverse toward '/'.
    # Keep explicit source entries without synthesizing ancestor groups.
    spec["options"]["createIntermediateGroups"] = False
    for name, target in spec["targets"].items():
        settings = target["settings"]["base"]
        settings["PRODUCT_BUNDLE_IDENTIFIER"] = APP + IDS[name]
        for key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"):
            if key not in settings:
                continue
            rel = settings[key]
            data = plistlib.loads((ios / rel).read_bytes())
            changes = {}
            if key == "CODE_SIGN_ENTITLEMENTS" and "com.apple.security.application-groups" in data:
                if data["com.apple.security.application-groups"] != [OLD_GROUP]:
                    raise ValueError("unexpected group entitlement")
                data["com.apple.security.application-groups"] = [GROUP]
                changes["appGroup"] = 1
            if name == "Aegis" and key == "INFOPLIST_FILE":
                schemes = data["CFBundleURLTypes"]
                if len(schemes) != 1 or schemes[0]["CFBundleURLSchemes"] != ["gcsa-aegis"]:
                    raise ValueError("unexpected URL scheme topology")
                schemes[0]["CFBundleURLSchemes"] = [SCHEME]
                schemes[0]["CFBundleURLName"] = APP + ".open"
                data["CFBundleDisplayName"] = "Aegis Alpha"
                changes.update(externalScheme=1, urlName=1, displayName=1)
            elif name in ("ShareExtension", "SafariWebExtension") and key == "INFOPLIST_FILE":
                data["CFBundleDisplayName"] += " Alpha"
                changes["displayName"] = 1
            if key == "INFOPLIST_FILE" and name in ("Aegis", "AegisTests", "AegisUITests"):
                data.pop("AegisPreparedSourceCommit", None)
                if source_commit:
                    data["AegisPreparedSourceCommit"] = source_commit
                    changes["preparedSourceCommit"] = 1
            settings[key] = overlay(rel, plistlib.dumps(data, sort_keys=False), changes)
        extra = []
        for source in target["sources"]:
            rel = source["path"]
            if source_commit and not (ios / rel).resolve().exists():
                raise ValueError("Xcode source is missing from the committed snapshot")
            source["path"] = mapping.get(rel, str((build_ios / rel).resolve()))
            if rel == "SharedWebExtension":
                source.setdefault("excludes", []).append("background.js")
                extra.append({"path": mapping["SharedWebExtension/background.js"], "buildPhase": "resources"})
        target["sources"].extend(extra)
        for script in target.get("postBuildScripts", []):
            allowed_scripts = {"Select private Access test node", "Select Aegis Firebase registration",
                               "Select private Access subscription",
                               "Install verified EmbeddedCore manifest"}
            if script.get("name") not in allowed_scripts:
                raise ValueError("unrecognized build script; review source-root conversion")
            # Core verification uses the independently recorded absolute
            # xcfilelist. Only the source compiler and app scripts use the snapshot.
            script_ios = root / "apps/ios" if script["name"] == "Install verified EmbeddedCore manifest" else build_ios
            script["script"] = script["script"].replace('${SRCROOT}/../..', str(root)).replace('${SRCROOT}', str(script_ios))
            for key in ("inputFiles", "inputFileLists"):
                if key in script:
                    script[key] = [p.replace('$(SRCROOT)/../..', str(root)).replace('$(SRCROOT)', str(script_ios)) for p in script[key]]
            if source_commit and script["name"] == "Install verified EmbeddedCore manifest":
                rel = "scripts/release/ios_embedded_core.py"
                build_snapshot = out / "source"
                frozen_verifier = str(build_snapshot / rel)
                script["script"] = script["script"].replace(str(root / rel), frozen_verifier).rstrip()
                script["script"] += f' --prepared-source "{build_snapshot}" {source_commit}\n'
                embedded = snapshot / "apps/ios/EmbeddedCore"
                bridge = embedded / "bridge"
                core_source_inputs = [embedded / "embedded-core-lock.json", bridge, *sorted(bridge.rglob("*"))]
                script["inputFiles"].extend([frozen_verifier, *(str(build_snapshot / p.relative_to(snapshot))
                                                               for p in core_source_inputs)])
        if name == "Aegis":
            settings["AEGIS_PRIVATE_TEST_NODE_FILE"] = node
            settings["AEGIS_FIREBASE_CHANNEL"] = "disabled"
            for config in target["settings"].get("configs", {}).values():
                config["AEGIS_FIREBASE_CHANNEL"] = "disabled"
    for data in files.values():
        if OLD_GROUP.encode() in data or b'gcsa-aegis://' in data or b'<string>gcsa-aegis</string>' in data:
            raise ValueError("production runtime identity remains in overlay")
    generated = (json.dumps(spec, indent=2) + "\n").encode()
    # Receipt intentionally omits spec bytes/paths that could disclose private node location.
    receipt = dict(schemaVersion=1, kind="isolated-alpha-device-test-variant",
                   productSourceUnchanged=True, sourceSpecSha256=digest(original),
                   generatedSpecSha256=digest(generated), appId=APP, appGroup=GROUP,
                   externalScheme=SCHEME, teamId=team_id, firebase="disabled",
                   coreVerification="NOT_RUN", build="NOT_RUN", device="NOT_RUN", overlays=overlays)
    if source_commit:
        receipt["sourceCommit"] = source_commit
        receipt["sourceArchiveSha256"] = archive_digest
    out.mkdir(mode=0o700)
    for path, data in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    if source_commit:
        snapshot.rename(out / "source")
        make_read_only(out / "source")
        make_read_only(out / "overlay")
    (out / "project.yml").write_bytes(generated)
    (out / "preparation-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-root", "output-dir", "embedded-core-products", "team-id"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--node-file")
    args = parser.parse_args()
    try:
        prepare(args.source_root, args.output_dir, args.embedded_core_products, args.team_id, args.node_file)
    except Exception:
        print("Alpha project preparation failed; inspect input contracts and private paths.", file=sys.stderr)
        return 2
    print("Prepared isolated Alpha variant; no build, signing, installation or core recording performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
