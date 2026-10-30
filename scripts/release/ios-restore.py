#!/usr/bin/env python3
"""Verify the current workflow's completed producer job before using its artifact."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('ios_action', Path(__file__).with_name('ios-action.py'))
action = importlib.util.module_from_spec(spec)
spec.loader.exec_module(action)

sha, tree = action.source()
run_id, attempt = int(os.environ['GITHUB_RUN_ID']), int(os.environ['GITHUB_RUN_ATTEMPT'])
kind = os.environ['IMPORT_KIND']
producer = 'ios-package' if kind == 'draft' else 'import'
run = action.api(f'actions/runs/{run_id}')
allowed = {'.github/workflows/ios-release.yml', '.github/workflows/ios-candidate.yml'} if kind == 'draft' else {'.github/workflows/ios-testflight.yml'}
if run['head_sha'] != sha or run['run_attempt'] != attempt or run['repository']['full_name'] != os.environ['GITHUB_REPOSITORY'] or run['path'] not in allowed:
    raise ValueError('Current artifact producer source/workflow changed')
jobs = action.api(f'actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100')
rows = [j for j in jobs['jobs'] if j['name'] == producer or j['name'].endswith(' / '+producer)]
if jobs['total_count'] > 100 or len(rows) != 1 or rows[0]['status'] != 'completed' or rows[0]['conclusion'] != 'success' or rows[0]['head_sha'] != sha:
    raise ValueError('Artifact producer job is not completed successfully at this exact source')
with tempfile.TemporaryDirectory(prefix='ios-restore-') as tmp:
    staged = Path(tmp)/'package'
    action.transport.extract_flat(action.ROOT/'.artifacts/download/package.zip', staged)
    manifest = action.transport.verify_package(staged, sha, tree, os.environ['RELEASE_MANIFEST_SHA256'])
    if [manifest[k] for k in ['profile', 'version', 'build']] != [os.environ[k] for k in ['RELEASE_PROFILE', 'RELEASE_VERSION', 'RELEASE_BUILD']]:
        raise ValueError('Package identity mismatch')
    origin = json.loads((staged/'package-origin.json').read_text())
    expected = int(os.environ['PACKAGE_RUN_ID'])
    if origin['runId'] != expected or origin['repository'] != os.environ['GITHUB_REPOSITORY'] or origin['sourceSha'] != sha or origin['sourceTree'] != tree or origin['manifestSha256'] != os.environ['RELEASE_MANIFEST_SHA256']:
        raise ValueError('Package origin mismatch')
    if kind == 'draft':
        if expected != run_id or origin['attempt'] != attempt or origin['runIdLocal'] != os.environ['RELEASE_RUN_ID']:
            raise ValueError('Draft origin differs from this package job')
    else:
        original = action.api(f'actions/runs/{expected}')
        action.transport.verify_run(original, os.environ['GITHUB_REPOSITORY'], sha, expected, int(origin['attempt']))
        if original['path'] not in {'.github/workflows/ios-release.yml', '.github/workflows/ios-candidate.yml'}:
            raise ValueError('Wrong original package workflow')
        if origin['runIdLocal'] != os.environ['RELEASE_RUN_ID']:
            raise ValueError('Validated package run identity changed')
    target = action.directory()
    if target.exists():
        raise ValueError('Refuse to overwrite restored package')
    target.parent.mkdir(parents=True, exist_ok=True)
    os.rename(staged, target)
