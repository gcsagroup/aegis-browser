#!/usr/bin/env python3
"""Prepare and publish source-bound, immutable public iOS GitHub Releases."""
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
import tarfile
import tempfile
import time
from urllib.parse import quote
import zipfile

from product_delivery import GitHub, Records, allocation

REPOSITORY = 'gcsagroup/aegis-browser'
REPOSITORY_ID = 1348409663
APPLICATION = '6827988433'
APPLICATION_ID = 'com.gcsa.aegis'
PRODUCTION_ENVIRONMENT = 'aegis-ios-github-production'
TAG_RULESET = '.github/ios-public-release-tag-ruleset.json'
PROFILE_FOR = {'beta': 'beta', 'stable': 'release'}
PREVIEW_ONLY = ('1.1.0', '8')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


transport = module('ios_release_transport', 'artifact-transport.py')


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as content:
        for chunk in iter(lambda: content.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def extract_verified_status_archive(archive, destination, expected_digest):
    archive, destination = Path(archive), Path(destination)
    require(is_sha(expected_digest, 64) and archive.is_file() and not archive.is_symlink(),
            'Apple status artifact digest or archive is invalid')
    require(sha256(archive) == expected_digest, 'Downloaded Apple status artifact digest differs')
    require(not destination.exists() and not destination.is_symlink(), 'Refuse to overwrite Apple status evidence')
    with zipfile.ZipFile(archive) as zipped:
        rows = zipped.infolist()
        require(len(rows) == 1 and rows[0].filename == 'status.json' and not rows[0].is_dir()
                and not stat.S_ISLNK(rows[0].external_attr >> 16) and rows[0].file_size <= 4 * 1024 * 1024,
                'Apple status artifact must contain exactly one bounded status.json file')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipped.open(rows[0]) as source, destination.open('xb') as target:
            shutil.copyfileobj(source, target)


def extract_verified_package_archive(archive, destination, expected_digest):
    archive, destination = Path(archive), Path(destination)
    require(is_sha(expected_digest, 64) and archive.is_file() and not archive.is_symlink(),
            'Package artifact digest or archive is invalid')
    require(sha256(archive) == expected_digest, 'Downloaded package artifact digest differs')
    require(not destination.exists() and not destination.is_symlink(), 'Refuse to overwrite the sealed package archive')
    with zipfile.ZipFile(archive) as zipped:
        rows = zipped.infolist()
        require(len(rows) == 1 and rows[0].filename == 'package.zip' and not rows[0].is_dir()
                and not stat.S_ISLNK(rows[0].external_attr >> 16) and rows[0].file_size <= 1024**3,
                'Sealed package artifact must contain exactly one bounded package.zip file')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipped.open(rows[0]) as source, destination.open('xb') as target:
            shutil.copyfileobj(source, target)


def _download_actions_artifact_zip(artifact_id, archive):
    with Path(archive).open('xb') as output:
        result = subprocess.run(['gh', 'api', '-H', 'Accept: application/vnd.github+json',
                                 f'repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip'],
                                stdout=output, stderr=subprocess.PIPE, timeout=120)
    require(result.returncode == 0, 'Workflow artifact download failed')


def download_package_artifact(run_id, artifact_id, destination):
    require(is_id(run_id) and is_id(artifact_id), 'Exact sealed package run/artifact identity is required')
    artifact_name = f'ios-package-{run_id}-1'
    artifact = _get_artifact(run_id, artifact_id, artifact_name)
    with tempfile.TemporaryDirectory(prefix='aegis-ios-package-') as temp:
        archive = Path(temp) / 'package-artifact.zip'
        _download_actions_artifact_zip(artifact_id, archive)
        extract_verified_package_archive(archive, destination, artifact['digest'].removeprefix('sha256:'))


def download_status_artifact(status_run_id, artifact_id, destination):
    require(is_id(status_run_id) and is_id(artifact_id), 'Exact Apple status run/artifact IDs are required')
    name = f'ios-release-status-{status_run_id}-1'
    artifact = _get_artifact(status_run_id, artifact_id, name)
    with tempfile.TemporaryDirectory(prefix='aegis-apple-status-') as temp:
        archive = Path(temp) / 'status-artifact.zip'
        _download_actions_artifact_zip(artifact_id, archive)
        extract_verified_status_archive(archive, destination, artifact['digest'].removeprefix('sha256:'))
    return artifact


def is_id(value):
    return type(value) is int and value > 0


def is_sha(value, length=40):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{%d}' % length, value) is not None


def _require_fresh_observation(value, max_age_seconds=1800):
    require(isinstance(value, str), 'Apple observation timestamp is missing')
    try:
        observed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as error:
        raise ValueError('Apple observation timestamp is invalid') from error
    require(observed.tzinfo is not None, 'Apple observation timestamp must include a timezone')
    age = (datetime.now(timezone.utc) - observed.astimezone(timezone.utc)).total_seconds()
    require(-120 <= age <= max_age_seconds, 'Apple VALID status is stale; run Wait again before release approval/publication')


def _run_identity(run, expected_id, expected_sha, path):
    return (run.get('id') == expected_id and run.get('run_attempt') == 1
            and run.get('head_sha') == expected_sha and run.get('head_branch') == 'main'
            and run.get('status') == 'completed' and run.get('conclusion') == 'success'
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


def _package_jobs(run, run_id, sha):
    path = run.get('path')
    prefixes = {'.github/workflows/ios-delivery.yml': '',
                '.github/workflows/ios-delivery-full.yml': 'delivery / '}
    require(path in prefixes and _run_identity(run, run_id, sha, path),
            'Package producer run identity/source differs')
    return {name: _successful_job(run, prefixes[path] + name)
            for name in ('ios-package', 'seal-package', 'upload-new')}


def _exact_artifact(value, artifact_id, name, digest):
    return (is_id(artifact_id) and isinstance(digest, str) and re.fullmatch(r'sha256:[0-9a-f]{64}', digest) is not None
            and value.get('id') == artifact_id and value.get('name') == name
            and value.get('expired') is False and value.get('digest') == digest)


def _package_source(origin, current_sha, current_tree, historical_preview):
    sha, tree = origin.get('sourceSha'), origin.get('sourceTree')
    require(is_sha(sha) and is_sha(tree), 'Invalid package producer source')
    if historical_preview and sha != current_sha:
        comparison = _api(f'compare/{sha}...{current_sha}')
        require(comparison.get('merge_base_commit', {}).get('sha') == sha
                and comparison.get('base_commit', {}).get('commit', {}).get('tree', {}).get('sha') == tree,
                'Historical package producer is not an ancestor of current main with the sealed tree')
    else:
        require((sha, tree) == (current_sha, current_tree), 'Package producer source is no longer current main')
    return sha, tree


def validate_delivery_evidence(evidence, release_type, *, preview=False):
    """Validate package, upload, Apple status and run identities without inferring provenance."""
    require(release_type in PROFILE_FOR, 'Unknown public release channel')
    profile = PROFILE_FOR[release_type]
    version, build = evidence.get('version'), evidence.get('build')
    require(isinstance(version, str) and re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', version)
            and isinstance(build, str) and re.fullmatch(r'[1-9][0-9]{0,9}', build),
            'Invalid version/build coordinate')
    repo = evidence.get('repository', {})
    require(repo == {'id': REPOSITORY_ID, 'full_name': REPOSITORY, 'default_branch': 'main'},
            'Canonical repository identity/default branch differs')
    current_sha, current_tree = evidence.get('current_sha'), evidence.get('current_tree')
    require(is_sha(current_sha) and is_sha(current_tree), 'Current main source/tree identity is invalid')

    package_run = evidence.get('package_run', {})
    origin = evidence.get('package_record', {}).get('origin', {})
    source_sha, source_tree = _package_source(origin, current_sha, current_tree, preview and (version, build) == PREVIEW_ONLY)
    package_id = package_run.get('id')
    require(is_id(package_id), 'Package producer run identity is invalid')
    require(origin.get('repository') == REPOSITORY and origin.get('runId') == package_id
            and origin.get('attempt') == 1 and origin.get('sourceSha') == source_sha
            and origin.get('sourceTree') == source_tree and origin.get('runIdLocal') == f'ios-gh-{package_id}-1',
            'Package origin is not bound to current main and producer run')
    require(is_sha(origin.get('manifestSha256'), 64), 'Package manifest digest is invalid')
    jobs = _package_jobs(package_run, package_id, source_sha)
    package_record = evidence.get('package_record', {})
    require(package_record.get('profile') == profile,
            'Recorded package profile differs from requested release channel')
    package_artifact = evidence.get('package_artifact', {})
    require(package_record.get('package_job_id') == jobs['ios-package']['id']
            and is_id(package_record.get('artifact_id'))
            and is_sha(package_record.get('artifact_digest', '').removeprefix('sha256:'), 64)
            and package_record.get('artifact_name') == f'ios-package-{package_id}-1'
            and package_record.get('profile') == profile and package_record.get('version') == version
            and package_record.get('build') == build
            and _exact_artifact(package_artifact, package_record.get('artifact_id'),
                                package_record.get('artifact_name'), package_record.get('artifact_digest')),
            'Immutable package artifact record differs from the successful producer')

    manifest = evidence.get('manifest', {})
    require(evidence.get('manifest_sha256') == origin.get('manifestSha256')
            and manifest.get('repository') == REPOSITORY and manifest.get('platform') == 'ios'
            and manifest.get('applicationId') == APPLICATION_ID and manifest.get('profile') == profile
            and manifest.get('version') == version and manifest.get('build') == build
            and manifest.get('source') == {'sha': source_sha, 'tree': source_tree, 'dirty': False},
            'Product manifest identity/source/profile differs')
    signing_mode = manifest.get('details', {}).get('signingMode')
    require(signing_mode in {'manual', 'cloud'},
            'Package signing mode is not verified')
    assets = manifest.get('assets')
    if signing_mode == 'cloud':
        expected_ipa = f'Aegis-cloud-poc-{version}-{build}.ipa'
        expected_dsym = f'Aegis-cloud-poc-{version}-{build}.dSYM.zip'
    else:
        expected_ipa = f'Aegis-{profile}-{version}-{build}-ios.ipa'
        expected_dsym = f'Aegis-{profile}-{version}-{build}-ios.app.dSYM.zip'
    require(isinstance(assets, list) and len(assets) >= 2
            and {asset.get('name') for asset in assets if isinstance(asset, dict)} >= {expected_ipa, expected_dsym}
            and sum(isinstance(asset, dict) and asset.get('name', '').endswith('.ipa') for asset in assets) == 1,
            'Package assets do not match the exact public iOS release inventory')

    intent = evidence.get('upload_start', {})
    terminal = evidence.get('upload_result', {})
    expected_identity = {'operation': 'apple-upload', 'platform': 'ios', 'applicationId': APPLICATION_ID,
                         'version': version, 'build': build, 'profile': profile, 'format': 'ipa',
                         'manifestSha256': origin['manifestSha256'], 'parameters': {}}
    require(intent == expected_identity and terminal.get('intent') == intent
            and terminal.get('result', {}).get('status') == 'uploaded_processing_unverified'
            and terminal.get('result', {}).get('appId') is not None,
            'Permanent upload intent/result does not identify this exact package')

    status_run = evidence.get('status_run', {})
    status_id = status_run.get('id')
    require(is_id(status_id) and _run_identity(status_run, status_id, current_sha,
            '.github/workflows/ios-delivery.yml'), 'Apple status run identity/source differs')
    _successful_job(status_run, 'status-query')
    status_artifact = evidence.get('status_artifact', {})
    require(_exact_artifact(status_artifact, status_artifact.get('id'),
            f'ios-release-status-{status_id}-1', status_artifact.get('digest'))
            and status_artifact.get('run_id') == status_id,
            'Exact successful Apple status artifact is missing or expired')
    status = evidence.get('status', {})
    remote = status.get('remote', {})
    require(status.get('platform') == 'ios' and status.get('applicationId') == APPLICATION_ID
            and status.get('version') == version and status.get('build') == build
            and status.get('queryMode') == 'release-wait' and status.get('readOnly') is True
            and status.get('packageProvenanceVerified') is False
            and status.get('querySource') == {'sha': current_sha, 'tree': current_tree, 'dirty': False}
            and remote.get('appId') == APPLICATION and remote.get('processingState') == 'VALID'
            and terminal.get('result', {}).get('appId') == remote.get('appId')
            and is_sha(remote.get('buildIdentitySha256'), 64)
            and remote.get('expired') is False
            and isinstance(remote.get('uploadState'), str)
            and set(remote['uploadState'].split(',')) <= {'PROCESSING', 'COMPLETE'},
            'Apple must report this exact uploaded build VALID and unexpired')
    _require_fresh_observation(remote.get('observedAt'))
    return {
        'channel': release_type, 'profile': profile, 'version': version, 'build': build,
        'source': {'sha': source_sha, 'tree': source_tree}, 'manifestSha256': origin['manifestSha256'],
        'packageRunId': package_id, 'packageAttempt': 1, 'statusRunId': status_id,
        'appleBuildIdentitySha256': remote['buildIdentitySha256'], 'appleObservedAt': remote['observedAt'], 'artifactId': package_record['artifact_id'],
        'artifactDigest': package_record['artifact_digest'], 'artifactName': package_record['artifact_name'],
        'statusArtifactId': status_artifact['id'], 'statusArtifactDigest': status_artifact['digest'],
        'manifest': manifest,
    }


def public_manifest_payloads(manifest):
    assets = [
        {key: row[key] for key in ('name', 'size', 'sha256')}
        for row in manifest['assets'] if row['name'].endswith(('.ipa', '.dSYM.zip'))
    ]
    public = {key: manifest[key] for key in ('repository', 'platform', 'applicationId', 'profile', 'version', 'build')}
    public['source'] = {key: manifest['source'][key] for key in ('sha', 'tree')}
    public.update(schema='aegis-ios-public-manifest-v1', assets=sorted(assets, key=lambda row: row['name']))
    payload = (json.dumps(public, sort_keys=True, indent=2) + '\n').encode()
    digest = hashlib.sha256(payload).hexdigest()
    return {'ios-manifest.json': payload, 'ios-manifest.json.sha256': f'{digest}  ios-manifest.json\n'.encode()}


def build_release_plan(candidate, publication=None):
    channel = candidate['channel']
    if publication is None:
        publication = 'prerelease' if channel == 'beta' else 'stable'
    require(publication in {'prerelease', 'stable'}, 'Unknown publication stage')
    require(channel != 'beta' or publication == 'prerelease', 'A Beta package cannot become the stable release')
    profile, version, build = candidate['profile'], candidate['version'], candidate['build']
    tag = f'ios/{version}-beta.{build}' if channel == 'beta' else f'ios/{version}-release.{build}'
    asset_hashes = {asset['name']: asset['sha256'] for asset in candidate['manifest']['assets']
                    if asset['name'].endswith(('.ipa', '.dSYM.zip'))}
    asset_hashes.update({name: hashlib.sha256(content).hexdigest()
                         for name, content in public_manifest_payloads(candidate['manifest']).items()})
    label = 'Beta' if channel == 'beta' else ('Prerelease' if publication == 'prerelease' else 'Stable')
    core = {
        'schema': 'aegis-ios-github-release-plan-v1', 'channel': channel, 'profile': profile,
        'version': version, 'build': build, 'tag': tag, 'source': candidate['source'],
        'manifestSha256': candidate['manifestSha256'], 'packageRunId': candidate['packageRunId'],
        'packageAttempt': candidate['packageAttempt'], 'statusRunId': candidate['statusRunId'],
        'appleObservedAt': candidate['appleObservedAt'],
        'appleBuildIdentitySha256': candidate['appleBuildIdentitySha256'], 'assets': dict(sorted(asset_hashes.items())),
        'prerelease': publication == 'prerelease', 'makeLatest': publication == 'stable',
    }
    # The tag stays bound to the package. A later promotion may change only the GitHub prerelease flag.
    release_identity = {key: value for key, value in core.items()
                        if key not in {'statusRunId', 'appleObservedAt', 'prerelease', 'makeLatest'}}
    release_identity_sha = hashlib.sha256(json.dumps(
        release_identity, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
    # Recovery matches the existing public bytes. Approval also binds the exact Actions archives read this time.
    core['evidenceArtifacts'] = {
        'package': {'id': candidate['artifactId'], 'digest': candidate['artifactDigest']},
        'status': {'id': candidate['statusArtifactId'], 'digest': candidate['statusArtifactDigest']},
    }
    plan_sha = hashlib.sha256(json.dumps(core, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
    body = ('Aegis iOS public release\n\n'
            f"Channel: {label}\n"
            f"Source: {candidate['source']['sha']}\n"
            f"Source tree: {candidate['source']['tree']}\n"
            f"Public manifest SHA-256: {asset_hashes['ios-manifest.json']}\n"
            f"Release identity SHA-256: {release_identity_sha}\n")
    return {**core, 'name': f'Aegis iOS {version} ({build}) · {label}',
            'releaseIdentitySha256': release_identity_sha, 'planSha256': plan_sha, 'body': body}


def public_asset_manifest(directory, manifest, manifest_digest):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), 'Package directory must be a real directory')
    manifest_path = directory / 'ios-manifest.json'
    checksum_path = directory / 'ios-manifest.json.sha256'
    require(manifest_path.is_file() and not manifest_path.is_symlink()
            and sha256(manifest_path) == manifest_digest, 'Manifest bytes/digest differ')
    require(json.loads(manifest_path.read_text()) == manifest, 'Manifest object differs from package bytes')
    expected_checksum = f'{manifest_digest}  ios-manifest.json\n'
    require(checksum_path.is_file() and not checksum_path.is_symlink()
            and checksum_path.read_text() == expected_checksum, 'Manifest checksum file differs')
    assets = []
    names = set()
    for row in manifest.get('assets', []):
        name = row.get('name')
        if not isinstance(name, str) or not name.endswith(('.ipa', '.dSYM.zip')):
            continue
        require(name not in names and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name)
                and '..' not in name, 'Invalid or duplicate public package asset')
        names.add(name)
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.resolve().parent == directory.resolve()
                and path.stat().st_size == row.get('size') and sha256(path) == row.get('sha256'),
                'Public package asset bytes differ from product manifest')
        assets.append({'name': name, 'size': path.stat().st_size, 'sha256': row['sha256'], 'path': str(path)})
    require(sum(item['name'].endswith('.ipa') for item in assets) == 1
            and sum(item['name'].endswith('.dSYM.zip') for item in assets) == 1,
            'Public release requires exactly one IPA and one dSYM archive')
    public = directory.parent / (directory.name + '-public-metadata')
    public.mkdir(mode=0o700)
    for name, payload in public_manifest_payloads(manifest).items():
        path = public / name
        with path.open('xb') as content:
            content.write(payload)
        assets.append({'name': name, 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(), 'path': str(path)})
    return sorted(assets, key=lambda item: item['name'])


def _api(path, payload=None, method=None):
    command = ['gh', 'api', '-H', 'Accept: application/vnd.github+json',
               '-H', 'X-GitHub-Api-Version: 2022-11-28']
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


def locate_package(version, build, release_type):
    require(release_type in PROFILE_FOR, 'Unknown public release channel')
    api = GitHub(REPOSITORY)
    store = Records(api, REPOSITORY_ID, APPLICATION)
    key = allocation(APPLICATION, version, build)
    payload = store.read('package', key)
    require(isinstance(payload, dict), 'No permanent package record exists for this version/build')
    require(payload.get('profile') == PROFILE_FOR[release_type]
            and payload.get('version') == version and payload.get('build') == build,
            'Recorded package profile/version/build differs from requested channel')
    origin = payload.get('origin', {})
    run_id, attempt = origin.get('runId'), origin.get('attempt')
    require(is_id(run_id) and attempt == 1, 'Only first-attempt package runs are admitted')
    artifact_id, artifact_name = payload.get('artifact_id'), payload.get('artifact_name')
    artifact = _get_artifact(run_id, artifact_id, artifact_name)
    require(artifact.get('digest') == payload.get('artifact_digest'), 'Package artifact digest differs from permanent record')
    return {'package_run_id': run_id, 'package_attempt': attempt,
            'package_artifact_id': artifact_id, 'package_artifact_name': artifact_name,
            'package_artifact_digest': payload['artifact_digest'],
            'source_sha': origin['sourceSha'], 'source_tree': origin['sourceTree'],
            'manifest_sha256': origin['manifestSha256']}


def extract_package(version, build, release_type, archive, destination, *, preview=False):
    _, current_sha, current_tree = _current_repository()
    locator = locate_package(version, build, release_type)
    package_sha, package_tree = _package_source({'sourceSha': locator['source_sha'], 'sourceTree': locator['source_tree']},
                                                current_sha, current_tree, preview and (version, build) == PREVIEW_ONLY)
    run_id = locator['package_run_id']
    producer = _get_run(run_id)
    producer['jobs'] = _get_jobs(run_id)
    _package_jobs(producer, run_id, package_sha)
    directory = Path(destination)
    require(not directory.exists() and not directory.is_symlink(), 'Package extraction destination must be new')
    transport.extract_flat(Path(archive), directory)
    manifest_path = directory / 'ios-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    digest = sha256(manifest_path)
    require(digest == locator['manifest_sha256'] and manifest.get('profile') == PROFILE_FOR[release_type]
            and manifest.get('version') == version and manifest.get('build') == build,
            'Extracted package identity differs from permanent record')
    transport.verify_package(directory, package_sha, package_tree, digest)
    transport.reject_private_resources(directory, manifest)


def _verify_packaged_ipa(ipa, version, build, profile, producer_sha, producer_tree, current_sha):
    command = [sys.executable, Path(__file__).with_name('verify-ipa.py'), ipa, version, build, profile]
    if producer_sha == current_sha:
        subprocess.run(command, check=True)
        return
    subprocess.run(['git', 'fetch', '--no-tags', '--depth=1',
                    f'https://github.com/{REPOSITORY}.git', producer_sha], check=True, timeout=120)
    tree = subprocess.check_output(['git', 'rev-parse', producer_sha + '^{tree}'], text=True).strip()
    require(tree == producer_tree, 'Fetched historical package tree differs from the sealed producer')
    paths = [
        'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared/vendor',
        'apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/bergamot/LICENSE',
        'apps/ios/BrowserKit/Resources', 'apps/ios/AegisPolicyKit/Resources/public_suffix_list.dat',
        'apps/ios/AegisApp/ThirdPartyNotices.txt',
        'apps/ios/Aegis.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
        'scripts/licenses', 'scripts/release/verify-ipa.py', 'scripts/release/safari_manifest.py',
    ]
    with tempfile.TemporaryDirectory(prefix='aegis-producer-') as temp:
        root = Path(temp)
        archive = root / 'source.tar'
        with archive.open('xb') as output:
            subprocess.run(['git', 'archive', producer_sha, '--', *paths], stdout=output, check=True, timeout=30)
        with tarfile.open(archive) as source:
            source.extractall(root, filter='data')
        subprocess.run([sys.executable, root / 'scripts/release/verify-ipa.py',
                        Path(ipa).resolve(), version, build, profile], check=True)


def _collect_evidence(version, build, release_type, status_run_id, package_dir, status_artifact_id, *, preview=False):
    repo, current_sha, current_tree = _current_repository()
    package_locator = locate_package(version, build, release_type)
    package_run = _get_run(package_locator['package_run_id'])
    package_run['jobs'] = _get_jobs(package_locator['package_run_id'])
    status_run_id = int(status_run_id)
    require(is_id(status_run_id), 'Exact Apple status run ID is required')
    status_run = _get_run(status_run_id)
    status_run['jobs'] = _get_jobs(status_run_id)

    api = GitHub(REPOSITORY)
    store = Records(api, REPOSITORY_ID, APPLICATION)
    key = allocation(APPLICATION, version, build)
    package_record = store.read('package', key)
    upload_start = store.read('upload-start', key)
    upload_result = store.read('upload-result', key)
    require(package_record is not None and upload_start is not None and upload_result is not None,
            'Permanent package/upload records are incomplete')
    package_artifact = _get_artifact(package_locator['package_run_id'],
                                     package_locator['package_artifact_id'],
                                     package_locator['package_artifact_name'])
    with tempfile.TemporaryDirectory(prefix='aegis-release-evidence-') as temp:
        status_path = Path(temp) / 'status.json'
        status_artifact = download_status_artifact(status_run_id, status_artifact_id, status_path)
        status = json.loads(status_path.read_text())
    package_dir = Path(package_dir)
    require(package_dir.is_dir() and not package_dir.is_symlink(), 'Downloaded package evidence is missing')
    origin = json.loads((package_dir / 'package-origin.json').read_text())
    require(origin == package_record.get('origin'), 'Downloaded package origin differs from permanent record')
    manifest_path = package_dir / 'ios-manifest.json'
    manifest_digest = sha256(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    if manifest_digest != origin.get('manifestSha256'):
        raise ValueError('Downloaded product manifest digest differs from package record')
    transport.verify_package(package_dir, origin['sourceSha'], origin['sourceTree'], manifest_digest)
    transport.reject_private_resources(package_dir, manifest)
    ipa = next(asset['name'] for asset in manifest['assets'] if asset['name'].endswith('.ipa'))
    evidence = {
        'repository': repo, 'current_sha': current_sha, 'current_tree': current_tree,
        'requested_profile': PROFILE_FOR[release_type], 'version': version, 'build': build,
        'package_run': package_run, 'package_record': package_record,
        'package_artifact': package_artifact, 'upload_start': upload_start,
        'upload_result': upload_result, 'manifest': manifest,
        'manifest_sha256': manifest_digest, 'status_run': status_run,
        'status_artifact': status_artifact, 'status': status,
    }
    candidate = validate_delivery_evidence(evidence, release_type, preview=preview)
    _verify_packaged_ipa(package_dir / ipa, version, build, PROFILE_FOR[release_type],
                         origin['sourceSha'], origin['sourceTree'], current_sha)
    assets = public_asset_manifest(package_dir, manifest, manifest_digest)
    candidate['publicAssets'] = [{key: asset[key] for key in ('name', 'size', 'sha256')} for asset in assets]
    return candidate, assets


def _write_plan(candidate, assets, path, publication=None):
    plan = build_release_plan(candidate, publication)
    actual = {asset['name']: asset['sha256'] for asset in assets}
    require(actual == plan['assets'], 'Public asset inventory differs from plan')
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
        with open(summary, 'a') as output:
            output.write(f"## iOS GitHub Release preview\n\n"
                         f"- Channel: {plan['channel']}\n- Tag: `{plan['tag']}`\n"
                         f"- Source: `{plan['source']['sha']}`\n"
                         f"- Manifest SHA-256: `{plan['manifestSha256']}`\n"
                         f"- Plan SHA-256: `{plan['planSha256']}`\n"
                         f"- Draft conflicts: checked by the publisher with its GitHub write token.\n\n"
                         f"### Proposed release notes\n\n{plan['body']}\n"
                         f"### Public assets\n\n| Name | Size | SHA-256 |\n|---|---:|---|\n")
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
        drafts = [row for row in _api_list('releases')
                  if row.get('tag_name') == tag and row.get('draft') is True]
        require(len(drafts) <= 1, 'Multiple drafts exist for this release tag')
        return drafts[0] if drafts else None


def _tag_target(tag):
    try:
        ref = _api('git/ref/tags/' + quote(tag, safe=''))
    except NotFoundError:
        return None
    obj = ref.get('object', {})
    require(obj.get('type') == 'tag' and is_sha(obj.get('sha')),
            'Existing release tag must be annotated and immutable')
    annotated = _api('git/tags/' + obj['sha'])
    target = annotated.get('object', {})
    return {'tag_sha': obj['sha'], 'target_sha': target.get('sha'),
            'message': annotated.get('message'), 'object_type': target.get('type')}


def _expected_tag_message(plan):
    return (f"Aegis iOS GitHub Release\n\nRelease identity SHA-256: {plan['releaseIdentitySha256']}\n"
            f"Source: {plan['source']['sha']}\n")


def _verify_release_metadata(plan, release):
    require(release.get('tag_name') == plan['tag'] and release.get('name') == plan['name']
            and release.get('body') == plan['body'] and type(release.get('draft')) is bool
            and release.get('prerelease') is plan['prerelease'],
            'Existing release metadata conflicts with the exact plan')


def _verify_existing_release(plan, release, tag):
    _verify_release_metadata(plan, release)
    _verify_release_tag(plan, tag)
    _verify_release_assets(plan, release)


def _verify_release_tag(plan, tag):
    tag_state = _tag_target(tag)
    require(tag_state is not None and tag_state['target_sha'] == plan['source']['sha']
            and tag_state['object_type'] == 'commit'
            and tag_state['message'] == _expected_tag_message(plan),
            'Existing release tag conflicts with the exact source/plan')


def _verify_release_assets(plan, release):
    expected = plan['assets']
    found = release.get('assets', [])
    require(isinstance(found, list) and len(found) <= len(expected)
            and {item.get('name') for item in found} <= set(expected),
            'Existing release asset inventory conflicts with the exact plan')
    if release['draft'] is False:
        require({item.get('name') for item in found} == set(expected), 'Public release asset inventory is incomplete')
    for item in found:
        require(item.get('state') == 'uploaded' and item.get('digest') == 'sha256:' + expected[item['name']],
                'Existing release asset digest conflicts with the exact plan: ' + item.get('name', '?'))


def _verify_latest_stable(plan, release):
    if not plan['makeLatest']:
        return
    latest = _api('releases/latest')
    require(latest.get('id') == release.get('id') and latest.get('tag_name') == plan['tag'],
            'Stable release did not become the repository Latest release')


def _create_tag(plan, api):
    tag = plan['tag']
    current = _tag_target(tag)
    if current:
        require(current['target_sha'] == plan['source']['sha'] and current['object_type'] == 'commit'
                and current['message'] == _expected_tag_message(plan),
                'Conflicting tag exists; no mutation attempted')
        return
    payload = {'tag': tag, 'message': _expected_tag_message(plan),
               'object': plan['source']['sha'], 'type': 'commit',
               'tagger': {'name': 'GCSA iOS Release Bot', 'email': 'github-actions[bot]@users.noreply.github.com',
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
    require(current and current['target_sha'] == plan['source']['sha']
            and current['message'] == _expected_tag_message(plan),
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
    raw_allowed = os.environ.get('AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS', '').split(',')
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
    require(reviewers <= set(current_admins),
            'Production environment reviewers must all be current repository Admins')
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
        user = approval.get('user', {})
        if (approval.get('state') == 'approved' and exact_environment
                and approval.get('comment') == expected_comment):
            matching.append(user)
    require(len(matching) == 1, 'Stable publish requires one approval with the exact plan digest')
    reviewer = matching[0]
    require(is_id(reviewer.get('id')) and reviewer['id'] in reviewers and reviewer['id'] in allowed
            and current_admins.get(reviewer['id']) == reviewer.get('login', '').lower(),
            'Stable approval must come from an allowlisted current Environment reviewer and repository Admin')


def preview_release(plan):
    _verify_tag_ruleset()
    existing_tag = _tag_target(plan['tag'])
    release = _release_by_tag(plan['tag'], include_drafts=False)
    if release is not None:
        if plan['makeLatest'] and release.get('prerelease') is True:
            require(release.get('draft') is False and release.get('tag_name') == plan['tag'],
                    'Stable promotion requires the public prerelease')
            _verify_release_tag(plan, plan['tag'])
            _verify_release_assets(plan, release)
        else:
            _verify_existing_release(plan, release, plan['tag'])
    elif existing_tag is not None:
        require(existing_tag['target_sha'] == plan['source']['sha']
                and existing_tag['object_type'] == 'commit'
                and existing_tag['message'] == _expected_tag_message(plan),
                'Conflicting tag exists; release preview is blocked')
    if plan['makeLatest']:
        _production_environment_config()
    return {'tag': plan['tag'], 'existingTag': existing_tag is not None, 'existingRelease': release is not None,
            'draftStatus': 'visible-public-release' if release else 'unverified',
            'productionEnvironmentVerified': bool(plan['makeLatest'])}


def _assert_current_release_source(plan):
    _, sha, tree = _current_repository()
    require(plan['source'] == {'sha': sha, 'tree': tree}, 'Publication source is no longer current main')


def _assert_release_write_allowed(plan):
    _assert_current_release_source(plan)
    _require_fresh_observation(plan['appleObservedAt'])


def _upload_asset_once(release_id, asset):
    token = os.environ.get('GH_TOKEN')
    require(token, 'Publisher GitHub token is required')
    path = f"/repos/{REPOSITORY}/releases/{release_id}/assets?name={quote(asset['name'], safe='')}"
    with Path(asset['path']).open('rb') as content:
        connection = http.client.HTTPSConnection('uploads.github.com', timeout=120)
        try:
            connection.request('POST', path, body=content, headers={
                'Authorization': 'Bearer ' + token,
                'Content-Type': 'application/octet-stream',
                'Content-Length': str(asset['size']),
                'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28',
                'User-Agent': 'aegis-ios-release-bot',
            })
            require(connection.getresponse().status == 201, 'Asset upload did not return HTTP 201')
        finally:
            connection.close()


def _promote_to_stable(plan):
    """Mark an already published prerelease as the official Latest release."""
    _assert_current_release_source(plan)
    release = _release_by_tag(plan['tag'], include_drafts=False)
    require(release is not None, 'Publish the prerelease before promoting it to the stable release')
    release_id = release.get('id')
    require(is_id(release_id) and release.get('draft') is False and release.get('tag_name') == plan['tag'],
            'Stable promotion requires the public prerelease')
    _verify_release_tag(plan, plan['tag'])
    _verify_release_assets(plan, release)
    if release.get('prerelease') is False:
        _verify_existing_release(plan, release, plan['tag'])
        _verify_latest_stable(plan, release)
        return release
    require(release.get('prerelease') is True, 'Only a public prerelease can be promoted')
    _check_approval(plan, os.environ['GITHUB_RUN_ID'])
    staged = _api(f'releases/{release_id}')
    require(staged.get('id') == release_id and staged.get('draft') is False and staged.get('prerelease') is True,
            'Prerelease changed before promotion')
    _verify_release_tag(plan, plan['tag'])
    _verify_release_assets(plan, staged)
    _assert_release_write_allowed(plan)
    _api(f'releases/{release_id}', {'name': plan['name'], 'body': plan['body'], 'draft': False,
                                    'prerelease': False, 'make_latest': 'true'}, method='PATCH')
    reread = _release_by_tag(plan['tag'])
    require(reread is not None and reread.get('id') == release_id and reread.get('draft') is False
            and reread.get('prerelease') is False, 'Promoted release cannot be read back')
    _verify_existing_release(plan, reread, plan['tag'])
    _verify_latest_stable(plan, reread)
    print(json.dumps({'state': 'promoted-and-verified', 'tag': plan['tag'],
                      'releaseId': release_id, 'url': reread.get('html_url')}))
    return reread


def publish_release(plan, assets):
    require((plan.get('version'), plan.get('build')) != PREVIEW_ONLY,
            'The current 1.1.0 (8) package is preview-only')
    require(plan.get('planSha256') == os.environ.get('EXPECTED_PLAN_SHA256'),
            'Post-approval evidence differs from the reviewed release plan')
    _verify_tag_ruleset()
    if plan['makeLatest']:
        _check_approval(plan, os.environ['GITHUB_RUN_ID'])
        return _promote_to_stable(plan)
    _assert_current_release_source(plan)
    release = _release_by_tag(plan['tag'])
    if release is None:
        _assert_current_release_source(plan)
        _create_tag(plan, GitHub(REPOSITORY))
        _assert_release_write_allowed(plan)
        release = _api('releases', {'tag_name': plan['tag'], 'target_commitish': plan['source']['sha'],
                                    'name': plan['name'], 'body': plan['body'], 'draft': True,
                                    'prerelease': plan['prerelease'], 'make_latest': 'false'})
    _verify_existing_release(plan, release, plan['tag'])
    release_id = release.get('id')
    require(is_id(release_id), 'Exact release ID is required for staging')
    if release['draft']:
        existing = {item['name'] for item in release['assets']}
        for asset in assets:
            if asset['name'] in existing:
                continue
            _assert_release_write_allowed(plan)
            try:
                _upload_asset_once(release_id, asset)
            except (OSError, ValueError, http.client.HTTPException) as error:
                # Reconcile once before any further POST, including when GitHub returned a 5xx.
                rows = _api_list(f'releases/{release_id}/assets')
                match = [row for row in rows if row.get('name') == asset['name']]
                if (len(match) != 1 or match[0].get('state') != 'uploaded'
                        or match[0].get('digest') != 'sha256:' + asset['sha256']):
                    raise ValueError('Asset upload outcome unknown; reconcile draft before retrying: ' + asset['name']) from error
        _assert_current_release_source(plan)
        _verify_release_tag(plan, plan['tag'])
        staged = _api(f'releases/{release_id}')
        require(staged.get('id') == release_id and staged.get('draft') is True,
                'Exact release draft moved during staging')
        _verify_release_metadata(plan, staged)
        _verify_release_assets(plan, staged)
        require({item.get('name') for item in staged['assets']} == set(plan['assets']),
                'Staged asset inventory is incomplete')
        _assert_release_write_allowed(plan)
        _api(f'releases/{release_id}', {'draft': False,
                 'make_latest': 'true' if plan['makeLatest'] else 'false'}, method='PATCH')
    reread = _release_by_tag(plan['tag'])
    require(reread is not None and reread.get('id') == release_id and reread.get('draft') is False,
            'Published release cannot be read back')
    _verify_existing_release(plan, reread, plan['tag'])
    _verify_latest_stable(plan, reread)
    print(json.dumps({'state': 'published-and-verified', 'tag': plan['tag'],
                      'releaseId': release_id, 'url': reread.get('html_url')}))
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
    parser.add_argument('operation', choices=['locate', 'download-package', 'extract', 'download-status', 'preview', 'publish'])
    parser.add_argument('--preview-package', action='store_true')
    parser.add_argument('--release-type', choices=['beta', 'stable'], required=True)
    parser.add_argument('--publication', choices=['prerelease', 'stable'])
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--status-run-id', required=True)
    parser.add_argument('--status-artifact-id', type=int)
    parser.add_argument('--package-run-id', type=int)
    parser.add_argument('--package-artifact-id', type=int)
    parser.add_argument('--package-directory', type=Path, default=Path('.artifacts/package'))
    parser.add_argument('--package-archive', type=Path, default=Path('.artifacts/package/package.zip'))
    parser.add_argument('--status-file', type=Path, help='output file for download-status')
    parser.add_argument('--plan-file', type=Path, default=Path('ios-release-plan.json'))
    args = parser.parse_args()
    if args.operation == 'locate':
        values = locate_package(args.version, args.build, args.release_type)
        status_id = int(args.status_run_id)
        require(is_id(status_id), 'Exact Apple status run ID is required')
        rows = _api_items(f'actions/runs/{status_id}/artifacts?per_page=100', 'artifacts')
        matches = [row for row in rows if row.get('name') == f'ios-release-status-{status_id}-1']
        require(len(matches) == 1 and is_id(matches[0].get('id')) and matches[0].get('expired') is False,
                'Exact Apple status artifact is missing, expired or ambiguous')
        values['status_artifact_id'] = matches[0]['id']
        _output_locator({key: values[key] for key in ('package_run_id', 'package_artifact_id', 'status_artifact_id')})
        return
    if args.operation == 'download-package':
        require(args.package_run_id is not None and args.package_artifact_id is not None, 'Exact sealed package artifact identity is required')
        download_package_artifact(args.package_run_id, args.package_artifact_id,
                                  args.package_archive)
        print(json.dumps({'state': 'sealed-package-artifact-downloaded-and-verified',
                          'file': str(args.package_archive)}))
        return
    if args.operation == 'extract':
        extract_package(args.version, args.build, args.release_type, args.package_archive, args.package_directory,
                        preview=args.preview_package)
        print(json.dumps({'state': 'package-extracted-and-verified', 'directory': str(args.package_directory)}))
        return
    if args.operation == 'download-status':
        require(args.status_artifact_id is not None, 'Exact Apple status artifact ID is required')
        download_status_artifact(int(args.status_run_id), args.status_artifact_id,
                                 args.status_file or Path('.artifacts/status/status.json'))
        print(json.dumps({'state': 'apple-status-artifact-downloaded-and-verified', 'file': str(args.status_file or Path('.artifacts/status/status.json'))}))
        return
    require(is_id(args.status_artifact_id) and args.status_file is None,
            'Preview and publication require an exact status artifact ID from the locator')
    candidate, assets = _collect_evidence(args.version, args.build, args.release_type,
                                           args.status_run_id, args.package_directory, args.status_artifact_id,
                                           preview=args.operation == 'preview')
    plan = _write_plan(candidate, assets, args.plan_file, args.publication)
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
