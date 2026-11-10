#!/usr/bin/env python3
"""Offline admission checks; never enter main(), inspect or stop a runner."""
import json
import os
from pathlib import Path
import re
import runpy
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HOOK = runpy.run_path(str(Path(__file__).with_name('self-host-job-started.py')))
REPOSITORY = {'id': HOOK['REPOSITORY_ID'], 'full_name': HOOK['REPOSITORY']}


class AdmissionTests(unittest.TestCase):
    def check(self, job='cpp-unit-tests', event='push', ref='refs/heads/develop',
              repository=REPOSITORY, head=REPOSITORY):
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / 'event.json'
            payload.write_text(json.dumps({'repository': repository, 'pull_request': {
                'head': {'repo': head}, 'base': {'ref': 'main'}}}))
            environment = {
                'GITHUB_REPOSITORY': HOOK['REPOSITORY'], 'GITHUB_EVENT_NAME': event,
                'GITHUB_WORKFLOW_REF': f"{HOOK['REPOSITORY']}/.github/workflows/cpp-unit-tests.yml@{ref}",
                'GITHUB_JOB': job, 'GITHUB_REF': ref, 'GITHUB_EVENT_PATH': str(payload),
            }
            # The host's admission marker and runner processes are outside this test.
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(Path, 'exists', return_value=False):
                HOOK['check']()

    def test_actual_workflow_job_key_is_admitted(self):
        workflow = (ROOT / '.github/workflows/cpp-unit-tests.yml').read_text()
        jobs = re.findall(r'^  ([a-z][a-z0-9-]*):$', workflow.split('\njobs:\n', 1)[1], re.M)
        self.assertEqual(jobs, ['cpp-unit-tests'])
        self.check(job=jobs[0])

    def test_display_name_is_not_the_job_key(self):
        with self.assertRaisesRegex(ValueError, 'unsupported test job'):
            self.check(job='c++-unit-tests')

    def test_trusted_pull_request_is_admitted(self):
        self.check(event='pull_request', ref='refs/pull/1/merge')

    def test_external_fork_and_wrong_repository_are_rejected(self):
        foreign = {'id': 1, 'full_name': 'other/browser'}
        with self.assertRaisesRegex(ValueError, 'external fork'):
            self.check(event='pull_request', head=foreign)
        with self.assertRaisesRegex(ValueError, 'event repository mismatch'):
            self.check(repository=foreign)

    def test_unapproved_push_branch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unsupported test branch'):
            self.check(ref='refs/heads/unapproved')


if __name__ == '__main__':
    unittest.main()
