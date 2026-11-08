#!/usr/bin/env python3
"""Import local Reality Vision endpoints for Access smoke tests.

Supports (in order):
1. `vless://` share URI (same minimal surface as iOS)
2. Xray Core outbound (`protocol` + `streamSettings.realitySettings`)
3. sing-box outbound (`type: vless` + `tls.reality`)
4. Flat parameter JSON

Never prints secrets (uuid / public key / short id).
Routing assets (geoip.dat / geosite*.srs) are out of scope.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

ENV_PATH = "AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"
ADMITTED_FLOW = "xtls-rprx-vision"
ADMITTED_NETWORK = "tcp"
ADMITTED_SECURITY = "reality"
ADMITTED_ENCRYPTION = "none"


class LocalV2RayError(Exception):
    pass


def _reject_poison(node: Any) -> None:
    stack = [node]
    while stack:
        current = stack.pop()
        if isinstance(current, dict):
            if "allowInsecure" in current:
                raise LocalV2RayError("allowInsecureRejected")
            if "wsSettings" in current:
                raise LocalV2RayError("unsupportedNetwork:ws")
            stack.extend(current.values())
        elif isinstance(current, list):
            stack.extend(current)


def _first_str(data: dict[str, Any], keys: list[str], field: str) -> str:
    for key in keys:
        if key in data and data[key] is not None:
            text = str(data[key]).strip()
            if not text:
                raise LocalV2RayError(f"emptyField:{field}")
            return text
    raise LocalV2RayError(f"emptyField:{field}")


def _port(value: Any) -> int:
    if value is None:
        raise LocalV2RayError("emptyField:port")
    port = int(value)
    if port <= 0 or port > 65535:
        raise LocalV2RayError("fieldNotCanonical:port")
    return port


def parameters_from_share_uri(raw: str) -> dict[str, Any]:
    text = raw.strip().splitlines()[0].strip()
    parsed = urlparse(text)
    if parsed.scheme.lower() != "vless":
        raise LocalV2RayError("invalidJSON")
    user_id = unquote(parsed.username or "")
    host = parsed.hostname or ""
    if not user_id:
        raise LocalV2RayError("emptyField:userID")
    if not host:
        raise LocalV2RayError("emptyField:address")
    if parsed.port is None:
        raise LocalV2RayError("emptyField:port")
    query = {k: v[-1] for k, v in parse_qs(parsed.query, keep_blank_values=False).items()}
    flow = query.get("flow") or ADMITTED_FLOW
    if flow != ADMITTED_FLOW:
        raise LocalV2RayError(f"unsupportedFlow:{flow}")
    security = query.get("security") or ""
    if security != ADMITTED_SECURITY:
        raise LocalV2RayError(f"unsupportedSecurity:{security or '<missing>'}")
    network = query.get("type") or ADMITTED_NETWORK
    if network != ADMITTED_NETWORK:
        raise LocalV2RayError(f"unsupportedNetwork:{network}")
    encryption = query.get("encryption")
    if encryption and encryption != ADMITTED_ENCRYPTION:
        raise LocalV2RayError("fieldNotCanonical:encryption")
    if "allowInsecure" in query:
        raise LocalV2RayError("allowInsecureRejected")
    return {
        "address": host,
        "port": _port(parsed.port),
        "userID": user_id,
        "serverName": query.get("sni") or query.get("serverName") or _missing("serverName"),
        "publicKey": query.get("pbk") or query.get("publicKey") or _missing("publicKey"),
        "shortID": query.get("sid") or query.get("shortId") or _missing("shortID"),
        "fingerprint": query.get("fp") or query.get("fingerprint") or "chrome",
        "source": "vless-uri",
    }


def _missing(field: str) -> str:
    raise LocalV2RayError(f"emptyField:{field}")


def parameters_from_xray_outbound(outbound: dict[str, Any]) -> dict[str, Any]:
    _reject_poison(outbound)
    if str(outbound.get("protocol", "")).lower() != "vless":
        raise LocalV2RayError("noAdmittedRealityOutbound")
    settings = outbound.get("settings") or {}
    vnext = settings.get("vnext") or []
    if not vnext:
        raise LocalV2RayError("emptyField:vnext")
    server = vnext[0]
    users = server.get("users") or []
    if not users:
        raise LocalV2RayError("emptyField:users")
    user = users[0]
    flow = user.get("flow") or ADMITTED_FLOW
    if flow != ADMITTED_FLOW:
        raise LocalV2RayError(f"unsupportedFlow:{flow}")
    stream = outbound.get("streamSettings") or {}
    network = stream.get("network") or ADMITTED_NETWORK
    if network != ADMITTED_NETWORK:
        raise LocalV2RayError(f"unsupportedNetwork:{network}")
    security = stream.get("security") or ""
    if security != ADMITTED_SECURITY:
        raise LocalV2RayError(f"unsupportedSecurity:{security or '<missing>'}")
    reality = stream.get("realitySettings") or {}
    _reject_poison(reality)
    return {
        "address": _first_str(server, ["address"], "address"),
        "port": _port(server.get("port")),
        "userID": _first_str(user, ["id"], "userID"),
        "serverName": _first_str(reality, ["serverName", "server_name", "sni"], "serverName"),
        "publicKey": _first_str(reality, ["publicKey", "public_key", "pbk"], "publicKey"),
        "shortID": _first_str(reality, ["shortId", "short_id", "sid"], "shortID"),
        "fingerprint": reality.get("fingerprint") or reality.get("fp") or "chrome",
        "source": "xray-core",
    }


def parameters_from_singbox_outbound(outbound: dict[str, Any]) -> dict[str, Any]:
    _reject_poison(outbound)
    if str(outbound.get("type", "")).lower() != "vless":
        raise LocalV2RayError("noAdmittedRealityOutbound")
    flow = outbound.get("flow") or ADMITTED_FLOW
    if flow != ADMITTED_FLOW:
        raise LocalV2RayError(f"unsupportedFlow:{flow}")
    # Leave transport unset = raw TCP. Explicit ws/http/grpc is rejected.
    transport = outbound.get("transport")
    if isinstance(transport, dict):
        transport_type = str(transport.get("type") or "").lower()
        if transport_type and transport_type not in {"tcp", "raw"}:
            raise LocalV2RayError(f"unsupportedNetwork:{transport_type}")
    network = outbound.get("network")
    if network and network != ADMITTED_NETWORK:
        # sing-box network restricts proxied traffic; tcp-only is fine.
        if network != "tcp":
            raise LocalV2RayError(f"unsupportedNetwork:{network}")
    tls = outbound.get("tls") or {}
    reality = tls.get("reality") or {}
    if not reality.get("enabled", False) and "public_key" not in reality and "publicKey" not in reality:
        raise LocalV2RayError("unsupportedSecurity:<missing-reality>")
    utls = tls.get("utls") or {}
    return {
        "address": _first_str(outbound, ["server", "address"], "address"),
        "port": _port(outbound.get("server_port") or outbound.get("port")),
        "userID": _first_str(outbound, ["uuid", "id", "userID"], "userID"),
        "serverName": _first_str(tls, ["server_name", "serverName", "sni"], "serverName"),
        "publicKey": _first_str(reality, ["public_key", "publicKey", "pbk"], "publicKey"),
        "shortID": _first_str(reality, ["short_id", "shortId", "sid"], "shortID"),
        "fingerprint": utls.get("fingerprint") or tls.get("fingerprint") or "chrome",
        "source": "sing-box",
    }


def parameters_from_flat(root: dict[str, Any]) -> dict[str, Any]:
    _reject_poison(root)
    flow = root.get("flow")
    if flow and flow != ADMITTED_FLOW:
        raise LocalV2RayError(f"unsupportedFlow:{flow}")
    network = root.get("network") or root.get("type")
    if network and network not in {ADMITTED_NETWORK, "vless"}:
        raise LocalV2RayError(f"unsupportedNetwork:{network}")
    security = root.get("security")
    if security and security != ADMITTED_SECURITY:
        raise LocalV2RayError(f"unsupportedSecurity:{security}")
    return {
        "address": _first_str(root, ["address", "host", "server"], "address"),
        "port": _port(root.get("port") or root.get("server_port")),
        "userID": _first_str(root, ["id", "userID", "userId", "uuid"], "userID"),
        "serverName": _first_str(root, ["serverName", "server_name", "sni"], "serverName"),
        "publicKey": _first_str(root, ["publicKey", "public_key", "pbk"], "publicKey"),
        "shortID": _first_str(root, ["shortId", "short_id", "sid"], "shortID"),
        "fingerprint": root.get("fingerprint") or root.get("fp") or "chrome",
        "source": "flat",
    }


def parameters_from_outbound(outbound: dict[str, Any]) -> dict[str, Any]:
    # Prefer explicit discriminators.
    if "protocol" in outbound or "streamSettings" in outbound:
        return parameters_from_xray_outbound(outbound)
    if str(outbound.get("type", "")).lower() == "vless" or "tls" in outbound:
        return parameters_from_singbox_outbound(outbound)
    raise LocalV2RayError("noAdmittedRealityOutbound")


def parse_root(root: dict[str, Any]) -> dict[str, Any]:
    _reject_poison(root)
    outbounds = root.get("outbounds")
    if isinstance(outbounds, list):
        for outbound in outbounds:
            if isinstance(outbound, dict):
                try:
                    return parameters_from_outbound(outbound)
                except LocalV2RayError:
                    continue
        raise LocalV2RayError("noAdmittedRealityOutbound")
    if "protocol" in root or "streamSettings" in root or str(root.get("type", "")).lower() == "vless":
        return parameters_from_outbound(root)
    return parameters_from_flat(root)


def parse_text(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        raise LocalV2RayError("invalidJSON")
    first = stripped.splitlines()[0].strip()
    if first.lower().startswith("vless://"):
        return parameters_from_share_uri(first)
    try:
        root = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise LocalV2RayError("invalidJSON") from exc
    if not isinstance(root, dict):
        raise LocalV2RayError("invalidJSON")
    return parse_root(root)


def load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise LocalV2RayError(f"fileNotFound:{path}")
    return parse_text(path.read_text(encoding="utf-8"))


def redacted_summary(path: Path, params: dict[str, Any]) -> str:
    return (
        f"ok reality_vision ({params.get('source', '?')}) from {path} -> "
        f"{params['address']}:{params['port']} "
        f"sni={params['serverName']} fp={params['fingerprint']} "
        f"(secrets redacted)"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        help=f"Client JSON or vless:// text path (default: ${ENV_PATH})",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run synthetic fixture checks (no local secrets required)",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        def require(condition: bool, message: str) -> None:
            if not condition:
                raise SystemExit(f"self-test failed: {message}")

        uri = (
            "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
            "?flow=xtls-rprx-vision&security=reality&encryption=none&type=tcp"
            "&sni=www.example.com&fp=chrome"
            "&pbk=abcdefghijklmnopqrstuvwxyzABCDEFG&sid=abcd1234#demo"
        )
        require(
            parameters_from_share_uri(uri)["address"] == "198.51.100.10",
            "vless uri address",
        )

        xray = {
            "outbounds": [
                {
                    "protocol": "vless",
                    "settings": {
                        "vnext": [
                            {
                                "address": "198.51.100.10",
                                "port": 443,
                                "users": [
                                    {
                                        "id": "550e8400-e29b-41d4-a716-446655440000",
                                        "flow": ADMITTED_FLOW,
                                    }
                                ],
                            }
                        ]
                    },
                    "streamSettings": {
                        "network": ADMITTED_NETWORK,
                        "security": ADMITTED_SECURITY,
                        "realitySettings": {
                            "serverName": "www.example.com",
                            "publicKey": "abcdefghijklmnopqrstuvwxyzABCDEFG",
                            "shortId": "abcd1234",
                            "fingerprint": "chrome",
                        },
                    },
                }
            ]
        }
        require(parse_root(xray)["source"] == "xray-core", "xray-core source")

        sing = {
            "outbounds": [
                {
                    "type": "vless",
                    "server": "198.51.100.10",
                    "server_port": 443,
                    "uuid": "550e8400-e29b-41d4-a716-446655440000",
                    "flow": ADMITTED_FLOW,
                    "tls": {
                        "enabled": True,
                        "server_name": "www.example.com",
                        "utls": {"enabled": True, "fingerprint": "chrome"},
                        "reality": {
                            "enabled": True,
                            "public_key": "abcdefghijklmnopqrstuvwxyzABCDEFG",
                            "short_id": "abcd1234",
                        },
                    },
                }
            ]
        }
        require(parse_root(sing)["source"] == "sing-box", "sing-box source")
        print("ok self-test (vless-uri + xray-core + sing-box)")
        return 0

    raw = args.path or os.environ.get(ENV_PATH, "").strip()
    if not raw:
        print(
            f"skip: set {ENV_PATH} or pass a path to a local vless:// / Xray / sing-box JSON",
            file=sys.stderr,
        )
        return 2
    path = Path(raw).expanduser()
    try:
        params = load(path)
    except LocalV2RayError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(redacted_summary(path, params))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
