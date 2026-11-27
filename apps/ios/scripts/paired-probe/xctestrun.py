"""Locate the test target in legacy or configuration-based XCTest descriptors."""

from pathlib import Path
import plistlib
import re


def device_identifier(value):
    """Keep the device ID a single destination value in xcodebuild."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,127}", value):
        raise SystemExit("AEGIS_PROBE_DEVICE must be a paired device identifier")
    return value


def aegis_test_target(descriptor):
    if "AegisTests" in descriptor:
        return descriptor["AegisTests"]
    targets = [target for configuration in descriptor.get("TestConfigurations", [])
               if configuration.get("IsEnabled", True)
               for target in configuration.get("TestTargets", [])
               if target.get("BlueprintName") == "AegisTests"]
    if len(targets) != 1:
        raise ValueError("Expected exactly one enabled AegisTests target in the XCTest descriptor")
    return targets[0]


def aegis_test_host(target, products):
    """Resolve the selected Aegis test host and validate its container identity."""
    prefix = "__TESTROOT__/"
    host_path = target.get("TestHostPath", "")
    if not isinstance(host_path, str) or not host_path.startswith(prefix):
        raise ValueError("Expected an app test host relative to the XCTest products")
    products = Path(products).resolve(strict=True)
    app = (products / host_path.removeprefix(prefix)).resolve(strict=True)
    if not app.is_relative_to(products) or app.name != "Aegis.app":
        raise ValueError("Expected Aegis.app inside the XCTest products")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") not in (
            "com.gcsa.aegis", "com.gcsa.aegis.alpha.internal"):
        raise ValueError("Unexpected Aegis test host bundle identifier")
    return app, info
