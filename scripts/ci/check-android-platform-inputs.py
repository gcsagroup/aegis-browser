"""Check committed Android candidate inputs without building or using release services."""

import json
from pathlib import Path
import re
import runpy


def verify_gn_settings(contents, expected):
    assignments = {name: [] for name in expected}
    for line in contents.splitlines():
        name, separator, value = line.partition("#")[0].partition("=")
        name = name.strip()
        if separator and name in assignments:
            assignments[name].append(value.strip())
    for name, value in expected.items():
        if assignments[name] != [json.dumps(value)]:
            raise ValueError(f"Invalid Android GN value for {name}")


def main():
    candidate = runpy.run_path("apps/browser/scripts/ci/candidate.py")
    delivery = runpy.run_path("scripts/release/android-delivery.py")
    pin, patches = candidate["read_candidate_pin"]("android", require_override=True)
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", pin["version"]):
        raise ValueError("Invalid Android Chromium version")
    if not re.fullmatch(r"[0-9a-f]{40}", pin["commit"]):
        raise ValueError("Invalid Android Chromium commit")
    patch_names = candidate["series"](patches)
    v8_patch_names = candidate["series"](patches / "v8")

    gn = Path("apps/browser/args/aegis-android.gn").read_text(encoding="utf-8")
    verify_gn_settings(gn, {
        "target_os": "android",
        "target_cpu": "arm64",
        "chrome_public_manifest_package": delivery["archive"].APPLICATION_ID,
    })

    print(json.dumps(
        {"androidPin": pin, "patches": len(patch_names), "v8Patches": len(v8_patch_names),
         "source": delivery["source_identity"]()},
        ensure_ascii=False,
    ))


if __name__ == "__main__":
    main()
