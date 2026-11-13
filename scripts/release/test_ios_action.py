import hashlib
import importlib.util
import json
import os
import signal
import subprocess  # nosec B404
import sys
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ios_action', Path(__file__).with_name('ios-action.py'))
action = importlib.util.module_from_spec(spec)
spec.loader.exec_module(action)


class IosActionTests(unittest.TestCase):
    def test_private_beta_package_never_exports_and_only_allows_manual_testflight_upload(self):
        env = dict(AEGIS_IOS_BETA_TEST_NODE_ENABLED='true', GITHUB_REPOSITORY=action.durable.REPOSITORY,
                   GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', RELEASE_RUN_ID='ios-gh-12-1',
                   RELEASE_OPERATION='package-upload', RELEASE_DESTINATION='testflight',
                   RELEASE_PROFILE='beta', RELEASE_SIGNING_MODE='manual', RELEASE_VERSION='1.0.3', RELEASE_BUILD='13')
        for change in (dict(RELEASE_OPERATION='package'), dict(RELEASE_DESTINATION='github-draft'),
                       dict(RELEASE_PROFILE='release'), dict(RELEASE_SIGNING_MODE='cloud'), dict(GITHUB_RUN_ATTEMPT='2')):
            with patch.dict(os.environ, dict(env, **change), clear=True), patch.object(action, 'run') as run:
                with self.assertRaises(ValueError):
                    action.package()
                run.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'ios-manifest.json').write_text('{}')
            with patch.dict(os.environ, env, clear=True), patch.object(action, 'directory', return_value=root), \
                    patch.object(action, 'run'), patch.object(action, 'source', return_value=('a'*40, 'b'*40)), \
                    patch.object(action, 'private_beta_manifest'), patch.object(action, 'output'), \
                    patch.object(action, 'export') as export:
                action.package()
                export.assert_not_called()

    def test_previous_direct_upload_step_with_unknown_result_blocks_new_run(self):
        row = dict(id=12, run_attempt=1, head_sha='a'*40, path='.github/workflows/ios-delivery-full.yml', status='completed')
        for conclusion in ('skipped', 'failure', 'success', None):
            job = dict(name='delivery / ios-package', run_id=12, run_attempt=1, head_sha='a'*40,
                       steps=[dict(name='Upload private Beta directly to TestFlight', conclusion=conclusion)])
            def lookup(path):
                return dict(total_count=1, jobs=[job]) if '/jobs?' in path else row
            with patch.object(action, 'api', side_effect=lookup):
                self.assertEqual(action.unstarted_store_run(row), conclusion == 'skipped')

    def test_private_handoff_binds_runner_source_and_bytes_outside_the_cleaned_workspace(self):
        env = dict(GITHUB_REPOSITORY=action.durable.REPOSITORY, GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1',
                   RELEASE_RUN_ID='ios-gh-12-1', RELEASE_OPERATION='package-upload', RELEASE_DESTINATION='testflight',
                   RELEASE_PROFILE='beta', RELEASE_SIGNING_MODE='manual', RELEASE_VERSION='1.0.3', RELEASE_BUILD='13',
                   RUNNER_ENVIRONMENT='self-hosted', RUNNER_OS='macOS', RUNNER_NAME='fixture-mac')
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            workspace = home / 'workspace'
            workspace.mkdir()
            ipa = workspace / 'fixture.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Aegis.app/AegisPrivateTestNode.vless', 'synthetic private node')
            raw_ipa = ipa.read_bytes()
            manifest = dict(repository=action.durable.REPOSITORY, platform='ios', profile='beta', version='1.0.3', build='13',
                source=dict(sha='a'*40, tree='b'*40, dirty=False),
                details=dict(privateBetaTestNode=True, privateBetaQuota=True, testFlightInternalTestingOnly=True),
                assets=[dict(name=ipa.name, size=len(raw_ipa), sha256=hashlib.sha256(raw_ipa).hexdigest())])
            raw = json.dumps(manifest).encode()
            digest = hashlib.sha256(raw).hexdigest()
            (workspace / 'ios-manifest.json').write_bytes(raw)
            (workspace / 'ios-manifest.json.sha256').write_text(digest + '  ios-manifest.json\n')
            (workspace / 'package-origin.json').write_text('{}')
            env['RELEASE_MANIFEST_SHA256'] = digest
            with (patch.dict(os.environ, env, clear=True), patch.object(action.Path, 'home', return_value=home),
                  patch.object(action, 'directory', return_value=workspace),
                  patch.object(action, 'source', return_value=('a'*40, 'b'*40))):
                action.retain_private_beta()
                retained = action.checked_private_beta_handoff()
                self.assertNotIn(workspace, retained.parents)
                for item in retained.rglob('*'):
                    self.assertEqual(item.stat().st_mode & 0o077, 0)
                action.cleanup_private_beta()
                with patch.dict(os.environ, {'RUNNER_NAME': 'different-runner'}), self.assertRaises(ValueError):
                    action.restore_private_beta()
                payload = retained / 'package/fixture.ipa'
                payload.write_bytes(b'tampered')
                with self.assertRaises(ValueError):
                    action.restore_private_beta()
                self.assertFalse(workspace.exists())
                payload.write_bytes(raw_ipa)
                def partial_copy(_source, destination, **_options):
                    self.assertEqual(destination.parent.stat().st_mode & 0o077, 0)
                    (destination / 'fixture.ipa').write_bytes(raw_ipa[:32])
                    raise OSError('fixture disk full')
                with patch.object(action.shutil, 'copytree', side_effect=partial_copy), self.assertRaises(OSError):
                    action.restore_private_beta()
                self.assertFalse(workspace.exists())
                self.assertEqual(list(workspace.parent.glob('.private-beta-restore-*')), [])
                self.assertEqual(payload.read_bytes(), raw_ipa)
                for foreign_kind in ('directory', 'symlink'):
                    with self.subTest(conflicting_workspace=foreign_kind):
                        target = home / 'foreign-target'
                        target.mkdir(mode=0o700)
                        (target / 'foreign').write_text('preserve')
                        def conflicting_copy(_source, destination, **_options):
                            (destination / 'fixture.ipa').write_bytes(raw_ipa[:32])
                            if foreign_kind == 'symlink': workspace.symlink_to(target, target_is_directory=True)
                            else: target.rename(workspace)
                            raise OSError('fixture copy failed after a conflicting workspace appeared')
                        with patch.object(action.shutil, 'copytree', side_effect=conflicting_copy), self.assertRaises(ValueError):
                            action.restore_private_beta()
                        staging, _ = action.private_beta_restore_staging()
                        self.assertFalse((staging / 'package').exists())
                        self.assertTrue((staging / 'owner.json').is_file())
                        self.assertEqual((workspace / 'foreign').read_text(), 'preserve')
                        self.assertEqual(payload.read_bytes(), raw_ipa)
                        if foreign_kind == 'symlink': workspace.unlink()
                        else: workspace.rename(target)
                        (target / 'foreign').unlink()
                        target.rmdir()
                        action.cleanup_private_beta_restore()
                child = """
import importlib.util, os, signal, sys
from contextlib import ExitStack, contextmanager
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location('ios_action', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cut = sys.argv[4]
order = sys.argv[5]
original_rename, original_unlink = Path.rename, os.unlink
original_scandir = os.scandir
@contextmanager
def reordered_scan(path):
    with original_scandir(path) as rows:
        yield iter(sorted(rows, key=lambda row: row.name, reverse=order == 'descending'))
def interrupted_copy(_source, destination, **_options):
    (destination / 'partial-state').write_text('fixture')
    (destination / 'fixture.ipa').write_bytes(b'partial private fixture')
    if cut == 'cleanup':
        if order != 'native':
            stack.enter_context(patch.object(os, 'scandir', reordered_scan))
        raise OSError('fixture disk full')
    os.kill(os.getpid(), signal.SIGTERM)
def interrupted_rename(path, destination):
    original_rename(path, destination)
    os.kill(os.getpid(), signal.SIGTERM)
def interrupted_unlink(path, *args, **kwargs):
    if Path(path).name == 'fixture.ipa':
        try:
            original_unlink(str(Path(path).with_name('partial-state')), *args, **kwargs)
        except FileNotFoundError:
            pass
        os.kill(os.getpid(), signal.SIGTERM)
    original_unlink(path, *args, **kwargs)
with ExitStack() as stack:
    stack.enter_context(patch.object(module.Path, 'home', return_value=Path(sys.argv[2])))
    stack.enter_context(patch.object(module, 'directory', return_value=Path(sys.argv[3])))
    stack.enter_context(patch.object(module, 'source', return_value=('a'*40, 'b'*40)))
    if cut == 'rename':
        stack.enter_context(patch.object(Path, 'rename', interrupted_rename))
    else:
        stack.enter_context(patch.object(module.shutil, 'copytree', side_effect=interrupted_copy))
    if cut == 'cleanup':
        stack.enter_context(patch.object(os, 'unlink', interrupted_unlink))
    module.restore_private_beta()
"""
                cuts = [('copy', 'native'), ('rename', 'native')]
                cuts += [('cleanup', order) for order in ('native', 'ascending', 'descending')]
                for cut, order in cuts:
                    with self.subTest(interrupted=cut, order=order):
                        # Fixed interpreter/literal program and local fixture paths plus a fixed fault label.
                        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
                        terminated = subprocess.run([sys.executable, '-c', child, action.__file__, str(home), str(workspace), cut, order],  # nosec B603
                                                    env=env, capture_output=True, timeout=10, check=False)
                        self.assertEqual(terminated.returncode, -signal.SIGTERM, terminated.stderr.decode())
                        staging, identity = action.private_beta_restore_staging()
                        copy = workspace if cut == 'rename' else staging / 'package'
                        self.assertTrue((copy / 'fixture.ipa').is_file())
                        self.assertEqual(workspace.exists(), cut == 'rename')
                        self.assertEqual(staging.stat().st_mode & 0o077, 0)
                        self.assertEqual(payload.read_bytes(), raw_ipa)
                        marker = staging / 'owner.json'
                        owner = json.loads(marker.read_text())
                        marker.write_text(json.dumps(dict(owner, identity=dict(identity, runId='other-run'))))
                        with self.assertRaises(ValueError): action.cleanup_private_beta_restore()
                        self.assertTrue((copy / 'fixture.ipa').exists())
                        marker.write_text(json.dumps(owner))
                        if cut == 'rename':
                            saved = home / 'saved-owned-copy'
                            workspace.rename(saved)
                            workspace.mkdir(mode=0o700)
                            (workspace / 'foreign').write_text('preserve')
                            with self.assertRaises(ValueError): action.cleanup_private_beta_restore()
                            self.assertEqual((workspace / 'foreign').read_text(), 'preserve')
                            (workspace / 'foreign').unlink()
                            workspace.rmdir()
                            saved.rename(workspace)
                        action.cleanup_private_beta_restore()
                        self.assertFalse(staging.exists())
                        self.assertFalse(workspace.exists())
                        self.assertEqual(payload.read_bytes(), raw_ipa)
                        action.cleanup_private_beta_restore()
                action.restore_private_beta()
                self.assertEqual((workspace / 'fixture.ipa').read_bytes(), raw_ipa)
                with self.assertRaises(ValueError):
                    action.restore_private_beta()
                action.cleanup_private_beta_restore()
                action.cleanup_private_beta_handoff()
                self.assertFalse(workspace.exists())
                self.assertFalse(retained.exists())

    def test_private_upload_requires_a_credential_free_quota_preflight_for_the_same_manifest(self):
        digest = 'c' * 64
        env = dict(RELEASE_MANIFEST_SHA256=digest, RELEASE_STAGE='upload')
        manifest = dict(assets=[dict(name='fixture.ipa')])
        with (patch.dict(os.environ, env, clear=True), patch.object(action, 'require_private_beta_upload'),
              patch.object(action, 'private_beta_manifest', return_value=manifest),
              patch.object(action, 'source', return_value=('a'*40, 'b'*40)),
              patch.object(action.transport, 'verify_package'), patch.object(action, 'check_new_upload_runs'),
              patch.object(action, 'directory', return_value=Path('/fixture')),
              patch.object(action, 'run') as run, patch.object(action, 'stage') as stage,
              patch.object(action, 'output') as output):
            with self.assertRaises(ValueError): action.private_beta_upload()
            stage.assert_not_called()
            for name in ('AEGIS_ASC_KEY_BASE64', 'AEGIS_ASC_KEY_PATH'):
                with self.subTest(name=name), patch.dict(os.environ, {name: 'synthetic'}), self.assertRaises(ValueError):
                    action.private_beta_preflight()
            run.assert_not_called()
            with patch.object(action, 'run', side_effect=ValueError('quota unavailable')), self.assertRaises(ValueError):
                action.private_beta_preflight()
            output.assert_not_called()
            action.private_beta_preflight()
            self.assertIn('verify-live', run.call_args.args)
            self.assertEqual(run.call_args.kwargs, {'environment': {}})
            output.assert_called_once_with('manifest_sha256', digest)
            with patch.dict(os.environ, {'AEGIS_PRIVATE_BETA_VERIFIED_MANIFEST_SHA256': 'd'*64}), self.assertRaises(ValueError):
                action.private_beta_upload()
            with patch.dict(os.environ, {'AEGIS_PRIVATE_BETA_VERIFIED_MANIFEST_SHA256': digest}):
                action.private_beta_upload()
            stage.assert_called_once()
            run.assert_called_once()

    def test_preflight_output_guard_fails_missing_empty_and_mismatched_outputs(self):
        expected = 'c'*64
        with patch.object(action, 'require_private_beta_upload'):
            for value in (None, '', 'd'*64, expected):
                env = {'RELEASE_MANIFEST_SHA256': expected}
                if value is not None: env['AEGIS_PRIVATE_BETA_VERIFIED_MANIFEST_SHA256'] = value
                with self.subTest(value=value), patch.dict(os.environ, env, clear=True):
                    if value == expected: action.require_private_beta_preflight()
                    else:
                        with self.assertRaises(ValueError): action.require_private_beta_preflight()

    def test_private_beta_manifest_requires_internal_testflight_audience(self):
        sha, tree = 'a' * 40, 'b' * 40
        env = dict(RELEASE_PROFILE='beta', RELEASE_VERSION='1.0.3', RELEASE_BUILD='13')
        manifest = dict(source=dict(sha=sha, tree=tree, dirty=False), repository=action.durable.REPOSITORY,
                        platform='ios', profile='beta', version='1.0.3', build='13',
                        details=dict(privateBetaTestNode=True, privateBetaQuota=True))
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, env, clear=True), \
                patch.object(action, 'directory', return_value=Path(tmp)), \
                patch.object(action, 'source', return_value=(sha, tree)):
            path = Path(tmp) / 'ios-manifest.json'
            for audience in (None, False, True):
                with self.subTest(audience=audience):
                    if audience is not None:
                        manifest['details']['testFlightInternalTestingOnly'] = audience
                    path.write_text(json.dumps(manifest))
                    digest = action.transport.digest(path)
                    if audience is True:
                        self.assertEqual(action.private_beta_manifest(digest), manifest)
                    else:
                        with self.assertRaisesRegex(ValueError, 'manifest identity'):
                            action.private_beta_manifest(digest)

    def test_private_beta_evidence_exposes_only_confirmed_status_and_allowlisted_identity(self):
        digest = 'c'*64
        manifest = dict(source=dict(sha='a'*40, tree='b'*40, dirty=False), platform='ios',
                        applicationId='com.gcsa.aegis', format='ipa', profile='beta', version='1.0.3', build='13',
                        details={'privateBetaTestNode': True, 'fixturePrivateData': 'never export me'})
        intent = {k: manifest[k] for k in ('platform', 'applicationId', 'profile', 'version', 'build', 'format')}
        intent.update(operation='apple-upload', manifestSha256=digest)
        for start, finish, expected in (
                (None, None, 'not_started'), (intent, None, 'unknown_reconcile_with_apple'),
                (intent, dict(intent=intent, result={'status': 'uploaded_processing_unverified',
                                                   'fixturePrivateData': 'never export me'}), 'uploaded_processing_unverified')):
            with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, dict(RUNNER_TEMP=tmp,
                    GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', RELEASE_MANIFEST_SHA256=digest)), \
                    patch.object(action, 'require_private_beta_upload'), \
                    patch.object(action, 'private_beta_manifest', return_value=manifest), \
                    patch.object(action.durable, 'records') as records, patch.object(action, 'output'), patch('builtins.print'):
                records.return_value.read.side_effect = [start, finish]
                action.private_beta_evidence()
                receipt = Path(tmp)/'aegis-private-beta-12-1.json'
                self.assertEqual(json.loads(receipt.read_text())['uploadState'], expected)
                self.assertNotIn('never export me', receipt.read_text())

    def test_package_entrypoints_use_cloud_default_and_forward_explicit_manual_fallback(self):
        base = dict(RELEASE_PROFILE='beta', RELEASE_VERSION='1.0.2', RELEASE_BUILD='12',
                    RELEASE_RUN_ID='ios-gh-12-1', RELEASE_DESTINATION='artifacts')
        class StopAfterInvocation(Exception):
            pass
        for entrypoint in ['actions', 'fastlane']:
            for selection in [None, 'manual']:
                calls = []
                env = dict(base, RELEASE_PACKAGE_ENTRYPOINT=entrypoint)
                if selection is not None:
                    env['RELEASE_SIGNING_MODE'] = selection
                def boundary(*args, **_kwargs):
                    calls.append(list(map(str, args)))
                    raise StopAfterInvocation
                with self.subTest(entrypoint=entrypoint, selection=selection), \
                        patch.dict(os.environ, env, clear=True), patch.object(action, 'run', boundary):
                    with self.assertRaises(StopAfterInvocation):
                        action.package()
                command = calls[0]
                if entrypoint == 'fastlane':
                    self.assertEqual(command[:5], ['bundle', 'exec', 'fastlane', 'ios', 'package'])
                    self.assertIn('signing_mode:'+(selection or 'cloud'), command)
                else:
                    self.assertEqual(command[1:3], ['ios', 'package'])
                    self.assertEqual(command[command.index('--signing-mode')+1], selection or 'cloud')

    def test_receipt_titles_cannot_discard_unknown_prior_mutations(self):
        token = action.receipt_codec.encode('beta', '1.0.0', '33', 100, 101, 1, 'a'*64)
        for stage, operation in [('upload', 'upload'), ('metadata', 'metadata'), ('compliance', 'compliance'),
                                 ('distribute', 'distribute-internal'), ('distribute', 'distribute-external')]:
            title = f'iOS Delivery {operation} {token}'
            self.assertTrue(action.matches_stage_title(title, stage, 'a'*64))
            self.assertFalse(action.matches_stage_title(title, stage, 'b'*64))
            row = dict(id=10, display_title=title)
            with patch.dict(os.environ, {'GITHUB_RUN_ID': '12', 'GITHUB_RUN_ATTEMPT': '1', 'RELEASE_MANIFEST_SHA256': 'a'*64}), \
                    patch.object(action, 'api', return_value={'workflow_runs': [row]}), \
                    patch.object(action, 'unstarted_store_run', return_value=False), self.assertRaises(ValueError):
                action.check_prior_stage_runs(stage, 11)
        for operation in ['upload', 'metadata', 'compliance', 'distribute-internal', 'distribute-external']:
            stage = 'distribute' if operation.startswith('distribute-') else operation
            for label in action.receipt_codec.OPERATION_LABELS[operation]:
                title = f'iOS Delivery {label} {token}'
                self.assertTrue(action.matches_stage_title(title, stage, 'a'*64))
                self.assertFalse(action.matches_stage_title(title, stage, 'b'*64))
        for title in [None, 'iOS Delivery upload invalid', 'unrelated', 'iOS Delivery status '+token]:
            self.assertFalse(action.matches_stage_title(title, 'upload', 'a'*64))
        self.assertTrue(action.matches_stage_title('iOS Delivery upload '+'a'*64, 'upload', 'a'*64))

    def test_receipt_pins_completed_state_without_changing_original_producer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = dict(source=dict(sha='a'*40, tree='b'*40, dirty=False), repository='gcsagroup/aegis-browser',
                            platform='ios', profile='beta', version='1.0.0', build='33')
            (root/'ios-manifest.json').write_text(json.dumps(manifest))
            digest = action.transport.digest(root/'ios-manifest.json')
            origin = dict(repository='gcsagroup/aegis-browser', sourceSha='a'*40, sourceTree='b'*40,
                          manifestSha256=digest, runId=100, attempt=1, runIdLocal='ios-gh-100-1')
            (root/'package-origin.json').write_text(json.dumps(origin))
            env = dict(GITHUB_REPOSITORY='gcsagroup/aegis-browser', GITHUB_RUN_ID='101', GITHUB_RUN_ATTEMPT='2',
                       RELEASE_PROFILE='beta', RELEASE_VERSION='1.0.0', RELEASE_BUILD='33', RELEASE_STAGE='status',
                       RELEASE_RUN_ID='ios-gh-100-1', RELEASE_MANIFEST_SHA256=digest, PACKAGE_RUN_ID='100',
                       GITHUB_OUTPUT=str(root/'output'), GITHUB_STEP_SUMMARY=str(root/'summary'))
            with patch.dict(os.environ, env), patch.object(action, 'directory', return_value=root), \
                    patch.object(action, 'source', return_value=('a'*40, 'b'*40)), patch('builtins.print') as printed:
                action.receipt()
                value = (root/'output').read_text().strip().split('=', 1)[1]
                pinned = action.receipt_codec.decode(value)
                self.assertEqual([pinned[k] for k in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']],
                                 ['100', '101', '2', digest])
                summary = (root/'summary').read_text()
                self.assertTrue(summary.startswith('### iOS Delivery receipt\n'))
                self.assertIn(value, summary)
                printed.assert_called_once_with(value)
                for changes in [dict(RELEASE_BUILD='34'), dict(PACKAGE_RUN_ID='99'), dict(RELEASE_MANIFEST_SHA256='c'*64),
                                dict(RELEASE_STAGE='package'), dict(GITHUB_REPOSITORY='foreign/repo')]:
                    with patch.dict(os.environ, changes), self.assertRaises(ValueError):
                        action.receipt()

    def test_denied_or_skipped_runs_do_not_poison_later_admin_stage(self):
        row = dict(id=10, run_attempt=1, head_sha='b'*40, path='.github/workflows/ios-delivery.yml',
                   status='completed', conclusion='failure', display_title='iOS Delivery upload '+'a'*64)
        env = dict(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', GITHUB_SHA='c'*40, RELEASE_MANIFEST_SHA256='a'*64)
        for jobs in [[], [dict(name='store', status='completed', conclusion='skipped', steps=[], run_id=10, run_attempt=1, head_sha='b'*40)]]:
            calls = []
            def api(path):
                calls.append(path)
                if 'workflows/' in path:
                    return dict(workflow_runs=[row])
                if path == 'actions/runs/10':
                    return row
                if path.endswith('/jobs?per_page=100'):
                    return dict(total_count=len(jobs), jobs=jobs)
                raise AssertionError(path)
            with patch.dict(os.environ, env), patch.object(action, 'api', api):
                action.check_prior_stage_runs('upload', 11)
            self.assertTrue(any('/attempts/1/jobs?' in path for path in calls), 'must prove no store steps ran')

    def test_skipped_job_with_wrong_own_run_or_attempt_is_not_trusted(self):
        row = dict(id=10, run_attempt=1, head_sha='b'*40, path='.github/workflows/ios-delivery.yml', status='completed')
        env = dict(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', GITHUB_SHA='b'*40, RELEASE_MANIFEST_SHA256='a'*64)
        job = dict(name='store', status='completed', conclusion='skipped', steps=[], run_id=10, run_attempt=1, head_sha='b'*40)
        for changes in [dict(run_id=9), dict(run_attempt=2), dict(head_sha='a'*40)]:
            def api(path):
                return row if path == 'actions/runs/10' else dict(total_count=1, jobs=[dict(job, **changes)])
            with patch.dict(os.environ, env), patch.object(action, 'api', api):
                self.assertFalse(action.unstarted_store_run(row))

    def test_possibly_started_mutation_or_earlier_attempt_still_blocks(self):
        row = dict(id=10, run_attempt=2, head_sha='b'*40, path='.github/workflows/ios-delivery.yml',
                   status='completed', conclusion='failure', display_title='iOS Delivery upload '+'a'*64)
        env = dict(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', GITHUB_SHA='b'*40, RELEASE_MANIFEST_SHA256='a'*64)
        for active in [dict(name='store', status='completed', conclusion='failure', steps=[]),
                       dict(name='store', status='in_progress', conclusion=None, steps=[]),
                       dict(name='store', status='completed', conclusion='skipped', steps=[dict(status='completed')])]:
            def api(path):
                if 'workflows/' in path:
                    return dict(workflow_runs=[row])
                if path == 'actions/runs/10':
                    return row
                if '/attempts/1/jobs?' in path:
                    return dict(total_count=1, jobs=[active])
                return dict(total_count=0, jobs=[])
            with patch.dict(os.environ, env), patch.object(action, 'api', api), self.assertRaises(ValueError):
                action.check_prior_stage_runs('upload', 11)

    def test_lost_response_cannot_be_replayed_in_the_same_run_next_attempt(self):
        with patch.dict(os.environ, {'GITHUB_RUN_ID': '12', 'GITHUB_RUN_ATTEMPT': '2', 'RELEASE_MANIFEST_SHA256': 'a'*64}):
            def api(_path):
                return {'workflow_runs': [{'id': 12, 'run_attempt': 2, 'display_title': 'iOS TF metadata '+'a'*64}]}
            with patch.object(action, 'api', api):
                with self.assertRaises(ValueError):
                    action.check_prior_stage_runs('metadata', 11)

    def test_protected_restore_and_direct_stage_reject_unreconciled_mutation_reruns(self):
        self.assertTrue(hasattr(action, 'validate_mutation_attempt'), 'shared attempt guard is missing')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'ios-metadata-started.json').write_text('{}')
            for stage in ['upload', 'metadata', 'compliance', 'distribute']:
                with self.assertRaises(ValueError):
                    action.validate_mutation_attempt(stage, 2, root)
            # Reads and first attempts remain available; completed identical journal is
            # independently reverified by Receipt/Journal before any call can occur.
            action.validate_mutation_attempt('status', 2, root)
            action.validate_mutation_attempt('metadata', 1, root)
            (root/'ios-metadata-result.json').write_text('{}')
            action.validate_mutation_attempt('metadata', 2, root)

    def test_tag_package_keeps_draft_destination_tag_and_repository_at_cli_boundary(self):
        env = {'RELEASE_PROFILE': 'release', 'RELEASE_VERSION': '1.0.0', 'RELEASE_BUILD': '14',
               'RELEASE_RUN_ID': 'ios-gh-14-1', 'RELEASE_DESTINATION': 'github-draft',
               'RELEASE_TAG': 'candidate/ios/1.0.0-release.14', 'GITHUB_REPOSITORY': 'owner/repo'}
        calls = []
        class StopAfterInvocation(Exception):
            pass
        def boundary(*args, **kwargs):
            calls.append(list(map(str, args)))
            raise StopAfterInvocation
        with patch.dict(os.environ, env), patch.object(action, 'run', boundary):
            with self.assertRaises(StopAfterInvocation):
                action.package()
        command = calls[0]
        self.assertEqual(command[1:3], ['ios', 'package'])
        self.assertEqual(command[command.index('--destination')+1], 'github-draft')
        self.assertEqual(command[command.index('--tag')+1], env['RELEASE_TAG'])
        self.assertEqual(command[command.index('--repository')+1], 'owner/repo')
        self.assertNotIn('upload', command)

    def test_nested_full_store_execution_is_not_mistaken_for_unstarted(self):
        row = dict(id=10, run_attempt=1, head_sha='b'*40, path='.github/workflows/ios-delivery-full.yml', status='completed')
        job = dict(name='delivery / store', status='completed', conclusion='success', steps=[{'name': 'upload'}], run_id=10, run_attempt=1, head_sha='b'*40)
        def api(path):
            return dict(total_count=1, jobs=[job]) if path.endswith('/jobs?per_page=100') else row
        with patch.object(action, 'api', api):
            for name in ('delivery / store', 'delivery / private-beta-store'):
                job['name'] = name
                with self.subTest(name=name):
                    self.assertFalse(action.unstarted_store_run(row))

    def test_replay_inventory_checks_both_entrypoints_before_allowing_a_mutation(self):
        calls = []
        def api(path):
            calls.append(path)
            if 'ios-delivery-full.yml' in path:
                return dict(workflow_runs=[dict(id=10, display_title='iOS Delivery upload '+'a'*64)])
            return dict(workflow_runs=[])
        env = dict(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', RELEASE_MANIFEST_SHA256='a'*64)
        with patch.dict(os.environ, env), patch.object(action, 'api', api), patch.object(action, 'unstarted_store_run', return_value=False):
            with self.assertRaises(ValueError):
                action.check_prior_stage_runs('upload', 11)
        self.assertTrue(any('ios-delivery.yml' in x for x in calls))
        self.assertTrue(any('ios-delivery-full.yml' in x for x in calls))

    def test_new_upload_blocks_prior_combined_or_receipt_upload_for_same_version_build(self):
        token = action.receipt_codec.encode('beta', '1.0.0', '36', 100, 100, 1, 'a'*64)
        titles = ['iOS Delivery package-upload 1.0.0(36)',
                  'iOS Delivery Package and upload 1.0.0(36)',
                  'iOS Delivery 打包并上传 TF / Package and upload 1.0.0(36)',
                  f'iOS Delivery upload {token}',
                  f'iOS Delivery Upload {token}']
        for title in titles:
            env = dict(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1', RELEASE_VERSION='1.0.0', RELEASE_BUILD='36')
            with patch.dict(os.environ, env), patch.object(action, 'api', return_value={'workflow_runs': [{'id': 10, 'display_title': title}]}), patch.object(action, 'unstarted_store_run', return_value=False):
                with self.assertRaises(ValueError):
                    action.check_new_upload_runs()
            with patch.dict(os.environ, env), patch.object(action, 'api', return_value={'workflow_runs': [{'id': 10, 'display_title': title}]}), patch.object(action, 'unstarted_store_run', return_value=True):
                action.check_new_upload_runs()
        with patch.dict(os.environ, dict(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='2', RELEASE_VERSION='1.0.0', RELEASE_BUILD='36')), self.assertRaises(ValueError):
            action.check_new_upload_runs()



if __name__ == '__main__':
    unittest.main()
