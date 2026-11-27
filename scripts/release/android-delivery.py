#!/usr/bin/env python3
"""Seal an Android package and run one explicit Play or GitHub Draft stage."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
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
PACKAGE_OPERATIONS = frozenset({'package', 'package-upload', 'draft'})


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
    metadata = json.loads((root / 'apps/browser/args/android-delivery-version.json').read_text())
    require(isinstance(metadata, dict) and set(metadata) == {'versionName', 'versionCode'},
            'Committed Android version metadata is incomplete')
    version, code = metadata['versionName'], metadata['versionCode']
    receipt.require_version_code(version, code)
    require(len(version.split('.')) == 3, 'Android versionName must have three components')
    return {'sha': sha, 'tree': tree, 'version': version, 'build': code}


def zip_symbols(out_dir, destination):
    libraries = [path for path in Path(out_dir, 'lib.unstripped').rglob('*.so') if path.is_file() and not path.is_symlink()]
    require(libraries, 'The Android producer did not generate unstripped native libraries for Release')
    with zipfile.ZipFile(destination, 'x') as zipped:
        for path in libraries:
            zipped.write(path, path.relative_to(out_dir / 'lib.unstripped').as_posix())
    archive.assert_symbols(destination)


def producer_output(run_id):
    chromium = Path(os.environ['CHROMIUM_ROOT']).resolve(strict=True)
    output = chromium / 'src' / 'out' / f'AegisAndroidDelivery-{run_id}-1'
    require(output.resolve() == output, 'Android producer requires a physical Chromium source and output path')
    return chromium, output


def verify_bundle_manifest(chromium, aab, build, *, version_name=None):
    jar = chromium / 'src/third_party/android_build_tools/bundletool/cipd/bundletool.jar'
    require(jar.is_file(), 'The pinned Chromium bundletool is missing')
    output = subprocess.run(['java', '-jar', str(jar), 'dump', 'manifest',
                             '--bundle=' + str(aab), '--module=base'],
                            capture_output=True, timeout=120, check=True)
    manifest = ET.fromstring(output.stdout)
    android = '{http://schemas.android.com/apk/res/android}'
    application = manifest.find('application')
    require(manifest.tag == 'manifest' and manifest.get('package') == archive.APPLICATION_ID
            and manifest.get(android + 'versionCode') == build,
            'Generated Android bundle package or versionCode differs from the producer')
    if version_name is not None:
        require(manifest.get(android + 'versionName') == version_name,
                'Generated Android bundle versionName differs from the producer')
    require(application is not None and application.get(android + 'debuggable', 'false') == 'false',
            'Generated App Bundle is debuggable')


def retire_producer_output():
    pending = json.loads((ROOT / '.artifacts/android-delivery/package-pending.json').read_bytes())
    run_id = int(os.environ['GITHUB_RUN_ID'])
    sha = os.environ['GITHUB_SHA']
    origin = pending['origin']
    require(os.environ['GITHUB_RUN_ATTEMPT'] == '1' and origin['runId'] == run_id and origin['sourceSha'] == sha,
            'Android producer cleanup does not own this run')
    key = records.allocation(archive.APPLICATION_ID, pending['version'], pending['build'])
    record = release._store().read('package', key)
    require(record is not None and record['origin'] == origin,
            'Retain Android producer output until the sealed artifact is recorded')
    _, output = producer_output(run_id)
    marker = output / '.aegis-producer'
    require(output.is_dir() and output.resolve() == output and not marker.is_symlink()
            and marker.read_text() == f'{run_id}\n{sha}\n', 'Cannot prove ownership of Android producer output')
    shutil.rmtree(output)


def build_and_seal(plan):
    identity = source_identity()
    require(identity['sha'] == os.environ['GITHUB_SHA'], 'Android producer checkout differs from workflow source')
    require((plan['version'], plan['build']) == (identity['version'], identity['build']),
            'Requested versionCode differs from the committed Android source')
    require(os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Package attempt must stay on the first run')
    run_id = int(os.environ['GITHUB_RUN_ID'])
    require_absent(plan['version'], plan['build'], release._store(), ('package', 'upload-start', 'upload-result'))
    certificate = verifier.normalize_certificate(os.environ['AEGIS_ANDROID_CERT_SHA256'])
    chromium, out = producer_output(run_id)
    release_dir = ROOT / '.artifacts/android-delivery'
    release_dir.mkdir(parents=True, exist_ok=True)
    # The unsigned AAB and symbols must come from this run's empty GN output.
    env = {**os.environ, 'CHROMIUM_ROOT': str(chromium), 'OUT_DIR': str(out),
           'AEGIS_ANDROID_VERSION_NAME': identity['version'], 'AEGIS_ANDROID_VERSION_CODE': identity['build']}
    subprocess.run(['bash', str(ROOT / 'apps/browser/scripts/build-android.sh'), '--app-bundle', plan['profile']],
                   cwd=ROOT, env=env, check=True)
    require(source_identity() == identity, 'Android producer source changed during the build')
    unsigned = out / 'apks/ChromePublic.aab'
    archive.assert_aab(unsigned)
    verify_bundle_manifest(chromium, unsigned, identity['build'], version_name=identity['version'])
    with tempfile.TemporaryDirectory(prefix='producer-', dir=release_dir) as temp:
        signed = Path(temp) / 'signed.aab'
        release._assert_current_release_source({'source': {'sha': identity['sha'], 'tree': identity['tree']}})
        signing = subprocess.run([
            'jarsigner', '-keystore', str(Path(os.environ['AEGIS_ANDROID_KEYSTORE']).resolve(strict=True)),
            '-storepass:env', 'AEGIS_ANDROID_STORE_PASSWORD', '-keypass:env', 'AEGIS_ANDROID_KEY_PASSWORD',
            '-signedjar', str(signed), str(unsigned), os.environ['AEGIS_ANDROID_KEY_ALIAS'],
        ], capture_output=True, timeout=120)
        require(signing.returncode == 0, 'Could not sign the current producer App Bundle with the Android upload key')
        require(verifier.certificate_sha256(signed) == certificate,
                'App Bundle certificate differs from the pinned upload key')
        symbols = None
        if plan['profile'] == 'release':
            symbols = Path(temp) / 'symbols.zip'
            zip_symbols(out, symbols)
        require(source_identity() == identity, 'Android producer source changed before sealing')
        return seal_package(plan, identity, signed, symbols, certificate, run_id)


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
    origin = pending['origin']

    def authorize_create():
        release._assert_current_release_source({'source': {'sha': origin['sourceSha'], 'tree': origin['sourceTree']}})

    return store.create('package', key, payload, authorize_create=authorize_create)


def approved_package(plan, store):
    operation = plan['operation']
    pinned = operation in {'upload', 'distribute', 'submit'}
    if pinned:
        require(plan.get('package_run_id') and plan.get('source_attempt') == '1'
                and release.is_sha(plan.get('manifest_sha256'), 64),
                'An exact first-attempt Android delivery receipt is required')
        run_id = int(plan['package_run_id'])
    else:
        require(operation in {'package-upload', 'draft'} and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
                'Same-run bundle import requires the original producer attempt')
        run_id = int(os.environ['GITHUB_RUN_ID'])
    key = records.allocation(archive.APPLICATION_ID, plan['version'], plan['build'])
    record = store.read('package', key)
    require(isinstance(record, dict) and all(record.get(field) == plan[field] for field in ('version', 'build', 'profile')),
            'Approved Android package identity is absent or differs from the delivery plan')
    origin = record.get('origin', {})
    require(isinstance(origin, dict) and origin.get('repository') == REPOSITORY
            and origin.get('runId') == run_id and type(origin.get('attempt')) is int and origin['attempt'] == 1
            and origin.get('runIdLocal') == f'android-gh-{run_id}-1'
            and release.is_sha(origin.get('sourceSha')) and release.is_sha(origin.get('sourceTree'))
            and release.is_sha(origin.get('manifestSha256'), 64)
            and release.is_id(record.get('package_job_id')) and release.is_id(record.get('artifact_id'))
            and record.get('artifact_name') == f'android-package-{run_id}-1'
            and isinstance(record.get('artifact_digest'), str)
            and re.fullmatch(r'sha256:[0-9a-f]{64}', record['artifact_digest']) is not None,
            'Android package record does not bind an exact producer and artifact')
    require(origin['sourceSha'] == os.environ['GITHUB_SHA'], 'Package source differs from the admitted workflow source')
    if pinned:
        require(origin['manifestSha256'] == plan['manifest_sha256'], 'Approved Android receipt manifest digest differs')
    return record


def verify_approved_package(plan, package_dir, approved):
    origin = approved['origin']
    directory = Path(package_dir)
    require(json.loads((directory / 'package-origin.json').read_text()) == origin,
            'Extracted Android package origin differs from the approved producer')
    manifest = archive.verify_package(directory, origin['sourceSha'], origin['sourceTree'], origin['manifestSha256'])
    require(all(manifest.get(field) == plan[field] for field in ('version', 'build', 'profile')),
            'Extracted Android package identity differs from the delivery plan')
    return manifest


def import_package(plan, store, destination):
    approved = approved_package(plan, store)
    origin = approved['origin']
    run_id = origin['runId']
    run = release._get_run(run_id)
    same_run = str(run_id) == os.environ['GITHUB_RUN_ID']
    run['jobs'] = release._get_jobs(run_id)
    job = release._package_job(run, run_id, origin['sourceSha'], same_run=same_run)
    require(job['id'] == approved['package_job_id'], 'Android package job differs from the approved producer')
    commit = release._api(f"git/commits/{origin['sourceSha']}")
    require(commit.get('sha') == origin['sourceSha'] and commit.get('tree', {}).get('sha') == origin['sourceTree'],
            'Approved Android producer tree differs from GitHub')
    destination = Path(destination)
    bundle = destination.parent / 'imported.zip'
    release.download_package_artifact(run_id, approved['artifact_id'], bundle, expected_digest=approved['artifact_digest'])
    archive.extract_flat(bundle, destination)
    return verify_approved_package(plan, destination, approved)


def validate_query(plan):
    require(plan.get('operation') in {'status-query', 'status-wait', 'status-release-wait'},
            'Query admission only accepts a read-only status operation')
    receipt.require_version_code(plan.get('version'), plan.get('build'))
    require(plan.get('destination') == 'play-internal' and not plan.get('track') and not plan.get('tag'),
            'Status cannot select a track, tag, or mutation')


def emit_receipt(record, upload_run_id=None):
    origin = record['origin']
    packaged = origin['runId']
    upload = upload_run_id is not None
    target = receipt.encode(record['profile'], record['version'], record['build'], packaged,
                            upload_run_id if upload else packaged, origin['attempt'], origin['manifestSha256'], draft=upload)
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with Path(path).open('a') as output:
            output.write(f'\n### Android delivery receipt\n\n`{target}`\n')
    else:
        print(target)


def play_stage(plan, package_dir, client, store):
    version, build = plan['version'], plan['build']
    code = receipt.require_version_code(version, build)
    key = records.allocation(archive.APPLICATION_ID, version, build)
    approved = approved_package(plan, store)
    verify_approved_package(plan, package_dir, approved)
    origin = approved['origin']
    source = {'source': {'sha': origin['sourceSha'], 'tree': origin['sourceTree']}}

    def authorize_write():
        release._assert_current_release_source(source)

    if plan['operation'] in {'package-upload', 'upload'}:
        require(os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Play upload requires the first workflow attempt')
        upload_run_id = int(os.environ['GITHUB_RUN_ID'])
        require_absent(version, build, store, ('upload-start', 'upload-result'))
        intent = play.draft_intent(version, build, plan['profile'], origin['manifestSha256'], plan['track'])
        client.check_test_track(code, plan['track'], authorize_write=authorize_write)
        store.create('upload-start', key, intent, authorize_create=authorize_write)
        result = client.upload_draft(Path(package_dir) / archive.asset_names(version, build)[0], code, plan['track'],
                                     authorize_write=authorize_write)
        store.create('upload-result', key, {'intent': intent, 'result': result,
                                          'uploadRunId': upload_run_id, 'uploadRunAttempt': 1})
        emit_receipt(approved, upload_run_id)
        return result
    require(plan['operation'] in {'distribute', 'submit'}, 'Unsupported Play stage')
    receipt_run = plan.get('upload_run_id')
    terminal = store.read('upload-result', key)
    require(isinstance(terminal, dict) and receipt_run and receipt_run == str(terminal.get('uploadRunId')),
            'Track changes require a receipt for the recorded Play upload')
    release.verify_play_upload(plan, origin, store.read('upload-start', key), terminal,
                               release.load_upload_run(terminal))
    if plan['operation'] == 'distribute':
        status = 'inProgress' if plan['user_fraction'] else 'completed'
        upload_result = terminal['result']
        snapshots = upload_result.get('trackVersionCodes')
        if snapshots is None:
            original = upload_result.get('retainedVersionCodes', [str(code)])
            snapshots = {upload_result['track']: [item for item in original if item != str(code)]}
        require(isinstance(snapshots, dict) and not set(snapshots) - {'internal', 'beta'},
                'Recorded Play test track snapshots are invalid')
        existing = snapshots.get(plan['track'], [])
        require(isinstance(existing, list) and all(isinstance(item, str) and receipt.CODE.fullmatch(item)
                and int(item) <= receipt.MAX_CODE for item in existing),
                'Recorded Play test track version codes are invalid')
        pending_codes = sorted(set(existing + [str(code)]), key=int)
        return client.update_track(code, plan['track'], status, plan['user_fraction'],
                                   authorize_write=authorize_write, pending_codes=pending_codes,
                                   expected_existing=existing, upload_track=upload_result['track'])
    return client.update_track(code, 'production', 'completed', '', authorize_write=authorize_write)


def main():
    command = sys_argv()
    value = plan_from_env()
    if command == 'check-new-package':
        require(value['operation'] in PACKAGE_OPERATIONS, 'Unused-version admission requires a new package')
        require_absent(value['version'], value['build'], release._store(), ('package', 'upload-start', 'upload-result'))
        return
    if command == 'validate-query':
        validate_query(value)
        return
    if command == 'package':
        build_and_seal(value)
        return
    if command == 'retire-producer-output':
        retire_producer_output()
        return
    if command == 'record-package':
        pending = json.loads((ROOT / '.artifacts/android-delivery/package-pending.json').read_text())
        run_id = int(os.environ['GITHUB_RUN_ID'])
        origin = pending['origin']
        require(origin['runId'] == run_id and origin['sourceSha'] == os.environ['GITHUB_SHA']
                and origin['attempt'] == 1 and os.environ['GITHUB_RUN_ATTEMPT'] == '1',
                'Package record must match the admitted producer source and run')
        name = f'android-package-{run_id}-1'
        rows = release._api_items(f'actions/runs/{run_id}/artifacts?per_page=100', 'artifacts')
        matches = [row for row in rows if row.get('name') == name and row.get('expired') is False]
        require(len(matches) == 1 and release.is_id(matches[0].get('id')), 'Sealed package artifact is missing or ambiguous')
        jobs = release._get_jobs(run_id)
        job_matches = [job for job in jobs if job.get('name') == 'delivery / package']
        require(len(job_matches) == 1 and release.is_id(job_matches[0].get('id')), 'Package job identity is ambiguous')
        record = record_package(pending, matches[0], job_matches[0]['id'], release._store())
        emit_receipt(record)
        return
    if command == 'import':
        import_package(value, release._store(), ROOT / '.artifacts/android-delivery/unpacked')
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
    approved = approved_package(plan, release._store())
    manifest = verify_approved_package(plan, package_dir, approved)
    assets = {row['name']: row['sha256'] for row in manifest['assets']}
    origin = approved['origin']
    source = {'source': {'sha': origin['sourceSha'], 'tree': origin['sourceTree']}}
    tag = plan['tag']
    head = git_output('rev-parse', 'HEAD')
    require(head == origin['sourceSha'], 'Candidate Draft checkout differs from the approved producer')
    release.require_candidate_tag_source(tag, head)
    existing = release._release_by_tag(tag)
    if existing is None:
        release._assert_current_release_source(source)
        release.require_candidate_tag_source(tag, head)
        existing = release._api('releases', {'tag_name': tag, 'target_commitish': head, 'name': tag,
                                            'body': 'Aegis Android candidate draft\n', 'draft': True,
                                            'prerelease': True, 'make_latest': 'false'})
    require(is_draft(existing, tag), 'Candidate release is no longer a draft for this tag')
    release_id = existing['id']

    def read_draft(*, complete=False):
        release.require_candidate_tag_source(tag, head)
        fresh = release._api(f'releases/{release_id}')
        require(is_draft(fresh, tag) and fresh['id'] == release_id,
                'Candidate release is no longer the same draft for this tag')
        release._verify_release_assets({'assets': assets}, fresh, complete=complete)
        return fresh

    for row in manifest['assets']:
        release._assert_current_release_source(source)
        current = read_draft()
        if row['name'] not in {item['name'] for item in current['assets']}:
            release._upload_asset_once(release_id, {**row, 'path': str(Path(package_dir) / row['name'])})
    read_draft(complete=True)
    proof_dir = ROOT / '.artifacts/release/android' / plan['build']
    proof_dir.mkdir(parents=True, exist_ok=True)
    proof = {'tag': tag, 'releaseId': release_id, 'draft': True, 'sha': head,
             'assets': assets}
    (proof_dir / 'github-draft.json').write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')



def is_draft(release_row, tag):
    return (isinstance(release_row, dict) and release_row.get('draft') is True
            and release_row.get('prerelease') is True and release_row.get('tag_name') == tag
            and release.is_id(release_row.get('id')))


def sys_argv():
    import sys
    require(len(sys.argv) == 2, 'Usage: android-delivery.py check-new-upload|package|record-package|retire-producer-output|import|play-stage|stage|validate-query')
    return sys.argv[1]


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError, ET.ParseError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
