import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ios_action', Path(__file__).with_name('ios-action.py'))
action = importlib.util.module_from_spec(spec)
spec.loader.exec_module(action)


class IosActionTests(unittest.TestCase):
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
                self.assertIn(value, (root/'summary').read_text())
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


if __name__ == '__main__':
    unittest.main()
