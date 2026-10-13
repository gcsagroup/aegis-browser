#!/usr/bin/env python3
"""实测不同二进制版本能否沿用钥匙串信任；只创建并清理自己的测试项。"""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import uuid
from pathlib import Path

IDENTITY = "7C33B517942161311A087CE893D2F1CE9B204B44"
IDENTIFIER = "app.gcsa.aegis.keychain-upgrade-check"
SOURCE = r'''
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
#ifndef PROBE_VERSION
#error 缺少探针版本
#endif
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  OSStatus status = SecKeychainSetUserInteractionAllowed(false);
  if (status != errSecSuccess) return 3;
  const char *account = "upgrade-regression";
  const char *value = "synthetic-upgrade-test-data";
  SecKeychainItemRef item = NULL;
  UInt32 size = 0;
  void *data = NULL;
  int matched = 0;
  if (strcmp(argv[1], "create") == 0) {
    status = SecKeychainAddGenericPassword(NULL, (UInt32)strlen(argv[2]),
      argv[2], (UInt32)strlen(account), account, (UInt32)strlen(value), value, &item);
  } else {
    status = SecKeychainFindGenericPassword(NULL, (UInt32)strlen(argv[2]),
      argv[2], (UInt32)strlen(account), account, &size, &data, &item);
    if (status == errSecSuccess) {
      matched = size == strlen(value) && memcmp(data, value, size) == 0;
      SecKeychainItemFreeContent(NULL, data);
      if (strcmp(argv[1], "delete") == 0) status = SecKeychainItemDelete(item);
    }
  }
  if (item) CFRelease(item);
  printf("{\"version\":%d,\"status\":%d,\"matched\":%s,\"interaction_allowed\":false}\n",
    PROBE_VERSION, (int)status, matched ? "true" : "false");
  return status == errSecSuccess ? 0 : 1;
}
'''


def command(args):
    return subprocess.run(args, check=True, text=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("此验收只适用于 macOS")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    source = root / "probe.c"
    source.write_text(SOURCE)
    executable = root / "keychain-upgrade-probe"
    service = "GCSA Upgrade Regression " + str(uuid.uuid4())
    report = {"schema": 1, "service": service, "versions": [],
              "scope": "独立探针跨二进制版本；不替代真实浏览器升级验收", "passed": False}
    created = False
    try:
        for version in (1, 2):
            # 每轮在同一路径生成不同的二进制；版本号也参与编译。
            command(["xcrun", "clang", "-Wno-deprecated-declarations",
                     f"-DPROBE_VERSION={version}", str(source), "-framework",
                     "Security", "-framework", "CoreFoundation", "-o", str(executable)])
            command(["codesign", "--force", "--sign", IDENTITY, "--identifier",
                     IDENTIFIER, "--timestamp=none", str(executable)])
            command(["codesign", "--verify", "--strict", str(executable)])
            requirement = command(["codesign", "-d", "-r-", str(executable)])
            row = {"version": version, "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                   "requirement": next(line.split("designated =>", 1)[1].strip() for line in (requirement.stdout + requirement.stderr).splitlines() if line.startswith("designated =>"))}
            if version == 1:
                row["create"] = json.loads(command([str(executable), "create", service]).stdout)
                created = True
                shutil.copy2(executable, root / "version-1-backup")
            row["read"] = json.loads(command([str(executable), "read", service]).stdout)
            assert row["read"]["matched"]
            report["versions"].append(row)
        first, second = report["versions"]
        assert first["sha256"] != second["sha256"]
        assert first["requirement"] == second["requirement"]
        assert "cdhash" not in second["requirement"]
        report["passed"] = True
    finally:
        if created:
            cleanup = subprocess.run([str(executable), "delete", service], text=True, capture_output=True)
            if cleanup.returncode:
                shutil.copy2(root / "version-1-backup", executable)
                cleanup = subprocess.run([str(executable), "delete", service], text=True, capture_output=True)
            report["cleanup_passed"] = cleanup.returncode == 0
            report["passed"] = report["passed"] and report["cleanup_passed"]
        (root / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
