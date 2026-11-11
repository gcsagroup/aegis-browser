import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'apps/ios/scripts/private_test_node.py'
URI = b'vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443?security=reality'


class PrivateNodePackagingTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.source = Path(temp.name) / 'operator input'
        self.source.write_bytes(URI + b'\n')
        self.output = Path(temp.name) / 'Aegis.app/AegisPrivateTestNode.vless'
        self.output.parent.mkdir()

    def stage(self, channel, source=None):
        env = dict(os.environ, AEGIS_ACCESS_RELEASE_CHANNEL=channel,
                   SCRIPT_INPUT_FILE_1=str(source or self.source), SCRIPT_OUTPUT_FILE_0=str(self.output))
        result = subprocess.run([sys.executable, '-B', str(SCRIPT)], env=env, capture_output=True)
        self.assertNotIn(URI, result.stdout + result.stderr)
        return result.returncode

    def test_channel_transitions_in_reused_product(self):
        for channel in ('alpha', 'beta'):
            self.assertEqual(self.stage(channel), 0)
            self.assertEqual(self.output.read_bytes(), URI)
        for channel in ('release', 'stable', 'dev', '', 'unknown'):
            self.output.write_bytes(URI)
            self.assertEqual(self.stage(channel, self.source.with_name('missing')), 0)
            self.assertFalse(self.output.exists())
        self.assertEqual(self.stage('alpha'), 0)
        self.assertEqual(self.stage('alpha', '/dev/null'), 0)
        self.assertFalse(self.output.exists())

    def test_bad_or_missing_private_input_rejects_build_and_clears_output(self):
        for data in (None, URI + b'\n' + URI, b'invalid', b'vless://', b'x' * 8193):
            self.output.write_bytes(URI)
            if data is None:
                self.source.unlink()
            else:
                self.source.write_bytes(data)
            self.assertNotEqual(self.stage('beta'), 0)
            self.assertFalse(self.output.exists())

    def test_private_signing_wrapper_keeps_uri_out_of_xcode_and_cleans_up(self):
        root = self.source.parent
        xcodebuild = root / 'xcodebuild'
        xcodebuild.write_text("""#!/usr/bin/env python3
import os, plistlib, sys
from pathlib import Path
args = sys.argv[1:]
assert 'AEGIS_ACCESS_TEST_NODE_URI' not in os.environ
assert all('vless://' not in arg for arg in args)
assert 'AEGIS_ACCESS_RELEASE_CHANNEL=beta' in args
path = Path(next(arg.split('=', 1)[1] for arg in args if arg.startswith('AEGIS_PRIVATE_TEST_NODE_FILE=')))
assert path.read_bytes() == Path(os.environ['EXPECTED_INPUT']).read_bytes()
assert path.stat().st_mode & 0o077 == 0
derived = Path(args[args.index('-derivedDataPath') + 1])
derived.mkdir()
(derived / 'cached-node').write_bytes(path.read_bytes())
app = Path(args[args.index('-archivePath') + 1]) / 'Products/Applications/Aegis.app'
app.mkdir(parents=True)
(app / 'AegisPrivateTestNode.vless').write_bytes(path.read_bytes().strip())
(app / 'Info.plist').write_bytes(plistlib.dumps({'AegisAccessReleaseChannel': os.environ['STAMP']}))
Path(os.environ['MARKER']).write_text(str(path))
sys.exit(int(os.environ['SIMULATED_EXIT']))
""")
        xcodebuild.chmod(0o700)
        marker = root / 'called'
        wrapper = SCRIPT.parents[3] / 'scripts/release/ios-private-test-node-archive.sh'
        for channel, stamp, upstream_exit, expected in [
                ('release', 'release', 0, 2), ('beta', 'beta', 0, 0),
                ('beta', 'release', 0, 1), ('beta', 'beta', 7, 7)]:
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], RUNNER_TEMP=str(root),
                       EXPECTED_INPUT=str(self.source), MARKER=str(marker), STAMP=stamp, SIMULATED_EXIT=str(upstream_exit),
                       AEGIS_ACCESS_TEST_NODE_URI=URI.decode())
            result = subprocess.run(['bash', str(wrapper), channel], env=env, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertNotIn(URI, result.stdout + result.stderr)
            if channel == 'release':
                self.assertFalse(marker.exists())
            else:
                input_path = Path(marker.read_text())
                self.assertFalse(input_path.exists())
                self.assertFalse((input_path.parent / 'DerivedData').exists())
