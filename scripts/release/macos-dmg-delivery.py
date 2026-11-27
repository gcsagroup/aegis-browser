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
# Candidate delivery versions can identify test packages built from a specific
# committed desktop version.
UPSTREAM_AD_HOC_TEST_VERSIONS = {('0.8.0', '1'): '7.5.0.345'}
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


def desktop_product_version():
    header = (Path(__file__).resolve().parents[2] /
              'apps/browser/overlay/chrome/browser/ui/webui/help/aegis_github_update.h')
    match = re.search(r'kProductVersion\[\] = "([0-9]+(?:\.[0-9]+){3})";',
                      header.read_text(encoding='utf-8'))
    require(match is not None, 'Missing desktop product version')
    return match[1]


def test_candidate_product_version(repository, package_kind, version, build):
    if repository == UPSTREAM and package_kind == 'ad-hoc':
        return UPSTREAM_AD_HOC_TEST_VERSIONS.get((version, build))
    return None


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
    if repository == UPSTREAM:
        require(package_kind == 'ad-hoc', 'Upstream DMG delivery currently accepts ad-hoc only')
        test_product = test_candidate_product_version(repository, package_kind, version, build)
        require(desktop_product_version() == (test_product or f'{version}.{build}'),
                'Ad-hoc coordinate must match its committed desktop product version')
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
    test_product = test_candidate_product_version(repository, package_kind, version, build)
    if test_product is not None:
        require(desktop_product_version() == test_product,
                'Test candidate desktop product version differs')
        manifest['desktopProductVersion'] = test_product
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
    test_product = test_candidate_product_version(repository, package_kind, version, build)
    if test_product is not None:
        require(manifest.get('desktopProductVersion') == test_product,
                'Sealed test candidate desktop product version differs')
        payload['desktopProductVersion'] = test_product
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


def github_request(path, token, method='GET', body=None, data=None, content_type=None, content_length=None):
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
            **({} if content_length is None else {'Content-Length': str(content_length)}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return None if response.status == 204 or not raw else json.loads(raw.decode())
    except urllib.error.HTTPError as error:
        raise DeliveryStatus(error.code) from None


def _read_optional(api, path):
    try:
        return api(path)
    except DeliveryStatus as error:
        if error.status != 404:
            raise
        return None


def _find_candidate_release(api, prefix, tag):
    release = _read_optional(api, prefix + '/releases/tags/' + urllib.parse.quote(tag, safe=''))
    if release is not None:
        return release
    drafts = []
    for page in range(1, 21):
        rows = api(prefix + f'/releases?per_page=100&page={page}')
        require(isinstance(rows, list) and len(rows) <= 100, 'Incomplete DMG release inventory')
        drafts.extend(row for row in rows if row.get('tag_name') == tag)
        if len(rows) < 100:
            require(len(drafts) <= 1, 'Multiple releases exist for this DMG candidate')
            return drafts[0] if drafts else None
    raise DeliveryError('Incomplete DMG release inventory')


def create_dmg_tag_release(api, plan_value, dmg_path):
    repository = admit_repository(str(plan_value.get('repository', '')))
    tag = str(plan_value['tag'])
    encoded = urllib.parse.quote(tag, safe='/')
    prefix = '/repos/' + repository
    path = Path(dmg_path)
    payload = json.loads(str(plan_value['message']).split('\n', 1)[1])
    expected = payload['artifacts'][0]
    require(path.is_file() and not path.is_symlink() and path.name == expected['filename'],
            'DMG release asset name differs')
    size = path.stat().st_size
    require(0 < size < 2 * 1024 ** 3, 'DMG release asset size is out of bounds')
    digest = _sha256(path)
    require(digest == expected['sha256'], 'DMG release asset digest differs')
    ref_path = prefix + '/git/ref/tags/' + encoded
    ref = _read_optional(api, ref_path)
    release = _find_candidate_release(api, prefix, tag)
    spec = {'tag': tag, 'message': plan_value['message'], 'object': plan_value['target'], 'type': 'commit'}
    if ref is None:
        require(release is None, 'Existing DMG release has no candidate tag')
        tag_sha = api(prefix + '/git/tags', method='POST', body=spec).get('sha')
        require(re.fullmatch(r'[0-9a-f]{40}', str(tag_sha or '')) is not None,
                'DMG tag object is unknown; reconcile without retrying')
        api(prefix + '/git/refs', method='POST', body={'ref': 'refs/tags/' + tag, 'sha': tag_sha})
    else:
        obj = ref.get('object') or {}
        tag_sha = obj.get('sha')
        require(obj.get('type') == 'tag' and re.fullmatch(r'[0-9a-f]{40}', str(tag_sha or '')) is not None,
                'Existing DMG tag is not the sealed annotated tag')
        original = api(prefix + '/git/tags/' + tag_sha)
        require(original.get('tag') == tag and original.get('message') == spec['message'] and
                original.get('object', {}).get('type') == 'commit' and
                original.get('object', {}).get('sha') == spec['object'],
                'Existing DMG tag differs from the sealed package')

    body = plan_value['message']
    if payload['packageKind'] == 'ad-hoc':
        note = 'Apple Silicon (arm64). Ad-hoc signature. Unnotarized.'
        if 'desktopProductVersion' in payload:
            note += (f'\n\nTest DMG {payload["version"]} (build {payload["build"]}). '
                     f'Embedded desktop product version {payload["desktopProductVersion"]}.')
        body = note + '\n\n' + body
    if release is None:
        release = api(prefix + '/releases', method='POST', body={
            'tag_name': tag, 'target_commitish': spec['object'], 'name': plan_value['name'], 'body': body,
            'draft': True, 'prerelease': True, 'make_latest': 'false', 'generate_release_notes': False,
        })
    release_id = release.get('id')
    require(type(release_id) is int and release_id > 0 and release.get('tag_name') == tag and
            release.get('prerelease') is True and type(release.get('draft')) is bool and release.get('body') == body,
            'DMG candidate release identity differs')

    def asset_matches(item):
        return (isinstance(item, dict) and type(item.get('id')) is int and item['id'] > 0 and
                item.get('name') == path.name and item.get('state') == 'uploaded' and
                item.get('size') == size and item.get('digest') == 'sha256:' + digest)

    assets = release.get('assets')
    require(isinstance(assets, list) and len(assets) <= 1, 'DMG candidate asset inventory differs')
    if assets:
        asset = assets[0]
    else:
        require(release['draft'], 'Public DMG candidate is missing its asset')
        upload = 'https://uploads.github.com' + prefix + f'/releases/{release_id}/assets'
        require(str(release.get('upload_url') or '').startswith(upload + '{'), 'DMG upload URL differs')
        with path.open('rb') as data:
            asset = api(upload + '?name=' + urllib.parse.quote(path.name), method='POST', data=data,
                        content_type='application/octet-stream', content_length=size)
    require(asset_matches(asset), 'DMG candidate asset differs')
    asset_id = asset['id']

    def verify_publication_target(snapshot, draft):
        assets = snapshot.get('assets')
        require(snapshot.get('id') == release_id and snapshot.get('tag_name') == tag and
                snapshot.get('prerelease') is True and snapshot.get('draft') is draft and
                snapshot.get('body') == body and isinstance(assets, list) and len(assets) == 1 and
                asset_matches(assets[0]) and assets[0]['id'] == asset_id,
                'DMG release or asset changed; reconcile without repeating the write')
        current_ref = api(ref_path).get('object')
        require(isinstance(current_ref, dict) and current_ref.get('type') == 'tag' and
                current_ref.get('sha') == tag_sha,
                'DMG candidate tag changed; reconcile without repeating the write')

    if release['draft']:
        release_path = prefix + f'/releases/{release_id}'
        verify_publication_target(api(release_path), True)
        public = api(release_path, method='PATCH',
                     body={'draft': False, 'prerelease': True, 'make_latest': 'false'})
        verify_publication_target(public, False)
    else:
        verify_publication_target(release, False)
    return {'tag': tag, 'tagObject': tag_sha, 'releaseId': release_id, 'prerelease': True,
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
            require(args.dmg is not None, 'Candidate release requires a sealed DMG')
            planned = plan_dmg_tag(manifest, digest, os.environ['GITHUB_SHA'])
            token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN') or ''
            require(token != '', 'DMG candidate release requires a token')
            api = lambda path, **options: github_request(path, token, **options)
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
