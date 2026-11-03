#!/usr/bin/env python3
"""Compile real string resources and exercise Apple Foundation in fresh processes.

This is a macOS host check, not an iOS Simulator/device acceptance result.
All temporary files stay in the chosen --work-dir (default: a new /tmp directory).
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def digest(value):
    canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def plist(path):
    return json.loads(run("plutil", "-convert", "json", "-o", "-", path))


def validate_sources(contract, catalog):
    strings = catalog["strings"]
    locales = set(contract["resourceLocales"])
    assert catalog["sourceLanguage"] == "zh-Hans"
    assert set(contract["requestedLocales"]) == locales | set(contract["regionalFallbacks"])
    assert {locale for entry in strings.values() for locale in entry["localizations"]} == locales
    for locale, expected in contract["preservedLocalizationsSHA256"].items():
        original = {key: strings[key]["localizations"][locale] for key in contract["preservedKeys"]}
        assert digest(original) == expected, f"Existing {locale} translations changed"
    for locale, expected in contract["preservedInfoPlistPrefixes"].items():
        content = (ROOT / f"AegisApp/{locale}.lproj/InfoPlist.strings").read_bytes()
        assert hashlib.sha256(content[:expected["byteCount"]]).hexdigest() == expected["sha256"]
    # Foundation does not fall through to en per missing key in a selected locale.
    # Every entry outside the translated slice must be an explicit English fallback.
    fallback_locales = locales - {"en", "zh-Hans", "zh-Hant"}
    for key in strings.keys() - set(contract["sliceKeys"]):
        english = strings[key]["localizations"]["en"]["stringUnit"]["value"]
        for locale in fallback_locales:
            unit = strings[key]["localizations"].get(locale, {}).get("stringUnit", {})
            assert unit.get("state") == "needs_review", (locale, key, "Fallback must remain needs_review")
            assert unit.get("value") == english, (locale, key, "Fallback must match en")
    for key in contract["sliceKeys"]:
        expected_formats = Counter(re.findall(r"%(?:\d+\$)?(?:lld|ld|@|d|f|s)", key))
        for locale in locales:
            unit = strings[key]["localizations"][locale]["stringUnit"]
            value = unit["value"]
            assert unit["state"] == "translated" and value.strip(), (locale, key)
            assert Counter(re.findall(r"%(?:\d+\$)?(?:lld|ld|@|d|f|s)", value)) == expected_formats, (locale, key)
            if locale not in {"en", "zh-Hans", "zh-Hant"}:
                english = strings[key]["localizations"]["en"]["stringUnit"]["value"]
                if value == english:
                    assert key in contract["identicalEnglishAllowlist"].get(locale, []), (locale, key, "English placeholder")
    for target in ["AegisApp", "ShareExtension", "SafariWebExtension"]:
        assert {p.stem for p in (ROOT / target).glob("*.lproj")} == locales
        assert plist(ROOT / target / "Info.plist")["CFBundleDevelopmentRegion"] == "zh-Hans"
        for locale in locales:
            values = plist(ROOT / target / f"{locale}.lproj/InfoPlist.strings")
            expected = {"NSCameraUsageDescription", "NSMicrophoneUsageDescription", "Markdown 文档"} if target == "AegisApp" else {"CFBundleDisplayName"}
            assert set(values) == expected and all(values.values()), (target, locale)


def validate_project(locales):
    project = plist(ROOT / "Aegis.xcodeproj/project.pbxproj")
    objects = project["objects"]
    assert set(objects[project["rootObject"]]["knownRegions"]) == set(locales) | {"Base"}
    assert objects[project["rootObject"]]["developmentRegion"] == "zh-Hans"
    for target, folder in [("Aegis", "AegisApp"), ("ShareExtension", "ShareExtension"), ("SafariWebExtension", "SafariWebExtension")]:
        target_object = next(v for v in objects.values() if v["isa"] == "PBXNativeTarget" and v["name"] == target)
        phase = next(objects[key] for key in target_object["buildPhases"] if objects[key]["isa"] == "PBXResourcesBuildPhase")
        refs = [objects[key]["fileRef"] for key in phase["files"]]
        group = next(v for v in objects.values() if v["isa"] == "PBXGroup" and v.get("path") == folder)
        variant_id = next(key for key in group["children"] if objects[key]["isa"] == "PBXVariantGroup")
        assert variant_id in refs, f"Unbundled InfoPlist.strings: {target}"
        assert {objects[key]["name"] for key in objects[variant_id]["children"]} == set(locales)
        for key in objects[variant_id]["children"]:
            assert (ROOT / folder / objects[key]["path"]).is_file()
        if target in {"Aegis", "ShareExtension"}:
            assert any(objects[key].get("path") == "Localizable.xcstrings" for key in refs)
        if target in {"Aegis", "SafariWebExtension"}:
            assert any(objects[key].get("path") == "_locales" and objects[key].get("lastKnownFileType") == "folder" for key in refs)
    spec = (ROOT / "project.yml").read_text()
    # Keep the directory hierarchy: flattening messages.json breaks WebExtension i18n.
    assert spec.count("path: SharedWebExtension/_locales\n        type: folder\n        buildPhase: resources") == 2


def validate_web_extension():
    manifest = json.loads((ROOT / "SharedWebExtension/manifest.json").read_text())
    assert manifest["default_locale"] == "en"
    assert manifest["permissions"] == ["activeTab", "scripting", "nativeMessaging", "webNavigation"]
    assert manifest["content_security_policy"]["extension_pages"] == "script-src 'self'; object-src 'none'"
    tokens = [manifest["name"], manifest["description"], manifest["action"]["default_title"]]
    expected = {re.fullmatch(r"__MSG_(\w+)__", token).group(1) for token in tokens}
    directories = ROOT / "SharedWebExtension/_locales"
    assert {p.name for p in directories.iterdir()} == set("de en es fr id it ja ko ms pt_BR pt_PT th vi zh_CN zh_TW".split())
    for path in directories.glob("*/messages.json"):
        messages = json.loads(path.read_text())
        assert set(messages) == expected and all(item["message"].strip() for item in messages.values())


def exercise_bundles(work, contract, catalog):
    app = work / "Probe.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    info = {"CFBundleIdentifier": "test.aegis.localizations", "CFBundleDevelopmentRegion": "zh-Hans",
            "CFBundleExecutable": "bundle-probe", "CFBundlePackageType": "APPL"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run("xcrun", "xcstringstool", "compile", ROOT / "AegisApp/Localizable.xcstrings", "--output-directory", resources)
    assert {p.stem for p in resources.glob("*.lproj")} == set(contract["resourceLocales"])
    for target in ["AegisApp", "ShareExtension", "SafariWebExtension"]:
        bundle = work / f"{target}.bundle"
        bundle.mkdir()
        system_info = plist(ROOT / target / "Info.plist")
        system_info.update({"CFBundleIdentifier": f"test.aegis.{target}",
                            "NSCameraUsageDescription": "UNLOCALIZED", "CFBundleDisplayName": "UNLOCALIZED"})
        (bundle / "Info.plist").write_bytes(plistlib.dumps(system_info))
        for path in (ROOT / target).glob("*.lproj"):
            shutil.copytree(path, bundle / path.name)
    hostile = work / "Hostile.bundle"
    hostile.mkdir()
    (hostile / "Info.plist").write_bytes(plistlib.dumps(info))
    for locale in contract["resourceLocales"]:
        directory = hostile / f"{locale}.lproj"
        directory.mkdir()
        (directory / "Localizable.strings").write_bytes(plistlib.dumps({"安心浏览，清楚掌控。": '<script> & " \''}))
    keys = work / "keys.json"
    keys.write_text(json.dumps(contract["sliceKeys"], ensure_ascii=False))
    executable = app / "Contents/MacOS/bundle-probe"
    executable.parent.mkdir()
    run("xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", work / "module-cache",
        ROOT / "Tests/Localization/main.swift", ROOT / "BrowserKit/FixtureSchemeHandler.swift",
        ROOT / "Shared/ShareInbox.swift", "-o", executable)
    for locale in contract["requestedLocales"]:
        print(run(executable, app, locale, keys, work, hostile, ROOT / "SharedWebExtension",
                  "-AppleLanguages", f"({locale})").strip(), flush=True)
    # Resource availability is not translation completion: report the states separately.
    for locale in contract["resourceLocales"]:
        states = Counter(entry["localizations"][locale]["stringUnit"]["state"]
                         for entry in catalog["strings"].values())
        print(f"Coverage {locale}: {states['translated']} translated; "
              f"{states['needs_review']} English fallback (needs_review); "
              f"{len(catalog['strings'])} total catalog entries")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=pathlib.Path, help="new directory for retained test artifacts")
    args = parser.parse_args()
    if args.work_dir:
        args.work_dir.mkdir(parents=True, exist_ok=False)
        work = args.work_dir.resolve()
    else:
        work = pathlib.Path(tempfile.mkdtemp(prefix="aegis-ios-localization-", dir="/tmp"))
    print(f"Artifacts: {work}", flush=True)
    contract = json.loads((ROOT / "Tests/Localization/coverage.json").read_text())
    catalog = json.loads((ROOT / "AegisApp/Localizable.xcstrings").read_text())
    validate_sources(contract, catalog)
    validate_project(contract["resourceLocales"])
    validate_web_extension()
    exercise_bundles(work, contract, catalog)
    print("PASS: source preservation, registration, compiled resources and macOS Foundation behavior")


if __name__ == "__main__":
    main()
