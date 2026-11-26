"""Read IPA metadata without extracting arbitrary archive paths or changing a package."""
import argparse
import plistlib
from pathlib import Path
import sys
import zipfile
from safari_manifest import verify as verify_safari_manifest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "licenses"))
import third_party_notices as notices

APP_ID = "com.gcsa.aegis"


def verify(path, version, build, release_profile=None, *, private_alpha_directory=None):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        roots = [n for n in names if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2]
        if len(roots) != 1 or len(names) != len(set(names)):
            raise ValueError("IPA must contain one unambiguous application")
        root = roots[0].removesuffix("Info.plist")
        if archive.getinfo(root + "Info.plist").file_size > 1024 * 1024:
            raise ValueError("Unexpectedly large Info.plist")
        main_info = plistlib.loads(archive.read(root + "Info.plist"))
        if private_alpha_directory is not None:
            from private_alpha_inputs import verify_resources

            if release_profile != "alpha":
                raise ValueError("Private Alpha verification requires the Alpha profile")
            verify_resources(archive, root, main_info, private_alpha_directory)
        elif any(name.replace('\\', '/').rstrip('/').rsplit('/', 1)[-1].casefold()
                 == "aegisalphatestnodes.json" for name in names):
            raise ValueError("Private Alpha resource is forbidden in the standard IPA verifier")
        if (main_info.get("AegisAccessReleaseChannel") not in ("dev", "alpha", "beta")
                or main_info.get("AegisReleaseProfile") not in ("dev", "alpha", "beta")):
            if any(name.rsplit('/', 1)[-1] in ("AegisPrivateTestNode.vless", "AegisPrivateTestSubscription.json") for name in names):
                raise ValueError("Private test resources are forbidden outside Dev/Alpha/Beta")
        expected = {root + "Info.plist": APP_ID,
                    root + "PlugIns/SafariWebExtension.appex/Info.plist": APP_ID + ".safari",
                    root + "PlugIns/ShareExtension.appex/Info.plist": APP_ID + ".share"}
        for member, identifier in expected.items():
            if archive.getinfo(member).file_size > 1024 * 1024:
                raise ValueError("Unexpectedly large Info.plist")
            info = plistlib.loads(archive.read(member))
            if info.get("CFBundleInfoDictionaryVersion") != "6.0":
                raise ValueError("Unsupported plist structure version: " + identifier)
            if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (identifier, version, build):
                raise ValueError("IPA bundle/version/build mismatch: " + identifier)
            if release_profile is not None and info.get("AegisReleaseProfile") != release_profile:
                raise ValueError("IPA release profile mismatch: " + identifier)
            profile = member.removesuffix("Info.plist") + "embedded.mobileprovision"
            if profile not in names:
                raise ValueError("Missing embedded provisioning profile: " + identifier)
        safari_root = root + "PlugIns/SafariWebExtension.appex/"

        def resource(name):
            member = safari_root + name
            if archive.getinfo(member).file_size > 8 * 1024 * 1024:
                raise ValueError("Safari resource is unexpectedly large")
            return archive.read(member)

        verify_safari_manifest(resource)
        notices.verify_ipa(archive)
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("release_profile", nargs="?")
    parser.add_argument("--private-alpha-directory", type=Path)
    args = parser.parse_args()
    try:
        verify(args.path, args.version, args.build, args.release_profile,
               private_alpha_directory=args.private_alpha_directory)
        print("IPA application and extension identities verified")
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        if args.private_alpha_directory is not None:
            sys.exit("Private Alpha IPA verification failed; no private values are logged.")
        sys.exit(str(error))
