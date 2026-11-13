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
              repository=REPOSITORY, head=REPOSITORY,
              workflow='cpp-unit-tests.yml'):
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / 'event.json'
            payload.write_text(json.dumps({'repository': repository, 'pull_request': {
                'head': {'repo': head}, 'base': {'ref': 'main'}}}))
            environment = {
                'GITHUB_REPOSITORY': HOOK['REPOSITORY'], 'GITHUB_EVENT_NAME': event,
                'GITHUB_WORKFLOW_REF': f"{HOOK['REPOSITORY']}/.github/workflows/{workflow}@{ref}",
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
        with self.assertRaisesRegex(ValueError, 'unsupported workflow/job combination'):
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

    def test_workflow_and_job_must_be_admitted_as_one_pair(self):
        mismatched = [
            ('quality.yml', 'cpp-unit-tests'),
            ('cpp-unit-tests.yml', 'quality'),
            ('macos-delivery.yml', 'simulator'),
            ('ios-fork-access.yml', 'access-tests'),
            ('ios-release-validation.yml', 'store'),
            ('ios-delivery.yml', 'ios-archive'),
        ]
        for workflow, job in mismatched:
            with self.subTest(workflow=workflow, job=job):
                with self.assertRaises(ValueError):
                    self.check(workflow=workflow, job=job)

    def test_each_supported_executing_job_keeps_its_workflow_binding(self):
        valid = [
            ('quality.yml', 'quality'),
            ('quality.yml', 'quality-summary'),
            ('cpp-unit-tests.yml', 'cpp-unit-tests'),
            ('ios-release-validation.yml', 'ios-archive'),
            ('ios-release-validation.yml', 'cloud-poc'),
            ('ios-delivery.yml', 'ios-package'),
            ('ios-delivery.yml', 'store'),
            ('ios-delivery.yml', 'upload-new'),
            ('ios-delivery.yml', 'ios-draft'),
            # A reusable workflow keeps the caller ref and executing job ID.
            ('ios-delivery-full.yml', 'ios-package'),
            ('ios-delivery-full.yml', 'store'),
            ('ios-delivery-full.yml', 'upload-new'),
            ('ios-delivery-full.yml', 'ios-draft'),
            ('ios-fork-access.yml', 'simulator'),
            ('ios-fork-access.yml', 'internal'),
            ('macos-delivery.yml', 'access-tests'),
            ('macos-delivery.yml', 'package'),
            ('macos-delivery.yml', 'internal-dmg'),
        ]
        for workflow, job in valid:
            with self.subTest(workflow=workflow, job=job):
                self.check(workflow=workflow, job=job)


if __name__ == '__main__':
    unittest.main()
