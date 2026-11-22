#!/usr/bin/env python3
"""Prepare and publish source-bound, immutable public Android GitHub Releases."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote
import zipfile


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


archive = module('android_package_archive', 'android_package_archive.py')
records = module('android_product_delivery', 'android_product_delivery.py')
play = module('android_play', 'android-play.py')
verifier = module('verify_aab', 'verify-aab.py')

REPOSITORY = archive.REPOSITORY
REPOSITORY_ID = 1348409663
APPLICATION_ID = archive.APPLICATION_ID
PRODUCTION_ENVIRONMENT = 'aegis-android-github-production'
TAG_RULESET = '.github/android-public-release-tag-ruleset.json'
PREFIXES = {'.github/workflows/android-delivery.yml': 'delivery / ',
            '.github/workflows/android-delivery-full.yml': 'delivery / '}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return archive.sha256(path)


def is_id(value):
    return type(value) is int and value > 0


def is_sha(value, length=40):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{%d}' % length, value) is not None


def extract_verified_status_archive(bundle, destination, expected_digest):
    bundle, destination = Path(bundle), Path(destination)
    require(is_sha(expected_digest, 64) and bundle.is_file() and not bundle.is_symlink(),
            'Play status artifact digest or archive is invalid')
    require(sha256(bundle) == expected_digest, 'Downloaded Play status artifact digest differs')
    require(not destination.exists() and not destination.is_symlink(), 'Refuse to overwrite Play status evidence')
    with zipfile.ZipFile(bundle) as zipped:
        rows = zipped.infolist()
        require(len(rows) == 1 and rows[0].filename == 'status.json' and not rows[0].is_dir()
                and not stat.S_ISLNK(rows[0].external_attr >> 16) and rows[0].file_size <= 4 * 1024 * 1024,
                'Play status artifact must contain exactly one bounded status.json file')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipped.open(rows[0]) as source, destination.open('xb') as target:
            shutil.copyfileobj(source, target)


def extract_verified_package_archive(bundle, destination, expected_digest):
    bundle, destination = Path(bundle), Path(destination)
    require(is_sha(expected_digest, 64) and bundle.is_file() and not bundle.is_symlink(),
            'Package artifact digest or archive is invalid')
    require(sha256(bundle) == expected_digest, 'Downloaded package artifact digest differs')
    require(not destination.exists() and not destination.is_symlink(), 'Refuse to overwrite the sealed package archive')
    with zipfile.ZipFile(bundle) as zipped:
        rows = zipped.infolist()
        require(len(rows) == 1 and rows[0].filename == 'package.zip' and not rows[0].is_dir()
                and not stat.S_ISLNK(rows[0].external_attr >> 16) and rows[0].file_size <= archive.MAX_MEMBER,
                'Sealed package artifact must contain exactly one bounded package.zip file')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipped.open(rows[0]) as source, destination.open('xb') as target:
            shutil.copyfileobj(source, target)


def _download_actions_artifact_zip(artifact_id, destination):
    with Path(destination).open('xb') as output:
        result = subprocess.run(['gh', 'api', '-H', 'Accept: application/vnd.github+json',
                                 f'repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip'],
                                stdout=output, stderr=subprocess.PIPE, timeout=120)
    require(result.returncode == 0, 'Workflow artifact download failed')


def _require_fresh_observation(value, max_age_seconds=1800):
    require(isinstance(value, str), 'Play observation timestamp is missing')
    try:
        observed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as error:
        raise ValueError('Play observation timestamp is invalid') from error
    require(observed.tzinfo is not None, 'Play observation timestamp must include a timezone')
    age = (datetime.now(timezone.utc) - observed.astimezone(timezone.utc)).total_seconds()
    require(-120 <= age <= max_age_seconds, 'Play VALID status is stale; run Release Wait again before publication')


def _run_identity(run, expected_id, expected_sha, path, *, completed=True):
    return (run.get('id') == expected_id and run.get('run_attempt') == 1
            and run.get('head_sha') == expected_sha and run.get('head_branch') == 'main'
            and (not completed or (run.get('status') == 'completed' and run.get('conclusion') == 'success'))
            and run.get('event') == 'workflow_dispatch' and run.get('path') == path
            and run.get('repository', {}).get('id') == REPOSITORY_ID
            and run.get('repository', {}).get('full_name') == REPOSITORY
            and run.get('head_repository', {}).get('id') == REPOSITORY_ID
            and run.get('head_repository', {}).get('full_name') == REPOSITORY)


def _successful_job(run, name):
    jobs = run.get('jobs')
    require(isinstance(jobs, list), 'Incomplete workflow job evidence')
    matches = [job for job in jobs if job.get('name') == name]
    require(len(matches) == 1, 'Required job is missing or ambiguous: ' + name)
    job = matches[0]
    require(is_id(job.get('id')) and job.get('run_id') == run.get('id')
            and job.get('run_attempt') == 1 and job.get('head_sha') == run.get('head_sha')
            and job.get('status') == 'completed' and job.get('conclusion') == 'success',
            'Required job did not succeed on the exact source/attempt: ' + name)
    return job


def _package_job(run, run_id, sha, *, same_run=False):
    path = run.get('path')
    # A subsequent store or draft job can fail after an immutable package is
    # recorded. Its own successful job is the authoritative producer.
    require(path in PREFIXES and _run_identity(run, run_id, sha, path, completed=False)
            and (same_run or (run.get('status') == 'completed' and run.get('conclusion') in {'success', 'failure'})),
            'Package producer run identity/source differs')
    return _successful_job(run, PREFIXES[path] + 'package')


def verify_play_upload(plan, origin, intent, terminal, upload_run):
    require(isinstance(intent, dict) and isinstance(terminal, dict), 'Permanent Play upload records are incomplete')
    track = (intent.get('parameters') or {}).get('track')
    expected = play.draft_intent(plan['version'], plan['build'], plan['profile'], origin['manifestSha256'], track)
    result = terminal.get('result', {})
    run_id = terminal.get('uploadRunId')
    path = upload_run.get('path')
    require(intent == expected and terminal.get('intent') == intent and result.get('status') == 'uploaded_draft'
            and result.get('packageName') == APPLICATION_ID and result.get('track') == track
            and result.get('releaseStatus') == 'draft' and result.get('versionCode') == int(plan['build']),
            'Permanent upload intent/result does not identify this exact draft package')
    require(is_id(run_id) and terminal.get('uploadRunAttempt') == 1 and path in PREFIXES
            and _run_identity(upload_run, run_id, origin['sourceSha'], path),
            'Play upload run differs from the approved package source')
    _successful_job(upload_run, PREFIXES[path] + 'store')
    return run_id


def _exact_artifact(value, artifact_id, name, digest):
    return (is_id(artifact_id) and isinstance(digest, str) and re.fullmatch(r'sha256:[0-9a-f]{64}', digest) is not None
            and value.get('id') == artifact_id and value.get('name') == name
            and value.get('expired') is False and value.get('digest') == digest)


def validate_delivery_evidence(evidence, release_type, publication):
    """Validate the sealed Release package, Play draft, and fresh Release Wait."""
    require(release_type == 'stable' and publication in {'prerelease', 'stable'}, 'Unknown Android publication')
    version, build = evidence.get('version'), evidence.get('build')
    from_receipt = module('android_delivery_receipt', 'android-delivery-receipt.py')
    from_receipt.require_version_code(version, build)
    repo = evidence.get('repository', {})
    require(repo == {'id': REPOSITORY_ID, 'full_name': REPOSITORY, 'default_branch': 'main'},
            'Canonical repository identity/default branch differs')
    current_sha, current_tree = evidence.get('current_sha'), evidence.get('current_tree')
    require(is_sha(current_sha) and is_sha(current_tree), 'Current main source/tree identity is invalid')
    package_run = evidence.get('package_run', {})
    origin = evidence.get('package_record', {}).get('origin', {})
    source_sha, source_tree = origin.get('sourceSha'), origin.get('sourceTree')
    require((source_sha, source_tree) == (current_sha, current_tree), 'Package producer source is no longer current main')
    package_id = package_run.get('id')
    require(is_id(package_id), 'Package producer run identity is invalid')
    require(origin.get('repository') == REPOSITORY and origin.get('runId') == package_id
            and origin.get('attempt') == 1 and origin.get('sourceSha') == source_sha
            and origin.get('sourceTree') == source_tree and origin.get('runIdLocal') == f'android-gh-{package_id}-1',
            'Package origin is not bound to current main and producer run')
    require(is_sha(origin.get('manifestSha256'), 64), 'Package manifest digest is invalid')
    producer = _package_job(package_run, package_id, source_sha)
    package_record = evidence.get('package_record', {})
    require(package_record.get('profile') == 'release' and package_record.get('version') == version
            and package_record.get('build') == build and package_record.get('package_job_id') == producer['id']
            and package_record.get('artifact_name') == f'android-package-{package_id}-1'
            and _exact_artifact(evidence.get('package_artifact', {}), package_record.get('artifact_id'),
                                package_record.get('artifact_name'), package_record.get('artifact_digest')),
            'Immutable package artifact record differs from the successful producer')
    manifest = evidence.get('manifest', {})
    aab_name, symbols_name = archive.asset_names(version, build)
    require(evidence.get('manifest_sha256') == origin.get('manifestSha256')
            and manifest.get('repository') == REPOSITORY and manifest.get('platform') == 'android'
            and manifest.get('applicationId') == APPLICATION_ID and manifest.get('profile') == 'release'
            and manifest.get('version') == version and manifest.get('build') == build
            and manifest.get('source') == {'sha': source_sha, 'tree': source_tree, 'dirty': False}
            and {row.get('name') for row in manifest.get('assets', []) if isinstance(row, dict)} >= {aab_name, symbols_name},
            'Product manifest identity/source/profile differs')
    upload_id = verify_play_upload(manifest, origin, evidence.get('upload_start'),
                                   evidence.get('upload_result'), evidence.get('upload_run', {}))
    status_run = evidence.get('status_run', {})
    status_id = status_run.get('id')
    require(is_id(status_id) and status_run.get('path') in PREFIXES
            and _run_identity(status_run, status_id, current_sha, status_run.get('path')),
            'Play status run identity/source differs')
    _successful_job(status_run, PREFIXES[status_run['path']] + 'query')
    status_artifact = evidence.get('status_artifact', {})
    require(_exact_artifact(status_artifact, status_artifact.get('id'), f'android-release-status-{status_id}-1',
                            status_artifact.get('digest')) and status_artifact.get('run_id') == status_id,
            'Exact successful Play status artifact is missing or expired')
    status = evidence.get('status', {})
    remote = status.get('remote', {})
    require(status.get('platform') == 'android' and status.get('applicationId') == APPLICATION_ID
            and status.get('version') == version and status.get('build') == build
            and status.get('queryMode') == 'release-wait' and status.get('readOnly') is True
            and status.get('packageProvenanceVerified') is False
            and status.get('querySource') == {'sha': current_sha, 'tree': current_tree, 'dirty': False}
            and remote.get('packageName') == APPLICATION_ID and remote.get('versionCode') == int(build)
            and remote.get('processingState') == 'VALID' and remote.get('expired') is False
            and remote.get('uploadState') == 'COMPLETE' and is_sha(remote.get('buildIdentitySha256'), 64),
            'Play must report this exact uploaded versionCode VALID and unexpired')
    _require_fresh_observation(remote.get('observedAt'))
    return {'channel': 'stable', 'profile': 'release', 'publication': publication, 'version': version, 'build': build,
            'source': {'sha': source_sha, 'tree': source_tree}, 'manifestSha256': origin['manifestSha256'],
            'packageRunId': package_id, 'packageAttempt': 1, 'uploadRunId': upload_id, 'statusRunId': status_id,
            'playBuildIdentitySha256': remote['buildIdentitySha256'], 'playObservedAt': remote['observedAt'],
            'artifactId': package_record['artifact_id'], 'artifactDigest': package_record['artifact_digest'],
            'artifactName': package_record['artifact_name'], 'statusArtifactId': status_artifact['id'],
            'statusArtifactDigest': status_artifact['digest'], 'manifest': manifest}


def _release_tag(candidate):
    return f"android/{candidate['version']}-release.{candidate['build']}"


def build_release_plan(candidate, *, stable_release_id=None):
    publication = candidate['publication']
    version, build = candidate['version'], candidate['build']
    tag = _release_tag(candidate)
    payloads = archive.public_manifest_payloads(candidate['manifest'])
    asset_hashes = {row['name']: row['sha256'] for row in candidate['manifest']['assets']
                    if row['name'].endswith(('.aab', '.symbols.zip'))}
    asset_hashes.update({name: hashlib.sha256(content).hexdigest() for name, content in payloads.items()})
    label = 'Prerelease' if publication == 'prerelease' else 'Stable'
    core = {'schema': 'aegis-android-github-release-plan-v1', 'channel': 'stable', 'profile': 'release',
            'version': version, 'build': build, 'tag': tag, 'source': candidate['source'],
            'manifestSha256': candidate['manifestSha256'], 'packageRunId': candidate['packageRunId'],
            'packageAttempt': 1, 'uploadRunId': candidate['uploadRunId'], 'statusRunId': candidate['statusRunId'],
            'playObservedAt': candidate['playObservedAt'], 'playBuildIdentitySha256': candidate['playBuildIdentitySha256'],
            'assets': dict(sorted(asset_hashes.items())), 'prerelease': publication == 'prerelease',
            'makeLatest': False}
    release_identity = {key: value for key, value in core.items()
                        if key not in {'statusRunId', 'playObservedAt', 'prerelease', 'makeLatest'}}
    release_identity_sha = hashlib.sha256(json.dumps(release_identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    core['evidenceArtifacts'] = {'package': {'id': candidate['artifactId'], 'digest': candidate['artifactDigest']},
                                 'status': {'id': candidate['statusArtifactId'], 'digest': candidate['statusArtifactDigest']}}
    if publication == 'stable':
        require(is_id(stable_release_id), 'Stable approval requires a positive GitHub Release ID')
        core['releaseId'] = stable_release_id
    plan_sha = hashlib.sha256(json.dumps(core, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    body = ('Aegis Android public release\n\n'
            f'Channel: {label}\nSource: {candidate["source"]["sha"]}\nSource tree: {candidate["source"]["tree"]}\n'
            f'Public manifest SHA-256: {asset_hashes["android-manifest.json"]}\n'
            f'Release identity SHA-256: {release_identity_sha}\n')
    return {**core, 'name': f'Aegis Android {version} ({build}) · {label}',
            'releaseIdentitySha256': release_identity_sha, 'planSha256': plan_sha, 'body': body}


def public_asset_manifest(directory, manifest, manifest_digest):
    directory = Path(directory)
    archive.verify_package(directory, manifest['source']['sha'], manifest['source']['tree'], manifest_digest)
    expected_cert = manifest.get('details', {}).get('certificateSha256')
    actual_cert = verifier.certificate_sha256(directory / archive.asset_names(manifest['version'], manifest['build'])[0])
    require(actual_cert == expected_cert, 'AAB certificate differs from the sealed manifest')
    assets = []
    for row in manifest['assets']:
        if not row['name'].endswith(('.aab', '.symbols.zip')):
            continue
        path = directory / row['name']
        assets.append({'name': row['name'], 'size': path.stat().st_size, 'sha256': row['sha256'], 'path': str(path)})
    public = directory.parent / (directory.name + '-public-metadata')
    public.mkdir(mode=0o700)
    for name, payload in archive.public_manifest_payloads(manifest).items():
        path = public / name
        with path.open('xb') as content:
            content.write(payload)
        assets.append({'name': name, 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(), 'path': str(path)})
    require(sum(item['name'].endswith('.aab') for item in assets) == 1
            and sum(item['name'].endswith('.symbols.zip') for item in assets) == 1,
            'Public release requires exactly one AAB and one native symbols archive')
    return sorted(assets, key=lambda item: item['name'])


def _api(path, payload=None, method=None):
    command = ['gh', 'api', '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28']
    if method:
        command += ['--method', method]
    elif payload is not None:
        command += ['--method', 'POST']
    if payload is not None:
        command += ['--input', '-']
    command += ['repos/' + REPOSITORY + ('/' + path.lstrip('/') if path else '')]
    try:
        result = subprocess.run(command, input=None if payload is None else json.dumps(payload),
                                text=True, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError('GitHub request outcome unavailable; reconcile before repeating a mutation') from error
    if result.returncode:
        if re.search(r'HTTP\s+404\b', result.stderr, re.IGNORECASE):
            raise NotFoundError('GitHub resource not found')
        raise ValueError('GitHub API request failed; reconcile any mutation before repeating it')
    if not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError('GitHub API response unavailable; reconcile before repeating a mutation') from error


class NotFoundError(ValueError):
    pass


def _api_items(path, field):
    result = _api(path)
    require(isinstance(result, dict) and isinstance(result.get(field), list)
            and result.get('total_count') == len(result[field]) and len(result[field]) <= 100,
            'Incomplete GitHub API inventory: ' + path)
    return result[field]


def _api_list(path):
    rows = []
    for page in range(1, 21):
        suffix = '&' if '?' in path else '?'
        batch = _api(f'{path}{suffix}per_page=100&page={page}')
        require(isinstance(batch, list) and len(batch) <= 100, 'Invalid GitHub API list: ' + path)
        rows.extend(batch)
        if len(batch) < 100:
            return rows
    raise ValueError('Incomplete GitHub API pagination: ' + path)


def _get_run(run_id):
    return _api(f'actions/runs/{run_id}/attempts/1')


def _get_jobs(run_id):
    return _api_items(f'actions/runs/{run_id}/attempts/1/jobs?per_page=100', 'jobs')


def load_upload_run(record):
    run_id = record.get('uploadRunId') if isinstance(record, dict) else None
    require(is_id(run_id) and record.get('uploadRunAttempt') == 1, 'Successful first-attempt Play upload is required')
    run = _get_run(run_id)
    run['jobs'] = _get_jobs(run_id)
    return run


def _get_artifact(run_id, artifact_id, name):
    rows = _api_items(f'actions/runs/{run_id}/artifacts?per_page=100', 'artifacts')
    found = [row for row in rows if row.get('id') == artifact_id and row.get('name') == name]
    require(len(found) == 1, 'Exact immutable workflow artifact is missing or ambiguous: ' + name)
    row = found[0]
    require(row.get('expired') is False and isinstance(row.get('digest'), str)
            and re.fullmatch(r'sha256:[0-9a-f]{64}', row['digest']),
            'Workflow artifact is expired or has no verified digest: ' + name)
    return {**row, 'run_id': run_id}


def _current_repository():
    repo = _api('')
    require(repo.get('id') == REPOSITORY_ID and repo.get('full_name') == REPOSITORY
            and repo.get('default_branch') == 'main', 'Canonical upstream repository identity changed')
    ref = _api('git/ref/heads/main')
    sha = ref.get('object', {}).get('sha')
    require(is_sha(sha), 'Current main ref is unavailable')
    tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    require(head == sha and is_sha(tree), 'Checkout must equal current upstream main')
    return {'id': REPOSITORY_ID, 'full_name': REPOSITORY, 'default_branch': 'main'}, sha, tree


def _store():
    return records.Records(records.GitHub(REPOSITORY), REPOSITORY_ID, APPLICATION_ID)


def locate_package(version, build):
    module('android_delivery_receipt', 'android-delivery-receipt.py').require_version_code(version, build)
    payload = _store().read('package', records.allocation(APPLICATION_ID, version, build))
    require(isinstance(payload, dict) and payload.get('profile') == 'release'
            and payload.get('version') == version and payload.get('build') == build,
            'No permanent Release package record exists for this versionCode')
    origin = payload.get('origin', {})
    run_id, attempt = origin.get('runId'), origin.get('attempt')
    require(is_id(run_id) and attempt == 1, 'Only first-attempt package runs are admitted')
    artifact = _get_artifact(run_id, payload.get('artifact_id'), payload.get('artifact_name'))
    require(artifact.get('digest') == payload.get('artifact_digest'), 'Package artifact digest differs from the permanent record')
    return {'package_run_id': run_id, 'package_attempt': attempt, 'package_artifact_id': payload.get('artifact_id'),
            'package_artifact_name': payload.get('artifact_name'), 'package_artifact_digest': payload['artifact_digest'],
            'source_sha': origin['sourceSha'], 'source_tree': origin['sourceTree'],
            'manifest_sha256': origin['manifestSha256']}


def download_package_artifact(run_id, artifact_id, destination, *, expected_digest=None):
    artifact = _get_artifact(run_id, artifact_id, f'android-package-{run_id}-1')
    require(expected_digest is None or artifact['digest'] == expected_digest,
            'Package artifact digest differs from the permanent record')
    with tempfile.TemporaryDirectory(prefix='aegis-android-package-') as temp:
        bundle = Path(temp) / 'package-artifact.zip'
        _download_actions_artifact_zip(artifact_id, bundle)
        extract_verified_package_archive(bundle, destination, artifact['digest'].removeprefix('sha256:'))


def download_status_artifact(status_run_id, artifact_id, destination):
    artifact = _get_artifact(status_run_id, artifact_id, f'android-release-status-{status_run_id}-1')
    with tempfile.TemporaryDirectory(prefix='aegis-play-status-') as temp:
        bundle = Path(temp) / 'status-artifact.zip'
        _download_actions_artifact_zip(artifact_id, bundle)
        extract_verified_status_archive(bundle, destination, artifact['digest'].removeprefix('sha256:'))
    return artifact


def extract_package(version, build, bundle, destination):
    _, current_sha, current_tree = _current_repository()
    locator = locate_package(version, build)
    require((locator['source_sha'], locator['source_tree']) == (current_sha, current_tree),
            'Package producer source is no longer current main')
    run_id = locator['package_run_id']
    producer = _get_run(run_id)
    producer['jobs'] = _get_jobs(run_id)
    _package_job(producer, run_id, locator['source_sha'])
    archive.extract_flat(Path(bundle), Path(destination))
    manifest = archive.verify_package(destination, locator['source_sha'], locator['source_tree'], locator['manifest_sha256'])
    require(manifest.get('version') == version and manifest.get('build') == build and manifest.get('profile') == 'release',
            'Extracted package identity differs from the permanent record')


def _collect_evidence(version, build, release_type, publication, status_run_id, package_dir, status_artifact_id):
    repo, current_sha, current_tree = _current_repository()
    locator = locate_package(version, build)
    package_run = _get_run(locator['package_run_id'])
    package_run['jobs'] = _get_jobs(locator['package_run_id'])
    status_run_id = int(status_run_id)
    status_run = _get_run(status_run_id)
    status_run['jobs'] = _get_jobs(status_run_id)
    store = _store()
    key = records.allocation(APPLICATION_ID, version, build)
    package_record = store.read('package', key)
    upload_start = store.read('upload-start', key)
    upload_result = store.read('upload-result', key)
    require(package_record is not None and upload_start is not None and upload_result is not None,
            'Permanent package/upload records are incomplete')
    upload_run = load_upload_run(upload_result)
    package_artifact = _get_artifact(locator['package_run_id'], locator['package_artifact_id'], locator['package_artifact_name'])
    with tempfile.TemporaryDirectory(prefix='aegis-android-evidence-') as temp:
        status_path = Path(temp) / 'status.json'
        status_artifact = download_status_artifact(status_run_id, status_artifact_id, status_path)
        status = json.loads(status_path.read_text())
    package_dir = Path(package_dir)
    origin = json.loads((package_dir / 'package-origin.json').read_text())
    require(origin == package_record.get('origin'), 'Downloaded package origin differs from the permanent record')
    manifest = archive.verify_package(package_dir, origin['sourceSha'], origin['sourceTree'], origin['manifestSha256'])
    evidence = {'repository': repo, 'current_sha': current_sha, 'current_tree': current_tree,
                'version': version, 'build': build, 'package_run': package_run, 'package_record': package_record,
                'package_artifact': package_artifact, 'upload_start': upload_start, 'upload_result': upload_result,
                'upload_run': upload_run,
                'manifest': manifest, 'manifest_sha256': origin['manifestSha256'], 'status_run': status_run,
                'status_artifact': status_artifact, 'status': status}
    candidate = validate_delivery_evidence(evidence, release_type, publication)
    assets = public_asset_manifest(package_dir, manifest, origin['manifestSha256'])
    return candidate, assets


def _write_plan(candidate, assets, path):
    release_id = None
    if candidate['publication'] == 'stable':
        release_id = _public_release_for_promotion(_release_tag(candidate))['id']
    plan = build_release_plan(candidate, stable_release_id=release_id)
    require({asset['name']: asset['sha256'] for asset in assets} == plan['assets'], 'Public asset inventory differs from the plan')
    if path:
        Path(path).write_text(json.dumps(plan, indent=2, sort_keys=True) + '\n')
    outputs = os.environ.get('GITHUB_OUTPUT')
    if outputs:
        with open(outputs, 'a') as output:
            output.write(f"plan_sha256={plan['planSha256']}\n")
            output.write(f"tag={plan['tag']}\n")
            output.write(f"package_run_id={plan['packageRunId']}\n")
            output.write(f"status_run_id={plan['statusRunId']}\n")
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        release_id_line = f"- GitHub Release ID: `{plan['releaseId']}`\n" if not plan['prerelease'] else ''
        with open(summary, 'a') as output:
            output.write(f"## Android GitHub Release preview\n\n- Channel: {plan['channel']}\n- Publication: "
                         f"{'prerelease' if plan['prerelease'] else 'stable'}\n- Tag: `{plan['tag']}`\n"
                         f"{release_id_line}- Source: `{plan['source']['sha']}`\n- Plan SHA-256: `{plan['planSha256']}`\n\n"
                         f"### Proposed release notes\n\n{plan['body']}\n")
            for asset in assets:
                output.write(f"| `{asset['name']}` | {asset['size']} | `{asset['sha256']}` |\n")
    return plan


def _verify_tag_ruleset():
    desired = json.loads((Path(__file__).resolve().parents[2] / TAG_RULESET).read_text())
    rows = _api_list('rulesets?includes_parents=true')
    matches = [row for row in rows if row.get('name') == desired['name']]
    require(len(matches) == 1 and is_id(matches[0].get('id')), 'Unique public tag ruleset is required')
    live = _api('rulesets/' + str(matches[0]['id']))
    require(live.get('id') == matches[0]['id'] and live.get('name') == desired['name']
            and live.get('target') == desired['target'] and live.get('enforcement') == 'active'
            and live.get('conditions') == desired['conditions']
            and ('bypass_actors' not in live or live['bypass_actors'] == desired['bypass_actors'])
            and sorted(rule.get('type') for rule in live.get('rules', [])) == ['deletion', 'update'],
            'Public release tag ruleset must protect update/deletion and allow creation')


def _release_by_tag(tag, *, include_drafts=True):
    try:
        return _api('releases/tags/' + quote(tag, safe=''))
    except NotFoundError:
        if not include_drafts:
            return None
        drafts = [row for row in _api_list('releases') if row.get('tag_name') == tag and row.get('draft') is True]
        require(len(drafts) <= 1, 'Multiple drafts exist for this release tag')
        return drafts[0] if drafts else None


def _public_release_for_promotion(tag):
    release = _release_by_tag(tag, include_drafts=False)
    require(release is not None and is_id(release.get('id')) and release.get('tag_name') == tag
            and release.get('draft') is False and type(release.get('prerelease')) is bool,
            'Stable promotion requires the public prerelease or its promoted release')
    return release


def _read_release_by_id(plan, release_id):
    fresh = _api(f'releases/{release_id}')
    require(is_id(fresh.get('id')) and fresh['id'] == release_id and fresh.get('tag_name') == plan['tag'],
            'Release ID or tag changed before publication')
    return fresh


def require_candidate_tag_source(tag, source_sha):
    require(is_sha(source_sha) and isinstance(tag, str) and tag.startswith('candidate/android/'),
            'Candidate draft needs an exact tag and source')
    commit = _api('commits/' + quote('refs/tags/' + tag, safe=''))
    require(commit.get('sha') == source_sha, 'Candidate tag no longer points at this source')


def _tag_target(tag):
    try:
        ref = _api('git/ref/tags/' + quote(tag, safe=''))
    except NotFoundError:
        return None
    obj = ref.get('object', {})
    require(obj.get('type') == 'tag' and is_sha(obj.get('sha')), 'Existing release tag must be annotated and immutable')
    annotated = _api('git/tags/' + obj['sha'])
    target = annotated.get('object', {})
    return {'tag_sha': obj['sha'], 'target_sha': target.get('sha'), 'message': annotated.get('message'),
            'object_type': target.get('type')}


def _expected_tag_message(plan):
    return (f"Aegis Android GitHub Release\n\nRelease identity SHA-256: {plan['releaseIdentitySha256']}\n"
            f"Source: {plan['source']['sha']}\n")


def _verify_release_metadata(plan, release):
    require(release.get('tag_name') == plan['tag'] and release.get('name') == plan['name']
            and release.get('body') == plan['body'] and type(release.get('draft')) is bool
            and release.get('prerelease') is plan['prerelease'],
            'Existing release metadata conflicts with the exact plan')


def _verify_release_tag(plan, tag):
    tag_state = _tag_target(tag)
    require(tag_state is not None and tag_state['target_sha'] == plan['source']['sha']
            and tag_state['object_type'] == 'commit' and tag_state['message'] == _expected_tag_message(plan),
            'Existing release tag conflicts with the exact source/plan')


def _verify_release_assets(plan, release, *, complete=False):
    expected = plan['assets']
    found = release.get('assets', [])
    require(isinstance(found, list) and all(isinstance(item, dict) for item in found),
            'Existing release asset inventory is invalid')
    names = {item.get('name') for item in found}
    require(len(names) == len(found) and names <= set(expected),
            'Existing release asset inventory conflicts with the exact plan')
    if complete or release['draft'] is False:
        require(names == set(expected), 'Release asset inventory is incomplete')
    for item in found:
        require(item.get('state') == 'uploaded' and item.get('digest') == 'sha256:' + expected[item['name']],
                'Existing release asset digest conflicts with the exact plan: ' + item['name'])


def _verify_existing_release(plan, release, tag):
    _verify_release_metadata(plan, release)
    _verify_release_tag(plan, tag)
    _verify_release_assets(plan, release)


def _verify_release_is_off_latest(release):
    try:
        latest = _api('releases/latest')
    except NotFoundError:
        return
    require(latest.get('id') != release.get('id'), 'Android release is occupying the repository Latest release')


def _create_tag(plan, api):
    tag = plan['tag']
    current = _tag_target(tag)
    if current:
        require(current['target_sha'] == plan['source']['sha'] and current['object_type'] == 'commit'
                and current['message'] == _expected_tag_message(plan), 'Conflicting tag exists; no mutation attempted')
        return
    payload = {'tag': tag, 'message': _expected_tag_message(plan), 'object': plan['source']['sha'], 'type': 'commit',
               'tagger': {'name': 'GCSA Android Release Bot', 'email': 'github-actions[bot]@users.noreply.github.com',
                          'date': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}}
    _assert_release_write_allowed(plan)
    annotated = api.request('git/tags', payload)
    tag_sha = annotated.get('sha')
    require(is_sha(tag_sha), 'Annotated tag creation outcome is unknown; reconcile read-only')
    _assert_release_write_allowed(plan)
    target = api.request('git/refs', {'ref': 'refs/tags/' + tag, 'sha': tag_sha})
    require(target.get('ref') == 'refs/tags/' + tag and target.get('object', {}).get('sha') == tag_sha,
            'Tag ref creation outcome is unknown; reconcile read-only')
    current = _tag_target(tag)
    require(current and current['target_sha'] == plan['source']['sha'] and current['message'] == _expected_tag_message(plan),
            'Created tag readback differs; no release mutation is authorized')


def _production_environment_config():
    env = _api('environments/' + PRODUCTION_ENVIRONMENT)
    rules = env.get('protection_rules', [])
    reviewer_rules = [rule for rule in rules if rule.get('type') == 'required_reviewers']
    reviewers = set()
    for rule in reviewer_rules:
        for row in rule.get('reviewers', []):
            reviewer = row.get('reviewer', {})
            require(row.get('type') == 'User' and isinstance(reviewer, dict) and is_id(reviewer.get('id'))
                    and reviewer['id'] not in reviewers, 'Production Environment requires named User reviewers only')
            reviewers.add(reviewer['id'])
    raw_allowed = os.environ.get('AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS', '').split(',')
    require(raw_allowed and all(re.fullmatch(r'[1-9][0-9]{0,15}', value) for value in raw_allowed),
            'Stable Admin reviewer allowlist is missing or malformed')
    allowed = {int(value) for value in raw_allowed}
    require(len(allowed) == len(raw_allowed) and len(reviewer_rules) == 1 and reviewers and allowed and reviewers <= allowed
            and env.get('can_admins_bypass') is False
            and (env.get('deployment_branch_policy') or {}).get('protected_branches') is True,
            'Stable environment must require an allowlisted Admin, disable admin bypass, and restrict protected branches')
    admins = []
    for page in range(1, 21):
        batch = _api(f'collaborators?affiliation=all&permission=admin&per_page=100&page={page}')
        require(isinstance(batch, list) and len(batch) <= 100, 'Invalid current Admin inventory')
        admins.extend(user for user in batch if user.get('permissions', {}).get('admin') is True)
        if len(batch) < 100:
            break
    else:
        raise ValueError('Incomplete current Admin inventory')
    current_admins = {user['id']: user['login'].lower() for user in admins
                      if is_id(user.get('id')) and isinstance(user.get('login'), str)}
    require(reviewers <= set(current_admins), 'Production environment reviewers must all be current repository Admins')
    return env, allowed, reviewers, current_admins


def _check_approval(plan, current_run_id):
    env, allowed, reviewers, current_admins = _production_environment_config()
    approvals = _api(f'actions/runs/{current_run_id}/approvals')
    require(isinstance(approvals, list), 'Exact production deployment approval record is unavailable')
    expected_comment = 'publish ' + plan['planSha256']
    matching = []
    for approval in approvals:
        environments = approval.get('environments', [])
        exact_environment = any(row.get('name') == PRODUCTION_ENVIRONMENT and row.get('id') == env.get('id')
                                for row in environments)
        if approval.get('state') == 'approved' and exact_environment and approval.get('comment') == expected_comment:
            matching.append(approval.get('user', {}))
    require(len(matching) == 1, 'Stable publish requires one approval with the exact plan digest')
    reviewer = matching[0]
    require(is_id(reviewer.get('id')) and reviewer['id'] in reviewers and reviewer['id'] in allowed
            and current_admins.get(reviewer['id']) == reviewer.get('login', '').lower(),
            'Stable approval must come from an allowlisted current Environment reviewer and repository Admin')


def preview_release(plan):
    _verify_tag_ruleset()
    existing_tag = _tag_target(plan['tag'])
    if not plan['prerelease']:
        release = _public_release_for_promotion(plan['tag'])
        require(release['id'] == plan['releaseId'], 'GitHub Release ID changed during stable preview')
        if release['prerelease']:
            _verify_release_tag(plan, plan['tag'])
            _verify_release_assets(plan, release)
        else:
            _verify_existing_release(plan, release, plan['tag'])
        _production_environment_config()
    else:
        release = _release_by_tag(plan['tag'], include_drafts=False)
        if release is not None:
            _verify_existing_release(plan, release, plan['tag'])
        elif existing_tag is not None:
            require(existing_tag['target_sha'] == plan['source']['sha'] and existing_tag['object_type'] == 'commit'
                    and existing_tag['message'] == _expected_tag_message(plan),
                    'Conflicting tag exists; release preview is blocked')
    return {'tag': plan['tag'], 'existingTag': existing_tag is not None, 'existingRelease': release is not None,
            'draftStatus': 'visible-public-release' if release else 'unverified',
            'productionEnvironmentVerified': not plan['prerelease']}


def _assert_current_release_source(plan):
    _, sha, tree = _current_repository()
    require(plan['source'] == {'sha': sha, 'tree': tree}, 'Publication source is no longer current main')


def _assert_release_write_allowed(plan):
    _assert_current_release_source(plan)
    _require_fresh_observation(plan['playObservedAt'])


def _upload_asset_once(release_id, asset):
    token = os.environ.get('GH_TOKEN')
    require(token, 'Publisher GitHub token is required')
    path = f"/repos/{REPOSITORY}/releases/{release_id}/assets?name={quote(asset['name'], safe='')}"
    with Path(asset['path']).open('rb') as content:
        connection = http.client.HTTPSConnection('uploads.github.com', timeout=120)
        try:
            connection.request('POST', path, body=content, headers={
                'Authorization': 'Bearer ' + token, 'Content-Type': 'application/octet-stream',
                'Content-Length': str(asset['size']), 'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'aegis-android-release-bot'})
            require(connection.getresponse().status == 201, 'Asset upload did not return HTTP 201')
        finally:
            connection.close()


def _promote_to_stable(plan):
    _assert_current_release_source(plan)
    release_id = plan['releaseId']
    require(is_id(release_id), 'Stable approval requires a positive GitHub Release ID')
    release = _public_release_for_promotion(plan['tag'])
    require(release['id'] == release_id, 'Public Release ID differs from the approved stable plan')
    _verify_release_tag(plan, plan['tag'])
    _verify_release_assets(plan, release)
    if release.get('prerelease') is False:
        _verify_existing_release(plan, release, plan['tag'])
        _verify_release_is_off_latest(release)
        return release
    _check_approval(plan, os.environ['GITHUB_RUN_ID'])
    _verify_release_tag(plan, plan['tag'])
    _assert_release_write_allowed(plan)
    staged = _read_release_by_id(plan, release_id)
    require(staged.get('draft') is False and staged.get('prerelease') is True,
            'Prerelease changed before promotion')
    _verify_release_assets(plan, staged)
    _api(f'releases/{release_id}', {'name': plan['name'], 'body': plan['body'], 'draft': False,
                                    'prerelease': False, 'make_latest': 'false'}, method='PATCH')
    reread = _public_release_for_promotion(plan['tag'])
    require(reread['id'] == release_id and reread['prerelease'] is False,
            'Promoted release cannot be read back')
    _verify_existing_release(plan, reread, plan['tag'])
    _verify_release_is_off_latest(reread)
    print(json.dumps({'state': 'promoted-and-verified', 'tag': plan['tag'], 'releaseId': release_id, 'url': reread.get('html_url')}))
    return reread


def publish_release(plan, assets):
    require(plan.get('planSha256') == os.environ.get('EXPECTED_PLAN_SHA256'),
            'Post-approval evidence differs from the reviewed release plan')
    _verify_tag_ruleset()
    if not plan['prerelease']:
        _check_approval(plan, os.environ['GITHUB_RUN_ID'])
        return _promote_to_stable(plan)
    _assert_current_release_source(plan)
    release = _release_by_tag(plan['tag'])
    if release is None:
        _create_tag(plan, records.GitHub(REPOSITORY))
        _assert_release_write_allowed(plan)
        release = _api('releases', {'tag_name': plan['tag'], 'target_commitish': plan['source']['sha'],
                                    'name': plan['name'], 'body': plan['body'], 'draft': True,
                                    'prerelease': True, 'make_latest': 'false'})
    _verify_existing_release(plan, release, plan['tag'])
    release_id = release.get('id')
    require(is_id(release_id), 'Exact release ID is required for staging')

    def read_draft(*, complete=False):
        _verify_release_tag(plan, plan['tag'])
        fresh = _read_release_by_id(plan, release_id)
        require(fresh.get('draft') is True, 'Exact release draft moved during staging')
        _verify_release_metadata(plan, fresh)
        _verify_release_assets(plan, fresh, complete=complete)
        return fresh

    if release['draft']:
        for asset in assets:
            _assert_release_write_allowed(plan)
            current = read_draft()
            if asset['name'] in {item['name'] for item in current['assets']}:
                continue
            try:
                _upload_asset_once(release_id, asset)
            except (OSError, ValueError, http.client.HTTPException) as error:
                rows = _api_list(f'releases/{release_id}/assets')
                match = [row for row in rows if row.get('name') == asset['name']]
                if (len(match) != 1 or match[0].get('state') != 'uploaded'
                        or match[0].get('digest') != 'sha256:' + asset['sha256']):
                    raise ValueError('Asset upload outcome unknown; reconcile draft before retrying: ' + asset['name']) from error
        _assert_release_write_allowed(plan)
        read_draft(complete=True)
        _api(f'releases/{release_id}', {'draft': False, 'make_latest': 'false'}, method='PATCH')
    reread = _release_by_tag(plan['tag'])
    require(reread is not None and reread.get('id') == release_id and reread.get('draft') is False,
            'Published release cannot be read back')
    _verify_existing_release(plan, reread, plan['tag'])
    _verify_release_is_off_latest(reread)
    print(json.dumps({'state': 'published-and-verified', 'tag': plan['tag'], 'releaseId': release_id, 'url': reread.get('html_url')}))
    return reread


def _output_locator(values):
    output_path = os.environ.get('GITHUB_OUTPUT')
    if output_path:
        with open(output_path, 'a') as output:
            for key, value in values.items():
                require(is_id(value), 'Only positive artifact and run IDs may be emitted')
                output.write(f'{key}={value}\n')
    else:
        print(json.dumps(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['locate', 'download-package', 'extract', 'preview', 'publish'])
    parser.add_argument('--release-type', choices=['stable'], required=True)
    parser.add_argument('--publication', choices=['prerelease', 'stable'])
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--status-run-id', required=True)
    parser.add_argument('--status-artifact-id', type=int)
    parser.add_argument('--package-run-id', type=int)
    parser.add_argument('--package-artifact-id', type=int)
    parser.add_argument('--package-directory', type=Path, default=Path('.artifacts/package/unpacked'))
    parser.add_argument('--package-archive', type=Path, default=Path('.artifacts/package/package.zip'))
    parser.add_argument('--plan-file', type=Path, default=Path('android-release-plan.json'))
    args = parser.parse_args()
    if args.operation == 'locate':
        values = locate_package(args.version, args.build)
        status_id = int(args.status_run_id)
        require(is_id(status_id), 'Exact Play status run ID is required')
        rows = _api_items(f'actions/runs/{status_id}/artifacts?per_page=100', 'artifacts')
        matches = [row for row in rows if row.get('name') == f'android-release-status-{status_id}-1']
        require(len(matches) == 1 and is_id(matches[0].get('id')) and matches[0].get('expired') is False,
                'Exact Play status artifact is missing, expired or ambiguous')
        values['status_artifact_id'] = matches[0]['id']
        _output_locator({key: values[key] for key in ('package_run_id', 'package_artifact_id', 'status_artifact_id')})
        return
    if args.operation == 'download-package':
        require(is_id(args.package_run_id) and is_id(args.package_artifact_id), 'Exact sealed package artifact identity is required')
        download_package_artifact(args.package_run_id, args.package_artifact_id, args.package_archive)
        print(json.dumps({'state': 'sealed-package-artifact-downloaded-and-verified', 'file': str(args.package_archive)}))
        return
    if args.operation == 'extract':
        extract_package(args.version, args.build, args.package_archive, args.package_directory)
        print(json.dumps({'state': 'package-extracted-and-verified', 'directory': str(args.package_directory)}))
        return
    require(args.publication and is_id(args.status_artifact_id), 'Preview and publication require a publication stage and status artifact')
    candidate, assets = _collect_evidence(args.version, args.build, args.release_type, args.publication,
                                          args.status_run_id, args.package_directory, args.status_artifact_id)
    plan = _write_plan(candidate, assets, args.plan_file)
    if args.operation == 'publish':
        publish_release(plan, assets)
    else:
        observation = preview_release(plan)
        print(json.dumps({'state': 'preview-ready', 'tag': plan['tag'], 'draftStatus': observation['draftStatus'],
                          'planSha256': plan['planSha256']}))


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
