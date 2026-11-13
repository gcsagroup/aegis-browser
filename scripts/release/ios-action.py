#!/usr/bin/env python3
"""GitHub Actions adapter. All inputs enter through environment, never shell interpolation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('artifact_transport', Path(__file__).with_name('artifact-transport.py'))
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
receipt_spec = importlib.util.spec_from_file_location('ios_delivery_receipt', Path(__file__).with_name('ios-delivery-receipt.py'))
receipt_codec = importlib.util.module_from_spec(receipt_spec)
receipt_spec.loader.exec_module(receipt_codec)
durable_spec = importlib.util.spec_from_file_location('ios_durable', Path(__file__).with_name('ios-durable.py'))
durable = importlib.util.module_from_spec(durable_spec)
durable_spec.loader.exec_module(durable)


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
    private_beta = os.environ.get('AEGIS_IOS_BETA_TEST_NODE_ENABLED') == 'true'
    if private_beta:
        require_private_beta_upload()
    if os.environ.get('RELEASE_PACKAGE_ENTRYPOINT', 'actions') not in {'actions', 'fastlane'}:
        raise ValueError('Unsupported package entrypoint')
    args = identity()+['--destination', os.environ.get('RELEASE_DESTINATION', 'artifacts'),
                       '--signing-mode', os.environ.get('RELEASE_SIGNING_MODE', 'cloud')]
    if os.environ.get('RELEASE_DESTINATION') == 'github-draft':
        args += ['--tag', os.environ['RELEASE_TAG'], '--repository', os.environ['GITHUB_REPOSITORY']]
    if os.environ.get('RELEASE_PACKAGE_ENTRYPOINT', 'actions') == 'fastlane':
        names = {'--profile': 'profile', '--version': 'version', '--build': 'build', '--run-id': 'run_id',
                 '--destination': 'destination', '--signing-mode': 'signing_mode', '--tag': 'tag', '--repository': 'repository'}
        pairs = [names[args[i]] + ':' + args[i+1] for i in range(0, len(args), 2)]
        run('bundle', 'exec', 'fastlane', 'ios', 'package', *pairs)
    else:
        run(ROOT/'release', 'ios', 'package', *args)
    sha, tree = source()
    origin = dict(repository=os.environ['GITHUB_REPOSITORY'], runId=int(os.environ['GITHUB_RUN_ID']),
                  attempt=int(os.environ['GITHUB_RUN_ATTEMPT']), sourceSha=sha, sourceTree=tree,
                  runIdLocal=os.environ['RELEASE_RUN_ID'], manifestSha256=transport.digest(directory()/'ios-manifest.json'))
    with (directory()/'package-origin.json').open('x') as f:
        json.dump(origin, f, indent=2)
    if private_beta:
        private_beta_manifest(origin['manifestSha256'])
        output('manifest_sha256', origin['manifestSha256'])
    else:
        export()
    output('private_beta', str(private_beta).lower())


def require_private_beta_upload():
    if (os.environ.get('GITHUB_REPOSITORY') != durable.REPOSITORY
            or os.environ.get('RELEASE_OPERATION') != 'package-upload'
            or os.environ.get('RELEASE_DESTINATION') != 'testflight'
            or os.environ.get('RELEASE_PROFILE') != 'beta'
            or os.environ.get('RELEASE_SIGNING_MODE') != 'manual'
            or os.environ.get('GITHUB_RUN_ATTEMPT') != '1'
            or os.environ.get('RELEASE_RUN_ID') != f"ios-gh-{os.environ.get('GITHUB_RUN_ID')}-1"):
        raise ValueError('Private Beta requires a first-attempt manual Package and upload to TestFlight')


def private_beta_manifest(digest):
    root = directory()
    sha, tree = source()
    path = root/'ios-manifest.json'
    manifest = json.loads(path.read_text())
    if (re.fullmatch(r'[0-9a-f]{64}', digest) is None or transport.digest(path) != digest
            or manifest.get('source') != dict(sha=sha, tree=tree, dirty=False)
            or manifest.get('repository') != durable.REPOSITORY or manifest.get('platform') != 'ios'
            or any(manifest.get(k) != os.environ['RELEASE_'+k.upper()] for k in ('profile', 'version', 'build'))
            or manifest['details'].get('privateBetaTestNode') is not True
            or manifest['details'].get('privateBetaQuota') is not True):
        raise ValueError('Private Beta manifest identity differs')
    return manifest


def private_beta_upload():
    require_private_beta_upload()
    private_beta_manifest(os.environ['RELEASE_MANIFEST_SHA256'])
    check_new_upload_runs()
    if os.environ.get('RELEASE_STAGE') != 'upload':
        raise ValueError('Private Beta can only run the Apple upload stage')
    stage()


def private_beta_evidence():
    require_private_beta_upload()
    digest = os.environ['RELEASE_MANIFEST_SHA256']
    manifest = private_beta_manifest(digest)
    store = durable.records()
    allocation = durable.key(manifest['version'], manifest['build'])
    started = store.read('upload-start', allocation)
    finished = store.read('upload-result', allocation)
    if started is not None and (started.get('operation') != 'apple-upload'
            or started.get('manifestSha256') != digest or any(started.get(k) != manifest.get(k)
                for k in ('platform', 'applicationId', 'profile', 'version', 'build', 'format'))):
        raise ValueError('Private Beta upload intent differs')
    if finished is not None and (started is None or finished.get('intent') != started
            or finished.get('result', {}).get('status') != 'uploaded_processing_unverified'):
        raise ValueError('Private Beta upload result differs')
    record = dict(source=manifest['source'], manifestSha256=digest, profile='beta',
                  version=manifest['version'], build=manifest['build'],
                  runId=int(os.environ['GITHUB_RUN_ID']), attempt=int(os.environ['GITHUB_RUN_ATTEMPT']),
                  uploadState=('uploaded_processing_unverified' if finished is not None else
                               'unknown_reconcile_with_apple' if started is not None else 'not_started'))
    path = Path(os.environ['RUNNER_TEMP'])/f"aegis-private-beta-{record['runId']}-{record['attempt']}.json"
    with path.open('x') as out:
        json.dump(record, out, indent=2)
    output('receipt_path', path)
    print(json.dumps(record))


def cleanup_private_beta():
    require_private_beta_upload()
    root = directory()
    if root.is_symlink() or root.resolve() != root:
        raise ValueError('Refuse to clean an aliased private Beta directory')
    if root.exists():
        shutil.rmtree(root)


def receipt():
    sha, tree = source()
    digest = transport.digest(directory()/'ios-manifest.json')
    expected = os.environ.get('RELEASE_MANIFEST_SHA256') or digest
    # Export already validates deliverable files; work/archive directories are not delivery members.
    manifest = json.loads((directory()/'ios-manifest.json').read_text())
    origin = json.loads((directory()/'package-origin.json').read_text())
    if (digest != expected or manifest.get('source') != dict(sha=sha, tree=tree, dirty=False) or
            manifest.get('repository') != 'gcsagroup/aegis-browser' or manifest.get('platform') != 'ios' or
            any(manifest.get(key) != os.environ['RELEASE_'+key.upper()] for key in ['profile', 'version', 'build']) or
            origin.get('repository') != os.environ['GITHUB_REPOSITORY'] or origin.get('sourceSha') != sha or
            origin.get('sourceTree') != tree or origin.get('manifestSha256') != digest or
            origin.get('runIdLocal') != os.environ['RELEASE_RUN_ID']):
        raise ValueError('Cannot issue a receipt for mismatched package identity')
    package_run = str(origin['runId'])
    current, attempt = os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT']
    if os.environ['RELEASE_STAGE'] == 'package':
        if package_run != current or origin.get('attempt') != int(attempt):
            raise ValueError('Package receipt differs from this producer attempt')
    elif package_run != os.environ['PACKAGE_RUN_ID']:
        raise ValueError('Store receipt differs from original package producer')
    value = receipt_codec.encode(manifest['profile'], manifest['version'], manifest['build'], package_run, current, attempt, digest, uploaded=(directory()/'apple-upload-result.json').is_file())
    output('delivery_receipt', value)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'### iOS Delivery receipt\n\n{manifest["version"]} ({manifest["build"]}) · {manifest["profile"]}\n\n'
                      'After the package and seal-package jobs succeed, retain this original receipt. The Full workflow verifies the sealed producer before recovery. Keep **Product** on **Auto**.\n\n'
                      f'```text\n{value}\n```\n\n'
                      'Keep the original receipt and use the latest successful receipt for each next step. Upload, processing, metadata/compliance and distribution remain explicit operations.\n\n'
                      'This receipt pins package identity. Admin, source, integrity and replay checks run separately.\n')
    print(value)  # Same non-secret pin in job logs for CLI operators and evidence readback.


def matches_stage_title(title, stage, digest):
    prefix = 'iOS Delivery '
    if title == f'{prefix}{stage} {digest}':
        return True  # Legacy run names remain part of the replay inventory.
    if not isinstance(title, str) or not title.startswith(prefix):
        return False
    operation, separator, token = title[len(prefix):].rpartition(' ')
    if not separator:
        return False
    try:
        operation = receipt_codec.canonical(operation, receipt_codec.OPERATION_LABELS)
        selected = 'distribute' if operation in {'distribute-internal', 'distribute-external'} else operation
        if selected != stage:
            return False
        return receipt_codec.decode(token)['manifest_sha256'] == digest
    except ValueError:
        return False


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
    digest = os.environ['RELEASE_MANIFEST_SHA256']
    for workflow in ['ios-delivery.yml', 'ios-delivery-full.yml']:
        for page in range(1, 21):
            rows = api(f'actions/workflows/{workflow}/runs?per_page=100&page={page}')['workflow_runs']
            for row in rows:
                if row['id'] == current or not matches_stage_title(row.get('display_title'), stage, digest):
                    continue
                if row['id'] != state_run and not unstarted_store_run(row):
                    raise ValueError('Earlier identical stage run exists outside imported state; read back and reconcile before retry')
            if len(rows) < 100:
                break
        else:
            raise ValueError('Cannot prove complete prior-stage inventory')


def check_new_upload_runs():
    current = int(os.environ['GITHUB_RUN_ID'])
    if int(os.environ['GITHUB_RUN_ATTEMPT']) != 1:
        raise ValueError('New-package upload cannot be rerun; reconcile the original run')
    version, build = os.environ['RELEASE_VERSION'], os.environ['RELEASE_BUILD']
    for workflow in ['ios-delivery.yml', 'ios-delivery-full.yml']:
        for page in range(1, 21):
            rows = api(f'actions/workflows/{workflow}/runs?per_page=100&page={page}')['workflow_runs']
            for row in rows:
                if row['id'] == current:
                    continue
                title = row.get('display_title')
                if not isinstance(title, str) or not title.startswith('iOS Delivery '):
                    continue
                operation, _, identity = title[len('iOS Delivery '):].rpartition(' ')
                try:
                    selected = receipt_codec.canonical(operation, receipt_codec.OPERATION_LABELS)
                    if selected == 'package-upload':
                        matches = identity == f'{version}({build})'
                    elif selected == 'upload':
                        pinned = receipt_codec.decode(identity)
                        matches = (pinned['version'], pinned['build']) == (version, build)
                    else:
                        matches = False
                except ValueError:
                    matches = False
                if matches and not unstarted_store_run(row):
                    raise ValueError('Earlier upload for this version/build may have executed; reconcile it before rebuilding')
            if len(rows) < 100:
                break
        else:
            raise ValueError('Cannot prove complete new-package upload inventory')


def unstarted_store_run(row):
    """All attempts must conclusively lack any executed store job, not just the last."""
    record = api(f'actions/runs/{row["id"]}')
    attempts = record.get('run_attempt')
    if (record.get('id') != row['id'] or record.get('path') not in {'.github/workflows/ios-delivery.yml', '.github/workflows/ios-delivery-full.yml'} or
            not isinstance(record.get('head_sha'), str) or len(record['head_sha']) != 40 or record.get('status') != 'completed' or
            type(attempts) is not int or not 1 <= attempts <= 20):
        return False
    for attempt in range(1, attempts+1):
        inventory = api(f'actions/runs/{row["id"]}/attempts/{attempt}/jobs?per_page=100')
        jobs = inventory.get('jobs')
        if not isinstance(jobs, list) or inventory.get('total_count') != len(jobs) or len(jobs) > 100:
            return False
        for job in jobs:
            if job.get('run_id') != record['id'] or job.get('run_attempt') != attempt or job.get('head_sha') != record['head_sha']:
                return False
            name = str(job.get('name', '')).rsplit(' / ', 1)[-1]
            if name in {'store', 'upload-new'} and not (job.get('status') == 'completed' and job.get('conclusion') == 'skipped' and job.get('steps') == []):
                return False
            if name == 'ios-package' and any(step.get('name') == 'Upload private Beta directly to TestFlight'
                    and step.get('conclusion') != 'skipped' for step in job.get('steps', [])):
                return False
    final = api(f'actions/runs/{row["id"]}')
    return final.get('run_attempt') == attempts and final.get('status') == 'completed' and final.get('head_sha') == record['head_sha']


def import_package():
    sha, tree = source()
    repository = os.environ['GITHUB_REPOSITORY']
    package_run = int(os.environ['PACKAGE_RUN_ID'])
    state_run = int(os.environ.get('UPLOAD_RUN_ID') or package_run)
    record = api(f'actions/runs/{state_run}')
    # Explicit attempt prevents a successful historical attempt masking a later rerun.
    attempt = int(os.environ['SOURCE_ATTEMPT'])
    sealed = verify_package_run(record, repository, sha, state_run, attempt) if state_run == package_run else None
    if state_run != package_run:
        transport.verify_run(record, repository, sha, state_run, attempt)
    if state_run == package_run and record['path'] not in transport.PACKAGE_WORKFLOWS:
        raise ValueError('Original package run is not an iOS package workflow')
    artifacts = api(f'actions/runs/{state_run}/artifacts?per_page=100')
    expected_name = f'ios-delivery-{state_run}-{attempt}'
    rows = [a for a in artifacts['artifacts'] if
            ((sealed is None and a['name'] == expected_name) or
             (sealed is not None and a['id'] == sealed['artifact_id']
              and a.get('digest') == sealed['artifact_digest'] and a['name'] == sealed['artifact_name']))
            and not a['expired']]
    if artifacts['total_count'] > 100 or len(rows) != 1:
        raise ValueError('Exact delivery artifact unavailable')
    with tempfile.TemporaryDirectory(prefix='ios-download-') as tmp:
        archive = Path(tmp)/'artifact.zip'
        # gh follows the authenticated Actions redirect; default JSON Accept is required.
        with archive.open('xb') as f:
            result = subprocess.run(['gh', 'api', '-H', 'Accept: application/vnd.github+json', f'repos/{repository}/actions/artifacts/{rows[0]["id"]}/zip'], stdout=f, stderr=subprocess.PIPE)
        if result.returncode:
            raise ValueError('Artifact download failed')
        if sealed is not None and 'sha256:' + transport.digest(archive) != sealed['artifact_digest']:
            raise ValueError('Sealed platform artifact bytes differ')
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
        verify_package_run(original, repository, sha, package_run, int(origin['attempt']))
        if original['path'] not in transport.PACKAGE_WORKFLOWS or origin['repository'] != repository or origin['runId'] != package_run or origin['sourceSha'] != sha or origin['sourceTree'] != tree or origin['manifestSha256'] != digest:
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


def verify_package_run(record, repository, sha, run_id, attempt):
    if record.get('conclusion') == 'success' and record.get('run_attempt') == attempt:
        transport.verify_run(record, repository, sha, run_id, attempt)
        return None
    store = durable.records()
    sealed = store.read('package', durable.key(os.environ['RELEASE_VERSION'], os.environ['RELEASE_BUILD']))
    if (sealed is None or repository != durable.REPOSITORY
            or sealed['origin']['runId'] != run_id or sealed['origin']['attempt'] != attempt
            or sealed['origin']['sourceSha'] != sha
            or sealed['origin']['manifestSha256'] != os.environ['RELEASE_MANIFEST_SHA256']
            or sealed['profile'] != os.environ['RELEASE_PROFILE']):
        raise ValueError('Unsuccessful run has no exact sealed package')
    job = durable.producer(store.api, run_id, attempt, sha)
    if job['id'] != sealed['package_job_id']:
        raise ValueError('Sealed package job differs')
    return sealed


def stage():
    if os.environ.get('IMPORT_KIND') == 'new-upload':
        check_new_upload_runs()
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
    {'package': package, 'export': export, 'import': import_package, 'stage': stage, 'receipt': receipt,
     'check-new-upload': check_new_upload_runs, 'private-beta-upload': private_beta_upload,
     'private-beta-evidence': private_beta_evidence, 'cleanup-private-beta': cleanup_private_beta}[sys.argv[1]]()
