#!/usr/bin/env python3
"""Aegis central signing PoC: development archive or export of an authenticated archive."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

import central_ios_protocol as p

ROOT = Path(__file__).resolve().parents[2]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def refuse_store_credentials(environment):
    p.require(not any(value and ('ASC_KEY' in key or 'APP_STORE_CONNECT_API_KEY' in key
                                or 'DISTRIBUTION_P12' in key) for key, value in environment.items()),
              'Archive producer must have only development signing credentials')


def bundle(archive, output, request):
    output.mkdir(parents=True, mode=0o700)
    target = output / 'archive.zip'
    with zipfile.ZipFile(target, 'x', compression=zipfile.ZIP_DEFLATED) as zipped:
        for path in sorted(archive.rglob('*')):
            p.require(not path.is_symlink(), 'Archive contains a symlink')
            if path.is_file():
                zipped.write(path, path.relative_to(archive).as_posix())
    request = dict(request, archive_sha256=p.file_digest(target), archive_size=target.stat().st_size)
    p.validate(request)
    (output / 'request.json').write_bytes(p.canonical(request))
    return p.digest(request)


def verify_development(archive, team, engine):
    app = archive / 'Products/Applications/Aegis.app'
    for target in [app, app / 'PlugIns/SafariWebExtension.appex', app / 'PlugIns/ShareExtension.appex']:
        engine.run('codesign', '--verify', '--deep', '--strict', str(target))
        result = subprocess.run(['codesign', '-d', '--verbose=4', str(target)], capture_output=True)
        p.require(result.returncode == 0 and b'Authority=Apple Development:' in result.stderr
                  and ('TeamIdentifier=' + team).encode() in result.stderr,
                  'Development archive identity differs')


def archive(options, environment):
    refuse_store_credentials(environment)
    engine = module('central_cloud_engine', 'cloud-signing-poc.py')
    engine.validate_identity(options.version, options.build, options.team)
    p.require(environment.get('GITHUB_ACTIONS') == 'true'
              and environment.get('RUNNER_OS') == 'macOS'
              and environment.get('GITHUB_RUN_ATTEMPT') == '1')
    identity = engine.source()
    p.require(identity['sha'] == environment['AEGIS_CENTRAL_SOURCE_SHA'], 'Frozen source differs')
    engine.no_distribution_identity()
    options.work.mkdir(parents=True, mode=0o700)
    work = engine.stage(options.work, environment, 'alpha')
    target = work / 'Aegis.xcarchive'
    engine.run('xcodebuild', '-project', str(work / 'apps/ios/Aegis.xcodeproj'),
               '-scheme', 'Aegis-Release', '-configuration', 'Release', '-destination', 'generic/platform=iOS',
               '-archivePath', str(target), '-derivedDataPath', str(work / 'DerivedData'),
               '-disableAutomaticPackageResolution', 'archive', 'CODE_SIGN_STYLE=Automatic',
               'CODE_SIGN_IDENTITY=Apple Development', 'DEVELOPMENT_TEAM=' + options.team,
               'MARKETING_VERSION=' + options.version, 'CURRENT_PROJECT_VERSION=' + options.build,
               'AEGIS_FIREBASE_CHANNEL=alpha', env=environment, log=options.work / 'archive.log', timeout=2400)
    verify_development(target, options.team, engine)
    module('archive_structure', 'verify-ios-archive.py').verify(target, options.version, options.build)
    request = {'schema': p.SCHEMA, 'product': 'aegis',
               'source': {'repository': p.SOURCE, **identity},
               'producer': {'repository': environment['GITHUB_REPOSITORY'],
                            'repository_id': int(environment['GITHUB_REPOSITORY_ID']),
                            'run_id': int(environment['GITHUB_RUN_ID']), 'attempt': 1,
                            'commit': environment['GITHUB_SHA'],
                            'workflow': '.github/workflows/ios-central-archive.yml'},
               'version': options.version, 'build': options.build, 'profile': 'alpha',
               'team': options.team, 'application': p.APP_ID, 'destination': 'export-only'}
    print(bundle(target, options.output, request))


def verify(options, environment):
    """Verify the original native output in a process with no store credentials."""
    refuse_store_credentials(environment)
    prepared = p.parse((options.work / 'prepared.json').read_bytes())
    request = p.validate(prepared['request'])
    p.require(p.digest(request) == prepared['request_sha256'])
    engine = module('central_cloud_engine', 'cloud-signing-poc.py')
    p.require(engine.source() == {k: request['source'][k] for k in ('sha', 'tree')})
    cleanup = p.parse((options.work / 'native-export.json').read_bytes())
    p.require(cleanup['request_sha256'] == p.digest(request) and cleanup['keychainRestored'] is True)
    p.require(p.file_digest(options.work / 'Aegis.ipa') == cleanup['ipa_sha256'])
    if options.work.resolve() != options.output.resolve():
        options.output.mkdir(parents=True, mode=0o700)
        for name in ('Aegis.ipa', 'cloud-upload-reservation.json'):
            shutil.copyfile(options.work / name, options.output / name)
    p.require(p.file_digest(options.work / 'archive.zip') == request['archive_sha256'])
    target = options.output / 'signing-archive'
    p.extract_archive((options.work / 'archive.zip').read_bytes(), target)
    work = engine.stage(options.output, environment, 'alpha')
    ipa = options.output / 'Aegis.ipa'
    engine.run(sys.executable, str(work / 'apps/ios/scripts/firebase_config.py'), 'verify-ipa',
               '--root', str(work / 'apps/ios/Firebase'), '--channel', 'alpha', '--artifact', str(ipa))
    verification = module('signed_verifier', 'verify-signed-ios.py').verify(
        ipa, request['version'], request['build'], 'alpha', request['team'], None, None, ROOT,
        cloud_poc=True, strict_entitlements=True)
    (options.output / 'signature-verification.json').write_bytes(p.canonical(verification))
    symbols = module('symbol_verifier', 'verify-ios-dsyms.py')
    symbols.verify(target, request['version'], request['build'])
    symbols.export_zip(target, options.output / 'Aegis.dSYM.zip')
    (options.output / 'dsym-verification.json').write_bytes(p.canonical(symbols.verify_delivered(
        ipa, options.output / 'Aegis.dSYM.zip', request['version'], request['build'])))
    evidence = {'schema': 'aegis-central-export-result-v1', 'request_sha256': p.digest(request),
                'request': request, 'execution': prepared['execution'], 'executor_commit': prepared['executor_commit'],
                'upload': 'not_attempted', 'deviceAcceptance': 'not_verified', 'releaseReady': False,
                'keychainRestored': True, 'status': 'verified_export'}
    evidence['assets'] = [{'name': f.name, 'size': f.stat().st_size, 'sha256': p.file_digest(f)}
                          for f in [ipa, options.output / 'Aegis.dSYM.zip', options.output / 'signature-verification.json',
                                    options.output / 'dsym-verification.json', options.output / 'cloud-upload-reservation.json']]
    (options.output / 'result.json').write_bytes(p.canonical(evidence))


def github_json(repository, path, token):
    environment = {'PATH': os.environ['PATH'], 'GH_TOKEN': token, 'GH_PROMPT_DISABLED': '1'}
    raw = subprocess.check_output(['gh', 'api', 'repos/' + repository + ('/' + path if path else '')], env=environment)
    return p.parse(raw)


def central_record(kind, key, token):
    repository = 'gcsagroup/apple-signing'
    repo = github_json(repository, '', token)
    p.require(repo['id'] == 1364015229 and repo['private'] is True)
    ref_name = 'heads/ios-export/aegis/' + kind + '/' + key
    ref = github_json(repository, 'git/ref/' + ref_name, token)
    p.require(ref['ref'] == 'refs/' + ref_name and ref['object']['type'] == 'commit')
    commit = github_json(repository, 'git/commits/' + ref['object']['sha'], token)
    p.require(commit['sha'] == ref['object']['sha'] and commit['parents'] == []
              and commit['tree']['sha'] == '4b825dc642cb6eb9a060e54bf8d69288fbee4904')
    record = p.parse(commit['message'])
    p.require(p.canonical(record).decode() == commit['message'] and set(record) == {'schema', 'kind', 'key', 'payload'}
              and record['schema'] == 'ios-export-record-v1' and record['kind'] == kind and record['key'] == key)
    return record['payload']


def verify_retained(options, environment):
    """Authenticate historical central records, then verify downloaded originals read-only."""
    refuse_store_credentials(environment)
    prepared = p.parse((options.work / 'prepared.json').read_bytes())
    request = p.validate(prepared['request'])
    p.require(prepared['request_sha256'] == p.digest(request))
    key = p.allocation(request)
    token = environment['AEGIS_CENTRAL_READ_TOKEN']
    start = central_record('start', key, token)
    result = central_record('result', key, token)
    p.require(start == prepared and result['request_sha256'] == prepared['request_sha256']
              and result['execution'] == prepared['execution'] and result['destination'] == 'export-only')
    execution = result['execution']
    run = github_json('gcsagroup/apple-signing', 'actions/runs/' + str(execution['run_id']), token)
    p.require(run['repository']['id'] == run['head_repository']['id'] == 1364015229
              and run['id'] == execution['run_id'] and run['run_attempt'] == execution['attempt'] == 1
              and run['path'] == execution['workflow'] == '.github/workflows/aegis-ios-export.yml'
              and run['head_sha'] == execution['workflow_commit'] and run['event'] == 'workflow_dispatch'
              and run['status'] == 'completed' and run['conclusion'] == 'success')
    p.require(result['repository'] == request['producer']['repository']
              and result['repository_id'] == request['producer']['repository_id'])
    expected = {'Aegis.ipa', 'Aegis.dSYM.zip', 'signature-verification.json', 'dsym-verification.json',
                'cloud-upload-reservation.json', 'result.json', 'archive.zip', 'prepared.json', 'native-export.json'}
    p.require(len(result['assets']) == 9 and {asset['name'] for asset in result['assets']} == expected)
    for asset in result['assets']:
        path = options.work / asset['name']
        p.require(not path.is_symlink() and path.stat().st_size == asset['size']
                  and 'sha256:' + p.file_digest(path) == asset['digest'])
    p.require(p.file_digest(options.work / 'result.json') == result['result_sha256'])
    original = p.parse((options.work / 'result.json').read_bytes())
    p.require(original['request'] == request and original['execution'] == execution
              and original['executor_commit'] == prepared['executor_commit'])
    engine = module('retained_cloud_engine', 'cloud-signing-poc.py')
    p.require(engine.source() == {k: request['source'][k] for k in ('sha', 'tree')})
    options.output.mkdir(parents=True, mode=0o700)
    report = module('retained_signed', 'verify-signed-ios.py').verify(
        options.work / 'Aegis.ipa', request['version'], request['build'], 'alpha', request['team'],
        None, None, ROOT, cloud_poc=True, strict_entitlements=True)
    report['symbols'] = module('retained_symbols', 'verify-ios-dsyms.py').verify_delivered(
        options.work / 'Aegis.ipa', options.work / 'Aegis.dSYM.zip', request['version'], request['build'])
    report.update(centralProvenanceVerified=True, requestSha256=p.digest(request), allocation=key,
                  releaseId=result['release_id'], upload='not_attempted')
    (options.output / 'retained-verification.json').write_bytes(p.canonical(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['archive', 'verify', 'verify-retained'])
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version')
    parser.add_argument('--build')
    parser.add_argument('--team')
    options = parser.parse_args()
    {'archive': archive, 'verify': verify, 'verify-retained': verify_retained}[options.operation](options, dict(os.environ))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Aegis central operation stopped; retain evidence and reconcile the original allocation.', file=sys.stderr)
        raise SystemExit(1)
