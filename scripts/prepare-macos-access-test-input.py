#!/usr/bin/env python3
"""Prepare private macOS test inputs for a single Alpha or Beta build.

Supply AEGIS_ACCESS_TEST_NODE_URI through the private build environment. Create
an unused directory with --output-dir, then set aegis_<channel>_test_node_enabled
and aegis_<channel>_test_resources_dir in that channel's non-official build.
The resulting test application contains the credential and must stay private.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

import access_local_v2ray_config as config


def prepare(channel, node_file, xray, xray_sha256, output):
    if channel not in ("alpha", "beta"):
        raise ValueError("Invalid private channel")
    binary = xray.read_bytes()
    digest = hashlib.sha256(binary).hexdigest()
    if digest != xray_sha256.lower():
        raise ValueError("Xray pin mismatch")
    if node_file is None:
        uri = os.environ.get("AEGIS_ACCESS_TEST_NODE_URI", "").strip()
        if not uri:
            raise ValueError("Missing private node URI")
        params = config.parameters_from_share_uri(uri)
    else:
        params = config.load(node_file)
    outbound = {
        "protocol": "vless",
        "settings": {"vnext": [{
            "address": params["address"], "port": params["port"],
            "users": [{"id": params["userID"], "encryption": config.ADMITTED_ENCRYPTION,
                       "flow": config.ADMITTED_FLOW}],
        }]},
        "streamSettings": {
            "network": config.ADMITTED_NETWORK, "security": config.ADMITTED_SECURITY,
            "realitySettings": {
                "serverName": params["serverName"], "publicKey": params["publicKey"],
                "shortId": params["shortID"], "fingerprint": params["fingerprint"],
            },
        },
    }
    node = json.dumps({"outbounds": [outbound]}).encode()
    manifest = {
        "schemaVersion": 1, "channel": channel, "binaryRelativePath": "xray",
        "binarySha256": digest, "nodeConfigRelativePath": "node.json",
        "nodeConfigSha256": hashlib.sha256(node).hexdigest(),
    }
    # Require an unused directory so an interrupted preparation cannot replace a
    # previous candidate. Write the manifest last so consumers require all files.
    output.mkdir(mode=0o700)
    try:
        for name, data, mode in (("xray", binary, 0o700), ("node.json", node, 0o600),
                                 ("core-manifest.json", json.dumps(manifest).encode(), 0o600)):
            with os.fdopen(os.open(output / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode),
                           "wb") as stream:
                stream.write(data)
    except BaseException:
        shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("alpha", "beta"), required=True)
    parser.add_argument("--node-file", type=Path,
                        help="Local alternative to the AEGIS_ACCESS_TEST_NODE_URI secret")
    parser.add_argument("--xray", type=Path, required=True)
    parser.add_argument("--xray-sha256", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.channel, args.node_file, args.xray, args.xray_sha256, args.output_dir)
    except (OSError, ValueError, TypeError, KeyError, IndexError, config.LocalV2RayError):
        parser.exit(1, "Cannot prepare private Access test inputs. Check inputs and output directory.\n")


if __name__ == "__main__":
    main()
