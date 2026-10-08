"""Offline SM-00 schema preparation for synthetic fixtures only.

This module has no service, socket, subprocess, or deployment integration.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


MAX_MANIFEST_BYTES = 64 * 1024
MAX_INTEGER = 2**53 - 1  # Exact in the JSON consumers planned for this contract.
MAX_SYNTHETIC_BYTES = 1_000_000_000
MAX_SYNTHETIC_SECONDS = 86_400
SYNTHETIC_ID = re.compile(r"synthetic-[a-z0-9][a-z0-9-]{0,62}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
SENTINELS = {"unknown", "null", "none", "tbd", "unbounded", "unlimited", "infinity"}


class ManifestError(ValueError):
    """A synthetic preflight input is incomplete or unsafe to interpret."""


def _reject(location: str, reason: str) -> None:
    raise ManifestError(f"{location}: {reason}")


def _object(value: Any, location: str, fields: set[str]) -> dict[str, Any]:
    if type(value) is not dict:
        _reject(location, "expected object")
    missing = fields - value.keys()
    if missing:
        _reject(location, "missing required field")
    if value.keys() - fields:
        _reject(location, "unexpected field")
    return value


def _list(value: Any, location: str, *, minimum: int = 1, maximum: int = 16) -> list[Any]:
    if type(value) is not list or not minimum <= len(value) <= maximum:
        _reject(location, "invalid bounded list")
    return value


def _literal(value: Any, expected: str, location: str) -> None:
    if type(value) is not str or value != expected:
        _reject(location, "unsupported value")


def _identifier(value: Any, location: str) -> str:
    if type(value) is not str or not SYNTHETIC_ID.fullmatch(value):
        _reject(location, "expected synthetic identifier")
    return value


def _hash(value: Any, location: str, *, commit: bool = False) -> None:
    pattern = COMMIT if commit else SHA256
    if type(value) is not str or not pattern.fullmatch(value) or len(set(value)) == 1:
        _reject(location, "invalid fixed digest")


def _integer(value: Any, location: str, *, minimum: int = 1,
             maximum: int = MAX_INTEGER) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        _reject(location, "invalid finite integer")
    return value


def _unique(values: list[str], location: str) -> None:
    if len(values) != len(set(values)):
        _reject(location, "duplicate identifier")


def _no_sentinels(value: Any, depth: int = 0) -> None:
    if depth > 32:
        _reject("manifest", "nesting limit exceeded")
    if type(value) is str and value.strip().casefold() in SENTINELS:
        _reject("manifest", "unresolved placeholder")
    if type(value) is dict:
        for child in value.values():
            _no_sentinels(child, depth + 1)
    elif type(value) is list:
        for child in value:
            _no_sentinels(child, depth + 1)


def _resources(value: Any) -> dict[str, str]:
    fields = {"nodeId", "centerId", "originId", "deploymentId", "capacityGroupId",
              "trafficPoolId", "failureDomainId", "serviceEnvironment", "serviceRealm",
              "operatorRole", "adapterOwnerRole", "ledgerOwnerRole"}
    resource = _object(value, "resources", fields)
    for field in fields:
        _identifier(resource[field], f"resources.{field}")
    return resource


def _identity(value: Any, resources: dict[str, str]) -> None:
    identity = _object(value, "identity", {"accounts", "profiles", "nodeAllowedAccountIds"})
    accounts = _list(identity["accounts"], "identity.accounts", maximum=8)
    account_ids = []
    for index, item in enumerate(accounts):
        path = f"identity.accounts[{index}]"
        account = _object(item, path, {"accountId", "periodId"})
        account_ids.append(_identifier(account["accountId"], f"{path}.accountId"))
        _identifier(account["periodId"], f"{path}.periodId")
    _unique(account_ids, "identity.accounts")
    allowed = [_identifier(item, "identity.nodeAllowedAccountIds") for item in
               _list(identity["nodeAllowedAccountIds"], "identity.nodeAllowedAccountIds",
                     maximum=8)]
    _unique(allowed, "identity.nodeAllowedAccountIds")
    if set(allowed) != set(account_ids):
        _reject("identity.nodeAllowedAccountIds", "account mapping mismatch")

    profiles = _list(identity["profiles"], "identity.profiles", minimum=2, maximum=16)
    profile_ids, principal_ids, credential_refs = [], [], []
    for index, item in enumerate(profiles):
        path = f"identity.profiles[{index}]"
        profile = _object(item, path, {"profileId", "principalId", "accountId",
                                       "credentialRef", "serviceEnvironment", "serviceRealm"})
        profile_ids.append(_identifier(profile["profileId"], f"{path}.profileId"))
        principal_ids.append(_identifier(profile["principalId"], f"{path}.principalId"))
        credential_refs.append(_identifier(profile["credentialRef"], f"{path}.credentialRef"))
        if profile["accountId"] not in allowed:
            _reject(f"{path}.accountId", "account mapping mismatch")
        if (profile["serviceEnvironment"] != resources["serviceEnvironment"] or
                profile["serviceRealm"] != resources["serviceRealm"]):
            _reject(path, "environment or realm mapping mismatch")
    for names, label in ((profile_ids, "profile"), (principal_ids, "principal"),
                         (credential_refs, "credential")):
        _unique(names, f"identity.profiles.{label}")
    profile_accounts = [profile["accountId"] for profile in profiles]
    if set(profile_accounts) != set(account_ids):
        _reject("identity.profiles", "account mapping mismatch")
    if len(profile_accounts) == len(set(profile_accounts)):
        _reject("identity.profiles", "missing shared-account profiles")


def _build(value: Any) -> None:
    fields = {"sourceCommit", "xrayBinarySha256", "serverConfigSha256", "adapterSha256",
              "originSha256", "clientSha256", "kernelRelease", "architecture", "provenance"}
    build = _object(value, "build", fields)
    _hash(build["sourceCommit"], "build.sourceCommit", commit=True)
    for field in fields - {"sourceCommit", "kernelRelease", "architecture", "provenance"}:
        _hash(build[field], f"build.{field}")
    _identifier(build["kernelRelease"], "build.kernelRelease")
    _identifier(build["provenance"], "build.provenance")
    if build["architecture"] not in ("amd64", "arm64"):
        _reject("build.architecture", "unsupported synthetic architecture")


def _bytes(value: Any) -> None:
    fixed = {
        "accountingVersion": "synthetic-target-bytes-v1",
        "unit": "target_connection_bytes",
        "aggregation": "uplink_plus_downlink",
        "uplinkBoundary": "decapsulated_payload_confirmed_target_write",
        "downlinkBoundary": "target_payload_confirmed_client_forward",
        "writerResultUnit": "target_connection_bytes",
    }
    byte_contract = _object(value, "bytes", set(fixed))
    for field, expected in fixed.items():
        _literal(byte_contract[field], expected, f"bytes.{field}")


def _paths(value: Any, max_buffered_bytes: int) -> None:
    paths = _object(value, "paths", {"coverageDeclaration", "applicableWriterIds",
                                       "applicableFastPathIds", "writerEvidence"})
    _literal(paths["coverageDeclaration"], "synthetic-all-paths-enumerated",
             "paths.coverageDeclaration")
    applicable = [_identifier(item, "paths.applicableWriterIds") for item in
                  _list(paths["applicableWriterIds"], "paths.applicableWriterIds", maximum=16)]
    fast = [_identifier(item, "paths.applicableFastPathIds") for item in
            _list(paths["applicableFastPathIds"], "paths.applicableFastPathIds", maximum=16)]
    _unique(applicable, "paths.applicableWriterIds")
    _unique(fast, "paths.applicableFastPathIds")
    evidence = _list(paths["writerEvidence"], "paths.writerEvidence", maximum=16)
    seen, observed_fast = [], []
    directions: set[tuple[str, str]] = set()
    fields = {"writerId", "direction", "mode", "syntheticSourceRef", "identityProofSha256",
              "permitProofSha256", "progressProofSha256", "cutoffProofSha256",
              "bufferBoundBytes"}
    for index, item in enumerate(evidence):
        path = f"paths.writerEvidence[{index}]"
        writer = _object(item, path, fields)
        seen.append(_identifier(writer["writerId"], f"{path}.writerId"))
        _identifier(writer["syntheticSourceRef"], f"{path}.syntheticSourceRef")
        if writer["direction"] not in ("uplink", "downlink"):
            _reject(f"{path}.direction", "unsupported direction")
        if writer["mode"] not in ("bounded_chunk", "optimized_fast"):
            _reject(f"{path}.mode", "unsupported writer mode")
        directions.add((writer["direction"], writer["mode"]))
        if writer["mode"] == "optimized_fast":
            observed_fast.append(writer["writerId"])
        for field in ("identityProofSha256", "permitProofSha256", "progressProofSha256",
                      "cutoffProofSha256"):
            _hash(writer[field], f"{path}.{field}")
        _integer(writer["bufferBoundBytes"], f"{path}.bufferBoundBytes", minimum=0,
                 maximum=max_buffered_bytes)
    _unique(seen, "paths.writerEvidence")
    if set(seen) != set(applicable) or set(fast) != set(observed_fast):
        _reject("paths", "applicable writer or fast path has no matching evidence")
    for direction in ("uplink", "downlink"):
        for mode in ("bounded_chunk", "optimized_fast"):
            if (direction, mode) not in directions:
                _reject("paths", "missing synthetic direction or fast path evidence")


def _budgets(value: Any) -> dict[str, int]:
    byte_fields = {"quotaBytes", "leaseBytes", "maxChunkBytes", "maxUnsettledBytes",
                   "maxBufferedBytes", "maxQueueBytes", "maxWireBytes", "maxLogBytes",
                   "maxQuotaOvershootBytes", "maxAfterStopBytes", "maxReconcileErrorBytes"}
    count_fields = {"maxInflightAttempts", "maxConcurrentConnections", "maxFaults", "maxRetries"}
    budget = _object(value, "budgets", byte_fields | count_fields | {"maxDurationSeconds"})
    for field in byte_fields:
        _integer(budget[field], f"budgets.{field}",
                 minimum=0 if field.startswith("maxQuotaOvershoot") or field in
                 {"maxAfterStopBytes", "maxReconcileErrorBytes"} else 1,
                 maximum=MAX_SYNTHETIC_BYTES)
    for field in count_fields:
        _integer(budget[field], f"budgets.{field}", maximum=10_000)
    _integer(budget["maxDurationSeconds"], "budgets.maxDurationSeconds",
             maximum=MAX_SYNTHETIC_SECONDS)
    if not (budget["maxChunkBytes"] <= budget["leaseBytes"] <= budget["quotaBytes"]):
        _reject("budgets", "chunk, lease, and account byte limits are inconsistent")
    if not (budget["maxQueueBytes"] <= budget["maxBufferedBytes"] <= budget["quotaBytes"]):
        _reject("budgets", "queue or buffer exceeds account limit")
    if not budget["maxUnsettledBytes"] <= budget["quotaBytes"]:
        _reject("budgets.maxUnsettledBytes", "unsettled limit exceeds account limit")
    if budget["maxInflightAttempts"] > budget["maxConcurrentConnections"] * 2:
        _reject("budgets.maxInflightAttempts", "inflight limit exceeds bounded connections")
    return budget


def _durability(value: Any) -> None:
    fixed = {"nodeCommit": "durable_before_write", "centerCommit": "durable_before_reply",
             "journalRecovery": "reopen_or_stop", "bootKey": "persist_before_request",
             "grantKey": "persist_before_request", "reportAck": "persist_after_validation",
             "exclusiveOwner": "required"}
    durability = _object(value, "durability", set(fixed) | {"failureModels", "maxJournalBytes",
                                                     "maxOutboxEntries"})
    for field, expected in fixed.items():
        _literal(durability[field], expected, f"durability.{field}")
    models = _list(durability["failureModels"], "durability.failureModels", maximum=8)
    if (not all(type(item) is str for item in models) or
            set(models) != {"synthetic-kill", "synthetic-disk-full",
                            "synthetic-journal-corrupt", "synthetic-center-unavailable"} or
            len(models) != 4):
        _reject("durability.failureModels", "missing synthetic failure model")
    _integer(durability["maxJournalBytes"], "durability.maxJournalBytes",
             maximum=MAX_SYNTHETIC_BYTES)
    _integer(durability["maxOutboxEntries"], "durability.maxOutboxEntries", maximum=10_000)


def _time(value: Any, budget: dict[str, int]) -> None:
    fields = {"clockSource", "pauseDetection", "maxSkewMs", "leaseTtlMs",
              "credentialTtlMs", "writeTimeoutMs", "retryDeadlineMs", "stopDeadlineMs",
              "eventResolutionMs", "samplingIntervalMs"}
    timing = _object(value, "time", fields)
    _literal(timing["clockSource"], "synthetic-monotonic-calibrated", "time.clockSource")
    _literal(timing["pauseDetection"], "stop-and-recalibrate", "time.pauseDetection")
    for field in fields - {"clockSource", "pauseDetection"}:
        _integer(timing[field], f"time.{field}", maximum=MAX_SYNTHETIC_SECONDS * 1000)
    if timing["leaseTtlMs"] > timing["credentialTtlMs"]:
        _reject("time", "lease lifetime exceeds credential lifetime")
    if timing["maxSkewMs"] >= timing["leaseTtlMs"]:
        _reject("time.maxSkewMs", "clock uncertainty consumes lease lifetime")
    if timing["writeTimeoutMs"] > timing["leaseTtlMs"] - timing["maxSkewMs"]:
        _reject("time.writeTimeoutMs", "write timeout exceeds usable lease lifetime")
    if timing["retryDeadlineMs"] > budget["maxDurationSeconds"] * 1000:
        _reject("time.retryDeadlineMs", "retry window exceeds run duration")
    if timing["stopDeadlineMs"] > budget["maxDurationSeconds"] * 1000:
        _reject("time.stopDeadlineMs", "stop window exceeds run duration")
    if timing["samplingIntervalMs"] >= budget["maxDurationSeconds"] * 1000:
        _reject("time.samplingIntervalMs", "sampling interval exceeds run duration")
    if timing["eventResolutionMs"] > timing["samplingIntervalMs"]:
        _reject("time.eventResolutionMs", "event resolution exceeds sampling interval")


def _execution(value: Any) -> None:
    fixed = {"checkOnly": True, "allowNetwork": False, "syntheticOnly": True,
             "stopOnObserverFailure": True, "cleanupPolicy": "owned-processes-only"}
    execution = _object(value, "execution", set(fixed))
    for field, expected in fixed.items():
        if type(execution[field]) is not type(expected) or execution[field] != expected:
            _reject(f"execution.{field}", "unsafe execution mode")


def validate_manifest(value: Any) -> None:
    root = _object(value, "manifest", {"schemaVersion", "classification", "resources",
                                       "identity", "build", "bytes", "paths", "budgets",
                                       "durability", "time", "execution"})
    _no_sentinels(root)
    _literal(root["schemaVersion"], "sm00-synthetic-v1", "schemaVersion")
    _literal(root["classification"], "SYNTHETIC_ONLY", "classification")
    resources = _resources(root["resources"])
    _identity(root["identity"], resources)
    _build(root["build"])
    _bytes(root["bytes"])
    budget = _budgets(root["budgets"])
    _paths(root["paths"], budget["maxBufferedBytes"])
    _durability(root["durability"])
    _time(root["time"], budget)
    _execution(root["execution"])


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError("manifest: duplicate JSON field")
        result[key] = value
    return result


def _no_json_constant(_value: str) -> None:
    raise ManifestError("manifest: non-finite JSON number")


def read_manifest(path: Path) -> tuple[Any, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            size = os.fstat(descriptor)
            if not stat.S_ISREG(size.st_mode) or not 0 < size.st_size <= MAX_MANIFEST_BYTES:
                _reject("manifest", "expected bounded regular file")
            with os.fdopen(descriptor, "rb") as source:
                descriptor = -1
                raw = source.read(MAX_MANIFEST_BYTES + 1)
        finally:
            if descriptor >= 0:
                os.close(descriptor)
    except OSError as error:
        raise ManifestError("manifest: local file unavailable") from error
    if not raw or len(raw) > MAX_MANIFEST_BYTES:
        _reject("manifest", "expected bounded regular file")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_duplicate_keys,
                           parse_constant=_no_json_constant)
    except ManifestError:
        raise
    except RecursionError as error:
        raise ManifestError("manifest: excessive JSON nesting") from error
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ManifestError("manifest: invalid UTF-8 JSON") from error
    return value, hashlib.sha256(raw).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Synthetic-only offline SM-00 preflight")
    parser.add_argument("--check-only", action="store_true", required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        manifest, digest = read_manifest(args.manifest)
        validate_manifest(manifest)
    except ManifestError as error:
        print(f"LOCAL_PREFLIGHT_REJECTED: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"classification": "LOCAL_PREFLIGHT_ONLY", "result": "PASS",
                      "manifestSha256": digest}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
