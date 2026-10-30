"""Read IPA metadata without extracting arbitrary archive paths or changing a package."""
import plistlib
import sys
import zipfile
from safari_manifest import verify as verify_safari_manifest

APP_ID = "com.gcsa.aegis"


def verify(path, version, build, release_profile=None):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        roots = [n for n in names if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2]
        if len(roots) != 1 or len(names) != len(set(names)):
            raise ValueError("IPA must contain one unambiguous application")
        root = roots[0].removesuffix("Info.plist")
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
    return True


if __name__ == "__main__":
    try:
        verify(*sys.argv[1:])
        print("IPA application and extension identities verified")
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
