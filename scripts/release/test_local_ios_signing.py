import importlib.util
import ctypes
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('local_signing', Path(__file__).with_name('local-ios-signing.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class LocalSigningTests(unittest.TestCase):
    def test_symlinked_receipt_stops_main_before_credentials_or_host_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            victim = root / 'private-material'
            victim.write_bytes(b'preserve this material')
            (root / 'signing-receipt.json').symlink_to(victim)
            arguments = ['local-ios-signing.py', '--team', 'ABCDEFGHIJ', '--certificate-sha1', 'A' * 40,
                         '--state-directory', str(root), '--unlock']
            with patch.object(signing.sys, 'argv', arguments), patch.object(signing, 'credentials') as credentials:
                with self.assertRaises(ValueError):
                    signing.main()
                credentials.assert_not_called()
            self.assertEqual(victim.read_bytes(), b'preserve this material')

    def test_receipt_replacement_does_not_truncate_hardlinked_material(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            victim = root / 'private-material'
            victim.write_bytes(b'preserve this material')
            (root / 'signing-receipt.json').hardlink_to(victim)
            signing.write_receipt(root, {'verified': True})
            self.assertEqual(victim.read_bytes(), b'preserve this material')
            self.assertIn('verified', (root / 'signing-receipt.json').read_text())

    def test_credentials_are_parsed_without_executing_shell(self):
        value = signing.parse_credentials('export APP_STORE_CONNECT_API_KEY_KEY_ID="ABCDEFGHIJ"\n'
                                          'export APP_STORE_CONNECT_API_KEY_ISSUER_ID="issuer"\n')
        self.assertEqual(value['AEGIS_ASC_KEY_ID'], 'ABCDEFGHIJ')
        for unsafe in ['$(touch /tmp/unsafe)', '`touch /tmp/unsafe`']:
            with self.assertRaises(ValueError):
                signing.parse_credentials('APP_STORE_CONNECT_API_KEY_KEY_ID="' + unsafe + '"')

    def test_duplicate_credential_assignment_is_rejected(self):
        with self.assertRaises(ValueError):
            signing.parse_credentials('APP_STORE_CONNECT_API_KEY_KEY_ID=a\nAPP_STORE_CONNECT_API_KEY_KEY_ID=b')

    def test_secret_files_require_private_owner_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'password'
            path.write_text('fixture-only')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                signing.private_file(path)
            path.chmod(0o600)
            self.assertEqual(signing.private_file(path), path)

    def test_symlinked_secret_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'password'
            path.write_text('fixture-only')
            path.chmod(0o600)
            link = Path(directory).resolve() / 'link'
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                signing.private_file(link)

    def test_matching_certificate_is_required_before_password_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            (path / 'certificate.cer').write_bytes(b'other certificate')
            (path / 'EXISTING-KEYCHAIN-PASSWORD.txt').write_text('fixture-only')
            with self.assertRaises(ValueError):
                signing.signing_material(path, 'A' * 40)

    def test_login_and_system_keychains_are_never_unlocked(self):
        with patch.object(signing, 'run', return_value=b'"/Users/test/Library/Keychains/login.keychain-db"\n"/Library/Keychains/System.keychain"') as run:
            with self.assertRaises(ValueError):
                signing.signing_keychain('A' * 40)
            self.assertEqual(run.call_count, 1)

    def test_non_login_keychain_selection_is_exact_and_unambiguous(self):
        outputs = [b'"/Users/test/Library/Keychains/signing.keychain-db"', b'SHA-1 hash: ' + b'A' * 40]
        with patch.object(signing, 'run', side_effect=outputs):
            self.assertEqual(signing.signing_keychain('A' * 40).name, 'signing.keychain-db')
        outputs = [b'"/one.keychain-db"\n"/two.keychain-db"', b'SHA-1 hash: ' + b'A' * 40, b'SHA-1 hash: ' + b'A' * 40]
        with patch.object(signing, 'run', side_effect=outputs):
            with self.assertRaises(ValueError):
                signing.signing_keychain('A' * 40)

    def test_native_unlock_keeps_password_out_of_subprocesses_and_wipes_buffer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'password'
            path.write_bytes(b'fixture-password\n')
            path.chmod(0o600)
            security, core = MagicMock(), MagicMock()
            def opened(_path, reference):
                ctypes.cast(reference, ctypes.POINTER(ctypes.c_void_p))[0] = 123
                return 0
            buffers = []
            def unlocked(_reference, size, buffer, _use_password):
                self.assertEqual(bytes(buffer), b'fixture-password')
                self.assertEqual(size, 16)
                buffers.append(buffer)
                return 0
            def status(_reference, output):
                ctypes.cast(output, ctypes.POINTER(ctypes.c_uint32))[0] = 1
                return 0
            security.SecKeychainOpen.side_effect = opened
            security.SecKeychainUnlock.side_effect = unlocked
            security.SecKeychainGetStatus.side_effect = status
            with patch.object(signing.ctypes, 'CDLL', side_effect=[security, core]), patch.object(signing.subprocess, 'run') as subprocess:
                signing.unlock_keychain(Path('/fixture/signing.keychain-db'), path)
                subprocess.assert_not_called()
            self.assertEqual(bytes(buffers[0]), b'\0' * 16)
            core.CFRelease.assert_called_once()

    def native_unlock_fixture(self, initially_unlocked):
        security, core = MagicMock(), MagicMock()
        buffers, statuses = [], [int(initially_unlocked), 1]
        def opened(_path, reference):
            ctypes.cast(reference, ctypes.POINTER(ctypes.c_void_p))[0] = 123
            return 0
        def unlocked(reference, _size, buffer, _use_password):
            self.assertEqual(reference.value, 123)
            buffers.append(buffer)
            return 0
        def status(_reference, output):
            ctypes.cast(output, ctypes.POINTER(ctypes.c_uint32))[0] = statuses.pop(0)
            return 0
        security.SecKeychainOpen.side_effect = opened
        security.SecKeychainUnlock.side_effect = unlocked
        security.SecKeychainGetStatus.side_effect = status
        security.SecKeychainLock.return_value = 0
        return security, core, buffers

    def test_activation_failure_restores_initial_lock_state_on_the_same_reference(self):
        for initially_unlocked in (False, True):
            with self.subTest(initially_unlocked=initially_unlocked), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'password'
                path.write_bytes(b'fixture-password\n')
                path.chmod(0o600)
                descriptor = os.open(path, os.O_RDONLY)
                security, core, buffers = self.native_unlock_fixture(initially_unlocked)
                try:
                    with patch.object(signing.ctypes, 'CDLL', side_effect=[security, core]):
                        with self.assertRaisesRegex(ValueError, 'postcondition rejected'):
                            with signing.activated_keychain_from_fd(Path('/fixture/keychain'), descriptor) as before:
                                self.assertEqual(before, initially_unlocked)
                                self.assertEqual(bytes(buffers[0]), b'\0' * 16)
                                raise ValueError('postcondition rejected')
                    self.assertEqual(security.SecKeychainLock.call_count, int(not initially_unlocked))
                    if not initially_unlocked:
                        self.assertEqual(security.SecKeychainLock.call_args.args[0].value, 123)
                    core.CFRelease.assert_called_once()
                finally:
                    os.close(descriptor)

    def test_password_fd_remains_bound_when_the_path_is_rotated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'password'
            path.write_bytes(b'fixture-password\n')
            path.chmod(0o600)
            descriptor = os.open(path, os.O_RDONLY)
            path.rename(path.with_name('previous'))
            path.write_bytes(b'replacement must not be read')
            security, core, _buffers = self.native_unlock_fixture(False)
            try:
                def unlocked(_reference, _size, buffer, _use_password):
                    self.assertEqual(bytes(buffer), b'fixture-password')
                    return 0
                security.SecKeychainUnlock.side_effect = unlocked
                with patch.object(signing.ctypes, 'CDLL', side_effect=[security, core]), \
                        patch.object(Path, 'read_bytes', side_effect=AssertionError('Password path reopened')):
                    with signing.activated_keychain_from_fd(Path('/fixture/keychain'), descriptor):
                        pass
                security.SecKeychainLock.assert_not_called()
            finally:
                os.close(descriptor)

    def test_password_is_wiped_on_format_and_native_library_initialization_errors(self):
        for value in (b'first\nsecond', b'fixture-password'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'password'
                path.write_bytes(value)
                path.chmod(0o600)
                descriptor = os.open(path, os.O_RDONLY)
                buffers = []
                original = os.readv
                def readv(fd, target):
                    buffers.append(target[0])
                    return original(fd, target)
                try:
                    with patch.object(signing.os, 'readv', side_effect=readv), \
                            patch.object(signing.ctypes, 'CDLL', side_effect=OSError('native unavailable')):
                        with self.assertRaises((ValueError, OSError)):
                            with signing.activated_keychain_from_fd(Path('/fixture/keychain'), descriptor):
                                self.fail('Invalid activation completed')
                    self.assertTrue(buffers)
                    self.assertFalse(any(buffers[0]))
                finally:
                    os.close(descriptor)

    def test_password_storage_is_fixed_until_the_complete_buffer_is_wiped(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'password'
            path.write_bytes(b'fixture-password\r\n')
            path.chmod(0o600)
            descriptor = os.open(path, os.O_RDONLY)
            security, core, _buffers = self.native_unlock_fixture(False)
            recorded = []
            original = os.readv
            def readv(fd, targets):
                buffer = targets[0]
                recorded.append((buffer, ctypes.addressof(ctypes.c_ubyte.from_buffer(buffer)), len(buffer)))
                return original(fd, targets)
            def unlocked(_reference, size, buffer, _use_password):
                self.assertEqual(size, 16)
                self.assertEqual(bytes(buffer), b'fixture-password')
                self.assertEqual(ctypes.addressof(buffer), recorded[0][1])
                self.assertEqual(len(recorded[0][0]), recorded[0][2])
                return 0
            security.SecKeychainUnlock.side_effect = unlocked
            try:
                with patch.object(signing.os, 'readv', side_effect=readv), patch.object(signing.ctypes, 'CDLL', side_effect=[security, core]):
                    with signing.activated_keychain_from_fd(Path('/fixture/keychain'), descriptor):
                        self.assertFalse(any(recorded[0][0]))
                buffer, address, size = recorded[0]
                self.assertEqual(len(buffer), size)
                self.assertEqual(ctypes.addressof(ctypes.c_ubyte.from_buffer(buffer)), address)
                self.assertFalse(any(buffer))
            finally:
                os.close(descriptor)

    def test_manual_unlock_accepts_1024_password_bytes_with_lf_or_crlf(self):
        for ending in (b'\n', b'\r\n'):
            with self.subTest(ending=ending), tempfile.TemporaryDirectory() as directory:
                path = Path(directory).resolve() / 'password'
                path.write_bytes(b'x' * 1024 + ending)
                path.chmod(0o600)
                security, core, buffers = self.native_unlock_fixture(False)
                with patch.object(signing.ctypes, 'CDLL', side_effect=[security, core]):
                    signing.unlock_keychain(Path('/fixture/keychain'), path)
                self.assertEqual(security.SecKeychainUnlock.call_args.args[1], 1024)
                self.assertFalse(any(buffers[0]))

    def test_multiline_password_is_rejected_without_native_or_ui_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'password'
            path.write_bytes(b'first\nsecond\n')
            path.chmod(0o600)
            with patch.object(signing.ctypes, 'CDLL') as native:
                with self.assertRaises(ValueError):
                    signing.unlock_keychain(Path('/fixture/signing.keychain-db'), path)
                native.assert_not_called()


if __name__ == '__main__':
    unittest.main()
