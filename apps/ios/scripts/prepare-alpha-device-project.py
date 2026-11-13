#!/usr/bin/env python3
"""Prepare an isolated Alpha device-test variant; never build, sign or install.

Uses installed PyYAML, or system Ruby safe_load. Output project.yml is JSON
(a YAML subset). Source files stay unchanged; overlays are explicitly receipted.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

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


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_spec(path):
    try:
        import yaml
    except ImportError:
        code = 'require "yaml"; require "json"; puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), [], [], false))'
        result = subprocess.run(["/usr/bin/ruby", "-e", code, str(path)],
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
    if any(c in str(ios) for c in ('"', '$', '`', '\n', '\r')):
        raise ValueError("source path cannot be represented safely in build scripts")
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
            settings[key] = overlay(rel, plistlib.dumps(data, sort_keys=False), changes)
        extra = []
        for source in target["sources"]:
            rel = source["path"]
            source["path"] = mapping.get(rel, str((ios / rel).resolve()))
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
            script["script"] = script["script"].replace('${SRCROOT}/../..', str(root)).replace('${SRCROOT}', str(ios))
            for key in ("inputFiles", "inputFileLists"):
                if key in script:
                    script[key] = [p.replace('$(SRCROOT)/../..', str(root)).replace('$(SRCROOT)', str(ios)) for p in script[key]]
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
    out.mkdir(mode=0o700)
    for path, data in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
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
