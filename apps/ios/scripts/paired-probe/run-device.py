#!/usr/bin/env python3
"""Run the signed paired probe and recover JSON without retaining credential-bearing XCTest files."""
import json
import os
from pathlib import Path
import plistlib
from xctestrun import aegis_test_host, aegis_test_target, device_identifier
import re
# Only fixed Xcode executables are invoked below.
import subprocess  # nosec B404
import tempfile
from urllib.parse import parse_qs, urlsplit

from uuid import uuid4

run = str(uuid4())
device = device_identifier(os.environ['AEGIS_PROBE_DEVICE'])
os.umask(0o077)
base = Path(os.environ['AEGIS_PROBE_OUTPUT']).resolve() / run
base.mkdir(mode=0o700, parents=True)
template = Path(os.environ['AEGIS_PROBE_XCTESTRUN']).resolve(strict=True)
products = template.parent
node_file = Path(os.environ['AEGIS_PROBE_NODE_FILE'])
print(f"Paired run directory: {base}", flush=True)
expected = {"security": ["reality"], "type": ["tcp"], "flow": ["xtls-rprx-vision"]}

with node_file.open(errors="replace") as handle:
    matches = [
        line.strip() for line in handle
        if line.strip().startswith("vless://")
        and all(value in line for value in ("security=reality", "type=tcp", "flow=xtls-rprx-vision"))
    ]
if len(matches) != 1:
    raise SystemExit("Expected one Reality Vision fixture in the original node source")
uri = matches[0]
if any(parse_qs(urlsplit(uri).query).get(key) != value for key, value in expected.items()):
    raise SystemExit("Original node source did not match the Reality Vision fixture")

with template.open("rb") as handle:
    descriptor = plistlib.load(handle)
target = aegis_test_target(descriptor)
try:
    _, host_info = aegis_test_host(target, products)
except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
    raise SystemExit("Probe requires a valid Aegis app test host") from None
host_bundle_id = host_info["CFBundleIdentifier"]
target.setdefault("EnvironmentVariables", {})["AEGIS_BLOCKED_CN_NODE_URI"] = uri
target["EnvironmentVariables"]["AEGIS_PAIRED_RUN"] = run
target["DefaultTestExecutionTimeAllowance"] = 14_400
target["MaximumTestExecutionTimeAllowance"] = 14_400

artifacts = {
    "blocked-cn-paired-progress.json": "pairs.json",
    "blocked-cn-paired-www.json": "www-pairs.json",
    "blocked-cn-paired-egress.json": "egress.json",
    "blocked-cn-paired-canaries.json": "canaries.json",
}
# Lock down the transient plist even when copying the template's larger settings.
os.umask(0o077)
with tempfile.TemporaryDirectory(prefix="aegis-blocked-cn-private-") as temp_dir:
    fd, path = tempfile.mkstemp(prefix="paired-", suffix=".xctestrun", dir=products)
    transient = Path(path)
    try:
        with os.fdopen(fd, "wb") as handle:
            plistlib.dump(descriptor, handle)
        result = Path(temp_dir) / "Paired.xcresult"
        # Copy only recognized, fixed-format progress out of the XCTest output.
        progress = re.compile(r"blocked-cn-paired (?:primary|www) \d+/\d+ complete")
        test_state = re.compile(r"Test Case '-\[AegisTests\.AccessEmbeddedCoreLiveTests testPhoneWiFiBlockedCNPaired\]' (?:started|(?:passed|failed) \([0-9.]+ seconds\))")
        diagnostic = re.compile(r"(?:Missing node environment|Reality Vision fixture could not be parsed|Expected 2,051 unique primary probe hosts|Testing failed|Wi-Fi or egress controls failed at boundary [123]|Reality Vision reached \d+/7 known hosts, expected at least 4|Active Wi-Fi required|Failed to prepare the device|device is locked|Unlock .{0,80} to continue)", re.I)
        started = False
        with (base / "device-progress.log").open("w") as log:
            # The descriptor and result are private absolute paths; device is a validated ID.
            with subprocess.Popen(  # nosec B603
                ["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(transient),
                 "-destination", f"id={device}", "-parallel-testing-enabled", "NO",
                 "-only-testing:AegisTests/AccessEmbeddedCoreLiveTests/testPhoneWiFiBlockedCNPaired",
                 "-resultBundlePath", str(result)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1,
            ) as proc:
                for line in proc.stdout:
                    match = progress.search(line) or test_state.search(line) or diagnostic.search(line)
                    if match:
                        message = match.group()
                        if message.startswith("Test Case ") and message.endswith(" started"):
                            started = True
                            transient.unlink(missing_ok=True)
                        print(message, file=log, flush=True)
                        print(message, flush=True)
                exit_code = proc.wait()
        summary = {"xcodeExitCode": exit_code, "testStarted": started}
        if result.is_dir():
            # Private result path.
            p = subprocess.run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary",  # nosec B603
                                "--path", str(result)], capture_output=True)
            if p.returncode == 0:
                result_summary = json.loads(p.stdout)
                for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "result"):
                    if key in result_summary:
                        summary[key] = result_summary[key]
                for failure in result_summary.get("testFailures", []):
                    matched = diagnostic.search(failure.get("failureText", "") or "")
                    if matched:
                        summary.setdefault("diagnostics", []).append(matched.group())
        recovered = {}
        for remote, name in artifacts.items():
            if not started:
                recovered[name] = None
                continue
            staged = Path(temp_dir) / name
            # Device and app host were validated; artifact names and output directory are fixed here.
            copy = subprocess.run(  # nosec B603
                ["/usr/bin/xcrun", "devicectl", "--timeout", "25", "device", "copy", "from", f"--device={device}",
                 "--domain-type", "appDataContainer", "--domain-identifier", host_bundle_id,
                 "--source", f"/Library/Caches/{run}-{remote}", "--destination", str(staged)],
                capture_output=True,
            )
            if copy.returncode != 0:
                recovered[name] = None
                continue
            data = staged.read_bytes()
            if uri.encode() in data or (urlsplit(uri).username or "").encode() in data:
                raise SystemExit("Unexpected credential in test data")
            payload = json.loads(data)
            (base / name).write_bytes(data)
            recovered[name] = len(payload)
        summary["recoveredCounts"] = recovered
        (base / "run-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary), flush=True)
        raise SystemExit(exit_code or int(any(count is None for count in recovered.values())))
    finally:
        transient.unlink(missing_ok=True)
