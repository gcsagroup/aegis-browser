#!/usr/bin/env python3
"""Seal an Android package and run one explicit Play or GitHub Draft stage."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote
import zipfile


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


archive = module('android_package_archive', 'android_package_archive.py')
receipt = module('android_delivery_receipt', 'android-delivery-receipt.py')
records = module('android_product_delivery', 'android_product_delivery.py')
play = module('android_play', 'android-play.py')
verifier = module('verify_aab', 'verify-aab.py')
release = module('android_github_release', 'android-github-release.py')

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = archive.REPOSITORY


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plan_from_env():
    value = json.loads(os.environ['ANDROID_DELIVERY_PLAN'])
    require(isinstance(value, dict), 'Android delivery plan is invalid')
    return value


def git_output(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def source_identity(root=ROOT):
    require(git_output('status', '--porcelain', '--untracked-files=all') == '',
            'Android packaging requires a clean committed source')
    sha, tree = git_output('rev-parse', 'HEAD'), git_output('rev-parse', 'HEAD^{tree}')
    gn = (root / 'apps/browser/args/aegis-android.gn').read_text()
    header = (root / 'apps/browser/overlay/chrome/browser/ui/webui/help/aegis_github_update.h').read_text()
    version = re.search(r'kProductVersion\[\] = "([^"]+)"', header)
    code = re.search(r'^android_override_version_code = "(\d+)"$', gn, re.M)
    label = re.search(r'^android_override_version_name = "([^"]+)"$', gn, re.M)
    require(version and code and label and label.group(1) in header, 'Committed Android version metadata is incomplete')
    receipt.require_version_code(version.group(1), code.group(1))
    return {'sha': sha, 'tree': tree, 'version': version.group(1), 'build': code.group(1)}


def locate_aab(out_dir):
    override = os.environ.get('AEGIS_ANDROID_AAB', '')
    if override:
        path = Path(override)
        require(path.is_file() and not path.is_symlink(), 'AEGIS_ANDROID_AAB must be a real file')
        return path
    found = [path for path in Path(out_dir).glob('apks/*.aab') if path.is_file() and not path.is_symlink()]
    require(len(found) == 1, 'The Android out directory must contain exactly one signed App Bundle at apks/*.aab')
    return found[0]


def zip_symbols(out_dir, destination):
    libraries = [path for path in Path(out_dir, 'lib.unstripped').rglob('*.so') if path.is_file() and not path.is_symlink()]
    require(libraries, 'Release packages require native libraries in out/AegisAndroid/lib.unstripped. '
            'symbol_level is 0 in the current Android build args, so this out directory has no symbols to publish.')
    with zipfile.ZipFile(destination, 'x') as zipped:
        for path in libraries:
            zipped.write(path, path.relative_to(out_dir / 'lib.unstripped').as_posix())
    archive.assert_symbols(destination)


def seal_package(plan, identity, aab, symbols, certificate, run_id):
    version, build = plan['version'], plan['build']
    require((version, build) == (identity['version'], identity['build']),
            'Requested versionCode differs from the committed Android source')
    aab_name, symbols_name = archive.asset_names(version, build)
    files = {aab_name: aab}
    if symbols is not None:
        files[symbols_name] = symbols
    require(plan['profile'] != 'release' or symbols is not None, 'A Release package requires native symbols')
    manifest = {'schema': 'aegis-android-manifest-v1', 'repository': REPOSITORY, 'platform': 'android',
                'applicationId': archive.APPLICATION_ID, 'profile': plan['profile'], 'version': version, 'build': build,
                'source': {'sha': identity['sha'], 'tree': identity['tree'], 'dirty': False},
                'details': {'certificateSha256': certificate},
                'assets': []}
    for name, path in files.items():
        manifest['assets'].append({'name': name, 'size': Path(path).stat().st_size, 'sha256': archive.sha256(path)})
    manifest['assets'].sort(key=lambda row: row['name'])
    signature = {'schema': 'aegis-android-signature-v1', 'certificateSha256': certificate,
                 'artifactSha256': next(row['sha256'] for row in manifest['assets'] if row['name'].endswith('.aab'))}
    origin = {'repository': REPOSITORY, 'runId': run_id, 'attempt': 1, 'sourceSha': identity['sha'],
              'sourceTree': identity['tree'], 'runIdLocal': f'android-gh-{run_id}-1'}
    directory = ROOT / '.artifacts/android-delivery/unpacked'
    digest, origin = archive.seal(directory, manifest, origin, signature, files)
    archive.zip_flat(directory, ROOT / '.artifacts/android-delivery/package.zip')
    pending = {'origin': origin, 'profile': plan['profile'], 'version': version, 'build': build,
               'manifestSha256': digest}
    (ROOT / '.artifacts/android-delivery/package-pending.json').write_text(json.dumps(pending, indent=2, sort_keys=True) + '\n')
    return pending


def require_absent(version, build, store, kinds):
    key = records.allocation(archive.APPLICATION_ID, version, build)
    for kind in kinds:
        require(store.read(kind, key) is None, 'This versionCode is already recorded; reconcile instead of replaying')


def record_package(pending, artifact, job_id, store):
    key = records.allocation(archive.APPLICATION_ID, pending['version'], pending['build'])
    payload = {'origin': pending['origin'], 'package_job_id': job_id, 'artifact_id': artifact['id'],
               'artifact_digest': artifact['digest'], 'artifact_name': artifact['name'],
               'version': pending['version'], 'build': pending['build'], 'profile': pending['profile']}
    existing = store.read('package', key)
    if existing is not None:
        require(existing == payload, 'Existing package record does not match this sealed artifact')
        return existing
    return store.create('package', key, payload)


def validate_query(plan):
    require(plan.get('operation') in {'status-query', 'status-wait', 'status-release-wait'},
            'Query admission only accepts a read-only status operation')
    receipt.require_version_code(plan.get('version'), plan.get('build'))
    require(plan.get('destination') == 'play-internal' and not plan.get('track') and not plan.get('tag'),
            'Status cannot select a track, tag, or mutation')


def play_stage(plan, package_dir, client, store):
    version, build = plan['version'], plan['build']
    code = receipt.require_version_code(version, build)
    key = records.allocation(archive.APPLICATION_ID, version, build)
    if plan['operation'] in {'package-upload', 'upload'}:
        require_absent(version, build, store, ('upload-start', 'upload-result'))
        origin = json.loads((Path(package_dir) / 'package-origin.json').read_text())
        archive.verify_package(package_dir, origin['sourceSha'], origin['sourceTree'], origin['manifestSha256'])
        intent = play.draft_intent(version, build, plan['profile'], archive.sha256(Path(package_dir) / 'android-manifest.json'), plan['track'])
        store.create('upload-start', key, intent)
        result = client.upload_draft(Path(package_dir) / archive.asset_names(version, build)[0], code, plan['track'])
        store.create('upload-result', key, {'intent': intent, 'result': result})
        return result
    if plan['operation'] == 'distribute':
        return client.update_track(code, plan['track'], 'inProgress', plan['user_fraction'])
    require(plan['operation'] == 'submit', 'Unsupported Play stage')
    return client.update_track(code, 'production', 'completed', '')


def main():
    command = sys_argv()
    value = plan_from_env()
    if command == 'check-new-upload':
        require(value['operation'] == 'package-upload', 'Unused-version admission is only for a new upload')
        require_absent(value['version'], value['build'], release._store(), ('package', 'upload-start', 'upload-result'))
        return
    if command == 'validate-query':
        validate_query(value)
        return
    if command == 'package':
        identity = source_identity()
        require(os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Package attempt must stay on the first run')
        certificate = verifier.normalize_certificate(os.environ['AEGIS_ANDROID_CERT_SHA256'])
        out = Path(os.environ['AEGIS_ANDROID_OUT']) if os.environ.get('AEGIS_ANDROID_OUT') else None
        if out is None and os.environ.get('CHROMIUM_ROOT'):
            out = Path(os.environ['CHROMIUM_ROOT']) / 'src' / 'out' / 'AegisAndroid'
        aab = locate_aab(out) if out or os.environ.get('AEGIS_ANDROID_AAB') else None
        require(aab is not None, 'Set AEGIS_ANDROID_AAB or CHROMIUM_ROOT to the signed App Bundle output')
        require(verifier.certificate_sha256(aab) == certificate, 'App Bundle certificate differs from the pinned upload key')
        symbols = None
        if value['profile'] == 'release':
            supplied = os.environ.get('AEGIS_ANDROID_SYMBOLS', '')
            symbols_path = Path(supplied) if supplied else ROOT / '.artifacts/android-delivery/symbols.zip'
            if not supplied:
                require(out is not None, 'Release packaging needs CHROMIUM_ROOT to collect native symbols')
                symbols_path.parent.mkdir(parents=True, exist_ok=True)
                zip_symbols(out, symbols_path)
            archive.assert_symbols(symbols_path)
            symbols = symbols_path
        seal_package(value, identity, aab, symbols, certificate, int(os.environ['GITHUB_RUN_ID']))
        return
    if command == 'record-package':
        pending = json.loads((ROOT / '.artifacts/android-delivery/package-pending.json').read_text())
        run_id = int(os.environ['GITHUB_RUN_ID'])
        name = f'android-package-{run_id}-1'
        rows = release._api_items(f'actions/runs/{run_id}/artifacts?per_page=100', 'artifacts')
        matches = [row for row in rows if row.get('name') == name and row.get('expired') is False]
        require(len(matches) == 1 and release.is_id(matches[0].get('id')), 'Sealed package artifact is missing or ambiguous')
        jobs = release._get_jobs(run_id)
        job_matches = [job for job in jobs if job.get('name') == 'delivery / package']
        require(len(job_matches) == 1 and release.is_id(job_matches[0].get('id')), 'Package job identity is ambiguous')
        record_package(pending, matches[0], job_matches[0]['id'], release._store())
        return
    if command == 'import':
        run_id = int(value['package_run_id'] or os.environ['GITHUB_RUN_ID'])
        rows = release._api_items(f'actions/runs/{run_id}/artifacts?per_page=100', 'artifacts')
        matches = [row for row in rows if row.get('name') == f'android-package-{run_id}-1' and row.get('expired') is False]
        require(len(matches) == 1 and release.is_id(matches[0].get('id')), 'Sealed package artifact is missing or ambiguous')
        destination = ROOT / '.artifacts/android-delivery/imported.zip'
        release.download_package_artifact(run_id, matches[0]['id'], destination)
        archive.extract_flat(destination, ROOT / '.artifacts/android-delivery/unpacked')
        return
    if command == 'play-stage':
        key = json.loads(os.environ['AEGIS_PLAY_JSON_KEY_DATA'])
        token = play.access_token(key, play.urllib_transport, int(__import__('time').time()))
        client = play.Play(play.urllib_transport, token)
        play_stage(value, ROOT / '.artifacts/android-delivery/unpacked', client, release._store())
        return
    require(command == 'stage', 'Unknown Android delivery command')
    stage_draft(value, ROOT / '.artifacts/android-delivery/unpacked')


def stage_draft(plan, package_dir):
    require(plan.get('operation') == 'draft' and plan.get('destination') == 'github-draft',
            'Draft stage requires a GitHub Draft destination')
    tag = plan['tag']
    head = git_output('rev-parse', 'HEAD')
    commit = release._api('commits/' + quote(tag, safe=''))
    require(commit.get('sha') == head, 'Candidate tag does not point at this source')
    try:
        existing = release._api('releases/tags/' + quote(tag, safe=''))
    except release.NotFoundError:
        existing = None
    if existing is None:
        existing = release._api('releases', {'tag_name': tag, 'target_commitish': head, 'name': tag,
                                            'body': 'Aegis Android candidate draft\n', 'draft': True,
                                            'prerelease': True, 'make_latest': 'false'})
    require(is_draft(existing, tag), 'Candidate release is no longer a draft for this tag')
    origin = json.loads((Path(package_dir) / 'package-origin.json').read_text())
    manifest = archive.verify_package(package_dir, origin['sourceSha'], origin['sourceTree'], origin['manifestSha256'])
    present = {item.get('name') for item in (existing.get('assets') or [])}
    for row in manifest['assets']:
        if row['name'] in present:
            continue
        release._upload_asset_once(existing['id'], {'name': row['name'], 'size': row['size'],
                                                   'sha256': row['sha256'], 'path': str(Path(package_dir) / row['name'])})
    proof_dir = ROOT / '.artifacts/release/android' / plan['build']
    proof_dir.mkdir(parents=True, exist_ok=True)
    proof = {'tag': tag, 'releaseId': existing['id'], 'draft': True, 'sha': head,
             'assets': {row['name']: row['sha256'] for row in manifest['assets']}}
    (proof_dir / 'github-draft.json').write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    (proof_dir / f"android-draft-download-{existing['id']}.json").write_text(json.dumps({'id': existing['id'], 'tag_name': tag, 'draft': True}, indent=2) + '\n')


def is_draft(release_row, tag):
    return isinstance(release_row, dict) and release_row.get('draft') is True and release_row.get('tag_name') == tag and release.is_id(release_row.get('id'))


def sys_argv():
    import sys
    require(len(sys.argv) == 2, 'Usage: android-delivery.py check-new-upload|package|record-package|import|play-stage|stage|validate-query')
    return sys.argv[1]


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
