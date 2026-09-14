#!/usr/bin/env python3

import json
import pathlib
import sys


ENUMS = {
    "policyState": {
        "absent": "PolicyState::kAbsent",
        "valid": "PolicyState::kValid",
        "conflict": "PolicyState::kConflict",
        "invalid": "PolicyState::kInvalid",
    },
    "effectiveMode": {
        "none": "AccessMode::kNone",
        "direct": "AccessMode::kDirect",
        "proxy": "AccessMode::kProxy",
        "reject": "AccessMode::kReject",
        "invalid": "AccessMode::kInvalid",
    },
    "policyScope": {
        "none": "PolicyScope::kNone",
        "site": "PolicyScope::kSite",
        "profile": "PolicyScope::kProfile",
        "invalid": "PolicyScope::kInvalid",
    },
    "snapshotState": {
        "missing": "SnapshotState::kMissing",
        "restoring": "SnapshotState::kRestoring",
        "published": "SnapshotState::kPublished",
        "corrupt": "SnapshotState::kCorrupt",
        "invalid": "SnapshotState::kInvalid",
    },
    "protectionRestriction": {
        "none": "ProtectionRestriction::kNone",
        "deny": "ProtectionRestriction::kDeny",
        "invalid": "ProtectionRestriction::kInvalid",
    },
    "managedRestriction": {
        "none": "ManagedRestriction::kNone",
        "force_proxy": "ManagedRestriction::kForceProxy",
        "force_direct": "ManagedRestriction::kForceDirect",
        "custom_proxy_forbidden": "ManagedRestriction::kCustomProxyForbidden",
        "invalid": "ManagedRestriction::kInvalid",
    },
    "runtimeState": {
        "stopped": "ProxyRuntimeState::kStopped",
        "preparing": "ProxyRuntimeState::kPreparing",
        "ready": "ProxyRuntimeState::kReady",
        "recovering": "ProxyRuntimeState::kRecovering",
        "offline": "ProxyRuntimeState::kOffline",
        "quota_exhausted": "ProxyRuntimeState::kQuotaExhausted",
        "signed_out": "ProxyRuntimeState::kSignedOut",
        "unavailable": "ProxyRuntimeState::kUnavailable",
        "invalid": "ProxyRuntimeState::kInvalid",
    },
    "channel": {
        "dev": "ChannelNamespace::kDev",
        "alpha": "ChannelNamespace::kAlpha",
        "beta": "ChannelNamespace::kBeta",
        "release": "ChannelNamespace::kRelease",
        "invalid": "ChannelNamespace::kInvalid",
    },
    "action": {
        "preserve_native": "RouteAction::kPreserveNative",
        "use_registered_proxy": "RouteAction::kUseRegisteredProxy",
        "wait": "RouteAction::kWait",
        "deny": "RouteAction::kDeny",
        "fail": "RouteAction::kFail",
    },
    "reason": {
        "none": "RouteReason::kNone",
        "missing_snapshot": "RouteReason::kMissingSnapshot",
        "snapshot_not_ready": "RouteReason::kSnapshotNotReady",
        "stale_generation": "RouteReason::kStaleGeneration",
        "ownership_mismatch": "RouteReason::kOwnershipMismatch",
        "site_ownership_unavailable": "RouteReason::kSiteOwnershipUnavailable",
        "invalid_policy": "RouteReason::kInvalidPolicy",
        "policy_conflict": "RouteReason::kPolicyConflict",
        "managed_restriction": "RouteReason::kManagedRestriction",
        "protection_restriction": "RouteReason::kProtectionRestriction",
        "proxy_unavailable": "RouteReason::kProxyUnavailable",
        "quota_exhausted": "RouteReason::kQuotaExhausted",
        "signed_out": "RouteReason::kSignedOut",
    },
}

INPUT_KEYS = {
    "policyState", "effectiveMode", "policyScope", "effectiveProxyGroupId",
    "requireProxyIntent", "siteOwnershipReliable", "requestOwner",
    "snapshotState", "snapshotOwner", "requestGenerations",
    "snapshotGenerations", "protectionRestriction", "managedRestriction",
    "runtimeState", "registeredEntry",
}
OWNER_KEYS = {"channel", "profileToken", "storagePartitionToken"}
GENERATION_KEYS = {
    "policyGeneration", "identityGeneration", "selectionGeneration",
    "networkEpoch", "baseProxyConfigGeneration",
}
ENTRY_KEYS = {"registrationId", "proxyGroupId", "owner", "generations"}


def require_dict(value, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def require_keys(value, allowed, label):
    unknown = set(value) - allowed
    if unknown:
        raise ValueError(f"{label} has unknown keys: {sorted(unknown)}")


def merge_object(base, override, allowed, label):
    require_dict(base, f"{label} base")
    require_dict(override, label)
    require_keys(override, allowed, label)
    return {**base, **override}


def merge_input(defaults, override):
    require_keys(defaults, INPUT_KEYS, "defaults")
    require_keys(override, INPUT_KEYS, "input")
    merged = {**defaults, **override}
    for key in ("requestOwner", "snapshotOwner"):
        merged[key] = merge_object(
            defaults[key], override.get(key, {}), OWNER_KEYS, key)
    for key in ("requestGenerations", "snapshotGenerations"):
        merged[key] = merge_object(
            defaults[key], override.get(key, {}), GENERATION_KEYS, key)
    if override.get("registeredEntry", object()) is None:
        merged["registeredEntry"] = None
    else:
        entry_override = override.get("registeredEntry", {})
        entry = merge_object(
            defaults["registeredEntry"], entry_override, ENTRY_KEYS,
            "registeredEntry")
        entry["owner"] = merge_object(
            defaults["registeredEntry"]["owner"],
            entry_override.get("owner", {}), OWNER_KEYS,
            "registeredEntry.owner")
        entry["generations"] = merge_object(
            defaults["registeredEntry"]["generations"],
            entry_override.get("generations", {}), GENERATION_KEYS,
            "registeredEntry.generations")
        merged["registeredEntry"] = entry
    return merged


def enum(kind, value, label):
    try:
        return ENUMS[kind][value]
    except (KeyError, TypeError):
        raise ValueError(f"{label} has unsupported value {value!r}") from None


def string(value, label):
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    return json.dumps(value, ensure_ascii=True)


def boolean(value, label):
    if not isinstance(value, bool):
        raise ValueError(f"{label} must be a boolean")
    return "true" if value else "false"


def uint(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a non-negative integer")
    return f"{value}u"


def owner(value, label):
    require_dict(value, label)
    require_keys(value, OWNER_KEYS, label)
    return "OwnershipKey{{{}, {}, {}}}".format(
        enum("channel", value["channel"], f"{label}.channel"),
        string(value["profileToken"], f"{label}.profileToken"),
        string(value["storagePartitionToken"],
               f"{label}.storagePartitionToken"),
    )


def generations(value, label):
    require_dict(value, label)
    require_keys(value, GENERATION_KEYS, label)
    return "GenerationTuple{{{}, {}, {}, {}, {}}}".format(
        uint(value["policyGeneration"], f"{label}.policyGeneration"),
        uint(value["identityGeneration"], f"{label}.identityGeneration"),
        uint(value["selectionGeneration"], f"{label}.selectionGeneration"),
        uint(value["networkEpoch"], f"{label}.networkEpoch"),
        uint(value["baseProxyConfigGeneration"],
             f"{label}.baseProxyConfigGeneration"),
    )


def entry(value, label):
    if value is None:
        return "std::nullopt"
    require_dict(value, label)
    require_keys(value, ENTRY_KEYS, label)
    return "RegisteredProxyEntry{{{}, {}, {}, {}}}".format(
        string(value["registrationId"], f"{label}.registrationId"),
        string(value["proxyGroupId"], f"{label}.proxyGroupId"),
        owner(value["owner"], f"{label}.owner"),
        generations(value["generations"], f"{label}.generations"),
    )


def emit_vector(vector, defaults, index):
    require_dict(vector, f"plannerVectors[{index}]")
    name = vector.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError(f"plannerVectors[{index}].name must be non-empty")
    input_value = merge_input(defaults, require_dict(vector.get("input"),
                                                       f"{name}.input"))
    expected = require_dict(vector.get("expected"), f"{name}.expected")
    require_keys(expected, {"action", "reason", "registrationId"},
                 f"{name}.expected")
    registration = expected["registrationId"]
    if registration is None:
        expected_entry = "std::nullopt"
    else:
        expected_entry = (
            "std::optional<std::string>{" +
            string(registration, f"{name}.expected.registrationId") + "}")
    return f'''vectors.push_back(GoldenRouteVector{{
    {string(name, f"{name}.name")},
    RouteInput{{
        {enum("policyState", input_value["policyState"], f"{name}.policyState")},
        {enum("effectiveMode", input_value["effectiveMode"], f"{name}.effectiveMode")},
        {enum("policyScope", input_value["policyScope"], f"{name}.policyScope")},
        {string(input_value["effectiveProxyGroupId"], f"{name}.effectiveProxyGroupId")},
        {boolean(input_value["requireProxyIntent"], f"{name}.requireProxyIntent")},
        {boolean(input_value["siteOwnershipReliable"], f"{name}.siteOwnershipReliable")},
        {owner(input_value["requestOwner"], f"{name}.requestOwner")},
        {enum("snapshotState", input_value["snapshotState"], f"{name}.snapshotState")},
        {owner(input_value["snapshotOwner"], f"{name}.snapshotOwner")},
        {generations(input_value["requestGenerations"], f"{name}.requestGenerations")},
        {generations(input_value["snapshotGenerations"], f"{name}.snapshotGenerations")},
        {enum("protectionRestriction", input_value["protectionRestriction"], f"{name}.protectionRestriction")},
        {enum("managedRestriction", input_value["managedRestriction"], f"{name}.managedRestriction")},
        {enum("runtimeState", input_value["runtimeState"], f"{name}.runtimeState")},
        {entry(input_value["registeredEntry"], f"{name}.registeredEntry")},
    }},
    {enum("action", expected["action"], f"{name}.expected.action")},
    {enum("reason", expected["reason"], f"{name}.expected.reason")},
    {expected_entry},
}});'''


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: generate_route_planner_vectors.py INPUT.json OUTPUT.inc")
    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    parsed = require_dict(json.loads(input_path.read_text()), "vector file")
    if parsed.get("schemaVersion") != 1:
        raise ValueError("schemaVersion must be 1")
    defaults = require_dict(parsed.get("defaults"), "defaults")
    vectors = parsed.get("plannerVectors")
    if not isinstance(vectors, list) or not vectors:
        raise ValueError("plannerVectors must be a non-empty array")
    names = [vector.get("name") for vector in vectors
             if isinstance(vector, dict)]
    if len(names) != len(vectors) or len(set(names)) != len(names):
        raise ValueError("planner vector names must be present and unique")
    content = ["// Generated from the shared route planner vectors."]
    content.extend(emit_vector(vector, defaults, index)
                   for index, vector in enumerate(vectors))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(content) + "\n")


if __name__ == "__main__":
    main()
