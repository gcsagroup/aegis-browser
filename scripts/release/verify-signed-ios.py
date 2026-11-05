"""Verify an exported iOS IPA without signing, credentials or source modification."""
import argparse
import ctypes
import datetime
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


def verified_profile(raw):
    """Verify CMS and the Apple provisioning signer, then decode the verified bytes."""
    if sys.platform != 'darwin' or not raw or len(raw) > 5 * 1024 * 1024:
        raise ValueError('Apple provisioning profile trust verification requires macOS and bounded CMS data')
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    try:
        policy_factory = security.SecPolicyCreateiPhoneProvisioningProfileSigning
        verify_cms = security.SecCMSVerifyCopyDataAndAttributes
    except AttributeError:
        raise ValueError('Required Apple provisioning verification policy is unavailable') from None
    core.CFDataCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long]
    core.CFDataCreate.restype = ctypes.c_void_p
    core.CFDataGetLength.argtypes = [ctypes.c_void_p]
    core.CFDataGetLength.restype = ctypes.c_long
    core.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    core.CFDataGetBytePtr.restype = ctypes.c_void_p
    core.CFRelease.argtypes = [ctypes.c_void_p]
    core.CFRelease.restype = None
    policy_factory.argtypes = []
    policy_factory.restype = ctypes.c_void_p
    verify_cms.argtypes = [ctypes.c_void_p] * 6
    verify_cms.restype = ctypes.c_int
    data, policy, content = None, None, ctypes.c_void_p()
    try:
        data = core.CFDataCreate(None, ctypes.create_string_buffer(raw), len(raw))
        policy = policy_factory()
        if not data or not policy:
            raise ValueError('Apple provisioning verification policy could not be created')
        # A NULL policy only decodes; a non-NULL trust output defers trust evaluation.
        # Keep the explicit Apple profile policy and NULL trust output to verify both.
        status = verify_cms(data, None, policy, None, ctypes.byref(content), None)
        if status or not content:
            raise ValueError('Apple provisioning CMS signature or signer trust failed')
        length, pointer = core.CFDataGetLength(content), core.CFDataGetBytePtr(content)
        if not pointer or not 0 < length <= 5 * 1024 * 1024:
            raise ValueError('Invalid verified provisioning content')
        return plistlib.loads(ctypes.string_at(pointer, length))
    finally:
        for reference in [content, policy, data]:
            if reference:
                core.CFRelease(reference)


def verify_distribution_signer(bundle, team):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Explicit Apple signer team required')
    requirement = ('anchor apple generic and certificate leaf[subject.OU] = "' + team +
                   '" and certificate leaf[field.1.2.840.113635.100.6.1.4] exists')
    command('codesign', '--verify', '--strict', '-R', '=' + requirement, str(bundle))


def verify_encryption_declaration(source_info, exported_info):
    key = 'ITSAppUsesNonExemptEncryption'
    if key not in source_info:
        return None  # Historical source/packages did not declare this plist key.
    value = source_info[key]
    if type(value) is not bool or type(exported_info.get(key)) is not bool or exported_info[key] is not value:
        raise ValueError('Exported encryption declaration must match committed Boolean Info.plist value')
    return value


def validate_cloud_profile(provision, signed, identifier, team, fingerprint, *, requested_entitlements=None):
    """Accept rotation, while enforcing the actual signed App Store identity."""
    expiration = provision.get('ExpirationDate')
    expected = {'application-identifier': team + '.' + identifier,
                'com.apple.developer.team-identifier': team,
                'get-task-allow': False}
    requested = ({'com.apple.security.application-groups': ['group.com.gcsa.aegis.ios.share-inbox']}
                 if requested_entitlements is None else requested_entitlements)
    if (provision.get('TeamIdentifier') != [team]
            or not isinstance(expiration, datetime.datetime)
            or expiration <= datetime.datetime.utcnow()
            or not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', provision.get('UUID', ''))
            or not provision.get('Name') or 'ProvisionedDevices' in provision or 'ProvisionsAllDevices' in provision):
        raise ValueError('Invalid cloud App Store profile: ' + identifier)
    for key, value in expected.items():
        if (type(signed.get(key)) is not type(value) or signed[key] != value
                or provision.get('Entitlements', {}).get(key) != value):
            raise ValueError('Cloud signed entitlement differs: ' + identifier + ' ' + key)
    for key, value in requested.items():
        if type(signed.get(key)) is not type(value) or signed[key] != value:
            raise ValueError('Cloud signed entitlement differs from source: ' + identifier + ' ' + key)
    group_key = 'com.apple.security.application-groups'
    if (signed.get(group_key) != requested.get(group_key)
            or provision.get('Entitlements', {}).get(group_key) != ['group.com.gcsa.aegis.ios.share-inbox']):
        raise ValueError('Cloud App Group differs from source/profile: ' + identifier)
    if not any(hashlib.sha1(c).hexdigest().upper() == fingerprint for c in provision.get('DeveloperCertificates', [])):
        raise ValueError('Cloud signing certificate absent from profile: ' + identifier)


def verify(ipa, version, build, profile, team, certificate_sha1, profiles, source_root, *, cloud_poc=False):
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or (not cloud_poc and not re.fullmatch(r"[A-Fa-f0-9]{40}", certificate_sha1)):
        raise ValueError("Provide the expected Apple team and certificate SHA-1")
    if not cloud_poc and sorted(profiles) != sorted(TARGETS):
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
            declaration = verify_encryption_declaration(plistlib.loads((source_root/'apps/ios/AegisApp/Info.plist').read_bytes()), info)
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
                provision = (verified_profile((bundle / 'embedded.mobileprovision').read_bytes()) if cloud_poc else
                             plistlib.loads(command("security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision"))))
                entitlements = provision.get("Entitlements", {})
                if not cloud_poc and (provision.get("TeamIdentifier") != [team] or provision.get("Name") != profiles[identifier]
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
                if not cloud_poc and fingerprint != certificate_sha1.upper():
                    raise ValueError("Signing certificate differs: " + identifier)
                if not any(hashlib.sha1(c).hexdigest().upper() == fingerprint for c in provision.get("DeveloperCertificates", [])):
                    raise ValueError("Signing certificate absent from profile: " + identifier)
                if cloud_poc:
                    verify_distribution_signer(bundle, team)
                    signed = plistlib.loads(command('codesign', '-d', '--entitlements', ':-', str(bundle)))
                    entitlement_paths = {APP_ID: 'AegisApp/Aegis.entitlements',
                                         APP_ID + '.safari': 'SafariWebExtension/SafariWebExtension.entitlements',
                                         APP_ID + '.share': 'ShareExtension/ShareExtension.entitlements'}
                    requested = plistlib.loads((source_root / 'apps/ios' / entitlement_paths[identifier]).read_bytes())
                    validate_cloud_profile(provision, signed, identifier, team, fingerprint, requested_entitlements=requested)
                    # Require an Apple-trusted code-signing chain, independently of the profile.
                    chain = sorted(certificates.glob('Distribution*'))
                    command('security', 'verify-cert', '-p', 'codeSign', *[v for c in chain for v in ('-c', str(c))])
                checked.append({"applicationId": identifier, "profileName": provision["Name"], "profileUuid": provision["UUID"], "certificateSha1": fingerprint})
    result = {"ipaSha256": hashlib.sha256(Path(ipa).read_bytes()).hexdigest(), "profile": profile,
            "version": version, "build": build, "deepSignatureVerification": True,
            "testFlightInternalTestingOnly": profile == "alpha", "sharedResourcesVerified": shared_count,
            "usesNonExemptEncryption": declaration,
            "bundles": checked, "deviceAcceptance": "not_verified"}
    if cloud_poc:
        result.update(profileCmsTrustVerified=True, distributionSignerTeamVerified=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ipa", "version", "build", "profile"):
        parser.add_argument(name)
    parser.add_argument("--team", required=True)
    parser.add_argument("--signing-mode", choices=['manual', 'cloud'], default='manual')
    parser.add_argument("--certificate-sha1")
    parser.add_argument("--profiles-json")
    parser.add_argument("--expected-verification", type=Path)
    parser.add_argument("--source-root", required=True)
    options = parser.parse_args()
    try:
        if options.signing_mode == 'manual' and (not options.certificate_sha1 or not options.profiles_json):
            raise ValueError('Manual verification requires the expected certificate and profile names')
        if options.signing_mode == 'cloud' and options.expected_verification is None:
            raise ValueError('Cloud re-verification requires the source-bound expected verification receipt')
        result = verify(options.ipa, options.version, options.build, options.profile, options.team,
                        options.certificate_sha1, json.loads(options.profiles_json) if options.profiles_json else None,
                        options.source_root, cloud_poc=options.signing_mode == 'cloud')
        if options.signing_mode == 'cloud':
            expected = json.loads(options.expected_verification.read_text())
            if any(result[key] != expected[key] for key in ['ipaSha256', 'version', 'build', 'profile', 'bundles']):
                raise ValueError('Cloud signature differs from the expected artifact receipt')
        print(json.dumps(result, sort_keys=True))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException):
        # Explicit diagnostic text is useful but never echo subprocess output or credentials.
        error = sys.exc_info()[1]
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
