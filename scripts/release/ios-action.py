#!/usr/bin/env python3
"""GitHub Actions adapter. All inputs enter through environment, never shell interpolation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('artifact_transport', Path(__file__).with_name('artifact-transport.py'))
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def run(*args, capture=False):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, text=True, capture_output=capture)
    if result.returncode:
        raise ValueError('Delivery command failed; no success is inferred')
    return result.stdout.strip() if capture else None


def api(path):
    return json.loads(run('gh', 'api', '-H', 'Accept: application/vnd.github+json', 'repos/'+os.environ['GITHUB_REPOSITORY']+'/'+path, capture=True))


def identity():
    args = ['--profile', os.environ['RELEASE_PROFILE'], '--version', os.environ['RELEASE_VERSION'], '--build', os.environ['RELEASE_BUILD'], '--run-id', os.environ['RELEASE_RUN_ID']]
    return args


def output(name, value):
    if '\n' in str(value):
        raise ValueError('Invalid multiline output')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
        f.write(f'{name}={value}\n')


def source():
    return run('git', 'rev-parse', 'HEAD', capture=True), run('git', 'rev-parse', 'HEAD^{tree}', capture=True)


def directory():
    name = os.environ['RELEASE_RUN_ID']
    if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in name) or '..' in name:
        raise ValueError('Unsafe package run ID')
    return ROOT/'.artifacts/release/ios'/name


def export():
    sha, tree = source()
    digest = transport.digest(directory()/'ios-manifest.json')
    output_dir = ROOT/'.artifacts/ios-delivery'
    output_dir.mkdir(parents=True, exist_ok=True)
    target = output_dir/'package.zip'
    run('python3', Path(__file__).with_name('artifact-transport.py'), 'export', '--directory', directory(), '--zip', target,
        '--sha', sha, '--tree', tree, '--manifest-sha256', digest)
    output('manifest_sha256', digest)
    output('run_id', os.environ['RELEASE_RUN_ID'])


def package():
    args = identity()+['--destination', os.environ.get('RELEASE_DESTINATION', 'artifacts')]
    if os.environ.get('RELEASE_DESTINATION') == 'github-draft':
        args += ['--tag', os.environ['RELEASE_TAG'], '--repository', os.environ['GITHUB_REPOSITORY']]
    run(ROOT/'release', 'ios', 'package', *args)
    sha, tree = source()
    origin = dict(repository=os.environ['GITHUB_REPOSITORY'], runId=int(os.environ['GITHUB_RUN_ID']),
                  attempt=int(os.environ['GITHUB_RUN_ATTEMPT']), sourceSha=sha, sourceTree=tree,
                  runIdLocal=os.environ['RELEASE_RUN_ID'], manifestSha256=transport.digest(directory()/'ios-manifest.json'))
    with (directory()/'package-origin.json').open('x') as f:
        json.dump(origin, f, indent=2)
    export()


def validate_mutation_attempt(stage, attempt, directory=None):
    if stage not in {'upload', 'metadata', 'compliance', 'distribute'} or attempt == 1:
        return
    receipt = 'apple-upload' if stage == 'upload' else 'ios-'+stage
    if directory is None or not (directory/(receipt+'-result.json')).is_file():
        raise ValueError('Mutation rerun requires recovered completed journal; reconcile prior attempt first')


def check_prior_stage_runs(stage, state_run):
    # A lost job/transport response is not permission to replay the mutation in another run.
    validate_mutation_attempt(stage, int(os.environ.get('GITHUB_RUN_ATTEMPT', '1')))
    current = int(os.environ['GITHUB_RUN_ID'])
    title = f'iOS TF {stage} {os.environ["RELEASE_MANIFEST_SHA256"]}'
    for page in range(1, 21):
        rows = api(f'actions/workflows/ios-testflight.yml/runs?per_page=100&page={page}')['workflow_runs']
        for row in rows:
            if row['id'] == current or row.get('display_title') != title:
                continue
            if row['id'] != state_run:
                raise ValueError('Earlier identical stage run exists outside imported state; read back and reconcile before retry')
        if len(rows) < 100:
            return
    raise ValueError('Cannot prove complete prior-stage inventory')


def import_package():
    sha, tree = source()
    repository = os.environ['GITHUB_REPOSITORY']
    package_run = int(os.environ['PACKAGE_RUN_ID'])
    state_run = int(os.environ.get('UPLOAD_RUN_ID') or package_run)
    record = api(f'actions/runs/{state_run}')
    # Explicit attempt prevents a successful historical attempt masking a later rerun.
    attempt = int(os.environ['SOURCE_ATTEMPT'])
    transport.verify_run(record, repository, sha, state_run, attempt)
    if state_run == package_run and record['path'] not in {'.github/workflows/ios-release.yml', '.github/workflows/ios-candidate.yml'}:
        raise ValueError('Original package run is not an iOS package workflow')
    artifacts = api(f'actions/runs/{state_run}/artifacts?per_page=100')
    expected_name = f'ios-delivery-{state_run}-{attempt}'
    rows = [a for a in artifacts['artifacts'] if a['name'] == expected_name and not a['expired']]
    if artifacts['total_count'] > 100 or len(rows) != 1:
        raise ValueError('Exact delivery artifact unavailable')
    with tempfile.TemporaryDirectory(prefix='ios-download-') as tmp:
        archive = Path(tmp)/'artifact.zip'
        # gh follows the authenticated Actions redirect; default JSON Accept is required.
        with archive.open('xb') as f:
            result = subprocess.run(['gh', 'api', '-H', 'Accept: application/vnd.github+json', f'repos/{repository}/actions/artifacts/{rows[0]["id"]}/zip'], stdout=f, stderr=subprocess.PIPE)
        if result.returncode:
            raise ValueError('Artifact download failed')
        # The Actions envelope must contain just our package.zip, not arbitrary files.
        import zipfile
        with zipfile.ZipFile(archive) as zipped:
            if zipped.namelist() != ['package.zip'] or zipped.getinfo('package.zip').file_size > 1024**3:
                raise ValueError('Unexpected Actions artifact envelope')
            payload = Path(tmp)/'package.zip'
            with zipped.open('package.zip') as content, payload.open('xb') as out:
                import shutil
                shutil.copyfileobj(content, out)
        staged = Path(tmp)/'staged'
        transport.extract_flat(payload, staged)
        digest = os.environ['RELEASE_MANIFEST_SHA256']
        manifest = transport.verify_package(staged, sha, tree, digest)
        if [manifest[k] for k in ['profile', 'version', 'build']] != [os.environ[k] for k in ['RELEASE_PROFILE', 'RELEASE_VERSION', 'RELEASE_BUILD']]:
            raise ValueError('Requested package identity mismatch')
        origin = json.loads((staged/'package-origin.json').read_text())
        original = api(f'actions/runs/{package_run}')
        transport.verify_run(original, repository, sha, package_run, int(origin['attempt']))
        if original['path'] not in {'.github/workflows/ios-release.yml', '.github/workflows/ios-candidate.yml'} or origin['repository'] != repository or origin['runId'] != package_run or origin['sourceSha'] != sha or origin['sourceTree'] != tree or origin['manifestSha256'] != digest:
            raise ValueError('Original package run/source/manifest mismatch')
        if state_run == package_run and origin['attempt'] != attempt:
            raise ValueError('Original package attempt mismatch')
        os.environ['RELEASE_RUN_ID'] = origin['runIdLocal']
        target = directory()
        if target.exists():
            raise ValueError('Refuse to overwrite package state')
        target.parent.mkdir(parents=True, exist_ok=True)
        os.rename(staged, target)
        # Expose only validated identity. No credential is loaded by this operation.
        output('run_id', origin['runIdLocal'])
        output('manifest_sha256', digest)
        stage = os.environ.get('RELEASE_STAGE', '')
        validate_mutation_attempt(stage, int(os.environ['GITHUB_RUN_ATTEMPT']), target)
        if stage not in {'status', 'wait', 'draft', ''}:
            if stage != 'upload' and not (target/'apple-upload-result.json').is_file():
                raise ValueError('Later mutation requires exact completed upload receipt')
            receipt = 'apple-upload' if stage == 'upload' else 'ios-'+stage
            if not (target/(receipt+'-result.json')).is_file():
                check_prior_stage_runs(stage, state_run)


def stage():
    operation = os.environ['RELEASE_STAGE']
    validate_mutation_attempt(operation, int(os.environ['GITHUB_RUN_ATTEMPT']), directory())
    if operation not in {'upload', 'wait', 'status', 'metadata', 'compliance', 'distribute', 'draft'}:
        raise ValueError('Action stage is not allowed')
    args = identity()
    destination = 'github-draft' if operation == 'draft' else os.environ.get('RELEASE_DESTINATION', 'testflight')
    args += ['--destination', destination]
    if operation == 'draft':
        args += ['--tag', os.environ['RELEASE_TAG'], '--repository', os.environ['GITHUB_REPOSITORY']]
    if os.environ.get('RELEASE_GROUPS'):
        args += ['--groups', os.environ['RELEASE_GROUPS']]
    args += ['--manifest-sha256', os.environ['RELEASE_MANIFEST_SHA256']]
    if operation in {'metadata', 'compliance'}:
        input_file = ROOT/'.artifacts/stage-input.json'
        with input_file.open('x') as f:
            f.write(os.environ['RELEASE_INPUT'])
        args += ['--input', str(input_file)]
    run(ROOT/'release', 'ios', 'upload' if operation == 'draft' else operation, *args)


if __name__ == '__main__':
    {'package': package, 'export': export, 'import': import_package, 'stage': stage}[sys.argv[1]]()
