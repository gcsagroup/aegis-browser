"""Native commands are mocked; these tests do not prove a real signing identity."""
import importlib.util
import json
import os
from contextlib import contextmanager
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


access = load('development_access_tests', 'development_key_access.py')
selection = load('development_access_selection_tests', 'development_signing.py')


class DevelopmentKeyAccessTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.configuration = self.root / 'configuration'
        self.configuration.mkdir(mode=0o700)
        self.password = self.configuration / 'development-keychain.password'
        self.password.write_text('owned-development-test-password\n')
        self.password.chmod(0o600)
        self.keychain = self.root / 'Development.keychain-db'
        self.keychain.write_bytes(b'encrypted native database fixture')
        self.keychain.chmod(0o644)
        self.output = self.root / 'output'
        self.output.mkdir(mode=0o700)
        self.evidence = dict(style='manual', certificateSha1='A' * 40,
                            configurationSha256='b' * 64, profiles={identifier: {
                                'uuid': f'abcdef01-2345-6789-abcd-{index:012x}', 'sha256': 'c' * 64}
                                for index, identifier in enumerate(selection.TARGETS)})
        self.visible = [str(self.keychain)]
        self.commands = []
        self.signed = False
        self.sign_failure = False
        self.unlock = Mock()
        self.rollback = Mock()
        self.initially_unlocked = False
        @contextmanager
        def activated(path, descriptor):
            self.password_inode = os.fstat(descriptor).st_ino
            self.unlock(path, descriptor)
            try:
                yield self.initially_unlocked
            except BaseException:
                if not self.initially_unlocked:
                    self.rollback(path)
                raise
        def run(*arguments, **options):
            self.commands.append((arguments, options))
            tool = Path(arguments[0]).name
            if tool == 'security':
                return ('SHA-1 hash: ' + 'A' * 40 + '\n').encode()
            if tool == 'xcrun':
                Path(arguments[arguments.index('-o') + 1]).write_bytes(b'native probe fixture')
            if tool == 'codesign' and '--sign' in arguments:
                if self.sign_failure:
                    raise ValueError('errSecInternalComponent fixture')
                self.signed = True
            if tool == 'codesign' and '--verify' in arguments and not self.signed:
                raise ValueError('Probe is not signed')
            return b''
        def module(_name, filename):
            if filename == 'development_signing.py':
                return selection
            if filename == 'local-ios-signing.py':
                return SimpleNamespace(activated_keychain_from_fd=activated)
            raise AssertionError('Unexpected native module')
        self.native = SimpleNamespace(run=run, keychains=lambda: self.visible,
                                      keychain_has_distribution=Mock(return_value=False), module=module,
                                      unretainable_keychain=lambda p: p.name.casefold() in {
                                          'login.keychain', 'login.keychain-db', 'system.keychain'})

    def prepare(self):
        return access.prepare(self.evidence, self.native, self.output,
                              configuration_directory=self.configuration)

    def test_owned_password_unlocks_only_the_unique_nonlogin_pinned_keychain(self):
        self.visible.insert(0, str(self.root / 'login.keychain-db'))
        self.visible.insert(0, str(self.root / 'Login.keychain-db'))
        self.assertEqual(self.prepare(), self.keychain)
        self.unlock.assert_called_once()
        self.assertEqual(self.unlock.call_args.args[0], self.keychain)
        self.assertEqual(self.password_inode, self.password.stat().st_ino)
        self.assertEqual(len(self.commands), 1)
        self.assertNotIn('login.keychain-db', self.commands[0][0])
        receipt = json.loads((self.output / 'development-keychain-activation.json').read_bytes())
        self.assertEqual(receipt['status'], 'unlocked_in_runner')
        self.assertNotIn('owned-development-test-password', json.dumps(receipt))

    def test_missing_optional_password_keeps_the_preunlocked_contract(self):
        self.password.unlink()
        self.assertIsNone(self.prepare())
        self.unlock.assert_not_called()
        self.assertEqual(self.commands, [])

    def test_automatic_selection_never_inspects_development_password_material(self):
        self.evidence = {'style': 'automatic'}
        self.password.chmod(0o644)
        self.assertIsNone(self.prepare())
        self.unlock.assert_not_called()
        self.assertEqual(self.commands, [])

    def test_exposed_password_is_rejected_before_identity_queries_or_unlock(self):
        self.password.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'owned Development password'):
            self.prepare()
        self.assertEqual(self.commands, [])
        self.unlock.assert_not_called()

    def test_password_symlink_is_rejected_before_identity_queries_or_unlock(self):
        original = self.configuration / 'original.password'
        self.password.rename(original)
        self.password.symlink_to(original)
        with self.assertRaises(OSError):
            self.prepare()
        self.assertEqual(self.commands, [])
        self.unlock.assert_not_called()

    def test_password_hardlink_is_rejected_before_identity_queries_or_unlock(self):
        os.link(self.password, self.configuration / 'alias.password')
        with self.assertRaisesRegex(ValueError, 'owned Development password'):
            self.prepare()
        self.assertEqual(self.commands, [])
        self.unlock.assert_not_called()

    def test_ambiguous_matching_keychains_never_try_a_password(self):
        second = self.root / 'Second.keychain-db'
        second.write_bytes(b'encrypted fixture')
        second.chmod(0o644)
        self.visible.append(str(second))
        with self.assertRaisesRegex(ValueError, 'Unique owned dedicated'):
            self.prepare()
        self.unlock.assert_not_called()

    def test_mixed_distribution_keychain_is_not_unlocked(self):
        self.native.keychain_has_distribution.return_value = True
        with self.assertRaisesRegex(ValueError, 'Distribution'):
            self.prepare()
        self.unlock.assert_not_called()

    def test_distribution_identity_revealed_after_unlock_still_stops_before_build(self):
        self.native.keychain_has_distribution.side_effect = [False, True]
        with self.assertRaisesRegex(ValueError, 'Unlocked Development keychain contains a Distribution'):
            self.prepare()
        self.unlock.assert_called_once()
        self.rollback.assert_called_once_with(self.keychain)
        self.assertFalse(any(Path(args[0]).name == 'xcrun' for args, _ in self.commands))

    def test_rejected_activation_preserves_a_previously_unlocked_keychain(self):
        self.initially_unlocked = True
        self.native.keychain_has_distribution.side_effect = [False, True]
        with self.assertRaisesRegex(ValueError, 'Unlocked Development keychain contains a Distribution'):
            self.prepare()
        self.rollback.assert_not_called()

    def test_receipt_publication_failure_rolls_back_while_native_reference_is_alive(self):
        from unittest.mock import patch
        with patch.object(access, 'write_result', side_effect=OSError('publication failed')):
            with self.assertRaisesRegex(OSError, 'publication failed'):
                self.prepare()
        self.rollback.assert_called_once_with(self.keychain)

    def test_keychain_database_hardlink_is_rejected_before_unlock(self):
        os.link(self.keychain, self.root / 'alias.keychain-db')
        with self.assertRaisesRegex(ValueError, 'owned physical database'):
            self.prepare()
        self.unlock.assert_not_called()

    def test_probe_signs_and_verifies_without_inheriting_asc_or_github_credentials(self):
        keychain = self.prepare()
        environment = dict(PATH='/usr/bin', HOME=str(self.root), TMPDIR=str(self.root),
                           DEVELOPER_DIR='/fixed/Xcode', SDKROOT='/product/iphoneos-sdk', AEGIS_ASC_KEY_BASE64='asc-secret',
                           GH_TOKEN='github-secret', GITHUB_TOKEN='github-secret', SOME_P12='p12-secret')
        access.verify(self.evidence, self.native, self.output, environment, keychain)
        commands = [(args, options) for args, options in self.commands if Path(args[0]).name != 'security']
        self.assertEqual([Path(args[0]).name for args, _ in commands], ['xcrun', 'codesign', 'codesign'])
        self.assertIn('--keychain', commands[1][0])
        for args, options in commands:
            self.assertEqual(set(options['env']), {'PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR'})
            self.assertNotIn('owned-development-test-password', repr(args))
        receipt = json.loads((self.output / 'development-key-access.json').read_bytes())
        self.assertEqual(receipt['status'], 'verified_in_runner')
        self.assertEqual(receipt['certificateSha1'], self.evidence['certificateSha1'])
        self.assertEqual(list(self.output.glob('development-key-probe-*')), [])

    def test_signing_failure_stops_before_verification_and_retains_public_diagnostics(self):
        self.sign_failure = True
        with self.assertRaisesRegex(ValueError, 'private-key probe failed in this runner session'):
            access.verify(self.evidence, self.native, self.output, {}, self.keychain)
        self.assertFalse(any('--verify' in args for args, _ in self.commands))
        receipt = json.loads((self.output / 'development-key-access.json').read_bytes())
        self.assertEqual((receipt['status'], receipt['stage']), ('failed', 'sign_probe'))
        self.assertNotIn('owned-development-test-password', json.dumps(receipt))

    def test_probe_rejects_an_activated_keychain_missing_from_the_isolated_search_list(self):
        self.visible.clear()
        with self.assertRaisesRegex(ValueError, 'private-key probe failed'):
            access.verify(self.evidence, self.native, self.output, {}, self.keychain)
        self.assertEqual(self.commands, [])


if __name__ == '__main__':
    unittest.main()
