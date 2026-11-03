#!/usr/bin/env python3
"""Offline generation and package checks for Aegis-added third-party notices.

Chromium's generated chrome://credits remains required separately. This is not
a complete SBOM, a linker inventory, or a release-qualification decision.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ENHANCEMENTS = "apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared/vendor"
LOCAL_AI = "apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai"
RULES = "apps/ios/BrowserKit/Resources"
SDK = "scripts/licenses/sdk-licenses"
IOS_OUTPUT = "apps/ios/AegisApp/ThirdPartyNotices.txt"
MAC_OUTPUT = "apps/browser/MACOS_THIRD_PARTY_NOTICES.txt"
JS_LICENSES = ["markdown-it-LICENSE", "DOMPurify-LICENSE", "task-lists-LICENSE",
               "acorn-LICENSE", "highlight-LICENSE"]


def read(root, relative):
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Missing or symlinked notice input: {relative}")
    return path.read_bytes()


def sdk_records(root):
    records = json.loads(read(root, f"{SDK}/manifest.json"))
    pins = json.loads(read(root, "apps/ios/Aegis.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))["pins"]
    expected = {(p["identity"], p["state"]["version"], p["state"]["revision"], p["location"]) for p in pins}
    actual = {(p["identity"], p["version"], p["revision"], p["repository"]) for p in records}
    if expected != actual or len(records) != len(expected):
        raise ValueError("Swift Package pins changed; refresh the SDK license inventory")
    for item in records:
        for notice in [item, *item.get("additionalNotices", [])]:
            name = notice["file"]
            if Path(name).name != name:
                raise ValueError("Invalid SDK license filename")
            if hashlib.sha256(read(root, f"{SDK}/{name}")).hexdigest() != notice["sha256"]:
                raise ValueError(f"SDK license hash mismatch: {item['identity']} / {name}")
    return records


def render(platform, root=ROOT):
    sections = ["GCSA Aegis — Third-party licenses and acknowledgements\n",
                "Third-party works retain their own licenses. These notices do not change those licenses.\n"]

    def include(title, path):
        sections.append(f"\n{'=' * 72}\n{title}\nSource file: {path}\n\n" + read(root, path).decode("utf-8").rstrip() + "\n")

    include("Web enhancements — component versions and sources", f"{ENHANCEMENTS}/NOTICE.txt")
    for name in JS_LICENSES:
        include(name, f"{ENHANCEMENTS}/{name}")
    if platform == "macos":
        sections.append("\nChromium and its bundled dependencies: open chrome://credits in Aegis.\n"
                        "The following notices supplement, and do not replace, Chromium's generated credits.\n")
        include("libtorrent-rasterbar 2.1.1 — BSD-3-Clause — https://www.libtorrent.org/",
                "apps/browser/overlay/third_party/aegis_libtorrent/LICENSE")
        for title, name in [("libtorrent upstream complete license and component notices", "UPSTREAM_LICENSE.txt"),
                            ("Apple Public Source License 2.0", "APSL-2.0.txt"),
                            ("Bundled routing-header source availability", "SOURCE_OFFER.txt")]:
            include(title, f"apps/browser/overlay/third_party/aegis_libtorrent/{name}")
        include("Boost headers used by the libtorrent integration — Boost Software License 1.0",
                "apps/browser/overlay/third_party/aegis_libtorrent/BOOST_LICENSE_1_0.txt")
        for title, name in [("libtorrent bundled try_signal — BSD-3-Clause", "TRY_SIGNAL_LICENSE.txt"),
                            ("libtorrent bundled ed25519 — public-domain and zlib declarations", "ED25519_LICENSE.txt")]:
            include(title, f"apps/browser/overlay/third_party/aegis_libtorrent/{name}")
        include("Local translation and model runtime — sources and modifications", f"{LOCAL_AI}/NOTICE.txt")
        for name in ["bergamot/LICENSE", "vendor/fzstd-LICENSE", "vendor/js-md5-LICENSE", "vendor/onnxruntime-web-LICENSE", "vendor/onnxruntime-web-NOTICES"]:
            include(name, f"{LOCAL_AI}/{name}")
        sections.append("\nBergamot modified source is distributed in the Aegis source repository:\n"
                        "https://github.com/gcsagroup/aegis-browser/tree/ea594be84df63c0514b94f9ab3873b36a2af3752/"
                        "apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/bergamot\n"
                        "Downloaded model weights have separate notices and are not covered by this inventory.\n")
    elif platform == "ios":
        include("EasyList and EasyPrivacy — The EasyList authors", f"{RULES}/FILTER-LICENSE.txt")
        include("NoCoin — Hosh — https://github.com/hoshsadiq/adblock-nocoin-list", f"{RULES}/nocoin-LICENSE.txt")
        include("Phishing Block List — The Block List Project", f"{RULES}/phishing-LICENSE.txt")
        include("Rule snapshot provenance", f"{RULES}/security-rules-sources.json")
        sections.append("\nPublic Suffix List — MPL-2.0\n"
                        "The unmodified source list is included in AegisPolicyKit.framework/public_suffix_list.dat.\n"
                        "Source snapshot: https://github.com/publicsuffix/list/blob/"
                        "3929462652695bad04f0a27afb600974014a3c8b/public_suffix_list.dat\n")
        include("Mozilla Public License 2.0 (Public Suffix List)", f"{LOCAL_AI}/bergamot/LICENSE")
        sections.append("\nSwift Package SDK notices\n"
                        "This section preserves the repository license for every resolved package, including optional dependencies.\n"
                        "It is not an assertion that each package is linked into this app.\n"
                        "Repository source licenses do not establish the license of precompiled SDK binaries.\n"
                        "Google Analytics is not open source; use is also subject to Google's applicable SDK/service terms:\n"
                        "https://developers.google.com/terms and https://firebase.google.com/terms/analytics\n")
        for item in sdk_records(root):
            include(f"{item['identity']} {item['version']}\n{item['url']}", f"{SDK}/{item['file']}")
            for notice in item.get("additionalNotices", []):
                include(f"{notice['component']}\n{notice['url']}", f"{SDK}/{notice['file']}")
    else:
        raise ValueError("Unsupported notice platform")
    return "\n".join(sections).encode("utf-8")


def check_outputs(root=ROOT):
    for platform, path in [("ios", IOS_OUTPUT), ("macos", MAC_OUTPUT)]:
        if read(root, path) != render(platform, root):
            raise ValueError(f"Stale generated notices: {path}; run scripts/licenses/third_party_notices.py generate")


def ipa_members(root=ROOT):
    """License resources which must survive Xcode's archive/export steps."""
    members = {"Payload/Aegis.app/ThirdPartyNotices.txt": render("ios", root)}
    framework = "Payload/Aegis.app/Frameworks/BrowserKit.framework/"
    for name in ["FILTER-LICENSE.txt", "nocoin-LICENSE.txt", "phishing-LICENSE.txt", "security-rules-sources.json"]:
        members[framework + name] = read(root, f"{RULES}/{name}")
    for name in [*JS_LICENSES, "NOTICE.txt"]:
        members[framework + "enhancements_shared/vendor/" + name] = read(root, f"{ENHANCEMENTS}/{name}")
    members["Payload/Aegis.app/Frameworks/AegisPolicyKit.framework/public_suffix_list.dat"] = read(root, "apps/ios/AegisPolicyKit/Resources/public_suffix_list.dat")
    return members


def verify_ipa(archive, root=ROOT):
    if len(archive.namelist()) != len(set(archive.namelist())):
        raise ValueError("Ambiguous IPA members")
    for name, content in ipa_members(root).items():
        try:
            info = archive.getinfo(name)
        except KeyError as exc:
            raise ValueError(f"Missing IPA license resource: {name}") from exc
        if info.file_size != len(content) or archive.read(info) != content:
            raise ValueError(f"IPA license resource differs from source: {name}")


def install_macos(bundle, root=ROOT):
    if bundle.is_symlink():
        raise ValueError("Symlink in staged macOS application path")
    # macOS temporary directories may have the system /var -> /private/var alias.
    # Resolve the chosen bundle, then reject symlinks inside that bundle.
    bundle = bundle.resolve()
    directory = bundle / "Contents/Resources"
    output = directory / "AegisThirdPartyNotices.txt"
    source_output = directory / "AegisLibtorrentRouteSource.txt"
    for path in [output, source_output, directory, bundle / "Contents"]:
        if path.is_symlink():
            raise ValueError(f"Symlink in bundle notice path: {path}")
    if not bundle.is_dir():
        raise ValueError("Missing staged macOS application")
    check_outputs(root)
    directory.mkdir(parents=True, exist_ok=True)
    output.write_bytes(render("macos", root))
    source_output.write_bytes(read(root, "apps/browser/overlay/third_party/aegis_libtorrent/UPSTREAM_ROUTE_H.txt"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["generate", "check", "install-macos", "verify-ipa"])
    parser.add_argument("artifact", type=Path, nargs="?")
    args = parser.parse_args()
    if args.operation == "generate":
        for platform, path in [("ios", IOS_OUTPUT), ("macos", MAC_OUTPUT)]:
            (ROOT / path).write_bytes(render(platform))
    elif args.operation == "check":
        check_outputs()
    elif args.artifact is None:
        parser.error("artifact is required")
    elif args.operation == "install-macos":
        install_macos(args.artifact)
    else:
        with zipfile.ZipFile(args.artifact) as archive:
            verify_ipa(archive)
    print("Aegis third-party notice check passed (not full release acceptance)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
