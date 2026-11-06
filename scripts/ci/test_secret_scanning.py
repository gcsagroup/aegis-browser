#!/usr/bin/env python3
"""Exercise the real scanner; generated test credentials never leave temp repos."""
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts/ci/scan-secrets.sh"


def executable(name):
    found = shutil.which(name)
    if found is None:
        raise RuntimeError(f"Required test executable is missing: {name}")
    return str(Path(found).resolve(strict=True))


GIT = executable("git")
OPENSSL = executable("openssl")
BASH = executable("bash")


class SecretScanningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aegis-secret-test-")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name) / "repo"
        self.repository.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Secret scanning test")
        self.git("config", "user.email", "secrets@example.invalid")
        (self.repository / "README.md").write_text("Clean test repository.\n")
        self.commit()

    def git(self, *arguments):
        # Arguments are constructed only by this synthetic fixture; no shell.
        return subprocess.run(  # nosec B603 B607
            ["git", "-C", str(self.repository), *arguments], executable=GIT,
            check=True, capture_output=True, text=True,
        )

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Synthetic scanner fixture")

    def scan(self, repository=None):
        return subprocess.run(  # nosec B603 B607
            ["bash", str(SCANNER), str(repository or self.repository)], executable=BASH,
            capture_output=True, text=True, timeout=60,
        )

    def test_clean_history_passes(self):
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Secret scan candidates: 0", result.stdout)

    def test_new_private_key_in_previously_exempted_path_is_blocked_after_deletion(self):
        # This path has historical false positives. An exact fingerprint baseline
        # must not exempt new commits or the entire test directory.
        target = self.repository / (
            "apps/browser/overlay/chrome/browser/aegis/agent/"
            "agent_observation_unittest.cc"
        )
        target.parent.mkdir(parents=True)
        # Fixed operation and locally generated temporary path; no external input.
        subprocess.run(  # nosec B603 B607
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt",
             "rsa_keygen_bits:2048", "-out", str(target)],
            executable=OPENSSL, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        key = target.read_text()
        self.commit()
        target.unlink()
        self.commit()
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('"rule": "private-key"', result.stdout)
        self.assertNotIn(key.splitlines()[1], result.stdout + result.stderr)

    def test_inline_allow_comment_cannot_hide_a_new_credential(self):
        token = "aegis_" + secrets.token_hex(24)
        (self.repository / "example.txt").write_text(
            f'api_key = "{token}" # gitleaks:allow\n'
        )
        self.commit()
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('"rule": "generic-api-key"', result.stdout)
        self.assertNotIn(token, result.stdout + result.stderr)

    def test_shallow_history_fails_closed(self):
        clone = Path(self.temporary.name) / "shallow"
        subprocess.run(  # nosec B603 B607
            ["git", "clone", "--quiet", "--depth", "1",
             self.repository.as_uri(), str(clone)],
            executable=GIT, check=True, capture_output=True, text=True,
        )
        result = self.scan(clone)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires complete Git history", result.stderr)


if __name__ == "__main__":
    if not shutil.which(os.environ.get("GITLEAKS_BIN", "gitleaks")):
        raise SystemExit("Install Gitleaks 8.30.1 or set GITLEAKS_BIN before testing.")
    unittest.main(verbosity=2)
