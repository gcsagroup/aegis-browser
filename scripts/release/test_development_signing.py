import copy
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
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
        self.profile_ids = {identifier: str(uuid.UUID(int=index + 1))
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

    def test_configuration_file_must_be_owner_only(self):
        self.config_path.chmod(0o644)
        with self.assertRaises(ValueError):
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
        with self.assertRaises(ValueError):
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
