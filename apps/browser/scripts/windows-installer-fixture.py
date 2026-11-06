#!/usr/bin/env python3
"""Run real Win32 UI/policy tests without installing Aegis or modifying a profile.

This fixture uses a FilePath character-type shim for installer constants. It is
not a Chromium GN build, a setup/mini_installer binary, or Explorer/token proof.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import urllib.request
import zipfile

CHROMIUM = "43a195105613ac83c21d3f14de279f4a045c7da0"
GTEST = "4fe3307fb2d9f86d19777c7eb0e4809e9694dde7"
GTEST_SHA256 = "7da5cbd7991e88e61a2e2142475041fe6685484ad13013401e8f1e3fb5f3001a"
HEADERS = {
    "build/win/common_controls.manifest":
        "3a8ca9721b476635b2bb6567f61c74adc85fdc168d4fd762d9b08414bb3f35c6",
    "chrome/installer/util/util_constants.h":
        "f40b2e5872bb326970857f23949b411964a902fa76f9feabe07b40bfaec2c749",
    "chrome/installer/mini_installer/mini_installer_resource.h":
        "294851fd8c62a5ff0ee9ace34473a6a498a68c32ff6d4713036d30aaffd89caf",
    "testing/gtest/include/gtest/gtest.h":
        "e65bc0f551d8016c5027352b013ecd90f0ee3c61ff0ddd9d1f8e7ba6676dee58",
}
SOURCES = [
    "chrome/installer/aegis_install_progress.h",
    "chrome/installer/mini_installer/aegis_overall_progress.h",
    "chrome/app/theme/gcsa_aegis/win/chromium.ico",
    "chrome/installer/mini_installer/aegis_install_ui.cc",
    "chrome/installer/mini_installer/aegis_install_ui.h",
    "chrome/installer/mini_installer/aegis_install_ui_unittest.cc",
    "chrome/installer/setup/aegis_launch_policy.h",
    "chrome/installer/setup/aegis_launch_policy_unittest.cc",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url, destination, expected):
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if digest(data) != expected:
        raise RuntimeError(f"Pinned download mismatch: {destination.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)


def verify_inputs(root, head, overlay):
    for name in SOURCES:
        relative = f"apps/browser/overlay/{name}"
        committed = subprocess.check_output(
            ["git", "rev-parse", f"{head}:{relative}"], cwd=root).strip()
        # Honor Git's clean conversion for text (e.g. Windows autocrlf), but
        # require byte identity for the icon. hash-object without -w is read-only.
        options = ["--no-filters"] if name.endswith(".ico") else ["--path", relative]
        actual = subprocess.check_output(
            ["git", "hash-object", *options, str(overlay / name)], cwd=root).strip()
        if committed != actual:
            raise RuntimeError(f"Fixture input differs from tested SHA: {name}")


def validate_results(tests, expected_tests):
    actual_tests = []
    for suite in tests["testsuites"]:
        for test in suite["testsuite"]:
            actual_tests.append(f"{suite['name']}.{test['name']}")
            if (test.get("status") != "RUN" or
                    test.get("result") != "COMPLETED" or
                    test.get("failures") or test.get("skipped")):
                raise RuntimeError("Fixture test failed, skipped or did not complete")
    if (set(actual_tests) != expected_tests or
            len(actual_tests) != len(expected_tests) or
            tests["tests"] != len(expected_tests) or tests["failures"] or
            tests["disabled"] or tests.get("skipped", 0) or tests.get("errors", 0)):
        raise RuntimeError("Expected the complete exact UI/progress/policy suite to pass")


def collect_loader_diagnostics(build, report_dir):
    """Preserve the actual PE and bounded, read-only SDK diagnostics before launch."""
    destination = report_dir / "loader-diagnostics"
    destination.mkdir(exist_ok=False)
    executable = build / "Release/installer_fixture.exe"
    shutil.copyfile(executable, destination / executable.name)
    cache = (build / "CMakeCache.txt").read_text(encoding="utf-8")
    tools = dict(re.findall(r"^(CMAKE_LINKER|CMAKE_MT):FILEPATH=(.+)$", cache, re.M))
    commands = []
    if "CMAKE_LINKER" in tools:
        commands.append(("imports", [str(Path(tools["CMAKE_LINKER"]).with_name(
            "dumpbin.exe")), "/IMPORTS", str(executable)]))
    if "CMAKE_MT" in tools:
        commands.append(("manifest", [tools["CMAKE_MT"], "-nologo",
            f"-inputresource:{executable};#1",
            f"-out:{destination / 'embedded.manifest'}"]))
    diagnostics = {"executableSha256": digest(executable.read_bytes()),
                   "tools": tools, "commands": []}
    for name, command in commands:
        record = {"argv": command}
        try:
            with (destination / f"{name}.log").open("wb") as output:
                completed = subprocess.run(command, stdout=output,
                    stderr=subprocess.STDOUT, timeout=30, check=False)
            record["exitCode"] = completed.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            record["error"] = str(error)
        diagnostics["commands"].append(record)
    # Missing SDK diagnostic tools never suppress the actual test execution.
    # The retained PE still contains the exact import and resource tables.
    (destination / "report.json").write_text(json.dumps(diagnostics, indent=2) + "\n")
    return diagnostics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tested-sha", required=True)
    parser.add_argument("--report-dir", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    report_dir = Path(args.report_dir).resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    report = {"result": "FAIL", "testedSha": args.tested_sha,
              "chromiumPin": CHROMIUM, "googletestPin": GTEST,
              "nativeWindows": os.name == "nt", "fullChromiumBuild": False,
              "installerExecuted": False, "explorerTokenAcceptance": False,
              "shim": "base::FilePath::CharType and FILE_PATH_LITERAL only",
              "commands": []}
    try:
        if os.name != "nt":
            raise RuntimeError("Native Windows is required")
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        if head != args.tested_sha:
            raise RuntimeError("Tested SHA does not match checkout")
        if (root / "apps/browser/CHROMIUM_COMMIT").read_text().strip() != CHROMIUM:
            raise RuntimeError("Update pinned fixture inputs for the new Chromium pin")
        overlay = root / "apps/browser/overlay"
        verify_inputs(root, head, overlay)
        hashes = {name: digest((overlay / name).read_bytes()) for name in SOURCES}
        report["inputHashes"] = hashes
        fixture = report_dir / "fixture"
        fixture.mkdir(exist_ok=False)
        for name in SOURCES:
            destination = fixture / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((overlay / name).read_bytes())
        for name, expected in HEADERS.items():
            download(f"https://raw.githubusercontent.com/chromium/chromium/{CHROMIUM}/{name}",
                     fixture / name, expected)
        archive = fixture / "googletest.zip"
        download(f"https://codeload.github.com/google/googletest/zip/{GTEST}",
                 archive, GTEST_SHA256)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(fixture / "download")
        gtest = fixture / "third_party/googletest/src"
        gtest.parent.mkdir(parents=True, exist_ok=True)
        (fixture / "download" / f"googletest-{GTEST}").rename(gtest)
        shim = fixture / "base/files/file_path.h"
        shim.parent.mkdir(parents=True, exist_ok=True)
        shim.write_text('#pragma once\nnamespace base { struct FilePath { '
                        'using CharType = wchar_t; }; }\n'
                        '#define FILE_PATH_LITERAL(x) L##x\n')
        (fixture / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.20)
project(AegisInstallerFixture LANGUAGES CXX RC)
set(CMAKE_CXX_STANDARD 20)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
add_subdirectory(third_party/googletest/src)
add_executable(installer_fixture
  installer_fixture.rc
  chrome/installer/mini_installer/aegis_install_ui.cc
  chrome/installer/mini_installer/aegis_install_ui_unittest.cc
  chrome/installer/setup/aegis_launch_policy_unittest.cc)
target_include_directories(installer_fixture PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(installer_fixture PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(installer_fixture PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/utf-8>)
target_link_libraries(installer_fixture PRIVATE gtest_main user32 gdi32 comctl32 dwmapi gdiplus)
# Match Chromium mini_installer's default_exe_manifest Common Controls v6 dependency.
target_link_options(installer_fixture PRIVATE /MANIFEST:EMBED
  "/MANIFESTINPUT:${CMAKE_CURRENT_SOURCE_DIR}/build/win/common_controls.manifest")
''')
        (fixture / "installer_fixture.rc").write_text(
            '#include "chrome/installer/mini_installer/mini_installer_resource.h"\n'
            'IDI_MINI_INSTALLER ICON "chrome/app/theme/gcsa_aegis/win/chromium.ico"\n')
        # Bind the result to every actual test in the copied production suites.
        expected_tests = set()
        for name in SOURCES:
            if name.endswith("_unittest.cc"):
                expected_tests.update(
                    f"{suite}.{test}" for suite, test in re.findall(
                        r"TEST\(\s*(\w+)\s*,\s*(\w+)\s*\)",
                        (fixture / name).read_text(encoding="utf-8")))
        if not expected_tests or any("DISABLED_" in name for name in expected_tests):
            raise RuntimeError("Empty or disabled fixture suite")
        report["expectedTests"] = sorted(expected_tests)
        report["excludedNativeSuites"] = [
            "AegisInstallProgressTest requires full Chromium setup_unittests",
            "LzmaUtilTest and WorkItemListTest require installer_util_unittests"]
        build = fixture / "build"
        commands = [
            ["cmake", "-S", str(fixture), "-B", str(build), "-A", "x64"],
            ["cmake", "--build", str(build), "--config", "Release", "--parallel", "2"],
            [str(build / "Release/installer_fixture.exe"),
             "--gtest_output=json:" + str(report_dir / "tests.json")],
        ]
        for index, command in enumerate(commands):
            if index == 2:
                report["loaderDiagnostics"] = collect_loader_diagnostics(build, report_dir)
            completed = subprocess.run(command, cwd=root, timeout=300, check=False)
            report["commands"].append({"argv": command, "exitCode": completed.returncode})
            if completed.returncode:
                raise RuntimeError(f"Fixture command failed: {command[0]}")
        tests = json.loads((report_dir / "tests.json").read_text(encoding="utf-8"))
        validate_results(tests, expected_tests)
        report["finalHashes"] = {name: digest((overlay / name).read_bytes()) for name in SOURCES}
        if hashes != report["finalHashes"]:
            raise RuntimeError("Source changed during fixture")
        report["result"] = "PASS"
    finally:
        (report_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: complete Win32 UI/progress/policy fixture suite; full Chromium/token gates remain separate")


if __name__ == "__main__":
    main()
