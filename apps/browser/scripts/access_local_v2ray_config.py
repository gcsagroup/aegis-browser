#!/usr/bin/env python3
"""Import a local V2Ray/Xray client JSON into admitted reality_vision fields.

Used for macOS/Linux smoke checks alongside the iOS AccessLocalV2RayConfigLoader.
Never prints secrets (user id / public key / short id).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

ENV_PATH = "AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"
ADMITTED_FLOW = "xtls-rprx-vision"
ADMITTED_NETWORK = "tcp"
ADMITTED_SECURITY = "reality"


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


def parameters_from_outbound(outbound: dict[str, Any]) -> dict[str, Any]:
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
        "fingerprint": (
            reality.get("fingerprint")
            or reality.get("fp")
            or "chrome"
        ),
    }


def parameters_from_flat(root: dict[str, Any]) -> dict[str, Any]:
    _reject_poison(root)
    flow = root.get("flow")
    if flow and flow != ADMITTED_FLOW:
        raise LocalV2RayError(f"unsupportedFlow:{flow}")
    network = root.get("network")
    if network and network != ADMITTED_NETWORK:
        raise LocalV2RayError(f"unsupportedNetwork:{network}")
    security = root.get("security")
    if security and security != ADMITTED_SECURITY:
        raise LocalV2RayError(f"unsupportedSecurity:{security}")
    return {
        "address": _first_str(root, ["address", "host"], "address"),
        "port": _port(root.get("port")),
        "userID": _first_str(root, ["id", "userID", "userId", "uuid"], "userID"),
        "serverName": _first_str(root, ["serverName", "server_name", "sni"], "serverName"),
        "publicKey": _first_str(root, ["publicKey", "public_key", "pbk"], "publicKey"),
        "shortID": _first_str(root, ["shortId", "short_id", "sid"], "shortID"),
        "fingerprint": root.get("fingerprint") or root.get("fp") or "chrome",
    }


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
    if "protocol" in root or "streamSettings" in root:
        return parameters_from_outbound(root)
    return parameters_from_flat(root)


def load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise LocalV2RayError(f"fileNotFound:{path}")
    try:
        root = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise LocalV2RayError("invalidJSON") from exc
    if not isinstance(root, dict):
        raise LocalV2RayError("invalidJSON")
    return parse_root(root)


def redacted_summary(path: Path, params: dict[str, Any]) -> str:
    return (
        f"ok reality_vision from {path} -> "
        f"{params['address']}:{params['port']} "
        f"sni={params['serverName']} fp={params['fingerprint']} "
        f"(secrets redacted)"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        help=f"Client JSON path (default: ${ENV_PATH})",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run synthetic fixture checks (no local secrets required)",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        sample = {
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
        params = parse_root(sample)
        assert params["address"] == "198.51.100.10"
        assert params["port"] == 443
        try:
            parse_root({"allowInsecure": True, "address": "x", "port": 1, "id": "y"})
            raise SystemExit("expected allowInsecure reject")
        except LocalV2RayError as exc:
            assert "allowInsecure" in str(exc)
        print("ok self-test")
        return 0

    raw = args.path or os.environ.get(ENV_PATH, "").strip()
    if not raw:
        print(
            f"skip: set {ENV_PATH} or pass a path to a local V2Ray/Xray JSON",
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
