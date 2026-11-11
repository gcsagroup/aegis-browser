import copy
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location('development_signing', Path(__file__).with_name('development_signing.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class DevelopmentSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.config_path = self.root / 'development-archive.json'
        self.directory = self.root / 'profiles'
        self.directory.mkdir()
        self.certificate = b'approved Development certificate fixture'
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest().upper()
        self.profile_ids = {identifier: f'abcdef0{index + 1}-2345-6789-abcd-{index + 1:012x}'
                            for index, identifier in enumerate(signing.TARGETS)}
        self.config = {'schema': signing.SCHEMA, 'team': 'ABCDEFGHIJ',
                       'certificateSha1': self.fingerprint, 'profiles': self.profile_ids}
        self.profiles = {}
        for identifier, profile_id in self.profile_ids.items():
            raw = ('profile fixture for ' + identifier).encode()
            self.profiles[raw] = {
                'UUID': profile_id, 'TeamIdentifier': ['ABCDEFGHIJ'],
                'ExpirationDate': datetime.datetime.utcnow() + datetime.timedelta(days=10),
                'DeveloperCertificates': [self.certificate], 'ProvisionedDevices': ['existing-device'],
                'Entitlements': {'application-identifier': 'ABCDEFGHIJ.' + identifier,
                                 'com.apple.developer.team-identifier': 'ABCDEFGHIJ',
                                 'get-task-allow': True, 'com.apple.security.application-groups': signing.GROUPS},
            }
            (self.directory / (profile_id + '.mobileprovision')).write_bytes(raw)
        self.save()

    def save(self):
        self.config_path.write_text(json.dumps(self.config))
        self.config_path.chmod(0o600)

    def resolve(self):
        return signing.resolve('ABCDEFGHIJ', lambda raw: copy.deepcopy(self.profiles[raw]),
                               config_path=self.config_path, profile_directories=[self.directory])

    def test_unconfigured_hosts_keep_automatic_development_signing(self):
        self.config_path.unlink()
        args, evidence = self.resolve()
        self.assertIn('CODE_SIGN_STYLE=Automatic', args)
        self.assertEqual(evidence, {'style': 'automatic'})

    def test_explicit_profiles_pin_every_target_and_the_development_certificate(self):
        args, evidence = self.resolve()
        self.assertIn('CODE_SIGN_STYLE=Manual', args)
        self.assertIn('CODE_SIGN_IDENTITY=' + self.fingerprint, args)
        self.assertIn('PROVISIONING_PROFILE_SPECIFIER=$(AEGIS_DEVELOPMENT_PROFILE_$(TARGET_NAME))', args)
        for identifier, (target, _) in signing.TARGETS.items():
            self.assertIn('AEGIS_DEVELOPMENT_PROFILE_' + target + '=' + self.profile_ids[identifier], args)
        self.assertEqual(evidence['certificateSha1'], self.fingerprint)
        self.assertEqual(evidence['configurationSha256'], hashlib.sha256(self.config_path.read_bytes()).hexdigest())
        signing.require_identity(evidence, lambda *_: ('  1) ' + self.fingerprint + ' "Apple Development: fixture"').encode())
        with self.assertRaisesRegex(ValueError, 'private identity'):
            signing.require_identity(evidence, lambda *_: b'0 valid identities found')

    def test_configured_errors_never_fall_back_to_automatic(self):
        original = copy.deepcopy(self.config)
        for change in [dict(team='OTHERTEAM1'), dict(schema='other'), dict(certificateSha1='invalid'),
                       dict(profiles={'com.gcsa.aegis': self.profile_ids['com.gcsa.aegis']}),
                       dict(profiles={**self.profile_ids, 'com.gcsa.aegis': '../outside'})]:
            with self.subTest(change=change):
                self.config = {**original, **change}
                self.save()
                with self.assertRaises(ValueError):
                    self.resolve()
        self.config = original
        self.save()
        self.config_path.write_text(self.config_path.read_text().replace('"schema":', '"schema":"other","schema":'))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.resolve()

    def test_uppercase_profile_ids_and_case_variant_filenames_are_supported(self):
        for profile in self.profiles.values():
            profile['UUID'] = profile['UUID'].upper()
        self.config['profiles'] = {key: value.upper() for key, value in self.profile_ids.items()}
        self.save()
        args, evidence = self.resolve()
        for identifier, (target, _) in signing.TARGETS.items():
            self.assertEqual(evidence['profiles'][identifier]['uuid'], self.profile_ids[identifier].lower())
            self.assertIn('AEGIS_DEVELOPMENT_PROFILE_' + target + '=' + self.profile_ids[identifier].upper(), args)
        self.config['profiles'] = self.profile_ids
        self.save()
        self.resolve()

    def test_mixed_case_profile_filenames_match_the_complete_uuid(self):
        for profile_id in self.profile_ids.values():
            original = self.directory / (profile_id + '.mobileprovision')
            mixed = 'AbCdEf' + profile_id[6:]
            original.rename(self.directory / (mixed + '.MoBiLePrOvIsIoN'))
        _, evidence = self.resolve()
        self.assertEqual(set(evidence['profiles']), set(signing.TARGETS))

    def test_profile_directories_and_ancestors_must_be_physical(self):
        direct = self.root / 'profile-directory-link'
        direct.symlink_to(self.directory, target_is_directory=True)
        ancestor = self.root / 'ancestor-link'
        ancestor.symlink_to(self.root, target_is_directory=True)
        for directory in [direct, ancestor / self.directory.name]:
            with self.subTest(directory=directory), self.assertRaises(OSError):
                signing.resolve('ABCDEFGHIJ', lambda raw: self.profiles[raw], config_path=self.config_path,
                                profile_directories=[directory])

    def test_profile_read_stays_bound_to_the_open_directory_if_its_path_changes(self):
        from unittest.mock import patch
        profile_id = next(iter(self.profile_ids.values()))
        expected = (self.directory / (profile_id + '.mobileprovision')).read_bytes()
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / (profile_id + '.mobileprovision')).write_bytes(b'outside bytes must not be read')
        original_scandir = os.scandir
        def replace_path(descriptor):
            self.directory.rename(self.root / 'original-profiles')
            self.directory.symlink_to(outside, target_is_directory=True)
            return original_scandir(descriptor)
        with patch.object(os, 'scandir', side_effect=replace_path):
            self.assertEqual(signing.installed_profile_contents(profile_id, [self.directory]), expected)

    def test_invalid_configuration_ancestors_do_not_fall_back_to_automatic(self):
        not_directory = self.root / 'regular-file-parent'
        not_directory.write_text('not a directory')
        loop = self.root / 'loop'
        loop.symlink_to('loop', target_is_directory=True)
        for invalid in [not_directory / 'configuration.json', loop / 'configuration.json']:
            with self.subTest(path=invalid), self.assertRaises(OSError):
                signing.resolve('ABCDEFGHIJ', lambda raw: self.profiles[raw], config_path=invalid,
                                profile_directories=[self.directory])

    def test_dangling_configuration_directory_does_not_fall_back_to_automatic(self):
        link = self.root / 'dangling-config-directory'
        link.symlink_to(self.root / 'missing-directory', target_is_directory=True)
        for invalid in [link / 'configuration.json', link / 'nested/configuration.json']:
            with self.subTest(path=invalid), self.assertRaises(OSError):
                signing.resolve('ABCDEFGHIJ', lambda raw: self.profiles[raw], config_path=invalid,
                                profile_directories=[self.directory])

    def test_extension_case_cannot_hide_a_conflicting_installed_profile(self):
        duplicate = self.root / 'other-profile-directory'
        duplicate.mkdir()
        profile_id = next(iter(self.profile_ids.values()))
        (duplicate / (profile_id + '.MobileProvision')).write_bytes(b'conflicting profile')
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            signing.installed_profile_contents(profile_id, [self.directory, duplicate])

    def test_matching_profile_copies_have_a_bounded_total_read_budget(self):
        from unittest.mock import patch
        profile_id = next(iter(self.profile_ids.values()))
        raw = (self.directory / (profile_id + '.mobileprovision')).read_bytes()
        directories = [self.directory]
        for index in range(8):
            directory = self.root / ('replica-' + str(index))
            directory.mkdir()
            (directory / (profile_id + '.mobileprovision')).write_bytes(raw)
            directories.append(directory)
        with patch.object(signing, 'read_regular', wraps=signing.read_regular) as read:
            with self.assertRaisesRegex(ValueError, 'Too many matching'):
                signing.installed_profile_contents(profile_id, directories)
            self.assertEqual(read.call_count, 8)

    def test_first_conflicting_profile_stops_before_reading_later_copies(self):
        from unittest.mock import patch
        profile_id = next(iter(self.profile_ids.values()))
        directories = [self.directory]
        for index in range(3):
            directory = self.root / ('conflict-' + str(index))
            directory.mkdir()
            (directory / (profile_id + '.mobileprovision')).write_bytes(b'conflicting profile')
            directories.append(directory)
        with patch.object(signing, 'read_regular', wraps=signing.read_regular) as read:
            with self.assertRaisesRegex(ValueError, 'Conflicting'):
                signing.installed_profile_contents(profile_id, directories)
            self.assertEqual(read.call_count, 2)

    def test_configuration_file_must_be_owner_only(self):
        self.config_path.chmod(0o644)
        with self.assertRaises(ValueError):
            self.resolve()

    def test_writable_ancestor_cannot_turn_a_configured_host_into_automatic(self):
        ancestor = self.root / 'shared-config-parent'
        ancestor.mkdir(mode=0o700)
        private = ancestor / 'signing'
        private.mkdir(mode=0o700)
        config = private / 'development-archive.json'
        config.write_bytes(self.config_path.read_bytes())
        config.chmod(0o600)
        ancestor.chmod(0o777)
        try:
            for existing in (True, False):
                if not existing:
                    config.unlink()
                with self.subTest(existing=existing), self.assertRaisesRegex(ValueError, 'untrusted directory'):
                    signing.resolve('ABCDEFGHIJ', lambda raw: self.profiles[raw], config_path=config,
                                    profile_directories=[self.directory])
        finally:
            ancestor.chmod(0o700)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native ancestor ACL regression')
    def test_ancestor_acl_allows_readonly_and_deny_entries_but_rejects_mutation_grants(self):
        import pwd
        ancestor = self.root / 'config-parent'
        ancestor.mkdir(mode=0o755)
        private = ancestor / 'signing'
        private.mkdir(mode=0o700)
        config = private / 'development-archive.json'
        config.write_bytes(self.config_path.read_bytes())
        config.chmod(0o600)
        def resolve():
            return signing.resolve('ABCDEFGHIJ', lambda raw: self.profiles[raw], config_path=config,
                                   profile_directories=[self.directory])
        user = pwd.getpwuid(os.getuid()).pw_name
        for rule in ['everyone deny delete', 'everyone allow read,readattr,readextattr,readsecurity,search',
                     f'user:{user} allow add_file,delete_child', 'user:root allow add_file']:
            subprocess.run(['chmod', '+a', rule, str(ancestor)], check=True)
            try:
                self.assertEqual(resolve()[1]['style'], 'manual')
            finally:
                subprocess.run(['chmod', '-N', str(ancestor)], check=True)
        for rule in ['everyone allow delete_child,add_subdirectory', 'group:wheel allow add_file',
                     'user:nobody allow add_file']:
            subprocess.run(['chmod', '+a', rule, str(ancestor)], check=True)
            try:
                with self.assertRaisesRegex(ValueError, 'writable extended ACL'):
                    resolve()
            finally:
                subprocess.run(['chmod', '-N', str(ancestor)], check=True)
        config.unlink()
        subprocess.run(['chmod', '+a', f'user:{user} allow add_file', str(ancestor)], check=True)
        try:
            self.assertEqual(resolve()[1]['style'], 'automatic')
        finally:
            subprocess.run(['chmod', '-N', str(ancestor)], check=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native extended ACL regression')
    def test_extended_acl_grants_are_rejected_even_with_private_modes(self):
        for path in [self.config_path, self.root]:
            with self.subTest(path=path):
                subprocess.run(['chmod', '+a', 'everyone allow write', str(path)], check=True)
                try:
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600 if path == self.config_path else 0o700)
                    with self.assertRaisesRegex(ValueError, 'extended ACL'):
                        self.resolve()
                finally:
                    subprocess.run(['chmod', '-N', str(path)], check=True)
        self.resolve()

    @unittest.skipIf(sys.platform == 'darwin', 'POSIX ACL regression')
    def test_posix_acl_grants_are_rejected(self):
        from unittest.mock import patch
        with patch.object(os, 'listxattr', return_value=['system.posix_acl_access']), \
                self.assertRaisesRegex(ValueError, 'extended ACL'):
            self.resolve()

    def test_profile_trust_failure_is_not_ignored(self):
        def rejected(_raw):
            raise ValueError('Apple CMS trust failed')
        with self.assertRaisesRegex(ValueError, 'Apple CMS trust'):
            signing.resolve('ABCDEFGHIJ', rejected, config_path=self.config_path,
                            profile_directories=[self.directory])

    def test_configuration_parent_and_nonregular_files_are_rejected(self):
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            self.resolve()
        self.root.chmod(0o700)
        self.save()
        saved = self.root / 'saved.json'
        self.config_path.rename(saved)
        self.config_path.symlink_to(saved)
        with self.assertRaises(OSError):
            self.resolve()
        self.config_path.unlink()
        import os
        os.mkfifo(self.config_path)
        self.config_path.chmod(0o600)
        with self.assertRaises(ValueError):
            self.resolve()

    def test_apple_profile_identity_and_development_entitlements_are_required(self):
        raw = next(iter(self.profiles))
        original = copy.deepcopy(self.profiles[raw])
        changes = [dict(UUID=str(uuid.UUID(int=100))), dict(TeamIdentifier=['OTHERTEAM1']),
                   dict(ExpirationDate=datetime.datetime.utcnow() - datetime.timedelta(days=1)),
                   dict(DeveloperCertificates=[b'another certificate']), dict(ProvisionedDevices=[]),
                   dict(ProvisionsAllDevices=True)]
        changes += [dict(Entitlements={**original['Entitlements'], key: value}) for key, value in [
            ('application-identifier', 'ABCDEFGHIJ.other'), ('get-task-allow', False),
            ('com.apple.developer.team-identifier', 'OTHERTEAM1'), ('com.apple.security.application-groups', ['other'])]]
        for change in changes:
            with self.subTest(change=change):
                self.profiles[raw] = {**original, **change}
                with self.assertRaises(ValueError):
                    self.resolve()

    def test_missing_symlinked_and_conflicting_profile_files_are_rejected(self):
        profile_id = next(iter(self.profile_ids.values()))
        path = self.directory / (profile_id + '.mobileprovision')
        raw = path.read_bytes()
        path.unlink()
        with self.assertRaises(ValueError):
            self.resolve()
        elsewhere = self.root / 'elsewhere'
        elsewhere.write_bytes(raw)
        path.symlink_to(elsewhere)
        with self.assertRaises(OSError):
            self.resolve()
        path.unlink()
        path.write_bytes(raw)
        duplicate = self.root / 'other-profile-directory'
        duplicate.mkdir()
        (duplicate / path.name).write_bytes(b'conflicting profile')
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            signing.resolve('ABCDEFGHIJ', lambda data: self.profiles[data], config_path=self.config_path,
                            profile_directories=[self.directory, duplicate])

    def archive_fixture(self):
        archive = self.root / 'Aegis.xcarchive'
        for identifier, (_, relative) in signing.TARGETS.items():
            bundle = archive / 'Products/Applications/Aegis.app' / relative
            bundle.mkdir(parents=True, exist_ok=True)
            source = self.directory / (self.profile_ids[identifier] + '.mobileprovision')
            (bundle / 'embedded.mobileprovision').write_bytes(source.read_bytes())
        return archive

    def native_extract(self, *args):
        self.assertEqual(args[:2], ('codesign', '-d'))
        self.assertTrue(args[2].startswith('--extract-certificates='))
        Path(args[2].split('=', 1)[1] + '0').write_bytes(self.certificate)

    def test_archive_must_embed_the_original_profiles_and_exact_signing_certificate(self):
        _, evidence = self.resolve()
        archive = self.archive_fixture()
        signing.verify_archive(archive, evidence, self.native_extract)
        self.certificate = b'another actual signer'
        with self.assertRaisesRegex(ValueError, 'certificate differs'):
            signing.verify_archive(archive, evidence, self.native_extract)
        (archive / 'Products/Applications/Aegis.app/embedded.mobileprovision').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'configured Development profile'):
            signing.verify_archive(archive, evidence, self.native_extract)

    def test_transfer_cannot_drop_signing_evidence_or_inject_profile_paths(self):
        _, evidence = self.resolve()
        archive = self.archive_fixture()
        for invalid in [None, {}, {'style': 'automatic', 'extra': True},
                        {**evidence, 'certificateSha1': 'untrusted'},
                        {**evidence, 'profiles': {'com.gcsa.aegis': {'uuid': '../bad', 'sha256': 'a' * 64}}}]:
            with self.subTest(evidence=invalid), self.assertRaises(ValueError):
                signing.verify_archive(archive, invalid, self.native_extract)


if __name__ == '__main__':
    unittest.main()
