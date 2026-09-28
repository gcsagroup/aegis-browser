"""SM-00 synthetic admission and no-network regression checks."""

from __future__ import annotations

import copy
import io
import json
import os
import socket
import subprocess
import tempfile
import unittest
import urllib.request
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from sm00_preflight import ManifestError, main, read_manifest, validate_manifest


FIXTURE = Path(__file__).with_name("sm00_synthetic_manifest.json")


class SyntheticPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.temporary = tempfile.TemporaryDirectory(prefix="aegis-sm00-synthetic-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "manifest.json"

    def reject(self, location: str) -> None:
        with self.assertRaisesRegex(ManifestError, location):
            validate_manifest(self.manifest)

    def test_complete_synthetic_manifest_and_check_only_cli(self) -> None:
        validate_manifest(self.manifest)
        output = io.StringIO()
        with (patch.object(socket, "socket", side_effect=AssertionError("network opened")),
              patch.object(subprocess, "Popen", side_effect=AssertionError("process started")),
              patch.object(urllib.request, "urlopen", side_effect=AssertionError("URL opened")),
              redirect_stdout(output)):
            self.assertEqual(main(["--check-only", "--manifest", str(FIXTURE)]), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["classification"], "LOCAL_PREFLIGHT_ONLY")
        self.assertEqual(result["result"], "PASS")
        self.assertEqual(len(result["manifestSha256"]), 64)
        self.assertNotIn("accountId", output.getvalue())

    def test_missing_unknown_and_duplicate_fields_fail_closed(self) -> None:
        del self.manifest["build"]["xrayBinarySha256"]
        self.reject("build")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["execution"]["endpointUrl"] = "https://unexpected.example"
        self.reject("execution")
        self.path.write_text('{"schemaVersion":1,"schemaVersion":2}', encoding="ascii")
        with self.assertRaisesRegex(ManifestError, "duplicate JSON field"):
            read_manifest(self.path)

    def test_identity_scope_and_account_mapping_cannot_be_inferred(self) -> None:
        self.manifest["identity"]["nodeAllowedAccountIds"].pop()
        self.reject("account mapping mismatch")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["identity"]["profiles"][1]["serviceRealm"] = "synthetic-realm-b"
        self.reject("environment or realm mapping mismatch")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["identity"]["profiles"][1]["credentialRef"] = (
            self.manifest["identity"]["profiles"][0]["credentialRef"])
        self.reject("duplicate identifier")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["identity"]["profiles"][2]["accountId"] = "synthetic-account-a"
        self.reject("account mapping mismatch")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["identity"]["profiles"].pop()
        self.manifest["identity"]["profiles"][1]["accountId"] = "synthetic-account-b"
        self.reject("missing shared-account profiles")

    def test_build_digest_and_byte_units_are_explicit(self) -> None:
        self.manifest["build"]["xrayBinarySha256"] = "0" * 64
        self.reject("invalid fixed digest")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["bytes"]["writerResultUnit"] = "encrypted_wire_bytes"
        self.reject("unsupported value")

    def test_every_applicable_writer_and_fast_path_needs_evidence(self) -> None:
        self.manifest["paths"]["applicableWriterIds"].append("synthetic-hidden-writer")
        self.reject("no matching evidence")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["paths"]["writerEvidence"][3]["progressProofSha256"] = "TBD"
        self.reject("unresolved placeholder")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["paths"]["applicableFastPathIds"].pop()
        self.reject("no matching evidence")

    def test_all_budgets_are_finite_integers_with_consistent_caps(self) -> None:
        for value in (None, "unknown", True, 1.5, -1, 10**100):
            with self.subTest(value=value):
                manifest = copy.deepcopy(self.manifest)
                manifest["budgets"]["maxWireBytes"] = value
                with self.assertRaises(ManifestError):
                    validate_manifest(manifest)
        self.manifest["budgets"]["maxChunkBytes"] = 513
        self.reject("chunk, lease, and account")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["budgets"]["maxFaults"] = 0
        self.reject("invalid finite integer")

    def test_durability_time_and_execution_are_bounded(self) -> None:
        self.manifest["durability"]["failureModels"] = [[], "synthetic-kill"]
        self.reject("missing synthetic failure model")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["time"]["writeTimeoutMs"] = 10000
        self.reject("write timeout exceeds usable lease lifetime")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["execution"]["allowNetwork"] = True
        self.reject("unsafe execution mode")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["time"]["samplingIntervalMs"] = 60000
        self.reject("sampling interval exceeds run duration")
        self.manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.manifest["time"]["eventResolutionMs"] = 1001
        self.reject("event resolution exceeds sampling interval")

    def test_read_input_is_bounded_regular_utf8_json(self) -> None:
        self.path.write_bytes(b"x" * (64 * 1024 + 1))
        with self.assertRaisesRegex(ManifestError, "bounded regular file"):
            read_manifest(self.path)
        self.path.write_bytes(b"\xff")
        with self.assertRaisesRegex(ManifestError, "invalid UTF-8 JSON"):
            read_manifest(self.path)
        self.path.write_text('{"n":' + "1" * 5000 + "}", encoding="ascii")
        with self.assertRaisesRegex(ManifestError, "invalid UTF-8 JSON"):
            read_manifest(self.path)
        self.path.unlink()
        os.symlink(FIXTURE, self.path)
        with self.assertRaisesRegex(ManifestError, "local file unavailable"):
            read_manifest(self.path)

    def test_deep_json_and_unknown_nested_keys_reject_without_echo(self) -> None:
        self.path.write_text("[" * 1100 + "0" + "]" * 1100, encoding="ascii")
        error = io.StringIO()
        with redirect_stderr(error):
            self.assertEqual(main(["--check-only", "--manifest", str(self.path)]), 2)
        self.assertIn("LOCAL_PREFLIGHT_REJECTED", error.getvalue())
        self.assertNotIn("RecursionError", error.getvalue())

        nested: object = 0
        for _ in range(40):
            nested = [nested]
        self.manifest["resources"]["nodeId"] = nested
        self.reject("nesting limit exceeded")

        self.manifest["resources"]["nodeId"] = {"synthetic-secret-key-marker": "TBD"}
        self.path.write_text(json.dumps(self.manifest), encoding="utf-8")
        error = io.StringIO()
        with redirect_stderr(error):
            self.assertEqual(main(["--check-only", "--manifest", str(self.path)]), 2)
        self.assertIn("unresolved placeholder", error.getvalue())
        self.assertNotIn("synthetic-secret-key-marker", error.getvalue())

    def test_cli_rejects_real_resource_and_does_not_echo_input(self) -> None:
        self.manifest["resources"]["nodeId"] = "private-node.example"
        self.path.write_text(json.dumps(self.manifest), encoding="utf-8")
        error = io.StringIO()
        with redirect_stderr(error):
            self.assertEqual(main(["--check-only", "--manifest", str(self.path)]), 2)
        self.assertIn("LOCAL_PREFLIGHT_REJECTED", error.getvalue())
        self.assertNotIn("private-node.example", error.getvalue())
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                main(["--manifest", str(FIXTURE)])
        self.assertEqual(result.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
