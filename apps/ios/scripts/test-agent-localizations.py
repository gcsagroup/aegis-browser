#!/usr/bin/env python3
"""Run compiled AgentContractTests and LocalizationTests in fresh locale hosts.

Example (use a new work directory each time):
  python3 apps/ios/scripts/test-agent-localizations.py --xctestrun /path/base.xctestrun \
      --device SIMULATOR-UUID --work-dir /path/new-run --language de
Omit --language to run all 17 preferences. Build the current tests first.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time

REGIONS = {
    "de": "DE", "en": "US", "en-GB": "GB", "en-HK": "HK", "es": "ES",
    "fr": "FR", "id": "ID", "it": "IT", "ja": "JP", "ko": "KR", "ms": "MY",
    "pt": "PT", "th": "TH", "vi": "VN", "zh-Hans": "CN", "zh-Hant": "TW",
    "zh-Hant-HK": "HK",
}
MARKER = "AEGIS_AGENT_LOCALE "


def resolve_testroot(value, root):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(root))
    if isinstance(value, list):
        return [resolve_testroot(item, root) for item in value]
    if isinstance(value, dict):
        return {key: resolve_testroot(item, root) for key, item in value.items()}
    return value


def locale_arguments(arguments, language, region, *, preferences=None, system_locale=None, family=None):
    # Preserve other host arguments, replacing any stale locale overrides.
    result = []
    index = 0
    while index < len(arguments):
        if arguments[index] in ("-AppleLanguages", "-AppleLocale", "-browser.languageFamily.v1"):
            if index + 1 >= len(arguments):
                raise ValueError("Missing value for existing locale argument")
            index += 2
        else:
            result.append(arguments[index])
            index += 1
    locale = language.replace("-", "_")
    if not locale.endswith(f"_{region}"):
        locale += f"_{region}"
    if "--ui-testing" not in result:
        result.append("--ui-testing")
    requested = ",".join(preferences or [language])
    return result + ["-AppleLanguages", f"({requested})", "-AppleLocale", system_locale or locale,
                     "-browser.languageFamily.v1", family or "system"]


def read_evidence(log, language, family=None, preferences=None, region=None):
    evidence = []
    for line in log.read_text(errors="replace").splitlines():
        if MARKER in line:
            item = json.loads(line.split(MARKER, 1)[1])
            if (item.get("expected") != language or item.get("selected") != language
                    or item.get("expectedSource") != "environment"
                    or not isinstance(item.get("requested"), list) or not item["requested"]):
                raise ValueError(f"Locale evidence mismatch: {item}")
            if family is not None and (item.get("expectedFamily") != family or item.get("selectedFamily") != family):
                raise ValueError(f"Family evidence mismatch: {item}")
            if preferences is not None and item["requested"] != preferences:
                raise ValueError(f"Requested preferences mismatch: {item}")
            if region is not None and item.get("region") != region:
                raise ValueError(f"Formatting region mismatch: {item}")
            evidence.append(item)
    if not evidence:
        raise ValueError("Missing AEGIS_AGENT_LOCALE evidence")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", required=True, type=Path)
    parser.add_argument("--device", required=True, help="Simulator device UUID")
    parser.add_argument("--work-dir", required=True, type=Path, help="Must not already exist")
    parser.add_argument("--language", action="append", choices=REGIONS,
                        help="Run only this preference; repeat for a subset")
    policy = json.loads((Path(__file__).resolve().parents[1] / "Tests/Fixtures/Localization/language-policy.json").read_text())
    policy_by_name = {item["name"]: item for item in policy}
    parser.add_argument("--policy-case", action="append", choices=policy_by_name,
                        help="Run an independent generic/region/manual fixture instead of the default 17 hosts; repeat as needed")
    args = parser.parse_args()
    base_path = args.xctestrun.resolve(strict=True)
    base_bytes = base_path.read_bytes()
    base = plistlib.loads(base_bytes)
    if (base.get("__xctestrun_metadata__", {}).get("FormatVersion") != 1
            or not all(key in base for key in ("AegisTests", "AegisUITests"))):
        parser.error("Expected flat v1 xctestrun with AegisTests and AegisUITests")
    languages = list(dict.fromkeys(args.language or ([] if args.policy_case else REGIONS)))
    families = {"en-GB": "en", "en-HK": "en", "zh-Hant-HK": "zh-Hant"}
    cases = [{"name": language, "preferences": [language], "region": REGIONS[language],
              "family": families.get(language, language), "agentResource": language, "selected": None}
             for language in languages]
    cases += [policy_by_name[name] for name in dict.fromkeys(args.policy_case or [])]
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    manifest = {
        "base": str(base_path), "base_sha256": hashlib.sha256(base_bytes).hexdigest(),
        "device": args.device, "languages": languages, "cases": cases, "status": "running", "runs": [],
    }

    def save():
        (work / "results.json").write_text(json.dumps(manifest, indent=2) + "\n")

    save()
    try:
        resolved = resolve_testroot(base, base_path.parent)
        for case in cases:
            name = case["name"]
            language = case["preferences"][0]
            configuration = copy.deepcopy(resolved)
            target = configuration["AegisTests"]
            target["TestLanguage"] = language
            region = case.get("region", case.get("systemLocale", "en_US").split("_")[-1])
            target["TestRegion"] = region
            target["CommandLineArguments"] = locale_arguments(
                target.get("CommandLineArguments", []), language, region,
                preferences=case["preferences"], system_locale=case.get("systemLocale"), family=case["selected"])
            target.setdefault("EnvironmentVariables", {})["AEGIS_EXPECTED_LANGUAGE"] = case["agentResource"]
            target["EnvironmentVariables"]["AEGIS_EXPECTED_FAMILY"] = case["family"]
            target["EnvironmentVariables"]["AEGIS_EXPECTED_REGION"] = region
            target["ParallelizationEnabled"] = False
            target["OnlyTestIdentifiers"] = ["AgentContractTests", "LocalizationTests"]
            target.pop("SkipTestIdentifiers", None)
            config = work / f"{name}.xctestrun"
            config.write_bytes(plistlib.dumps(configuration))
            manifest["runs"].append({"language": name, "expected": case["agentResource"],
                                     "family": case["family"], "region": region, "preferences": case["preferences"], "configuration": str(config),
                                     "status": "pending"})
        save()
        for run in manifest["runs"]:
            language = run["language"]
            log = work / f"{language}.log"
            command = [
                "xcodebuild", "test-without-building", "-xctestrun", run["configuration"],
                "-destination", f"platform=iOS Simulator,id={args.device}",
                "-only-testing:AegisTests/AgentContractTests",
                "-only-testing:AegisTests/LocalizationTests",
                "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never",
                "-resultBundlePath", str(work / f"{language}.xcresult"),
            ]
            run.update(status="running", command=command, log=str(log))
            save()
            print(f"Running {language}", flush=True)
            started = time.monotonic()
            with log.open("wb") as output:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    run["exit_code"] = process.wait(timeout=900)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    run["status"] = "timeout"
                    raise RuntimeError(f"{language}: exceeded 900-second host timeout")
                finally:
                    run["elapsed_seconds"] = round(time.monotonic() - started, 2)
            if run["exit_code"] != 0:
                raise RuntimeError(f"{language}: XCTest exit {run['exit_code']}")
            run["evidence"] = read_evidence(log, run["expected"], run["family"], run["preferences"], run["region"])
            run["status"] = "passed"
            save()
        manifest["status"] = "passed"
    except (OSError, ValueError, RuntimeError) as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        for run in manifest["runs"]:
            if run["status"] == "running":
                run["status"] = "failed"
        print(str(error), file=sys.stderr)
    finally:
        save()
    return 0 if manifest["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
