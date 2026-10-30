"""Verify an exported iOS IPA without signing, credentials or source modification."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

APP_ID = "com.gcsa.aegis"
TARGETS = {APP_ID: "", APP_ID + ".safari": "PlugIns/SafariWebExtension.appex", APP_ID + ".share": "PlugIns/ShareExtension.appex"}
SHARED = Path("apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared")


def command(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise ValueError(Path(args[0]).name + " verification failed")
    return result.stdout


def verify(ipa, version, build, profile, team, certificate_sha1, profiles, source_root):
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[A-Fa-f0-9]{40}", certificate_sha1):
        raise ValueError("Provide the expected Apple team and certificate SHA-1")
    if sorted(profiles) != sorted(TARGETS):
        raise ValueError("Expected App Store profile names for all three targets")
    with zipfile.ZipFile(ipa) as archive:
        infos = archive.infolist()
        names = [i.filename for i in infos]
        if len(set(names)) != len(names):
            raise ValueError("Duplicate archive member")
        if len(infos) > 20000 or sum(i.file_size for i in infos) > 512 * 1024 * 1024:
            raise ValueError("Archive exceeds verification size bounds")
        for item in infos:
            path = Path(item.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in item.filename:
                raise ValueError("Unsafe archive path")
            if stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError("Archive symlink is not accepted")
        spec = importlib.util.spec_from_file_location("aegis_ipa_structure", Path(__file__).with_name("verify-ipa.py"))
        structure = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(structure)
        structure.verify(ipa, version, build, profile)
        with tempfile.TemporaryDirectory(prefix="aegis-ios-verification-") as temporary:
            root = Path(temporary)
            archive.extractall(root)
            app = root / "Payload/Aegis.app"
            info = plistlib.loads((app / "Info.plist").read_bytes())
            if info.get("TFInternalTestingOnly", False) is not (profile == "alpha"):
                raise ValueError("Native TestFlight audience marker differs from profile")
            source_root = Path(source_root).resolve()
            tracked = command("git", "-C", str(source_root), "ls-files", "-z", str(SHARED)).decode().split("\0")
            shared_count = 0
            for relative in filter(None, tracked):
                source = source_root / relative
                exported = app / "Frameworks/BrowserKit.framework/enhancements_shared" / Path(relative).relative_to(SHARED)
                if not exported.is_file() or hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(exported.read_bytes()).digest():
                    raise ValueError("Shared resource missing or differs: " + relative)
                shared_count += 1
            if shared_count == 0:
                raise ValueError("No committed shared resources were verified")
            command("codesign", "--verify", "--deep", "--strict", str(app))
            checked = []
            for identifier, relative in TARGETS.items():
                bundle = app / relative
                provision = plistlib.loads(command("security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")))
                entitlements = provision.get("Entitlements", {})
                if (provision.get("TeamIdentifier") != [team] or provision.get("Name") != profiles[identifier]
                        or entitlements.get("application-identifier") != team + "." + identifier
                        or entitlements.get("get-task-allow") is not False
                        or "ProvisionedDevices" in provision or "ProvisionsAllDevices" in provision
                        or entitlements.get("com.apple.security.application-groups") != ["group.com.gcsa.aegis.ios.share-inbox"]):
                    raise ValueError("App Store provisioning differs: " + identifier)
                certificates = root / (identifier + "-certificates")
                certificates.mkdir()
                prefix = certificates / "Distribution"
                command("codesign", "-d", "--extract-certificates=" + str(prefix), str(bundle))
                fingerprint = hashlib.sha1(Path(str(prefix) + "0").read_bytes()).hexdigest().upper()
                if fingerprint != certificate_sha1.upper():
                    raise ValueError("Signing certificate differs: " + identifier)
                if not any(hashlib.sha1(c).hexdigest().upper() == fingerprint for c in provision.get("DeveloperCertificates", [])):
                    raise ValueError("Signing certificate absent from profile: " + identifier)
                checked.append({"applicationId": identifier, "profileName": provision["Name"], "profileUuid": provision["UUID"], "certificateSha1": fingerprint})
    return {"ipaSha256": hashlib.sha256(Path(ipa).read_bytes()).hexdigest(), "profile": profile,
            "version": version, "build": build, "deepSignatureVerification": True,
            "testFlightInternalTestingOnly": profile == "alpha", "sharedResourcesVerified": shared_count,
            "bundles": checked, "deviceAcceptance": "not_verified"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ipa", "version", "build", "profile"):
        parser.add_argument(name)
    parser.add_argument("--team", required=True)
    parser.add_argument("--certificate-sha1", required=True)
    parser.add_argument("--profiles-json", required=True)
    parser.add_argument("--source-root", required=True)
    options = parser.parse_args()
    try:
        result = verify(options.ipa, options.version, options.build, options.profile, options.team,
                        options.certificate_sha1, json.loads(options.profiles_json), options.source_root)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException):
        # Explicit diagnostic text is useful but never echo subprocess output or credentials.
        error = sys.exc_info()[1]
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
