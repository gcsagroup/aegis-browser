#!/usr/bin/env python3
"""Compile real string resources and exercise Apple Foundation in fresh processes.

This is a macOS host check, not an iOS Simulator/device acceptance result.
All temporary files stay in the chosen --work-dir (default: a new /tmp directory).
"""
import argparse
import copy
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
FIXTURES = ROOT / "Tests/Fixtures/Localization"
FORMAT = re.compile(r"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSpn%]")


def require(condition, message):
    """Validation must remain active even when Python optimization is enabled."""
    if not condition:
        raise ValueError(message)


def digest(value):
    canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def plist(path):
    return json.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                                              text=True, shell=False))


def numbers(value):
    value = FORMAT.sub("", value)
    # Normalize localized thousands separators without dropping decimal points.
    value = re.sub(r"(?<=\d)[ .,\u00a0\u202f](?=\d{3}(?:\D|$))", "", value)
    return Counter(re.findall(r"\d+(?:\.\d+)?", value))


def validate_catalog(contract, catalog, probes):
    strings = catalog["strings"]
    locales = set(contract["resourceLocales"])
    require(catalog["sourceLanguage"] == "zh-Hans", 'Guard failed: catalog["sourceLanguage"] == "zh-Hans"')
    additions = set(contract.get("languageSelectorAddedKeys", []))
    require(additions == {"语言", "地区版本自动匹配系统语言偏好，地区格式保持系统设置。"}, 'Guard failed: additions == {"语言", "地区版本自动匹配系统语言偏好，地区格式保持系统设置。"}')
    require(additions <= set(strings), 'Guard failed: additions <= set(strings)')
    require(len(strings) == contract["catalogKeyCount"] + len(additions), 'Guard failed: len(strings) == contract["catalogKeyCount"] + len(additions)')
    require(digest(sorted(set(strings) - additions)) == contract["catalogInventorySHA256"], "Catalog key inventory changed")
    require(set(contract["requestedLocales"]) == locales | set(contract["regionalFallbacks"]), 'Guard failed: set(contract["requestedLocales"]) == locales | set(contract["regionalFallbacks"])')
    require({locale for entry in strings.values() for locale in entry["localizations"]} == locales, 'Guard failed: {locale for entry in strings.values() for locale in entry["localizations"]} == locales')
    for locale, expected in contract["preservedLocalizationsSHA256"].items():
        original = {key: strings[key]["localizations"][locale] for key in contract["preservedKeys"]}
        require(digest(original) == expected, f"Existing {locale} translations changed")
    for locale, expected in contract["preservedAddedLocalizationsSHA256"].items():
        original = {key: strings[key]["localizations"][locale] for key in contract["preservedAddedLocaleKeys"]}
        require(digest(original) == expected, f"Existing {locale} translations changed")
    added = locales - {"en", "zh-Hans", "zh-Hant"}
    seen_identical = {locale: set() for locale in added}
    for key, entry in strings.items():
        require(set(entry["localizations"]) == locales, key)
        english = strings[key]["localizations"]["en"]["stringUnit"]["value"]
        expected_formats = FORMAT.findall(key)
        for locale in locales:
            unit = entry["localizations"][locale]["stringUnit"]
            value = unit["value"]
            require(unit["state"] == "translated" and value.strip(), (locale, key))
            require(FORMAT.findall(value) == expected_formats, (locale, key, "Format type/order/position changed"))
            if locale in added:
                extra = contract["numericAdditions"].get(locale, {}).get(key, {})
                require(numbers(value) == numbers(key) + Counter(extra.get("tokens", [])), (locale, key, "Numeric constraint changed"))
                if value.strip() == english.strip():
                    allowed = contract["identicalEnglishAllowlist"][locale].get(key, {})
                    require(value == allowed.get("value") and allowed.get("reason"), (locale, key, "English placeholder"))
                    seen_identical[locale].add(key)
                # Also reject a copied English sentence hidden behind a locale prefix.
                if len(english.strip()) >= 24 and len(english.split()) >= 4:
                    require(english.strip() not in value, (locale, key, "Copied English prose"))
    for locale in added:
        require(seen_identical[locale] == set(contract["identicalEnglishAllowlist"][locale]), (locale, "Stale English exception"))
    for key, translations in probes.items():
        require(set(translations) == locales, key)
        for locale, literal in translations.items():
            require(strings[key]["localizations"][locale]["stringUnit"]["value"] == literal, (locale, key, "Literal regression"))


def validate_sources(contract, catalog, probes):
    validate_catalog(contract, catalog, probes)
    locales = set(contract["resourceLocales"])
    for locale, expected in contract["preservedInfoPlistPrefixes"].items():
        content = (ROOT / f"AegisApp/{locale}.lproj/InfoPlist.strings").read_bytes()
        require(hashlib.sha256(content[:expected["byteCount"]]).hexdigest() == expected["sha256"], 'Guard failed: hashlib.sha256(content[:expected["byteCount"]]).hexdigest() == expected["sha256"]')
    for target in ["AegisApp", "ShareExtension", "SafariWebExtension"]:
        require({p.stem for p in (ROOT / target).glob("*.lproj")} == locales, 'Guard failed: {p.stem for p in (ROOT / target).glob("*.lproj")} == locales')
        require(plist(ROOT / target / "Info.plist")["CFBundleDevelopmentRegion"] == "zh-Hans", 'Guard failed: plist(ROOT / target / "Info.plist")["CFBundleDevelopmentRegion"] == "zh-Hans"')
        for locale in locales:
            values = plist(ROOT / target / f"{locale}.lproj/InfoPlist.strings")
            expected = {"NSCameraUsageDescription", "NSMicrophoneUsageDescription", "Markdown 文档"} if target == "AegisApp" else {"CFBundleDisplayName"}
            require(set(values) == expected and all(values.values()), (target, locale))


def verify_regression_detection(contract, catalog, probes):
    """Prove the guards reject representative fallback and safety-copy regressions."""
    consent = "将资料发送给模型？"
    private = "你正在私密浏览。确认后，所选页面内容会离开本机，模型服务可能保留请求或回答。Aegis 不会自动保存此次任务记录。"
    destination = "所选页面的标题和脱敏正文将发送到 %@，使用模型 %@。服务可能按用量收费。"
    mutations = [
        (consent, "state", "needs_review"),
        (consent, "value", ""),
        (consent, "value", catalog["strings"][consent]["localizations"]["en"]["stringUnit"]["value"]),
        (private, "value", "[de] " + catalog["strings"][private]["localizations"]["en"]["stringUnit"]["value"]),
        (private, "value", catalog["strings"][private]["localizations"]["de"]["stringUnit"]["value"].replace("nicht automatisch", "automatisch")),
        (destination, "value", catalog["strings"][destination]["localizations"]["de"]["stringUnit"]["value"].replace("%@", "%lld", 1)),
        ("1 GB", "value", "2 GB"),
    ]
    for key, field, value in mutations:
        changed = copy.deepcopy(catalog)
        changed["strings"][key]["localizations"]["de"]["stringUnit"][field] = value
        try:
            validate_catalog(contract, changed, probes)
        except ValueError:
            continue
        raise ValueError(f"Guard accepted mutation: {key}/{field}")
    print(f"PASS: {len(mutations)} negative catalog regressions rejected", flush=True)


def validate_agent_errors(contract):
    catalog = json.loads((ROOT / "AgentKit/AgentErrors.xcstrings").read_text())
    languages = set(contract["requestedLocales"])
    require(catalog["sourceLanguage"] == "zh-Hans", 'Guard failed: catalog["sourceLanguage"] == "zh-Hans"')
    for key, entry in catalog["strings"].items():
        require(key.startswith("agent.error.") and entry["extractionState"] == "manual", key)
        translations = entry["localizations"]
        require(set(translations) == languages, key)
        source = translations[catalog["sourceLanguage"]]["stringUnit"]["value"]
        for language, translation in translations.items():
            unit = translation["stringUnit"]
            value = unit["value"]
            require(unit["state"] == "translated" and value.strip() and value != key, (key, language))
            require(FORMAT.findall(value) == FORMAT.findall(source), (key, language))
            require(numbers(value) == numbers(source), (key, language))
            if language not in {"en", "en-GB", "en-HK"}:
                require(value != translations["en"]["stringUnit"]["value"], (key, language))


def validate_project(locales):
    project = plist(ROOT / "Aegis.xcodeproj/project.pbxproj")
    objects = project["objects"]
    require(set(objects[project["rootObject"]]["knownRegions"]) == set(locales) | {"Base"}, 'Guard failed: set(objects[project["rootObject"]]["knownRegions"]) == set(locales) | {"Base"}')
    require(objects[project["rootObject"]]["developmentRegion"] == "zh-Hans", 'Guard failed: objects[project["rootObject"]]["developmentRegion"] == "zh-Hans"')
    for target, folder in [("Aegis", "AegisApp"), ("ShareExtension", "ShareExtension"), ("SafariWebExtension", "SafariWebExtension")]:
        target_object = next(v for v in objects.values() if v["isa"] == "PBXNativeTarget" and v["name"] == target)
        phase = next(objects[key] for key in target_object["buildPhases"] if objects[key]["isa"] == "PBXResourcesBuildPhase")
        refs = [objects[key]["fileRef"] for key in phase["files"]]
        group = next(v for v in objects.values() if v["isa"] == "PBXGroup" and v.get("path") == folder)
        variant_id = next(key for key in group["children"] if objects[key]["isa"] == "PBXVariantGroup")
        require(variant_id in refs, f"Unbundled InfoPlist.strings: {target}")
        require({objects[key]["name"] for key in objects[variant_id]["children"]} == set(locales), 'Guard failed: {objects[key]["name"] for key in objects[variant_id]["children"]} == set(locales)')
        for key in objects[variant_id]["children"]:
            require((ROOT / folder / objects[key]["path"]).is_file(), 'Guard failed: (ROOT / folder / objects[key]["path"]).is_file()')
        if target in {"Aegis", "ShareExtension"}:
            require(any(objects[key].get("path") == "Localizable.xcstrings" for key in refs), 'Guard failed: any(objects[key].get("path") == "Localizable.xcstrings" for key in refs)')
        notice_refs = [key for key in refs if objects[key].get("path") == "ThirdPartyNotices.txt"]
        require(len(notice_refs) == (1 if target == "Aegis" else 0), f"Acknowledgements must belong to the main App: {target}")
        if target == "Aegis":
            sources = next(objects[key] for key in target_object["buildPhases"] if objects[key]["isa"] == "PBXSourcesBuildPhase")
            require(any(objects[objects[key]["fileRef"]].get("path") == "ThirdPartyNoticesView.swift" for key in sources["files"]), 'Guard failed: any(objects[objects[key]["fileRef"]].get("path") == "ThirdPartyNoticesView.swift" for key in sources["files"])')
        if target in {"Aegis", "SafariWebExtension"}:
            require(any(objects[key].get("path") == "_locales" and objects[key].get("lastKnownFileType") == "folder" for key in refs), 'Guard failed: any(objects[key].get("path") == "_locales" and objects[key].get("lastKnownFileType") == "folder" for key in refs)')
    helper_targets = set()
    for value in objects.values():
        if value["isa"] != "PBXNativeTarget":
            continue
        sources = next((objects[key] for key in value["buildPhases"] if objects[key]["isa"] == "PBXSourcesBuildPhase"), None)
        if sources and any(objects[objects[key]["fileRef"]].get("path") == "AppLocalization.swift" for key in sources["files"]):
            helper_targets.add(value["name"])
    require(helper_targets == {"Aegis", "BrowserKit", "AgentKit", "ShareExtension"}, 'Guard failed: helper_targets == {"Aegis", "BrowserKit", "AgentKit", "ShareExtension"}')
    spec = (ROOT / "project.yml").read_text()
    require(spec.count("path: Shared/AppLocalization.swift") == 4, 'Guard failed: spec.count("path: Shared/AppLocalization.swift") == 4')
    # Keep the directory hierarchy: flattening messages.json breaks WebExtension i18n.
    require(spec.count("path: SharedWebExtension/_locales\n        type: folder\n        buildPhase: resources") == 2, 'Guard failed: spec.count("path: SharedWebExtension/_locales\\n        type: folder\\n        buildPhase: resources") == 2')


def validate_web_extension():
    manifest = json.loads((ROOT / "SharedWebExtension/manifest.json").read_text())
    require(manifest["default_locale"] == "en", 'Guard failed: manifest["default_locale"] == "en"')
    require(manifest["permissions"] == ["activeTab", "scripting", "nativeMessaging", "webNavigation"], 'Guard failed: manifest["permissions"] == ["activeTab", "scripting", "nativeMessaging", "webNavigation"]')
    require(manifest["content_security_policy"]["extension_pages"] == "script-src 'self'; object-src 'none'", 'Guard failed: manifest["content_security_policy"]["extension_pages"] == "script-src \'self\'; object-src \'none\'"')
    tokens = [manifest["name"], manifest["description"], manifest["action"]["default_title"]]
    expected = {re.fullmatch(r"__MSG_(\w+)__", token).group(1) for token in tokens}
    directories = ROOT / "SharedWebExtension/_locales"
    require({p.name for p in directories.iterdir()} == set("de en es fr id it ja ko ms pt_BR pt_PT th vi zh_CN zh_TW".split()), 'Guard failed: {p.name for p in directories.iterdir()} == set("de en es fr id it ja ko ms pt_BR pt_PT th vi zh_CN zh_TW".split())')
    for path in directories.glob("*/messages.json"):
        messages = json.loads(path.read_text())
        require(set(messages) == expected and all(item["message"].strip() for item in messages.values()), 'Guard failed: set(messages) == expected and all(item["message"].strip() for item in messages.values())')


def exercise_bundles(work, contract, catalog):
    app = work / "Probe.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    info = {"CFBundleIdentifier": "test.aegis.localizations", "CFBundleDevelopmentRegion": "zh-Hans",
            "CFBundleExecutable": "bundle-probe", "CFBundlePackageType": "APPL"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["/usr/bin/xcrun", "xcstringstool", "compile", str(ROOT / "AegisApp/Localizable.xcstrings"),
                    "--output-directory", str(resources)], check=True, shell=False)
    require({p.stem for p in resources.glob("*.lproj")} == set(contract["resourceLocales"]), 'Guard failed: {p.stem for p in resources.glob("*.lproj")} == set(contract["resourceLocales"])')
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
    expected = work / "expected.json"
    expected.write_text(json.dumps({locale: {key: entry["localizations"][locale]["stringUnit"]["value"]
                                            for key, entry in catalog["strings"].items()}
                                    for locale in contract["resourceLocales"]}, ensure_ascii=False))
    executable = app / "Contents/MacOS/bundle-probe"
    executable.parent.mkdir()
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-D", "DEBUG",
                    "-module-cache-path", str(work / "module-cache"), str(ROOT / "Tests/Localization/main.swift"),
                    str(ROOT / "BrowserKit/FixtureSchemeHandler.swift"), str(ROOT / "Shared/ShareInbox.swift"),
                    str(ROOT / "Shared/AppLocalization.swift"), "-o", str(executable)], check=True, shell=False)
    require(executable.is_file() and not executable.is_symlink() and executable.parent == app / "Contents/MacOS",
            "Expected freshly compiled task-owned bundle probe")
    for locale in contract["requestedLocales"]:
        print(subprocess.check_output([str(executable), str(app), locale, str(expected), str(work), str(hostile),
                                       str(ROOT / "SharedWebExtension"), str(FIXTURES / "literal-probes.json"),
                                       "-AppleLanguages", f"({locale})", "--ui-testing",
                                       "-browser.languageFamily.v1", "system"], text=True, shell=False).strip(), flush=True)
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
    contract = json.loads((FIXTURES / "coverage.json").read_text())
    catalog = json.loads((ROOT / "AegisApp/Localizable.xcstrings").read_text())
    probes = json.loads((FIXTURES / "literal-probes.json").read_text())
    validate_sources(contract, catalog, probes)
    verify_regression_detection(contract, catalog, probes)
    validate_project(contract["resourceLocales"])
    validate_web_extension()
    validate_agent_errors(contract)
    exercise_bundles(work, contract, catalog)
    print("PASS: source preservation, registration, compiled resources and macOS Foundation behavior")


if __name__ == "__main__":
    main()
