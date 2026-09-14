#!/usr/bin/env python3

import json
import pathlib
import sys


ENUMS = {
    "attribution": {
        "document": "RequestAttributionKind::kDocument",
        "profile_only": "RequestAttributionKind::kProfileOnly",
    },
    "scope": {
        "none": "PolicyScope::kNone",
        "site": "PolicyScope::kSite",
        "profile": "PolicyScope::kProfile",
        "invalid": "PolicyScope::kInvalid",
    },
    "scheme": {
        "http": "RequestScheme::kHttp",
        "https": "RequestScheme::kHttps",
        "ws": "RequestScheme::kWs",
        "wss": "RequestScheme::kWss",
    },
    "portScope": {
        "all": "PortScope::kAllBrowserPermitted",
        "explicit": "PortScope::kExplicitSubset",
    },
    "mode": {
        "none": "AccessMode::kNone",
        "direct": "AccessMode::kDirect",
        "proxy": "AccessMode::kProxy",
        "reject": "AccessMode::kReject",
        "invalid": "AccessMode::kInvalid",
    },
    "protectionOverride": {
        "none": "ProtectionOverride::kNone",
        "tracker": "ProtectionOverride::kTracker",
        "easylist": "ProtectionOverride::kEasyList",
        "cname": "ProtectionOverride::kCname",
    },
    "state": {
        "absent": "PolicyState::kAbsent",
        "valid": "PolicyState::kValid",
        "conflict": "PolicyState::kConflict",
        "invalid": "PolicyState::kInvalid",
    },
    "reason": {
        "none": "PolicyMatchReason::kNone",
        "no_matching_rule": "PolicyMatchReason::kNoMatchingRule",
        "ownership_mismatch": "PolicyMatchReason::kOwnershipMismatch",
        "invalid_snapshot": "PolicyMatchReason::kInvalidSnapshot",
        "invalid_rule": "PolicyMatchReason::kInvalidRule",
        "policy_conflict": "PolicyMatchReason::kPolicyConflict",
    },
}

FULL_SCHEMES = ["http", "https", "ws", "wss"]


def require_dict(value, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def require_keys(value, allowed, label):
    unknown = set(value) - allowed
    if unknown:
        raise ValueError(f"{label} has unknown keys: {sorted(unknown)}")


def string(value, label):
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    return json.dumps(value, ensure_ascii=True)


def boolean(value, label):
    if not isinstance(value, bool):
        raise ValueError(f"{label} must be a boolean")
    return "true" if value else "false"


def enum(kind, value, label):
    try:
        return ENUMS[kind][value]
    except (KeyError, TypeError):
        raise ValueError(f"{label} has unsupported value {value!r}") from None


def vector(values, emit, label):
    if not isinstance(values, list):
        raise ValueError(f"{label} must be an array")
    return "{" + ", ".join(emit(value, label) for value in values) + "}"


def uint16(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 < value <= 65535:
        raise ValueError(f"{label} must be an integer in 1..65535")
    return f"{value}u"


def emit_rule(rule, vector_name, index):
    label = f"{vector_name}.rules[{index}]"
    require_dict(rule, label)
    require_keys(
        rule,
        {
            "id", "scope", "topLevelSite", "host", "includeSubdomains",
            "schemes", "portScope", "explicitPorts", "mode",
            "proxyGroupId", "protectionOverride",
        },
        label,
    )
    scope = rule.get("scope")
    top_level_site = rule.get(
        "topLevelSite", "https://example.test" if scope == "site" else "")
    mode = rule.get("mode")
    proxy_group = rule.get(
        "proxyGroupId", "proxy-primary" if mode == "proxy" else "")
    schemes = rule.get("schemes", FULL_SCHEMES)
    port_scope = rule.get("portScope", "all")
    explicit_ports = rule.get("explicitPorts", [])
    return """AccessPolicyRule{{
        {rule_id}, TestOwner(), {scope}, {top_level_site}, {host},
        {include_subdomains}, {schemes},
        RulePortSelector{{{port_scope}, {ports}}}, {mode}, {proxy_group},
        {protection_override}, 1u, 1u}}""".format(
        rule_id=string(rule.get("id"), f"{label}.id"),
        scope=enum("scope", scope, f"{label}.scope"),
        top_level_site=string(top_level_site, f"{label}.topLevelSite"),
        host=string(rule.get("host"), f"{label}.host"),
        include_subdomains=boolean(
            rule.get("includeSubdomains", False),
            f"{label}.includeSubdomains",
        ),
        schemes=vector(
            schemes,
            lambda value, item_label: enum("scheme", value, item_label),
            f"{label}.schemes",
        ),
        port_scope=enum("portScope", port_scope, f"{label}.portScope"),
        ports=vector(explicit_ports, uint16, f"{label}.explicitPorts"),
        mode=enum("mode", mode, f"{label}.mode"),
        proxy_group=string(proxy_group, f"{label}.proxyGroupId"),
        protection_override=enum(
            "protectionOverride",
            rule.get("protectionOverride", "none"),
            f"{label}.protectionOverride",
        ),
    )


def expected_defaults(state):
    if state == "absent":
        return {
            "mode": "none", "scope": "none", "ruleId": "",
            "reason": "no_matching_rule",
        }
    if state == "conflict":
        return {
            "mode": "invalid", "scope": "invalid", "ruleId": "",
            "reason": "policy_conflict",
        }
    if state == "invalid":
        return {
            "mode": "invalid", "scope": "invalid", "ruleId": "",
            "reason": "invalid_rule",
        }
    return {"reason": "none"}


def emit_vector(value, index):
    label = f"policyVectors[{index}]"
    value = require_dict(value, label)
    require_keys(value, {"name", "context", "rules", "expected"}, label)
    name = value.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError(f"{label}.name must be non-empty")
    context = require_dict(value.get("context"), f"{name}.context")
    require_keys(context, {"targetUrl", "topFrameUrl", "attribution"},
                 f"{name}.context")
    target_url = string(context.get("targetUrl"), f"{name}.targetUrl")
    top_frame_url = string(
        context.get("topFrameUrl", "https://www.example.test/page"),
        f"{name}.topFrameUrl",
    )
    attribution = enum(
        "attribution", context.get("attribution", "document"),
        f"{name}.attribution")
    rules = value.get("rules")
    if not isinstance(rules, list):
        raise ValueError(f"{name}.rules must be an array")
    emitted_rules = ",\n      ".join(
        emit_rule(rule, name, rule_index)
        for rule_index, rule in enumerate(rules)
    )
    expected = require_dict(value.get("expected"), f"{name}.expected")
    require_keys(expected, {"state", "mode", "scope", "ruleId", "reason"},
                 f"{name}.expected")
    state = expected.get("state")
    merged_expected = {**expected_defaults(state), **expected}
    return f"""vectors.push_back(GoldenPolicyVector{{
    {string(name, f"{name}.name")}, {target_url}, {top_frame_url},
    {attribution},
    {{{emitted_rules}}},
    {enum("state", state, f"{name}.expected.state")},
    {enum("mode", merged_expected.get("mode"), f"{name}.expected.mode")},
    {enum("scope", merged_expected.get("scope"), f"{name}.expected.scope")},
    {string(merged_expected.get("ruleId"), f"{name}.expected.ruleId")},
    {enum("reason", merged_expected.get("reason"), f"{name}.expected.reason")},
}});"""


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: generate_policy_matcher_vectors.py INPUT.json OUTPUT.inc")
    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    parsed = require_dict(json.loads(input_path.read_text()), "vector file")
    require_keys(parsed, {"schemaVersion", "policyVectors"}, "vector file")
    if parsed.get("schemaVersion") != 1:
        raise ValueError("schemaVersion must be 1")
    vectors = parsed.get("policyVectors")
    if not isinstance(vectors, list) or not vectors:
        raise ValueError("policyVectors must be a non-empty array")
    names = [value.get("name") for value in vectors if isinstance(value, dict)]
    if len(names) != len(vectors) or len(set(names)) != len(names):
        raise ValueError("policy vector names must be present and unique")
    content = ["// Generated from the shared policy matcher vectors."]
    content.extend(emit_vector(value, index)
                   for index, value in enumerate(vectors))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(content) + "\n")


if __name__ == "__main__":
    main()
