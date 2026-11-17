"""Run the independent Access contract on the adb-selected Android device."""

import os
from pathlib import Path
import re
import shutil
import subprocess  # nosec B404 - only the validated local adb tool is executed, without a shell.
import sys


class Adb:
    def __init__(self):
        configured = os.environ.get("ADB", "adb")
        if "\0" in configured or Path(configured).name.lower() not in {"adb", "adb.exe"}:
            raise ValueError("ADB must name the adb executable, not a command or another program")
        found = shutil.which(configured)
        if not found:
            raise ValueError(f"Android adb executable not found: {configured!r}")
        executable = Path(found).resolve(strict=True)
        if (executable.name.lower() not in {"adb", "adb.exe"}
                or not executable.is_file() or not os.access(executable, os.X_OK)):
            raise ValueError(f"Not an Android adb executable: {executable}")
        self.executable = str(executable)

    def run(self, *args, capture_output=False, text=False):
        if any(not isinstance(arg, str) or "\0" in arg for arg in args):
            raise ValueError("adb arguments must be literal non-NUL strings")
        # ADB/PATH are trusted local SDK configuration, never device/server input.
        # The executable is resolved once and basename-checked above; callers use
        # fixed adb operations. Local paths stay absolute argv data, and the only
        # variable remote shell path is strictly validated after mktemp below.
        # Dynamic-argv/env audit rules cannot infer these boundaries. Offline
        # tests exercise real argv delivery, rejected tools and remote injection.
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        return subprocess.run([self.executable, *args], shell=False, check=True, timeout=25,  # nosec B603
                              capture_output=capture_output, text=text)


def main(binary, abi, min_api):
    binary = Path(binary).resolve(strict=True)
    if not binary.is_file():
        raise ValueError(f"Android test binary is not a regular file: {binary}")
    adb = Adb().run
    print("Android test device:", flush=True)
    serial = adb("get-serialno", capture_output=True, text=True).stdout.strip()
    if not serial or serial == "unknown":
        raise RuntimeError("No Android test device selected")
    print(serial, flush=True)

    def on_device(*args, **kwargs):
        return adb("-s", serial, *args, **kwargs)

    supported_abis = on_device(
        "shell", "getprop", "ro.product.cpu.abilist", capture_output=True, text=True
    ).stdout.strip()
    api = on_device(
        "shell", "getprop", "ro.build.version.sdk", capture_output=True, text=True
    ).stdout.strip()
    print(f"Android ABI list: {supported_abis}, API: {api}", flush=True)
    if abi not in supported_abis.split(",") or int(api) < min_api:
        raise RuntimeError(f"Android test requires {abi} and API {min_api} or newer")
    directory = on_device("shell", "mktemp", "-d", "/data/local/tmp/aegis-access.XXXXXXXX",
                    capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r"/data/local/tmp/aegis-access\.[a-zA-Z0-9]+", directory):
        raise RuntimeError(f"Unexpected test directory: {directory!r}")
    destination = f"{directory}/contract"
    try:
        on_device("push", str(binary), destination)
        on_device("shell", "chmod", "700", destination)
        on_device("shell", destination)
    finally:
        on_device("shell", "rm", "-rf", directory)


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]))
