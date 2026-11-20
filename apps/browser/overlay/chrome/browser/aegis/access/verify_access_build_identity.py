#!/usr/bin/env python3
# Copyright 2026 GCSA
"""Validate native Access flags against the macOS app's channel metadata."""
import argparse
import plistlib
from pathlib import Path


def chromium_channel(branded, metadata):
    # chrome/common/channel_info_mac.mm ignores Keystone when unbranded.
    if not branded or metadata.get("KSProductID") is None:
        return "unknown"
    tag = metadata.get("KSChannelID")
    if tag is None or tag in ("arm64", "universal"):
        return "stable"
    if not isinstance(tag, str):
        raise ValueError("KSChannelID must be a string")
    for prefix in ("arm64-", "universal-"):
        if tag.startswith(prefix):
            tag = tag[len(prefix):]
            break
    if tag == "extended":
        return "stable"
    return tag if tag in ("beta", "dev", "canary") else "unknown"


def validate_identity(product, internal, branded, metadata):
    if product not in ("unknown", "debug", "alpha", "beta", "stable"):
        raise ValueError("Unknown Access product identity")
    if internal and product not in ("debug", "alpha"):
        raise ValueError("Internal Options requires Debug or Alpha identity")
    browser = chromium_channel(branded, metadata)
    if browser in ("beta", "stable") and product not in ("unknown", browser):
        raise ValueError("Access product identity conflicts with Chromium release channel")
    return browser


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plist", type=Path, required=True)
    parser.add_argument("--product-channel", required=True)
    parser.add_argument("--internal-options", choices=("true", "false"), required=True)
    parser.add_argument("--chrome-branded", choices=("true", "false"), required=True)
    parser.add_argument("--stamp", type=Path, required=True)
    args = parser.parse_args()
    with args.plist.open("rb") as source:
        metadata = plistlib.load(source)
    validate_identity(args.product_channel, args.internal_options == "true",
                      args.chrome_branded == "true", metadata)
    args.stamp.parent.mkdir(parents=True, exist_ok=True)
    args.stamp.write_text("Access build identity verified\n", encoding="utf-8")


if __name__ == "__main__":
    main()
