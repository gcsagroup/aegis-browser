import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
from xctestrun import aegis_test_target
import re
import subprocess
import sys
import tempfile
from uuid import uuid4
from urllib.parse import parse_qs,urlsplit


def bundled_test_uri(target, products):
    """Read only for output redaction. XCTest reads the signed resource itself."""
    prefix = "__TESTROOT__/"
    host_path = target.get("TestHostPath", "")
    if not host_path.startswith(prefix):
        raise ValueError("Expected an app test host relative to the XCTest products")
    app = (products / host_path.removeprefix(prefix)).resolve()
    if not app.is_relative_to(products) or app.name != "Aegis.app":
        raise ValueError("Expected Aegis.app inside the XCTest products")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    channel = info.get("AegisAccessReleaseChannel")
    bundle_id = info.get("CFBundleIdentifier")
    if (channel not in ("dev", "alpha") or info.get("AegisReleaseProfile") != channel
            or bundle_id not in ("com.gcsa.aegis", "com.gcsa.aegis.alpha.internal")):
        raise ValueError("Expected a Dev or Alpha app test host")
    with (app / "AegisAlphaTestNodes.json").open("rb") as file:
        raw = file.read(131_501)
    if len(raw) > 131_500:
        raise ValueError("Oversized test node resource")
    routes = json.loads(raw)
    if not isinstance(routes, list) or len(routes) != 1 or not isinstance(routes[0], str):
        raise ValueError("Expected exactly one packaged test node")
    parsed = urlsplit(routes[0])
    query = parse_qs(parsed.query)
    if (parsed.scheme != "vless" or not parsed.username
            or any(query.get(k) != [v] for k, v in (
                ("security", "reality"), ("type", "tcp"), ("flow", "xtls-rprx-vision")))):
        raise ValueError("Expected a VLESS Reality Vision test node")
    return channel, bundle_id, routes[0]


out = Path(os.environ['AEGIS_PROBE_OUTPUT']).resolve()
template = Path(os.environ['AEGIS_PROBE_XCTESTRUN']).resolve(strict=True)
products = template.parent
device = os.environ['AEGIS_PROBE_DEVICE']
os.umask(0o077)
out.mkdir(mode=0o700, parents=True, exist_ok=True)
assets_only="--assets-only" in sys.argv
search_dom="--search-dom" in sys.argv
search_only="--search-only" in sys.argv or search_dom
webkit_only="--webkit-only" in sys.argv or assets_only or search_only
tls_only="--tls-only" in sys.argv
use_bundled_node = "--bundled-test-node" in sys.argv or "--bundled-alpha-node" in sys.argv
comparison_node=os.environ.get("AEGIS_COMPARISON_NODE_FILE") if tls_only else None
if use_bundled_node and comparison_node:
    raise SystemExit("Choose either the bundled test node or the comparison relay")
if comparison_node:
    out=out/os.environ["AEGIS_COMPARISON_RUN"]
    if not out.is_dir() or (out/"device.log").exists():
        raise SystemExit("Expected a fresh comparison relay run directory")
else:
    out = out / ('directed-' + str(uuid4()))
    out.mkdir(mode=0o700)
run_id = str(uuid4())
selectors=[
    "AegisTests/AccessEmbeddedCoreLiveTests/testPhoneDirectedTLSTrace",
    "AegisTests/AccessHostRecoveryWebKitTests/testPhoneDirectedGoogleWebKit",
]
if tls_only:
    selectors=selectors[:1]
elif webkit_only:
    selectors=selectors[1:]
descriptor = plistlib.loads(template.read_bytes())
target = aegis_test_target(descriptor)
host_bundle_id = "com.gcsa.aegis"
if use_bundled_node:
    try:
        bundled_channel, host_bundle_id, uri = bundled_test_uri(target, products)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        raise SystemExit("Bundled probe requires a signed Dev or Alpha app with one Reality Vision node") from None
else:
    node_file=Path(comparison_node) if comparison_node else Path(os.environ["AEGIS_PROBE_NODE_FILE"])
    with node_file.open(errors="replace") as handle:
        matches=[l.strip() for l in handle if l.strip().startswith("vless://")
                 and all(k in l for k in ("security=reality","type=tcp","flow=xtls-rprx-vision"))]
    if len(matches)!=1:
        raise SystemExit("The original Reality Vision fixture was not unique")
    uri=matches[0]
parsed=urlsplit(uri)
fields = parse_qs(parsed.query)
public_keys = [value for name in ("pbk", "publicKey", "public_key") for value in fields.get(name, [])]
needles=[part.encode() for part in (uri, parsed.username, *public_keys) if part]
test_environment = target.setdefault("EnvironmentVariables", {})
test_environment.pop("AEGIS_BLOCKED_CN_NODE_URI", None)
test_environment.pop("AEGIS_DIRECTED_BUNDLED_TEST_NODE", None)
if use_bundled_node:
    test_environment["AEGIS_DIRECTED_BUNDLED_TEST_NODE"] = "1"
else:
    test_environment["AEGIS_BLOCKED_CN_NODE_URI"] = uri
test_environment.update({
    "AEGIS_DIRECTED_PROBE":"1",
    "AEGIS_DIRECTED_RUN":run_id,
    "AEGIS_DIRECTED_ASSETS_ONLY":"1" if assets_only else "0",
    "AEGIS_DIRECTED_SEARCH_ONLY":"1" if search_only else "0",
})
comparison_result = f"aegis-comparison-{out.name}.json" if comparison_node else None
if comparison_result:
    target["EnvironmentVariables"]["AEGIS_COMPARISON_RESULT_NAME"] = comparison_result
    target["EnvironmentVariables"]["AEGIS_COMPARISON_PROXY_COUNTRY"] = os.environ["AEGIS_COMPARISON_PROXY_COUNTRY"]
target["DefaultTestExecutionTimeAllowance"]=900
target["MaximumTestExecutionTimeAllowance"]=900
safe_line=re.compile(
    r"AEGIS-DIRECTED-(?:CONNECT [-A-F0-9]+ [A-Za-z0-9.\[\]:-]+ [A-Za-z0-9 ._=-]+|"
    r"(?:PAGE (?:categories|all) |SAMPLE )[a-zA-Z0-9.\-]+ (?:begin|end))"
    r"|AEGIS-COMPARISON-REACHABILITY [a-z0-9-]+"
    r"|Test Case '-\[AegisTests\.(?:AccessEmbeddedCoreLiveTests|AccessHostRecoveryWebKitTests) testPhoneDirected[A-Za-z]+\]' "
    r"(?:started|(?:passed|failed) \([0-9.]+ seconds\))"
    r"|\*\* TEST (?:SUCCEEDED|FAILED) \*\*"
)
common_failure=re.compile(r"(?:device is locked|Could not import directed test node|Missing per-sample Xray diagnostics|Known public asset control|Comparison LAN TCP preflight failed|failed: \([A-Za-z0-9_ .-]+\))",re.I)
os.umask(0o077)
def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def extract_dns_sans(value):
    for row in value["samples"]:
        trust = row["proxy"].get("serverTrust")
        if not trust:
            continue
        certificate = trust.pop("leafDER", None)
        if certificate:
            parsed = subprocess.run(
                ["openssl", "x509", "-inform", "DER", "-noout", "-ext", "subjectAltName"],
                input=base64.b64decode(certificate, validate=True), capture_output=True, timeout=5,
            )
            trust["dnsSANs"] = re.findall(rb"DNS:(\*?[A-Za-z0-9.-]+)", parsed.stdout)
            trust["dnsSANs"] = [name.decode("ascii") for name in trust["dnsSANs"]]
            trust["certificateParsed"] = parsed.returncode == 0


with tempfile.TemporaryDirectory(prefix="aegis-directed-private-") as temp_dir:
    temp=Path(temp_dir)
    fd,path=tempfile.mkstemp(prefix="directed-",suffix=".xctestrun",dir=products)
    transient=Path(path)
    try:
        with os.fdopen(fd,"wb") as f:
            plistlib.dump(descriptor,f)
        result=temp/"Directed.xcresult"
        args=["xcodebuild","test-without-building","-xctestrun",str(transient),
              "-destination",f"id={device}","-parallel-testing-enabled","NO",
              *["-only-testing:"+s for s in selectors],"-resultBundlePath",str(result)]
        started_at = now()
        with (out/"device.log").open("w") as log, subprocess.Popen(args,stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,text=True,errors="replace") as proc:
            for line in proc.stdout:
                m=safe_line.search(line) or common_failure.search(line)
                if not m:
                    continue
                event=m.group().strip()
                if any(n in event.encode() for n in needles):
                    continue
                if event.startswith("Test Case ") and event.endswith(" started"):
                    transient.unlink(missing_ok=True)
                print(f"{now()} {event}" if tls_only else event, file=log, flush=True)
            code=proc.wait()
        node_source = f"bundled-{bundled_channel}" if use_bundled_node else "comparison-relay" if comparison_node else "node-file"
        summary={"exitCode":code, "startedAtUTC":started_at, "finishedAtUTC":now(), "nodeSource":node_source}
        if result.is_dir():
            p=subprocess.run(["xcrun","xcresulttool","get","test-results","summary","--path",str(result)],capture_output=True)
            if p.returncode==0:
                d=json.loads(p.stdout)
                summary.update({k:d[k] for k in ("totalTestCount","passedTests","failedTests","skippedTests","result") if k in d})
                failures=[]
                for f in d.get("testFailures",[]):
                    description=f.get("failureText","")
                    if any(n in description.encode() for n in needles):
                        continue
                    failures.append(description[:200])
                if failures:
                    summary["failures"]=failures
        for name in (("tls",) if tls_only else (("webkit",) if webkit_only else ("webkit","tls"))):
            staged=temp/f"{name}.json"
            result=subprocess.run(["xcrun","devicectl","--timeout","20","device","copy","from","--device",device,
                "--domain-type","appDataContainer","--domain-identifier",host_bundle_id,
                "--source",f"/Library/Caches/{comparison_result or (run_id + '-directed-' + name + '.json')}",
                "--destination",str(staged)],capture_output=True)
            if result.returncode:
                summary[name]="not recovered"
                continue
            data=staged.read_bytes()
            if any(n in data for n in needles):
                summary[name]="redaction rejected result"
                continue
            value=json.loads(data)
            if comparison_result:
                extract_dns_sans(value)
                data = (json.dumps(value, indent=2) + "\n").encode()
            (out/f"{name}.json").write_bytes(data)
            summary[name]=len(value if isinstance(value,list) else value["samples"])
            if comparison_result:
                summary["preflight"] = value["preflight"]
                summary["diagnosticSamplesCompleted"] = len(value["samples"])
                summary["resourceChecks"] = value.get("resources")
        (out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
        print(json.dumps(summary),flush=True)
        raise SystemExit(code or int(any(summary.get(name) in ("not recovered", "redaction rejected result")
                                        for name in ("tls", "webkit"))))
    finally:
        transient.unlink(missing_ok=True)
