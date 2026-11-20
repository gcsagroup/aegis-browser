#!/usr/bin/env python3
"""Plan an Aegis macOS DMG the way MacCleaner delivery plans one.

DMG only. There is no App Store package, TestFlight upload, status, or wait.
The self-hosted builder produces one arm64 disk image. Ad-hoc and host-signed
packages are not notarized. A stable release can only promote a notarized
candidate.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UPSTREAM = 'gcsagroup/aegis-browser'
FORK = 'quinn521/aegis-browser'
ALLOWED = {UPSTREAM, FORK}
# Keep the old name for callers that still import REPOSITORY as the upstream product repo.
REPOSITORY = UPSTREAM
DMG_KINDS = {'ad-hoc', 'host-signed', 'notarized'}
SIGNING_MODES = {'ad-hoc', 'host-signed', 'notarized', 'none'}
TAG_SCHEMA = 'aegis-macos-dmg-v1'
MANIFEST_SCHEMA = 'aegis-macos-delivery-v1'
VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+')
BUILD = re.compile(r'[1-9][0-9]*')
INPUT_KEYS = (
    'operation', 'version', 'build', 'package_kind', 'signing_mode',
    'approved_source_sha', 'tag_release', 'bot_callback',
)


class DeliveryError(ValueError):
    pass


class DeliveryStatus(DeliveryError):
    def __init__(self, status):
        super().__init__('GitHub request failed: HTTP ' + str(status))
        self.status = status


def require(condition, message):
    if not condition:
        raise DeliveryError(message)


def admit_repository(name):
    require(name in ALLOWED, 'DMG delivery starts on the fork first, then the upstream repository')
    return name


def normalize_kind(package_kind, signing_mode):
    if package_kind == 'unsigned-dmg':
        package_kind = 'ad-hoc'
    if signing_mode == 'none':
        signing_mode = 'ad-hoc'
    return package_kind, signing_mode


def runner_label(environment):
    for key in ('AEGIS_MACOS_RUNNER_LABEL', 'AEGIS_IOS_RUNNER_LABEL'):
        label = environment.get(key, '')
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', label):
            return label
    raise DeliveryError('Set AEGIS_MACOS_RUNNER_LABEL or keep the existing self-hosted AEGIS_IOS_RUNNER_LABEL')


def plan(environment, inputs):
    require(environment.get('AEGIS_MACOS_DELIVERY_ENABLED') == 'true',
            'macOS DMG delivery is disabled until AEGIS_MACOS_DELIVERY_ENABLED=true')
    repository = admit_repository(environment.get('GITHUB_REPOSITORY', ''))
    require(environment.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'DMG delivery requires workflow_dispatch')
    require(environment.get('GITHUB_REF') == 'refs/heads/main', 'DMG delivery ref is not allowed')
    sha = environment.get('GITHUB_SHA', '')
    require(re.fullmatch(r'[0-9a-f]{40}', sha) is not None, 'DMG delivery source SHA is malformed')
    require(re.fullmatch(r'[1-9][0-9]*', environment.get('GITHUB_RUN_ATTEMPT', '')) is not None,
            'DMG delivery run attempt is malformed')
    require(isinstance(inputs, dict) and set(inputs) <= set(INPUT_KEYS), 'Unknown DMG delivery inputs')
    require(all(isinstance(value, str) for value in inputs.values()), 'DMG delivery inputs must be strings')
    require(inputs.get('operation') == 'Package', 'DMG delivery only packages a disk image')
    version = inputs.get('version', '')
    build = inputs.get('build', '')
    require(VERSION.fullmatch(version) is not None and BUILD.fullmatch(build) is not None,
            'Enter version and build, for example 0.8.0 and 800001')
    package_kind, signing_mode = normalize_kind(inputs.get('package_kind', ''), inputs.get('signing_mode', ''))
    require(package_kind in DMG_KINDS, 'DMG package kind must be ad-hoc, host-signed, or notarized')
    require(signing_mode == package_kind, 'DMG signing mode must match the package kind')
    approved = inputs.get('approved_source_sha', '')
    require(approved == sha, 'Package delivery requires the approved source SHA')
    tag_release = inputs.get('tag_release') or 'no'
    bot_callback = inputs.get('bot_callback') or 'yes'
    require(tag_release in {'yes', 'no'} and bot_callback in {'yes', 'no'}, 'DMG tag and bot callback must be yes or no')
    label = runner_label(environment)
    values = {
        'operation': 'package',
        'package_kind': package_kind,
        'signing_mode': signing_mode,
        'version': version,
        'build': build,
        'upload': 'false',
        'tag_release': 'true' if tag_release == 'yes' else 'false',
        'bot_callback': 'true' if bot_callback == 'yes' else 'false',
        'architectures': 'arm64',
        'approved_source_sha': approved,
        'repository': repository,
        'runner_label': label,
        'runner': json.dumps(['self-hosted', 'macOS', 'ARM64', label], separators=(',', ':')),
    }
    require(all('\n' not in value and '\r' not in value for value in values.values()), 'Invalid multiline workflow output')
    return values


def dmg_filename(version):
    return f'GCSA-aegis-{version}-mac-arm64.dmg'


def _sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def seal(directory, package_kind, version, build, source_sha, repository):
    repository = admit_repository(repository)
    require(package_kind in DMG_KINDS, 'DMG seal package kind is unknown')
    require(VERSION.fullmatch(version) is not None and BUILD.fullmatch(build) is not None, 'DMG seal coordinate is malformed')
    require(directory.is_dir() and not directory.is_symlink(), 'Delivery directory must be a physical directory')
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha) is not None, 'Delivery manifest source is malformed')
    filename = dmg_filename(version)
    path = directory / filename
    require(path.is_file() and not path.is_symlink(), 'Missing delivery artifact: ' + filename)
    require(path.resolve().parent == directory.resolve(), 'Delivery artifact escapes its directory')
    entries = list(directory.iterdir())
    require(all(entry.is_file() and not entry.is_symlink() for entry in entries),
            'Delivery directory contains an unexpected entry')
    require(sorted(entry.name for entry in entries) == sorted([filename, 'macos-delivery-receipt.json']),
            'Delivery directory must contain the arm64 DMG and its package receipt')
    receipt = json.loads((directory / 'macos-delivery-receipt.json').read_text(encoding='utf-8'))
    expected_signing = 'developer-id' if package_kind in {'host-signed', 'notarized'} else 'ad-hoc'
    require(receipt.get('notarized') is False and receipt.get('signingMode') == expected_signing and
            receipt.get('version') == version and receipt.get('arch') == 'arm64',
            'Low-level package receipt does not match this DMG kind')
    require(receipt.get('sourceSha') == source_sha and receipt.get('packagingSourceSha') == source_sha,
            'Package receipt source differs from the requested delivery source')
    if package_kind == 'notarized':
        require(receipt.get('notarizationSigning') is True, 'Notarized DMG requires distribution signing')
    digest = _sha256(path)
    if package_kind != 'notarized':
        require(receipt.get('dmg', {}).get('sha256') == digest, 'DMG digest differs from the package receipt')
    manifest = {
        'schema': MANIFEST_SCHEMA,
        'repository': repository,
        'sourceSha': source_sha,
        'packageKind': package_kind,
        'version': version,
        'build': build,
        'architectures': ['arm64'],
        'notarized': package_kind == 'notarized',
        'artifacts': [{
            'filename': filename,
            'architecture': 'arm64',
            'role': 'package',
            'uploadable': False,
            'sha256': digest,
            'sizeBytes': path.stat().st_size,
        }],
    }
    target = directory / 'macos-delivery-manifest.json'
    require(not target.exists() and not target.is_symlink(), 'Refusing to replace a delivery manifest')
    target.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    return manifest


def dmg_tag_name(version, build, package_kind):
    require(package_kind in DMG_KINDS, 'Tag release is only for a DMG package')
    require(VERSION.fullmatch(version) is not None and BUILD.fullmatch(build) is not None, 'DMG tag coordinate is malformed')
    return f'candidate/macos/{version}-{package_kind}.{build}'


def plan_dmg_tag(manifest, manifest_digest, source_sha):
    require(manifest.get('schema') == MANIFEST_SCHEMA, 'DMG manifest schema differs')
    repository = admit_repository(str(manifest.get('repository', '')))
    require(manifest.get('sourceSha') == source_sha and re.fullmatch(r'[0-9a-f]{40}', source_sha) is not None,
            'DMG manifest source differs')
    require(re.fullmatch(r'[0-9a-f]{64}', manifest_digest) is not None, 'DMG manifest digest is malformed')
    package_kind = manifest.get('packageKind')
    if package_kind == 'unsigned-dmg':
        package_kind = 'ad-hoc'
    version = str(manifest.get('version', ''))
    build = str(manifest.get('build', ''))
    tag = dmg_tag_name(version, build, str(package_kind))
    artifacts = manifest.get('artifacts')
    require(isinstance(artifacts, list) and len(artifacts) == 1, 'DMG tag requires the single arm64 package')
    item = artifacts[0]
    require(item.get('architecture') == 'arm64' and item.get('uploadable') is False, 'DMG tag architecture differs')
    filename = item.get('filename')
    digest = item.get('sha256')
    require(filename == dmg_filename(version), 'DMG tag artifact name differs')
    require(re.fullmatch(r'[0-9a-f]{64}', str(digest)) is not None, 'DMG tag artifact digest is malformed')
    payload = {
        'schema': TAG_SCHEMA,
        'packageKind': package_kind,
        'version': version,
        'build': build,
        'sourceSha': source_sha,
        'manifestSha256': manifest_digest,
        'artifacts': [{'architecture': 'arm64', 'filename': filename, 'sha256': digest}],
    }
    message = TAG_SCHEMA + '\n' + json.dumps(payload, sort_keys=True, separators=(',', ':'))
    return {
        'tag': tag,
        'message': message,
        'target': source_sha,
        'repository': repository,
        'prerelease': True,
        'makeLatest': 'false',
        'name': f'GCSA Aegis {version} ({build})',
    }


def github_request(path, token, method='GET', body=None, data=None, content_type=None):
    payload = data if data is not None else (None if body is None else json.dumps(body).encode())
    if str(path).startswith('https://uploads.github.com/'):
        url = path
    else:
        require(str(path).startswith('/'), 'GitHub request path is malformed')
        url = 'https://api.github.com' + path
    request = urllib.request.Request(
        url,
        data=payload,
        method=method,
        headers={
            'Accept': 'application/vnd.github+json',
            'Authorization': 'Bearer ' + token,
            'X-GitHub-Api-Version': '2022-11-28',
            **({} if payload is None else {'Content-Type': content_type or 'application/json'}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return None if response.status == 204 or not raw else json.loads(raw.decode())
    except urllib.error.HTTPError as error:
        raise DeliveryStatus(error.code) from None


def _absent(api, path):
    try:
        api(path)
    except DeliveryStatus as error:
        if error.status != 404:
            raise
    else:
        raise DeliveryError('DMG tag already exists; reconcile instead of replacing it')


def create_dmg_tag_release(api, plan_value, dmg_path=None):
    repository = admit_repository(str(plan_value.get('repository', '')))
    tag = str(plan_value['tag'])
    encoded = urllib.parse.quote(tag, safe='/')
    _absent(api, '/repos/' + repository + '/git/ref/tags/' + encoded)
    created = api('/repos/' + repository + '/git/tags', method='POST', body={
        'tag': tag,
        'message': plan_value['message'],
        'object': plan_value['target'],
        'type': 'commit',
    })
    require(isinstance(created, dict), 'DMG tag object is unknown; reconcile without retrying')
    tag_sha = created.get('sha')
    require(re.fullmatch(r'[0-9a-f]{40}', str(tag_sha or '')) is not None, 'DMG tag object is unknown; reconcile without retrying')
    api('/repos/' + repository + '/git/refs', method='POST', body={'ref': 'refs/tags/' + tag, 'sha': tag_sha})
    release = api('/repos/' + repository + '/releases', method='POST', body={
        'tag_name': tag,
        'target_commitish': plan_value['target'],
        'name': plan_value['name'],
        'body': plan_value['message'],
        'draft': False,
        'prerelease': True,
        'make_latest': 'false',
        'generate_release_notes': False,
    })
    require(isinstance(release, dict) and isinstance(release.get('id'), int) and release.get('id') > 0 and
            release.get('prerelease') is True and release.get('draft') is not True, 'DMG prerelease identity differs')
    asset_id = None
    if dmg_path is not None:
        path = Path(dmg_path)
        payload = json.loads(str(plan_value['message']).split('\n', 1)[1])
        expected = payload['artifacts'][0]
        require(path.is_file() and not path.is_symlink() and path.name == expected['filename'],
                'DMG release asset name differs')
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == expected['sha256'], 'DMG release asset digest differs')
        prefix = 'https://uploads.github.com/repos/' + repository + '/releases/' + str(release['id']) + '/assets'
        require(str(release.get('upload_url') or '').startswith(prefix + '{'), 'DMG upload URL differs')
        asset = api(prefix + '?name=' + urllib.parse.quote(path.name),
                    method='POST', data=data, content_type='application/octet-stream')
        require(isinstance(asset, dict) and asset.get('name') == path.name and asset.get('state') == 'uploaded',
                'DMG release asset was not uploaded')
        asset_id = asset.get('id')
    return {'tag': tag, 'tagObject': tag_sha, 'releaseId': release['id'], 'prerelease': True,
            'assetId': asset_id, 'repository': repository}


def promote_candidate(api, candidate_tag, actor_login, approved, repository=UPSTREAM):
    require(repository == UPSTREAM, 'Stable promotion waits until the fork matrix is synced to upstream')
    require(approved is True, 'Stable Direct release stays closed until an admin approves the candidate')
    require(re.fullmatch(r'candidate/macos/[0-9]+\.[0-9]+\.[0-9]+-(?:ad-hoc|host-signed|notarized)\.[1-9][0-9]*', candidate_tag) is not None,
            'Only a DMG candidate tag can be promoted')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}', actor_login) is not None, 'Admin identity is malformed')
    permission = api('/repos/' + UPSTREAM + '/collaborators/' + urllib.parse.quote(actor_login) + '/permission')
    require(isinstance(permission, dict) and permission.get('permission') == 'admin', 'Stable release requires a repository admin')
    ref = api('/repos/' + UPSTREAM + '/git/ref/tags/' + urllib.parse.quote(candidate_tag, safe='/'))
    require(isinstance(ref, dict), 'Candidate must be an annotated tag')
    obj = ref.get('object') or {}
    require(obj.get('type') == 'tag' and re.fullmatch(r'[0-9a-f]{40}', str(obj.get('sha', ''))) is not None,
            'Candidate must be an annotated tag')
    annotation = api('/repos/' + UPSTREAM + '/git/tags/' + obj['sha'])
    require(isinstance(annotation, dict), 'Candidate annotation is not a DMG tag')
    message = annotation.get('message') or ''
    require(message.startswith(TAG_SCHEMA + '\n'), 'Candidate annotation is not a DMG tag')
    payload = json.loads(message.split('\n', 1)[1])
    require(payload.get('schema') == TAG_SCHEMA and
            re.fullmatch(r'[0-9a-f]{40}', str(payload.get('sourceSha', ''))) is not None,
            'Candidate annotation identity is malformed')
    require(payload.get('packageKind') == 'notarized', 'Only a notarized candidate can become the stable release')
    commit = annotation.get('object') or {}
    require(commit.get('type') == 'commit' and commit.get('sha') == payload.get('sourceSha'),
            'Candidate target differs from its recorded source')
    version = str(payload.get('version', ''))
    require(VERSION.fullmatch(version) is not None, 'Candidate version is malformed')
    require(candidate_tag == dmg_tag_name(version, str(payload.get('build', '')), 'notarized'),
            'Candidate tag differs from its recorded coordinate')
    artifacts = payload.get('artifacts')
    require(isinstance(artifacts, list) and len(artifacts) == 1 and isinstance(artifacts[0], dict),
            'Candidate must record one arm64 DMG')
    expected = artifacts[0]
    require(expected.get('architecture') == 'arm64' and expected.get('filename') == dmg_filename(version) and
            re.fullmatch(r'[0-9a-f]{64}', str(expected.get('sha256', ''))) is not None,
            'Candidate DMG identity is malformed')
    candidate = api('/repos/' + UPSTREAM + '/releases/tags/' + urllib.parse.quote(candidate_tag, safe=''))
    require(isinstance(candidate, dict) and type(candidate.get('id')) is int and candidate['id'] > 0 and
            candidate.get('tag_name') == candidate_tag and candidate.get('prerelease') is True and
            candidate.get('draft') is False, 'Candidate prerelease identity differs')

    def verified_asset(release):
        assets = release.get('assets')
        require(isinstance(assets, list), 'Candidate DMG asset inventory is missing')
        matches = [asset for asset in assets if isinstance(asset, dict) and asset.get('name') == expected['filename']]
        require(len(matches) == 1, 'Candidate must contain exactly one matching DMG asset')
        asset = matches[0]
        require(type(asset.get('id')) is int and asset['id'] > 0 and asset.get('state') == 'uploaded' and
                type(asset.get('size')) is int and asset['size'] > 0 and
                asset.get('digest') == 'sha256:' + expected['sha256'], 'Candidate DMG asset digest or state differs')
        return asset['id']

    asset_id = verified_asset(candidate)
    stable = 'v' + version
    try:
        api('/repos/' + UPSTREAM + '/git/ref/tags/' + urllib.parse.quote(stable, safe=''))
    except DeliveryStatus as error:
        if error.status != 404:
            raise
    else:
        raise DeliveryError('Stable tag already exists; reconcile instead of replacing it')
    # Promote the existing release so the verified asset stays attached. The
    # annotated candidate tag remains available as the original evidence.
    api('/repos/' + UPSTREAM + '/git/refs', method='POST', body={
        'ref': 'refs/tags/' + stable, 'sha': payload['sourceSha'],
    })
    release = api('/repos/' + UPSTREAM + '/releases/' + str(candidate['id']), method='PATCH', body={
        'tag_name': stable,
        'target_commitish': payload['sourceSha'],
        'name': f'GCSA Aegis {version}',
        'body': 'Promoted from ' + candidate_tag + ' by ' + actor_login + '.\n\n' + message,
        'draft': False,
        'prerelease': False,
        'make_latest': 'true',
    })
    require(isinstance(release, dict) and release.get('id') == candidate['id'] and
            release.get('tag_name') == stable and release.get('prerelease') is False and
            release.get('draft') is False and verified_asset(release) == asset_id, 'Stable release identity differs')
    return {'tag': stable, 'candidate': candidate_tag, 'releaseId': release['id'], 'prerelease': False,
            'assetId': asset_id, 'repository': UPSTREAM}


def accept_complete(environment, destination):
    policy = json.loads(environment.get('AEGIS_IOS_DELIVERY_BOT') or 'null')
    require(isinstance(policy, dict) and isinstance(policy.get('slug'), str), 'Pinned App configuration required')
    repository = admit_repository(environment.get('GITHUB_REPOSITORY', ''))
    require(environment.get('GITHUB_REF') == 'refs/heads/main', 'Bot completion must stay on main')
    require(environment.get('GITHUB_ACTOR') == policy['slug'] + '[bot]', 'Bot completion actor differs')
    require(str(environment.get('GITHUB_ACTOR_ID')) == str(policy.get('actorId')), 'Bot completion actor differs')
    operation = environment.get('AEGIS_MACOS_INPUT_COMPLETED_OPERATION', '')
    require(operation == 'package', 'Completed DMG operation is unknown')
    version = environment.get('AEGIS_MACOS_INPUT_VERSION', '')
    build = environment.get('AEGIS_MACOS_INPUT_BUILD', '')
    sha = environment.get('AEGIS_MACOS_INPUT_APPROVED_SOURCE_SHA', '')
    parent = environment.get('AEGIS_MACOS_INPUT_PARENT_RUN_ID', '')
    manifest = environment.get('AEGIS_MACOS_INPUT_MANIFEST_SHA256', '')
    package_kind = environment.get('AEGIS_MACOS_INPUT_PACKAGE_KIND', '')
    signing_mode = environment.get('AEGIS_MACOS_INPUT_SIGNING_MODE', '')
    candidate_tag = environment.get('AEGIS_MACOS_INPUT_CANDIDATE_TAG', '')
    require(VERSION.fullmatch(version) is not None and BUILD.fullmatch(build) is not None, 'Completed coordinate is malformed')
    require(re.fullmatch(r'[0-9a-f]{40}', sha) is not None, 'Completed source is malformed')
    require(re.fullmatch(r'[1-9][0-9]*', parent) is not None, 'Completed parent run is malformed')
    require(re.fullmatch(r'[0-9a-f]{64}', manifest) is not None, 'Completed manifest is missing')
    require(package_kind in DMG_KINDS and signing_mode == package_kind, 'Completed package kind differs')
    require(not candidate_tag or candidate_tag == dmg_tag_name(version, build, package_kind),
            'Completed candidate coordinate differs')
    receipt = {
        'schema': 'aegis-macos-delivery-bot-v1',
        'operation': operation,
        'version': version,
        'build': build,
        'sourceSha': sha,
        'parentRunId': int(parent),
        'manifestSha256': manifest,
        'repository': repository,
        'actor': policy['slug'] + '[bot]',
        'packageKind': package_kind,
        'candidateTag': candidate_tag,
    }
    require(not destination.exists(), 'Refusing to replace a bot receipt')
    destination.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    return receipt


def inputs_from_environment(environment):
    return {key: environment.get('AEGIS_MACOS_INPUT_' + key.upper(), '') for key in INPUT_KEYS}


def write_output(path, values):
    with path.open('a', encoding='utf-8') as handle:
        for key in sorted(values):
            handle.write(f'{key}={values[key]}\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'seal', 'tag-release', 'promote', 'accept-complete'])
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--package-kind')
    parser.add_argument('--version')
    parser.add_argument('--build')
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--dmg', type=Path)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--candidate-tag')
    args = parser.parse_args(argv)
    try:
        if args.command == 'plan':
            values = plan(dict(os.environ), inputs_from_environment(dict(os.environ)))
            write_output(Path(os.environ['GITHUB_OUTPUT']), values)
        elif args.command == 'seal':
            seal(args.directory, args.package_kind, args.version, args.build, os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY'])
        elif args.command == 'tag-release':
            manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
            digest = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
            planned = plan_dmg_tag(manifest, digest, os.environ['GITHUB_SHA'])
            token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN') or ''
            require(token != '', 'DMG candidate release requires a token')
            api = lambda path, method='GET', body=None, data=None, content_type=None: github_request(
                path, token, method, body, data, content_type)
            print(json.dumps(create_dmg_tag_release(api, planned, args.dmg)))
        elif args.command == 'promote':
            token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN') or ''
            require(token != '', 'Stable promotion requires an admin token')
            api = lambda path, method='GET', body=None, data=None, content_type=None: github_request(
                path, token, method, body, data, content_type)
            print(json.dumps(promote_candidate(
                api, args.candidate_tag, os.environ.get('GITHUB_ACTOR', ''),
                os.environ.get('AEGIS_MACOS_DMG_STABLE_RELEASE_APPROVED') == 'true',
                os.environ.get('GITHUB_REPOSITORY', ''))))
        else:
            destination = args.receipt or Path(os.environ['RUNNER_TEMP']) / 'macos-delivery-bot-receipt.json'
            print(json.dumps(accept_complete(dict(os.environ), destination)))
    except (DeliveryError, OSError, KeyError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
