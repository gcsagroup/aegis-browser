"""Correlate one post-fix Mac or iPhone run and write its failure inventory."""
from datetime import datetime
import json
from pathlib import Path
import re
import socket
import sys


HOSTS = ("githubassets.com", "ytimg.com", "googlevideo.com", "www.githubcopilot.com", "nflxvideo.net")
CONNECT = re.compile(r"AEGIS-DIRECTED-CONNECT ([A-F0-9-]+) ([a-z0-9.-]+):443 (.+)")


def read_json(path, default):
    return json.loads(path.read_text()) if path.is_file() else default


def timestamp(row):
    return datetime.fromisoformat(row["time"])


def classify(flow, client):
    status = client.get("status")
    if status and int(status):
        return "http-response"
    dns = next((event for event in flow if event["event"] == "lan-dns-response"), None)
    if dns and not any(record["answers"] for record in dns["records"]):
        codes = {record["rcode"] for record in dns["records"]}
        if codes == {"NOERROR"}:
            return "relay-dns-no-address"
        if codes == {"NXDOMAIN"}:
            return "relay-dns-nxdomain"
        return "relay-dns-error"
    for event in flow:
        if event["event"] == "dns-error":
            empty = {socket.EAI_NONAME, getattr(socket, "EAI_NODATA", socket.EAI_NONAME)}
            return "relay-dns-no-address" if event["code"] in empty else "relay-dns-error"
    kinds = {event["event"] for event in flow}
    closes = {event["action"] for event in flow if event["event"] == "close"}
    if "socks-host-unreachable" in closes:
        return "relay-dns-no-usable-address"
    if "all-target-dials-failed" in closes:
        errors = [event["kind"] for event in flow if event["event"] == "tcp-error"]
        if errors and all(kind == "TimeoutError" for kind in errors):
            return "relay-target-tcp-timeout"
        return "relay-target-tcp-failed" if errors else "relay-dns-no-usable-address"
    if "tls-alert" in kinds:
        return "tls-alert"
    cert_codes = set(range(-1204, -1200))
    if (client.get("serverTrust") or {}).get("error"):
        return "tls-certificate-verification"
    if client.get("curl_code") == 60 or any(
        error["domain"] == "NSURLErrorDomain" and error["code"] in cert_codes
        for error in client.get("errors", [])
    ):
        return "tls-certificate-verification"
    if any(error["domain"] == "NSURLErrorDomain" and error["code"] in (-1205, -1206)
           for error in client.get("errors", [])):
        return "tls-client-identity"
    if "tcp-open" in kinds:
        return "tls-or-stream-failure"
    return "unresolved"


def summarize(root):
    events = [json.loads(line) for line in (root / "origin-events.jsonl").read_text().splitlines()]
    start = next(event for event in events if event["event"] == "run-start")
    finish = next((event for event in events if event["event"] == "run-finish"), {})
    summary = read_json(root / "summary.json", {})
    phone = start["client"] == "phone"
    expected_peer = "lan-peer" if phone else "mac-control"
    ingress = {event["xray_source_port"]: event for event in events if event["event"] == "reality-ingress-forwarded"}
    accepted = read_json(root / "xray-targets.json", [])

    def relay_accept(row, peer):
        entry = ingress.get(row["xray_source_port"])
        return entry is not None and entry["peer"] == peer and timestamp(entry) <= timestamp(row)

    def accepted_targets(host, peer=expected_peer):
        return [row for row in accepted if row["target"] == host and relay_accept(row, peer)]

    def mac_result(host):
        return next((event for event in events if event["event"] == "mac-case-end" and event["host"] == host), {})

    device_log = root / "device.log"
    connect = {}
    if device_log.is_file():
        for line in device_log.read_text().splitlines():
            match = CONNECT.search(line)
            if match:
                stream, host, action = match.groups()
                connect.setdefault(host, []).append({"stream": stream, "action": action})
    payload = read_json(root / "tls.json", {})
    device_rows = {row["target"]["h"]: row for row in payload.get("samples", [])}
    standalone = next((event for event in events if event["event"] == "mac-control"), {})
    standalone_ok = standalone.get("code") == 0 and standalone.get("country") == start["expected_proxy_country"]
    standalone_ok = standalone_ok and bool(accepted_targets("www.cloudflare.com", "mac-control"))
    css = payload.get("cssControl", {}) if phone else mac_result("github.githubassets.com")
    controls_ok = standalone_ok and str(css.get("status")) == "200" and bool(accepted_targets("github.githubassets.com"))
    if phone:
        controls_ok = controls_ok and payload.get("preflight") == "controls-passed"

    rows = []
    for host in HOSTS:
        client = device_rows.get(host, {}).get("proxy", {}) if phone else mac_result(host)
        direct = device_rows.get(host, {}).get("direct") if phone else None
        if not client:
            continue
        records = accepted_targets(host)
        requests = [event for event in events if event["event"] == "target-request" and event["host"] == host]
        local = connect.get(host, [])
        http_tunnel = (not phone or (
            len({entry["stream"] for entry in local}) == 1
            and any(entry["action"] == "connect-200" for entry in local)
            and any("tunneling request" in line and f"tcp:{host}:443" in line
                    for line in device_rows[host].get("xray", []))
        ))
        matched = len(records) == len(requests) == 1 and http_tunnel
        if matched:
            delta = (timestamp(requests[0]) - timestamp(records[0])).total_seconds()
            matched = abs(delta) <= 2
        flow = [event for event in events if event.get("flow") == requests[0]["flow"]] if matched else []
        closes = [event for event in flow if event["event"] == "close"]
        eof = [event for event in closes if event["action"] == "read-eof"]
        rows.append({
            "host": host,
            "matched": matched,
            "stage": classify(flow, client) if matched else "unmatched",
            "local_connect": local,
            "xray_accepted": records,
            "origin_flow": requests[0]["flow"] if matched else None,
            "dns": [event for event in flow if event["event"] in ("dns-error", "lan-dns-response", "dns-addresses")],
            "tcp": [event for event in flow if event["event"].startswith("tcp-")],
            "client_hello": next((event for event in flow if event["event"] == "client-hello"), None),
            "first_tls_records": [event for event in flow if event["event"] == "first-tls-record"],
            "tls_alerts": [event for event in flow if event["event"] == "tls-alert"],
            "first_eof": eof[0] if eof else None,
            "closes": closes,
            "client": client,
            "direct": direct,
        })

    resources = (payload.get("resources") or {}) if phone else {
        "cssRulePresent": any(event["event"] == "mac-css-control" and event["present"] for event in events),
        "thumbnailDecoded": any(event["event"] == "mac-thumbnail-control" and event["decoded"] for event in events),
    }
    css_check = "cssApplied" if phone else "cssRulePresent"
    resources_ok = (resources.get(css_check) is True and resources.get("thumbnailDecoded") is True
                    and bool(accepted_targets("i.ytimg.com")))
    diagnostics_ok = controls_ok and len(rows) == len(HOSTS) and all(
        row["matched"] and row["stage"] != "unresolved" for row in rows
    )
    return {
        "run": root.name,
        "client": start["client"],
        "origin_interface": start["origin_interface"],
        "preflight": summary.get("preflight", "mac-control" if not phone else "device-test-not-started"),
        "runner_exit": finish.get("exit_code"),
        "controls_passed": controls_ok,
        "diagnostics_completed": len(rows),
        "diagnostics_matched": sum(row["matched"] for row in rows),
        "diagnostics_accepted": diagnostics_ok,
        "resource_checks": resources,
        "resources_accepted": resources_ok,
        "accepted": diagnostics_ok and resources_ok and finish.get("exit_code") == 0,
        "samples": rows,
    }


if __name__ == "__main__":
    root = Path(sys.argv[1])
    result = summarize(root)
    (root / "acceptance.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}, indent=2))
    raise SystemExit(0 if result["accepted"] else 1)
