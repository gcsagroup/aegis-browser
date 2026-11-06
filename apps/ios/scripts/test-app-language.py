#!/usr/bin/env python3
"""Focused macOS Foundation/extraction checks; no Xcode build or simulator execution."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    """Validation must remain active even when Python optimization is enabled."""
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", required=True, type=Path, help="new directory for retained evidence")
    parser.add_argument("--plist-fixtures", action="store_true",
                        help="Use native binary .strings fixtures when catalog compilation is unavailable; report that gap")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TMPDIR=str(work))
    spec = importlib.util.spec_from_file_location("catalog_checks", ROOT / "scripts/test-localizations.py")
    checks = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checks)
    fixture = ROOT / "Tests/Fixtures/Localization"
    coverage = json.loads((fixture / "coverage.json").read_text())
    catalog = json.loads((ROOT / "AegisApp/Localizable.xcstrings").read_text())
    probes = json.loads((fixture / "literal-probes.json").read_text())
    checks.validate_sources(coverage, catalog, probes)
    checks.verify_regression_detection(coverage, catalog, probes)
    checks.validate_project(coverage["resourceLocales"])
    checks.validate_agent_errors(coverage)
    guard_spec = importlib.util.spec_from_file_location("agent_runner", ROOT / "scripts/test-agent-localizations.py")
    guard = importlib.util.module_from_spec(guard_spec)
    guard_spec.loader.exec_module(guard)
    evidence = {"expected": "en-GB", "selected": "en-GB", "expectedSource": "environment",
                "requested": ["en"], "expectedFamily": "en", "selectedFamily": "en", "region": "GB"}
    receipt = work / "guard-fixture.log"
    receipt.write_text(guard.MARKER + json.dumps(evidence))
    require(guard.read_evidence(receipt, "en-GB", "en", ["en"], "GB"), 'Guard failed: guard.read_evidence(receipt, "en-GB", "en", ["en"], "GB")')
    failures = [("expected", "en"), ("selected", "en"), ("expectedSource", "system"),
                ("requested", []), ("expectedFamily", "de"), ("selectedFamily", "de"), ("region", "US")]
    for field, value in failures:
        changed = dict(evidence, **{field: value})
        receipt.write_text(guard.MARKER + json.dumps(changed))
        try:
            guard.read_evidence(receipt, "en-GB", "en", ["en"], "GB")
        except ValueError:
            continue
        raise ValueError(f"Native matrix guard accepted {field} mismatch")
    receipt.write_text("no receipt")
    try:
        guard.read_evidence(receipt, "en-GB", "en", ["en"], "GB")
    except ValueError:
        pass
    else:
        raise ValueError("Native matrix guard accepted missing evidence")
    arguments = guard.locale_arguments(["--ui-testing-preferences-keep", "-AppleLanguages", "(fr)",
                                       "-browser.languageFamily.v1", "de"], "en", "GB", family="en")
    require("--ui-testing-preferences-keep" in arguments and "--ui-testing" in arguments, 'Guard failed: "--ui-testing-preferences-keep" in arguments and "--ui-testing" in arguments')
    require("(fr)" not in arguments and "de" not in arguments, 'Guard failed: "(fr)" not in arguments and "de" not in arguments')
    print("PASS: 8 native evidence rejection cases and isolated argument construction")
    owners = []
    for name, source in [("App", "AegisApp/Localizable.xcstrings"), ("Agent", "AgentKit/AgentErrors.xcstrings"),
                         ("Share", "AegisApp/Localizable.xcstrings")]:
        bundle = work / f"{name}.bundle"
        resources = bundle / "Contents/Resources"
        resources.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": f"test.aegis.language.{name}", "CFBundleDevelopmentRegion": "zh-Hans",
        }))
        if args.plist_fixtures:
            strings = json.loads((ROOT / source).read_text())["strings"]
            languages = {language for value in strings.values() for language in value["localizations"]}
            for language in languages:
                folder = resources / f"{language}.lproj"
                folder.mkdir()
                values = {key: value["localizations"][language]["stringUnit"]["value"] for key, value in strings.items()}
                (folder / (Path(source).stem + ".strings")).write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
        else:
            subprocess.run(["/usr/bin/xcrun", "xcstringstool", "compile", str(ROOT / source),
                            "--output-directory", str(resources)], check=True, shell=False, env=env)
        owners.append(bundle)
    resources = owners[0] / "Contents/Resources"
    for language, values in [("en", {"Identity": "Wrong fallback", "Fallback": "English fallback"}),
                             ("de", {"Identity": "Identity"})]:
        (resources / f"{language}.lproj/Adapter.strings").write_bytes(plistlib.dumps(values))
    for name, malformed in [("BadArray", ["not a table"]), ("BadValue", {"key": 42})]:
        (resources / f"en.lproj/{name}.strings").write_bytes(plistlib.dumps(malformed))
    plural = {"Aegis apples %lld": {"NSStringLocalizedFormatKey": "%#@apples@", "apples": {
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
        "one": "%lld apple", "other": "%lld apples"}}}
    (resources / "en.lproj/Adapter.stringsdict").write_bytes(plistlib.dumps(plural))
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                  text=True, shell=False, env=env).strip()
    require(Path(sdk).is_absolute() and Path(sdk).is_dir() and Path(sdk).suffix == ".sdk", "Invalid macOS SDK path")
    executable = work / "language-probe"
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-D", "DEBUG", "-sdk", sdk,
                    "-module-cache-path", str(work / "module-cache"), str(ROOT / "Shared/AppLocalization.swift"),
                    str(ROOT / "Tests/AppLanguage/main.swift"), "-o", str(executable)],
                   check=True, shell=False, env=env)
    require(executable.is_file() and not executable.is_symlink() and executable.parent == work,
            "Expected freshly compiled task-owned language probe")
    output = subprocess.check_output([str(executable), str(fixture / "language-policy.json"),
                                      *map(str, owners), "--ui-testing", "-browser.languageFamily.v1", "zh-Hant"],
                                     text=True, shell=False, env=env)
    (work / "probe.log").write_text(output)
    print(output, end="")
    extraction = work / "extraction"
    extraction.mkdir()
    source = work / "extraction-probe.swift"
    source.write_text('import Foundation\nfunc sample(_ count: Int) {\n'
                      ' _ = AegisLocalization.string("Aegis typed extraction")\n'
                      ' _ = AegisLocalization.string("Aegis typed count \\(count)")\n}\n')
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-sdk", sdk,
                    "-emit-object", "-whole-module-optimization", "-module-cache-path", str(work / "module-cache"),
                    "-emit-localized-strings", "-emit-localized-strings-path", str(extraction),
                    str(ROOT / "Shared/AppLocalization.swift"), str(source), "-o", str(work / "extraction.o")],
                   check=True, shell=False, env=env)
    extracted = "\n".join(p.read_text() for p in extraction.glob("*.stringsdata"))
    require("Aegis typed extraction" in extracted and "Aegis typed count %lld" in extracted, 'Guard failed: "Aegis typed extraction" in extracted and "Aegis typed count %lld" in extracted')
    (work / "results.json").write_text(json.dumps({"status": "passed", "policyCases": 45,
        "resourceMode": "binary plist fixtures" if args.plist_fixtures else "xcstringstool compiled catalogs",
        "checks": ["catalog preservation and rejection guards", "four target memberships", "native Foundation lookup",
                   "pure persistence", "system formatting", "argument-domain isolation", "typed extraction",
                   "8 native evidence rejection cases"],
        "notRun": (["catalog compilation"] if args.plist_fixtures else []) +
                  ["iOS build", "native XCTest", "UI tests", "CI", "independent review"]}, indent=2) + "\n")
    print("PASS: typed extraction and unchanged historical catalog guards")


if __name__ == "__main__":
    main()
