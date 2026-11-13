"""Cloud PoC boundaries and identity checks; actual cloud signing needs Apple access."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


poc = load('cloud_poc', 'cloud-signing-poc.py')
verifier = load('cloud_verifier', 'verify-signed-ios.py')


class CloudSigningTests(unittest.TestCase):
    def test_distribution_checks_include_expired_matching_identities(self):
        def lookup(*args, **_options):
            return (b'0 valid identities' if '-v' in args else
                    b'1) ABC "Apple Distribution: expired fixture" (CSSMERR_TP_CERT_EXPIRED)\n0 valid identities')
        with patch.object(poc, 'run', side_effect=lookup):
            self.assertTrue(poc.keychain_has_distribution('/owned/development.keychain-db'))
            with self.assertRaisesRegex(ValueError, 'Distribution private identity'):
                poc.no_distribution_identity()

    def test_key_access_adapter_scrubs_secrets_for_inventory_and_native_commands(self):
        environment = {'PATH': '/usr/bin', 'HOME': '/owned', 'DEVELOPER_DIR': '/fixed/Xcode',
                       'AEGIS_ASC_KEY_BASE64': 'asc-secret', 'GH_TOKEN': 'gh-secret',
                       'GITHUB_TOKEN': 'gh-secret', 'SDKROOT': '/product/iphoneos'}
        with patch.object(poc, 'run', return_value=b'') as run:
            runtime = poc.key_access_runtime(environment)
            runtime.keychains()
            runtime.keychain_has_distribution('/owned/development.keychain-db')
            runtime.run('/usr/bin/security', 'find-certificate', env={'GH_TOKEN': 'injected'})
        for call in run.call_args_list:
            self.assertEqual(call.kwargs['env'], {'PATH': '/usr/bin', 'HOME': '/owned', 'DEVELOPER_DIR': '/fixed/Xcode'})
        self.assertNotIn('-v', run.call_args_list[1].args)

    def test_protected_keychain_filter_rejects_case_variants_and_database_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            protected = root / 'Library/Keychains/login.keychain-db'
            protected.parent.mkdir(parents=True)
            protected.write_bytes(b'encrypted fixture')
            alias = root / 'renamed.keychain-db'
            os.link(protected, alias)
            with patch.object(Path, 'home', return_value=root):
                self.assertTrue(poc.unretainable_keychain(alias))
                self.assertTrue(poc.unretainable_keychain(root / 'Login.keychain-db'))
                alias.unlink()
                alias.symlink_to(protected)
                self.assertTrue(poc.unretainable_keychain(alias))

    def test_prepared_inline_selection_is_reused_without_unlocking_or_resolving_twice(self):
        options = SimpleNamespace(team='ABCDEFGHIJ', version='1.0.2', build='16', profile='beta')
        signing = SimpleNamespace(resolve=Mock(), require_identity=Mock(), verify_archive=Mock())
        access = SimpleNamespace(prepare=Mock(), verify=Mock())
        proof = {'style': 'manual'}
        prepared = (signing, ['CODE_SIGN_STYLE=Manual'], proof, access, Path('/owned/development.keychain-db'))
        with patch.object(poc, 'module', side_effect=AssertionError('Prepared selection must not be resolved again')), \
                patch.object(poc, 'run'):
            poc.build_inline_archive(Path('/work'), Path('/output'), options, 'development', {}, {},
                                     SimpleNamespace(verify_development=Mock()), prepared)
        signing.resolve.assert_not_called()
        access.prepare.assert_not_called()
        access.verify.assert_called_once()

    def test_inline_development_archive_uses_the_explicit_selection_without_overwriting_it(self):
        options = SimpleNamespace(team='ABCDEFGHIJ', version='1.0.2', build='16', profile='beta')
        proof = {'style': 'manual', 'certificateSha1': 'A' * 40}
        arguments = ['CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=' + 'A' * 40,
                     'PROVISIONING_PROFILE_SPECIFIER=explicit-profile']
        signing = SimpleNamespace(resolve=Mock(return_value=(arguments, proof)), require_identity=Mock(), verify_archive=Mock())
        trust = SimpleNamespace(verified_profile=Mock())
        transfer = SimpleNamespace(verify_development=Mock())
        access = SimpleNamespace(prepare=Mock(return_value=None), verify=Mock())
        evidence = {}
        def modules(_name, filename):
            if filename == 'development_key_access.py':
                return access
            return signing if filename == 'development_signing.py' else trust
        with patch.object(poc, 'module', side_effect=modules), patch.object(poc, 'run') as run:
            poc.build_inline_archive(Path('/work'), Path('/output'), options, 'development', {}, evidence, transfer)
        command = run.call_args.args
        self.assertTrue(all(value in command for value in arguments))
        self.assertNotIn('CODE_SIGN_STYLE=Automatic', command)
        self.assertNotIn('PROVISIONING_PROFILE_SPECIFIER=', command)
        signing.require_identity.assert_called_once()
        signing.verify_archive.assert_called_once()
        access.prepare.assert_called_once()
        access.verify.assert_called_once()
        transfer.verify_development.assert_called_once()
        self.assertEqual(evidence['developmentSigning'], proof)
        self.assertIs(evidence['archiveCompleted'], True)

    def test_invalid_explicit_selection_stops_inline_archive_before_native_work(self):
        options = SimpleNamespace(team='ABCDEFGHIJ', version='1.0.2', build='16', profile='beta')
        signing = SimpleNamespace(resolve=Mock(side_effect=ValueError('Invalid explicit selection')))
        trust = SimpleNamespace(verified_profile=Mock())
        with patch.object(poc, 'module', side_effect=lambda _n, f: signing if f == 'development_signing.py' else trust), \
                patch.object(poc, 'run') as run, self.assertRaisesRegex(ValueError, 'Invalid explicit'):
            poc.build_inline_archive(Path('/work'), Path('/output'), options, 'development', {}, {}, Mock())
        run.assert_not_called()

    def test_explicit_ad_hoc_experiment_does_not_load_development_configuration(self):
        options = SimpleNamespace(team='ABCDEFGHIJ', version='1.0.2', build='16', profile='beta')
        evidence = {}
        with patch.object(poc, 'module', side_effect=AssertionError('Unexpected Development configuration')), \
                patch.object(poc, 'run') as run, patch.object(poc, 'verify_ad_hoc_archive') as verify:
            poc.build_inline_archive(Path('/work'), Path('/output'), options, 'ad-hoc', {}, evidence, Mock())
        self.assertIn('CODE_SIGN_IDENTITY=-', run.call_args.args)
        verify.assert_called_once()
        self.assertIs(evidence['adHocArchiveSignaturesVerified'], True)

    def test_transfer_requires_independent_digest_and_cannot_be_combined_with_reuse(self):
        for values in [dict(archive_input=Path('/fixture'), archive_manifest_sha256=None),
                       dict(archive_input=None, archive_manifest_sha256='a' * 64),
                       dict(archive_input=Path('/fixture'), archive_manifest_sha256='bad'),
                       dict(archive_input=Path('/fixture'), archive_manifest_sha256='a' * 64, archive_from='prior')]:
            options = SimpleNamespace(**dict(dict(version='1.0.2', build='16', team='ABCDEFGHIJ', archive_from=None), **values))
            with self.subTest(values=values), patch.object(poc, 'source', side_effect=AssertionError('Native work started')), \
                    self.assertRaisesRegex(ValueError, 'producer manifest digest'):
                poc.experiment(options, {})

    def test_hosted_proof_requires_a_fresh_github_runner_and_refuses_archive_reuse(self):
        good = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'macOS'}
        self_hosted = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'RUNNER_OS': 'macOS'}
        poc.validate_runtime('github-hosted', good, None)
        poc.validate_runtime('self-hosted', self_hosted, None)
        for environment, archive in [({}, None), (self_hosted, None), (good, 'prior')]:
            with self.assertRaises(ValueError):
                poc.validate_runtime('github-hosted', environment, archive)
        for environment, archive in [({}, None), (good, None), (self_hosted, 'prior')]:
            with self.assertRaises(ValueError):
                poc.validate_runtime('self-hosted', environment, archive)
        with self.assertRaises(ValueError):
            poc.validate_runtime('local-fallback', good, None)

    def test_alpha_cloud_export_retains_internal_only_audience(self):
        self.assertIs(poc.export_options('ABCDEFGHIJ', 'alpha')['testFlightInternalTestingOnly'], True)
        self.assertIs(poc.export_options('ABCDEFGHIJ', 'release')['testFlightInternalTestingOnly'], False)

    def test_reused_archive_rejects_modified_files_and_native_source_changes(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(poc, 'ROOT', Path(directory).resolve()):
            previous = Path(directory).resolve() / '.artifacts/cloud-signing-poc/first'
            archive = previous / 'work/Aegis.xcarchive'
            app = archive / 'Products/Applications/Aegis.app/Info.plist'
            app.parent.mkdir(parents=True)
            app.write_bytes(b'app fixture')
            (archive / 'Info.plist').write_bytes(b'archive fixture')
            identity = {'sha': 'a' * 40, 'tree': 'b' * 40}
            poc.snapshot_archive(previous, identity)
            receipt = {'source': identity, 'version': '1.0.1', 'build': '16', 'team': 'ABCDEFGHIJ',
                       'archiveCompleted': True, 'distributionP12Imported': False,
                       'distributionIdentityAbsentBeforeArchive': True}
            poc.write(previous / 'poc-receipt.json', receipt)
            with patch.object(poc, 'run', return_value=b''):
                self.assertEqual(poc.reusable_archive('first', '1.0.1', '16', 'ABCDEFGHIJ')[1], identity)
            with patch.object(poc, 'run', return_value=b'native source differs'), self.assertRaisesRegex(ValueError, 'Native inputs'):
                poc.reusable_archive('first', '1.0.1', '16', 'ABCDEFGHIJ')
            app.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'proof or identity'):
                poc.reusable_archive('first', '1.0.1', '16', 'ABCDEFGHIJ')

    def test_receipt_is_private_and_cannot_overwrite_previous_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'
            poc.write(path, {'status': 'failed'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertIn('failed', path.read_text())
            with self.assertRaises(FileExistsError):
                poc.write(path, {'status': 'success'})

    def test_export_is_artifact_only_and_disables_version_mutation(self):
        value = poc.export_options('ABCDEFGHIJ')
        self.assertEqual(value['destination'], 'export')
        self.assertEqual(value['signingStyle'], 'automatic')
        self.assertIs(value['manageAppVersionAndBuildNumber'], False)
        self.assertNotIn('provisioningProfiles', value)

    def test_poc_does_not_accept_an_upload_destination_or_implicit_mode(self):
        with patch('sys.argv', ['poc', '--destination', 'app-store']), self.assertRaises(SystemExit):
            poc.main()

    def test_rejects_shell_metacharacters_in_native_identity(self):
        for values in [('1.0.1;echo', '16', 'ABCDEFGHIJ'), ('1.0.1', '0', 'ABCDEFGHIJ'),
                       ('1.0.1', '16', 'wrong')]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                poc.validate_identity(*values)

    def test_keychain_state_restored_on_archive_or_export_failure(self):
        for failure in ('archive', 'export', None):
            calls = []
            evidence = {}
            original = ['/original/keychain-db']
            with tempfile.TemporaryDirectory() as directory:
                def security(*args, **_kwargs):
                    calls.append(args)
                    if args[1] == 'default-keychain' and '-s' not in args:
                        return b'"/original/default-db"\n'
                    return b''
                with patch.object(poc, 'run', side_effect=security), patch.object(poc, 'keychains', return_value=original):
                    try:
                        with poc.isolated_keychain(Path(directory), evidence):
                            if failure:
                                raise RuntimeError(failure)
                    except RuntimeError:
                        pass
                self.assertTrue(evidence['keychainRestored'])
                self.assertFalse(evidence['distributionP12Imported'])
                self.assertEqual(evidence['retainedDevelopmentKeychains'], [])
                self.assertIn(('security', 'list-keychains', '-d', 'user', '-s', *original), calls)
                self.assertIn(('security', 'default-keychain', '-d', 'user', '-s', '/original/default-db'), calls)
                self.assertFalse(any(c[1] == 'import' for c in calls))

    def test_development_archive_skips_login_and_keeps_unlocked_dev_keychains(self):
        calls = []
        evidence = {}
        original = [
            '/shared/distribution.keychain-db',
            '/Users/me/login.keychain-db',
            '/Users/me/Library/Keychains/dev-ci.keychain-db',
        ]
        with tempfile.TemporaryDirectory() as directory:
            def security(*args, **_kwargs):
                calls.append(args)
                if args[1] == 'default-keychain' and '-s' not in args:
                    return b'"/Users/me/login.keychain-db"\n'
                if args[1] == 'find-identity' and args[-1].endswith('distribution.keychain-db'):
                    return b'1) ABC "Apple Distribution: Team"\n'
                if args[1] == 'find-identity' and args[-1].endswith('login.keychain-db'):
                    return b'1) DEF "Apple Development: Dev"\n'
                if args[1] == 'find-identity' and args[-1].endswith('dev-ci.keychain-db'):
                    return b'1) GHI "Apple Development: CI"\n'
                if args[1] == 'find-identity':
                    return b'1) GHI "Apple Development: CI"\n'
                return b''
            with patch.object(poc, 'run', side_effect=security), patch.object(poc, 'keychains', return_value=original):
                with poc.isolated_keychain(Path(directory), evidence, retain_development=True):
                    pass
            temp = str(Path(directory) / 'cloud-poc.keychain-db')
            self.assertEqual(evidence['retainedDevelopmentKeychains'],
                             ['/Users/me/Library/Keychains/dev-ci.keychain-db'])
            self.assertIn(('security', 'list-keychains', '-d', 'user', '-s', temp,
                           '/Users/me/Library/Keychains/dev-ci.keychain-db'), calls)
            self.assertTrue(evidence['distributionIdentityAbsentBeforeArchive'])

    def test_rejects_local_distribution_identity(self):
        for kind in ('Apple Distribution', 'iPhone Distribution', 'Developer ID Application'):
            with patch.object(poc, 'run', return_value=f'1) ABC "{kind}: Team"'.encode()), self.assertRaises(ValueError):
                poc.no_distribution_identity()

    def profile(self):
        entitlements = {'application-identifier': 'ABCDEFGHIJ.com.gcsa.aegis',
                        'com.apple.developer.team-identifier': 'ABCDEFGHIJ', 'get-task-allow': False,
                        'com.apple.security.application-groups': ['group.com.gcsa.aegis.ios.share-inbox']}
        profile = {'Name': 'Rotated managed profile', 'UUID': 'ABCD1234-1234-1234-1234-123456789ABC',
                   'TeamIdentifier': ['ABCDEFGHIJ'], 'ExpirationDate': datetime.datetime.utcnow() + datetime.timedelta(days=1),
                   'DeveloperCertificates': [b'new certificate'], 'Entitlements': entitlements}
        return profile, dict(entitlements), hashlib.sha1(b'new certificate').hexdigest().upper()

    def test_cloud_accepts_rotated_certificate_bound_to_actual_profile(self):
        profile, signed, fingerprint = self.profile()
        verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint)

    def test_safari_without_app_group_matches_its_committed_entitlements(self):
        profile, signed, fingerprint = self.profile()
        signed.pop('com.apple.security.application-groups')
        verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint, requested_entitlements={})
        signed['com.apple.security.application-groups'] = ['unexpected']
        with self.assertRaises(ValueError):
            verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint, requested_entitlements={})

    def test_cloud_rejects_device_enterprise_expired_and_wrong_team_profiles(self):
        for change in ({'ProvisionedDevices': ['phone']}, {'ProvisionsAllDevices': True},
                       {'ExpirationDate': datetime.datetime(2000, 1, 1)}, {'TeamIdentifier': ['OTHERTEAM1']},
                       {'DeveloperCertificates': [b'wrong certificate']}, {'UUID': '../../escape'}):
            profile, signed, fingerprint = self.profile()
            profile.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint)

    def test_cloud_checks_signed_entitlements_in_addition_to_embedded_profile(self):
        for key, value in [('get-task-allow', True), ('get-task-allow', 0),
                           ('application-identifier', 'ABCDEFGHIJ.other'),
                           ('com.apple.security.application-groups', ['wrong'])]:
            profile, signed, fingerprint = self.profile()
            signed[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint)


if __name__ == '__main__':
    unittest.main()
