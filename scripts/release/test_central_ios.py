import copy
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parent))
import central_ios_protocol as p


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


central = load('central', 'central-ios.py')
symbols = load('central_symbols', 'verify-ios-dsyms.py')
signed = load('central_signed', 'verify-signed-ios.py')


def request():
    return {'schema': p.SCHEMA, 'product': 'aegis', 'application': p.APP_ID,
            'source': {'repository': p.SOURCE, 'sha': 'a' * 40, 'tree': 'b' * 40},
            'producer': {'repository': 'owner/private-evidence', 'repository_id': 123,
                         'run_id': 456, 'attempt': 1, 'commit': 'c' * 40,
                         'workflow': '.github/workflows/ios-central-archive.yml'},
            'version': '1.9.0', 'build': '1', 'profile': 'alpha', 'team': 'R3JK7R29AC',
            'archive_sha256': 'd' * 64, 'archive_size': 100, 'destination': 'export-only'}


class ContractTests(unittest.TestCase):
    def test_canonical_request_roundtrip_and_allocation_survives_provider_change(self):
        value = request()
        self.assertEqual(p.validate(p.parse(p.canonical(value))), value)
        self.assertEqual(p.allocation(value), p.allocation(dict(value, profile='beta', producer={})))
        self.assertNotEqual(p.allocation(value), p.allocation(dict(value, build='2')))

    def test_reject_wrong_product_unknown_field_duplicates_and_noncanonical_versions(self):
        for key, replacement in [('product', 'watermark'), ('destination', 'upload'),
                                 ('profile', 'beta'), ('version', '01.9.0'), ('build', '0')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                p.validate(dict(request(), **{key: replacement}))
        with self.assertRaises(ValueError):
            p.validate(dict(request(), command='arbitrary'))
        with self.assertRaises(ValueError):
            p.parse(b'{"product":"aegis","product":"other"}')

    def test_archive_bundle_pins_original_bytes_and_preserves_executable_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'archive'
            source.mkdir()
            binary = source / 'MachO'
            binary.write_bytes(b'fixture-binary')
            binary.chmod(0o755)
            output = root / 'output'
            value = request()
            digest = central.bundle(source, output, value)
            observed = p.parse((output / 'request.json').read_bytes())
            self.assertEqual(observed['archive_sha256'], p.file_digest(output / 'archive.zip'))
            self.assertEqual(p.digest(observed), digest)
            with zipfile.ZipFile(output / 'archive.zip') as zipped:
                self.assertEqual(zipped.read('MachO'), b'fixture-binary')
                self.assertTrue(zipped.getinfo('MachO').external_attr >> 16 & 0o111)
            with self.assertRaises(FileExistsError):
                central.bundle(source, output, value)

    def test_store_keys_rejected_before_any_archive_command(self):
        for name in ['AEGIS_ASC_KEY_BASE64', 'APP_STORE_CONNECT_API_KEY_KEY_ID', 'AEGIS_IOS_DISTRIBUTION_P12_BASE64']:
            with self.assertRaisesRegex(ValueError, 'development signing'):
                central.refuse_store_credentials({name: 'fixture'})
        central.refuse_store_credentials({'DEVELOPMENT_TEAM': 'R3JK7R29AC'})

    def test_archive_link_cannot_import_an_untracked_external_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'archive'
            archive.mkdir()
            (archive / 'link').symlink_to(root / 'outside')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                central.bundle(archive, root / 'output', request())

    def test_additional_signed_capability_or_other_keychain_group_rejected(self):
        identity = {'application-identifier': 'R3JK7R29AC.com.gcsa.aegis',
                    'com.apple.developer.team-identifier': 'R3JK7R29AC', 'get-task-allow': False}
        signed.validate_central_entitlements(identity, {}, 'com.gcsa.aegis', 'R3JK7R29AC')
        for changed in [dict(identity, **{'aps-environment': 'production'}),
                        dict(identity, **{'keychain-access-groups': ['R3JK7R29AC.other-app']})]:
            with self.assertRaises(ValueError):
                signed.validate_central_entitlements(changed, {}, 'com.gcsa.aegis', 'R3JK7R29AC')

    def test_apple_beta_reports_requires_exact_true_and_profile_authorization(self):
        for identifier in p.TARGETS:
            signed.validate_central_entitlements({'beta-reports-active': True}, {}, identifier,
                                                 'R3JK7R29AC', {'beta-reports-active': True})
        for actual, allowed in [(False, True), (1, True), (True, False), (True, None)]:
            with self.assertRaises(ValueError):
                signed.validate_central_entitlements({'beta-reports-active': actual}, {}, 'com.gcsa.aegis',
                                                     'R3JK7R29AC', {'beta-reports-active': allowed})

    def test_actual_keychain_group_must_be_allowed_by_the_verified_profile(self):
        actual = {'keychain-access-groups': ['R3JK7R29AC.com.gcsa.aegis']}
        for permitted in [['R3JK7R29AC.com.gcsa.aegis'], ['R3JK7R29AC.*']]:
            signed.validate_central_entitlements(actual, {}, 'com.gcsa.aegis', 'R3JK7R29AC',
                                                 {'keychain-access-groups': permitted})
        for permitted in [None, [], ['*'], ['R3JK7R29AC.other-app']]:
            with self.assertRaises(ValueError):
                signed.validate_central_entitlements(actual, {}, 'com.gcsa.aegis', 'R3JK7R29AC',
                                                     {'keychain-access-groups': permitted})


class DeliveredSymbolTests(unittest.TestCase):
    def fixture(self, root):
        ipa, dwarf = root / 'package.ipa', root / 'symbols.zip'
        with zipfile.ZipFile(ipa, 'w') as app_zip, zipfile.ZipFile(dwarf, 'w') as sym_zip:
            for relative, identifier in symbols.TARGETS.items():
                app_zip.writestr('Payload/' + relative + '/Info.plist', plistlib.dumps({
                    'CFBundleIdentifier': identifier, 'CFBundleShortVersionString': '1.9.0',
                    'CFBundleVersion': '1', 'CFBundleExecutable': 'Executable'}))
                app_zip.writestr('Payload/' + relative + '/Executable', b'fixture')
                sym_zip.writestr(Path(relative).name + '.dSYM/Contents/Resources/DWARF/Executable', b'symbol')
        return ipa, dwarf

    def test_downloaded_ipa_all_architectures_must_match_original_symbols(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa, dwarf = self.fixture(Path(temporary))
            ids = [('arm64', 'A' * 36), ('arm64e', 'B' * 36)]
            with patch.object(symbols, 'uuids', return_value=ids):
                self.assertEqual(len(symbols.verify_delivered(ipa, dwarf, '1.9.0', '1')['bundles']), 3)
            with patch.object(symbols, 'uuids', side_effect=lambda path: ids[:1] if 'DWARF' in path.parts else ids):
                with self.assertRaisesRegex(ValueError, 'UUID differs'):
                    symbols.verify_delivered(ipa, dwarf, '1.9.0', '1')

    def test_symbol_zip_cannot_escape_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa, dwarf = self.fixture(Path(temporary))
            with zipfile.ZipFile(dwarf, 'a') as zipped:
                zipped.writestr('../escape', b'data')
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                symbols.verify_delivered(ipa, dwarf, '1.9.0', '1')


if __name__ == '__main__':
    unittest.main()
