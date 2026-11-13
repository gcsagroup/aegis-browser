import fcntl
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


cloud = load('cloud-signing-poc.py', 'session_cloud')
archive = load('cloud-archive.py', 'session_archive')


class NativeSessionTests(unittest.TestCase):
    def invoke(self, name, output, action):
        argv = ['command', '--version', '1.0.2', '--build', '16', '--team', 'ABCDEFGHIJ', '--profile', 'beta']
        if name == 'cloud':
            argv += ['--signing-mode', 'cloud', '--run-id', 'session-test']
            with patch.object(cloud, 'experiment', side_effect=action), patch.object(sys, 'argv', argv):
                cloud.main()
        else:
            argv += ['--output', str(output)]
            with patch.object(archive, 'engine', return_value=cloud), \
                    patch.object(archive, 'create', side_effect=action), patch.object(sys, 'argv', argv):
                archive.main()

    def test_both_cli_entries_stop_before_payload_when_the_host_lock_is_owned(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / 'Library/Caches'
            cache.mkdir(parents=True)
            with (cache / 'aegis-cloud-signing-poc.lock').open('a') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for name in ['cloud', 'archive']:
                    action = Mock()
                    with patch.object(Path, 'home', return_value=root), \
                            patch.object(cloud, 'run', return_value=b''), self.assertRaises(BlockingIOError):
                        self.invoke(name, root / 'output', action)
                    action.assert_not_called()

    def test_both_cli_entries_refuse_an_existing_native_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Library/Caches').mkdir(parents=True)
            for name in ['cloud', 'archive']:
                for process in [b'/usr/bin/xcodebuild', b'/usr/bin/codesign']:
                    action = Mock()
                    with patch.object(Path, 'home', return_value=root), \
                            patch.object(cloud, 'run', return_value=process), self.assertRaises(ValueError):
                        self.invoke(name, root / 'output', action)
                    action.assert_not_called()

    def test_term_and_hup_unwind_keychain_state_and_restore_handlers_in_both_entries(self):
        # Signals target an isolated fixture process, with every native command replaced.
        script = r'''
import json, os, signal, sys
from pathlib import Path
from unittest.mock import patch
from test_native_signing_session import NativeSessionTests, cloud
root, entry, signum = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
(root / 'Library/Caches').mkdir(parents=True)
state = dict(search=['/original/keychain'], default='/original/default', deleted=False)
previous = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
def native(*args, **kwargs):
    if args[0] == 'ps':
        return b''
    if args[1] == 'list-keychains':
        if '-s' in args:
            state['search'] = list(args[args.index('-s') + 1:])
        return b''
    if args[1] == 'default-keychain':
        if '-s' in args:
            state['default'] = args[-1]
        return ('"' + state['default'] + '"').encode()
    if args[1] == 'delete-keychain':
        state['deleted'] = True
    return b''
def payload(*args):
    evidence = {}
    with cloud.isolated_keychain(root, evidence):
        os.kill(os.getpid(), signum)
with patch.object(Path, 'home', return_value=root), patch.object(cloud, 'run', side_effect=native), patch.object(cloud, 'keychains', side_effect=lambda: state['search']):
    try:
        NativeSessionTests().invoke(entry, root / 'output', payload)
    except SystemExit as error:
        state['exit'] = error.code
state['handlersRestored'] = all(signal.getsignal(sig) == handler for sig, handler in previous.items())
print(json.dumps(state))
'''
        for entry in ['cloud', 'archive']:
            for sig in [signal.SIGTERM, signal.SIGHUP]:
                with self.subTest(entry=entry, signal=sig), tempfile.TemporaryDirectory() as temporary:
                    result = subprocess.run([sys.executable, '-c', script, temporary, entry, str(int(sig))],
                                            cwd=Path(__file__).parent, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    state = json.loads(result.stdout)
                    self.assertEqual(state['search'], ['/original/keychain'])
                    self.assertEqual(state['default'], '/original/default')
                    self.assertTrue(state['deleted'])
                    self.assertTrue(state['handlersRestored'])
                    self.assertEqual(state['exit'], 128 + sig)


if __name__ == '__main__':
    unittest.main()
