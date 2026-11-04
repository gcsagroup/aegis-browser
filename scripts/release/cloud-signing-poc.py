#!/usr/bin/env python3
"""Explicit, artifact-only iOS cloud-signing experiment. Manual delivery is unchanged."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run(*args, env=None, log=None, timeout=120):
    if log:
        with log.open('xb') as output:
            os.chmod(log, 0o600)
            process = subprocess.Popen(args, cwd=ROOT, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                process.wait(timeout=timeout)
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            result = process
    else:
        result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, timeout=timeout)
    if result.returncode:
        raise ValueError(f'{Path(args[0]).name} failed (exit {result.returncode}); see retained diagnostic logs')
    return b'' if log else result.stdout


def write(path, value):
    with open(path, 'x', opener=lambda p, flags: os.open(p, flags, 0o600)) as output:
        json.dump(value, output, indent=2)
        output.write('\n')


def keychains():
    return re.findall(r'"([^"\n]+)"', run('security', 'list-keychains', '-d', 'user').decode())


def no_distribution_identity():
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning').decode()
    if re.search(r'"(?:Apple Distribution|iPhone Distribution|Developer ID Application):', identities):
        raise ValueError('Distribution private identity is visible; cloud-only proof refused')


@contextmanager
def isolated_keychain(directory, evidence):
    """Save/restore the user search list and default; never import a P12 or touch ACLs."""
    original = keychains()
    default = run('security', 'default-keychain', '-d', 'user').decode().strip().strip('"')
    path = str(directory / 'cloud-poc.keychain-db')
    password = secrets.token_urlsafe(32)
    evidence.update(originalSearchList=original, originalDefaultKeychain=default,
                    distributionP12Imported=False, keychainRestored=False)
    try:
        run('security', 'create-keychain', '-p', password, path)
        run('security', 'set-keychain-settings', '-lut', '7200', path)
        run('security', 'unlock-keychain', '-p', password, path)
        run('security', 'list-keychains', '-d', 'user', '-s', path)
        run('security', 'default-keychain', '-d', 'user', '-s', path)
        no_distribution_identity()
        evidence['distributionIdentityAbsentBeforeArchive'] = True
        yield
    finally:
        # Restore even if archive/export is interrupted. The generated development key is disposable.
        run('security', 'list-keychains', '-d', 'user', '-s', *original)
        run('security', 'default-keychain', '-d', 'user', '-s', default)
        evidence['keychainRestored'] = keychains() == original
        run('security', 'delete-keychain', path)


def export_options(team):
    return {'method': 'app-store-connect', 'destination': 'export', 'teamID': team,
            'signingStyle': 'automatic', 'manageAppVersionAndBuildNumber': False,
            'testFlightInternalTestingOnly': False}


def validate_identity(version, build, team):
    if (not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version)
            or not re.fullmatch(r'[1-9]\d{0,9}', build)
            or not re.fullmatch(r'[A-Z0-9]{10}', team)):
        raise ValueError('Expected an explicit version, positive build and Apple team')


def source():
    if run('git', 'status', '--porcelain', '--untracked-files=all').strip():
        raise ValueError('Commit PoC source before running; exact clean SHA/tree required')
    return {'sha': run('git', 'rev-parse', 'HEAD').decode().strip(),
            'tree': run('git', 'rev-parse', 'HEAD^{tree}').decode().strip()}


def archive_files(archive):
    files = {}
    for path in sorted(archive.rglob('*')):
        if path.is_symlink():
            raise ValueError('Archive symlink refused')
        if path.is_file():
            files[str(path.relative_to(archive))] = hashlib.sha256(path.read_bytes()).hexdigest()
    if 'Info.plist' not in files or not any(p.startswith('Products/Applications/Aegis.app/') for p in files):
        raise ValueError('Missing completed native archive')
    return files


def snapshot_archive(directory, identity):
    value = {'source': identity, 'files': archive_files(directory / 'work/Aegis.xcarchive')}
    write(directory / 'archive-provenance.json', value)


def reusable_archive(run_id, version, build, team):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', run_id):
        raise ValueError('Unsafe archive run ID')
    directory = ROOT / '.artifacts/cloud-signing-poc' / run_id
    if any(p.is_symlink() for p in [directory, *directory.parents]):
        raise ValueError('Archive path must be physical')
    receipt = json.loads((directory / 'poc-receipt.json').read_text())
    provenance = json.loads((directory / 'archive-provenance.json').read_text())
    archive = directory / 'work/Aegis.xcarchive'
    if (receipt.get('archiveCompleted') is not True or receipt.get('distributionP12Imported') is not False
            or receipt.get('distributionIdentityAbsentBeforeArchive') is not True
            or (receipt.get('version'), receipt.get('build'), receipt.get('team')) != (version, build, team)
            or provenance['source'] != receipt['source'] or provenance['files'] != archive_files(archive)):
        raise ValueError('Prior archive proof or identity differs')
    old_sha = receipt['source']['sha']
    if not re.fullmatch(r'[0-9a-f]{40}', old_sha):
        raise ValueError('Invalid archive source SHA')
    if run('git', 'diff', old_sha, 'HEAD', '--', 'apps/ios',
           'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
           'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json').strip():
        raise ValueError('Native inputs changed; a fresh archive is required')
    return directory, receipt['source']


def stage(directory, environment):
    work = directory / 'work'
    files = run('git', 'ls-files', '-z', 'apps/ios',
                'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
                'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json').decode().split('\0')
    for relative in filter(None, files):
        original = ROOT / relative
        if any(p.is_symlink() for p in [original, *original.parents]):
            raise ValueError('Symlink source input refused')
        target = work / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
    firebase = work / 'apps/ios/scripts/firebase_config.py'
    run(sys.executable, str(firebase), 'stage', '--root', str(work / 'apps/ios/Firebase'), '--channel', 'beta', env=environment)
    for target in ('AegisApp', 'SafariWebExtension', 'ShareExtension'):
        path = work / 'apps/ios' / target / 'Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['AegisReleaseProfile'] = 'beta'
        path.write_bytes(plistlib.dumps(info))
    return work


def experiment(options, environment):
    validate_identity(options.version, options.build, options.team)
    identity = source()
    directory = ROOT / '.artifacts/cloud-signing-poc' / options.run_id
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', options.run_id):
        raise ValueError('Unsafe PoC run ID')
    if directory.exists() or any(p.is_symlink() for p in [directory, *directory.parents]):
        raise ValueError('PoC output must be a new physical directory')
    if shutil.disk_usage(ROOT).free < 10 * 1024**3:
        raise ValueError('At least 10 GiB free is required before the PoC')
    directory.mkdir(parents=True, mode=0o700)
    evidence = {'schemaVersion': 1, 'source': identity, 'version': options.version, 'build': options.build,
                'team': options.team, 'signingMode': 'cloud-poc', 'status': 'started',
                'upload': 'not_attempted', 'deviceAcceptance': 'not_verified', 'releaseReady': False}
    try:
        environment = dict(environment)
        # Refuse inherited distribution secrets; this entrypoint never invokes manual signing helpers.
        if any(environment.get(k) for k in environment if 'P12' in k):
            raise ValueError('Remove inherited P12 configuration for this experiment')
        credential_helper = module('local_credentials', 'local-ios-signing.py')
        environment = credential_helper.credentials(options.downloads, environment)
        # Xcode needs the path, not a base64 copy of the key in its environment.
        environment.pop('AEGIS_ASC_KEY_BASE64', None)
        evidence['xcode'] = run('xcodebuild', '-version').decode().strip()
        if options.archive_from:
            previous, archive_source = reusable_archive(options.archive_from, options.version, options.build, options.team)
            work = previous / 'work'
            evidence.update(source=archive_source, executionSource=identity, reusedArchiveFrom=options.archive_from,
                            archiveCompleted=True, distributionIdentityAbsentBeforeArchive=True,
                            archiveManifestSha256=hashlib.sha256((previous / 'archive-provenance.json').read_bytes()).hexdigest())
        else:
            work = stage(directory, environment)
        archive = work / 'Aegis.xcarchive'
        auth = ['-allowProvisioningUpdates', '-authenticationKeyPath', environment['AEGIS_ASC_KEY_PATH'],
                '-authenticationKeyID', environment['AEGIS_ASC_KEY_ID'],
                '-authenticationKeyIssuerID', environment['AEGIS_ASC_ISSUER_ID']]
        with isolated_keychain(directory, evidence):
            if not options.archive_from:
                print('Archiving with automatic development signing and no Distribution identity', flush=True)
                run('xcodebuild', '-project', str(work / 'apps/ios/Aegis.xcodeproj'), '-scheme', 'Aegis-Release',
                    '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                    '-archivePath', str(archive), '-derivedDataPath', str(work / 'DerivedData'),
                    '-disableAutomaticPackageResolution', *auth, 'archive',
                    'CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development',
                    'PROVISIONING_PROFILE_SPECIFIER=', 'DEVELOPMENT_TEAM=' + options.team,
                    'MARKETING_VERSION=' + options.version, 'CURRENT_PROJECT_VERSION=' + options.build,
                    'AEGIS_FIREBASE_CHANNEL=beta', env=environment, log=directory / 'archive.log', timeout=2400)
                evidence['archiveCompleted'] = True
                snapshot_archive(directory, identity)
                evidence['archiveManifestSha256'] = hashlib.sha256((directory / 'archive-provenance.json').read_bytes()).hexdigest()
            no_distribution_identity()
            evidence['distributionIdentityAbsentBeforeExport'] = True
            plist = directory / 'ExportOptions.plist'
            plist.write_bytes(plistlib.dumps(export_options(options.team)))
            exported = directory / 'export'
            print('Exporting via automatic cloud signing; destination=export', flush=True)
            run('xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(exported),
                '-exportOptionsPlist', str(plist), *auth, env=environment, log=directory / 'export.log', timeout=1200)
            no_distribution_identity()
            evidence['distributionIdentityAbsentAfterExport'] = True
            evidence['exportCompleted'] = True
        ipas = list(exported.glob('*.ipa'))
        if len(ipas) != 1:
            raise ValueError('Expected exactly one exported IPA')
        ipa = directory / f'Aegis-cloud-poc-{options.version}-{options.build}.ipa'
        shutil.copyfile(ipas[0], ipa)
        run(sys.executable, str(work / 'apps/ios/scripts/firebase_config.py'), 'verify-ipa',
            '--root', str(work / 'apps/ios/Firebase'), '--channel', 'beta', '--artifact', str(ipa))
        verifier = module('cloud_verifier', 'verify-signed-ios.py')
        verification = verifier.verify(ipa, options.version, options.build, 'beta', options.team, None, None, ROOT, cloud_poc=True)
        write(directory / 'signature-verification.json', verification)
        if source() != identity:
            raise ValueError('Source changed during experiment')
        evidence.update(status='ipa_verified', ipa=ipa.name, ipaSha256=hashlib.sha256(ipa.read_bytes()).hexdigest(),
                        bundles=verification['bundles'])
    except BaseException as error:
        evidence.update(status='failed', error=str(error))
        raise
    finally:
        write(directory / 'poc-receipt.json', evidence)
        print('PoC evidence: ' + str(directory), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-mode', choices=['cloud-poc'], required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--archive-from', help='Reuse a prior source-bound archive; retry export only')
    parser.add_argument('--downloads', type=Path, default=Path.home() / 'Downloads')
    options = parser.parse_args()
    # Coordinate this entrypoint and refuse a busy native signing host before changing keychain state.
    lock_path = Path.home() / 'Library/Caches/aegis-cloud-signing-poc.lock'
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        processes = run('ps', '-axo', 'comm=').decode().splitlines()
        if any(Path(p.strip()).name in {'xcodebuild', 'codesign'} for p in processes):
            raise ValueError('Native signing/build process active; retry on an idle host')
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda signum, _frame: sys.exit(128 + signum))
        experiment(options, os.environ)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
