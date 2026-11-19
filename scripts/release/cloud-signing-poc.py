#!/usr/bin/env python3
"""Explicit, artifact-only iOS cloud-signing experiment. Manual delivery is unchanged."""
import argparse
import base64
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
import time
from types import SimpleNamespace

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


def keychains(env=None):
    options = {'env': env} if env is not None else {}
    return re.findall(r'"([^"\n]+)"', run('security', 'list-keychains', '-d', 'user', **options).decode())


def no_distribution_identity():
    identities = run('security', 'find-identity', '-p', 'codesigning').decode()
    if re.search(r'"(?:Apple Distribution|iPhone Distribution|Developer ID Application):', identities):
        raise ValueError('Distribution private identity is visible; cloud-only proof refused')


def keychain_has_distribution(path, env=None):
    """True when a keychain exposes a Distribution/Developer ID private identity."""
    options = {'env': env} if env is not None else {}
    identities = run('security', 'find-identity', '-p', 'codesigning', path, **options).decode()
    return bool(re.search(r'"(?:Apple Distribution|iPhone Distribution|Developer ID Application):', identities))


# login/System stay locked or ACL-gated under headless Actions; retaining them
# makes codesign pick those identities and fail with errSecInternalComponent.
_UNRETAINABLE_KEYCHAINS = {'login.keychain-db', 'login.keychain', 'system.keychain'}


def unretainable_keychain(value):
    path = Path(value)
    if not path.is_absolute() or path.name.casefold() in _UNRETAINABLE_KEYCHAINS:
        return True
    try:
        identity = path.stat()
    except FileNotFoundError:
        return False  # The native inventory lookup will reject a missing database.
    if identity.st_nlink != 1:
        return True
    protected = [Path.home() / 'Library/Keychains' / name for name in ('login.keychain-db', 'login.keychain')]
    protected.append(Path('/Library/Keychains/System.keychain'))
    for candidate in protected:
        try:
            info = candidate.stat()
        except FileNotFoundError:
            continue
        if (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
            return True
    return False


def development_keychains(original):
    """Keep unlocked non-login Development identities without exposing Distribution secrets."""
    retained = []
    for path in original:
        if unretainable_keychain(path):
            continue
        if keychain_has_distribution(path):
            continue
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning', path).decode()
        if re.search(r'"Apple Development:', identities):
            retained.append(path)
    return retained


NATIVE_BUILD_TOOLS = frozenset({'xcodebuild', 'codesign'})
NATIVE_IDLE_TIMEOUT = 600
NATIVE_IDLE_POLL = 15


def conflicting_native_processes():
    """Same-account xcodebuild and codesign processes share this keychain."""
    account = str(os.getuid())
    conflicts = []
    for line in run('ps', '-axo', 'pid=,uid=,user=,comm=').decode().splitlines():
        parts = line.split(None, 3)
        if len(parts) != 4:
            continue
        pid, uid, user, command = parts
        command = command.strip()
        if uid != account or not pid.isdigit() or Path(command).name not in NATIVE_BUILD_TOOLS:
            continue
        conflicts.append(pid + ' ' + user + ' ' + command)
    return conflicts


def wait_until_native_host_idle():
    """Wait until this account has no native build or signing process."""
    deadline = time.monotonic() + NATIVE_IDLE_TIMEOUT
    announced = False
    while True:
        conflicts = conflicting_native_processes()
        if not conflicts:
            return
        detail = ', '.join(conflicts)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('Native signing/build process active; retry on an idle host: ' + detail)
        if not announced:
            print('Waiting for native signing/build processes to exit: ' + detail, flush=True)
            announced = True
        time.sleep(min(NATIVE_IDLE_POLL, remaining))


@contextmanager
def native_session():
    """Serialize account-wide keychain changes and unwind on TERM/HUP."""
    lock_path = Path.home() / 'Library/Caches/aegis-cloud-signing-poc.lock'
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        wait_until_native_host_idle()
        previous = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
        def stop(signum, _frame):
            raise SystemExit(128 + signum)
        try:
            for sig in previous:
                signal.signal(sig, stop)
            yield
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)


@contextmanager
def isolated_keychain(directory, evidence, retain_development=False):
    """Save/restore the user search list and default; never import a P12 or touch ACLs.

    Disposable keychains lose Apple Development private keys after each job. When
    archive signing needs Development, keep unlocked non-login host keychains that
    expose Development identities without Distribution secrets. login/System are
    never retained (headless codesign cannot use their private keys).
    """
    original = keychains()
    default = run('security', 'default-keychain', '-d', 'user').decode().strip().strip('"')
    path = str(directory / 'cloud-poc.keychain-db')
    password = secrets.token_urlsafe(32)
    retained = development_keychains(original) if retain_development else []
    evidence.update(originalSearchList=original, originalDefaultKeychain=default,
                    distributionP12Imported=False, keychainRestored=False,
                    retainedDevelopmentKeychains=retained)
    try:
        run('security', 'create-keychain', '-p', password, path)
        run('security', 'set-keychain-settings', '-lut', '7200', path)
        run('security', 'unlock-keychain', '-p', password, path)
        run('security', 'list-keychains', '-d', 'user', '-s', path, *retained)
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


def export_options(team, profile='beta'):
    return {'method': 'app-store-connect', 'destination': 'export', 'teamID': team,
            'signingStyle': 'automatic', 'manageAppVersionAndBuildNumber': False,
            'testFlightInternalTestingOnly': profile == 'alpha'}


def validate_runtime(runtime, environment, archive_from):
    hosted = environment.get('GITHUB_ACTIONS') == 'true'
    if runtime == 'github-hosted':
        if (not hosted or environment.get('RUNNER_ENVIRONMENT') != 'github-hosted'
                or environment.get('RUNNER_OS') != 'macOS' or archive_from):
            raise ValueError('Fresh GitHub-hosted macOS archive required; reuse/local runners are not accepted')
    elif runtime == 'self-hosted':
        if (not hosted or environment.get('RUNNER_ENVIRONMENT') != 'self-hosted'
                or environment.get('RUNNER_OS') != 'macOS' or archive_from):
            raise ValueError('Self-hosted Actions macOS archive required; reuse/local runners are not accepted')
    elif hosted:
        raise ValueError('Local fallback cannot claim hosted-runner evidence')


def prepare_credentials(directory, options, environment):
    if options.runtime not in ('github-hosted', 'self-hosted'):
        return module('local_credentials', 'local-ios-signing.py').credentials(options.downloads, environment), None
    key_id, issuer = environment.get('AEGIS_ASC_KEY_ID', ''), environment.get('AEGIS_ASC_ISSUER_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', issuer):
        raise ValueError('Hosted ASC key/issuer identity missing')
    raw = base64.b64decode(environment.get('AEGIS_ASC_KEY_BASE64', ''), validate=True)
    if not raw.startswith(b'-----BEGIN PRIVATE KEY-----') or len(raw) > 16384:
        raise ValueError('Hosted ASC key encoding is invalid')
    path = directory / ('AuthKey_' + key_id + '.p8')
    with open(path, 'xb', opener=lambda p, flags: os.open(p, flags, 0o600)) as output:
        output.write(raw)
    environment['AEGIS_ASC_KEY_PATH'] = str(path)
    return environment, path


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


def reusable_archive(run_id, version, build, team, profile='beta'):
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
            or receipt.get('profile', 'beta') != profile
            or (receipt.get('version'), receipt.get('build'), receipt.get('team')) != (version, build, team)
            or provenance['source'] != receipt['source'] or provenance['files'] != archive_files(archive)):
        raise ValueError('Prior archive proof or identity differs')
    old_sha = receipt['source']['sha']
    if not re.fullmatch(r'[0-9a-f]{40}', old_sha):
        raise ValueError('Invalid archive source SHA')
    if run('git', 'diff', old_sha, 'HEAD', '--', 'apps/ios', 'scripts/release/*ios*core*',
           'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
           'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json').strip():
        raise ValueError('Native inputs changed; a fresh archive is required')
    return directory, receipt['source']


def stage(directory, environment, profile='beta', *, build_core=True):
    work = directory / 'work'
    files = run('git', 'ls-files', '-z', 'apps/ios', 'scripts/release/ios_embedded_core.py',
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
    run(sys.executable, str(firebase), 'stage', '--root', str(work / 'apps/ios/Firebase'), '--channel', profile, env=environment)
    if build_core:
        run('bash', str(ROOT / 'scripts/release/prepare-ios-package-core.sh'), str(work),
            env=environment, log=directory / 'embedded-core.log', timeout=2400)
    return work


def key_access_runtime(environment):
    public = {name: environment[name] for name in (
        'PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL') if name in environment}
    def public_run(*arguments, **options):
        options['env'] = public
        return run(*arguments, **options)
    return SimpleNamespace(run=public_run, keychains=lambda: keychains(env=public),
                           keychain_has_distribution=lambda path: keychain_has_distribution(path, env=public),
                           unretainable_keychain=unretainable_keychain, module=module)


def prepare_inline_development(options, directory, environment):
    signing = module('inline_development_signing', 'development_signing.py')
    arguments, proof = signing.resolve(
        options.team, module('inline_profile_trust', 'verify-signed-ios.py').verified_profile)
    access = module('inline_development_access', 'development_key_access.py')
    keychain = access.prepare(proof, key_access_runtime(environment), directory)
    return signing, arguments, proof, access, keychain


def build_inline_archive(work, directory, options, archive_signing, environment, evidence, archive_transfer,
                         development_selection=None):
    """Direct Fastlane/PoC archives use the selected archive identity."""
    if archive_signing not in ('development', 'ad-hoc', 'unsigned'):
        raise ValueError('Archive signing must be development, ad-hoc, or unsigned')
    archive = work / 'Aegis.xcarchive'
    signing = None
    if archive_signing == 'development':
        signing, signing_args, proof, access, keychain = (development_selection
            if development_selection is not None else prepare_inline_development(options, directory, environment))
        runtime = key_access_runtime(environment)
        signing.require_identity(proof, runtime.run)
        access.verify(proof, runtime, directory, environment, keychain)
        evidence['developmentSigning'] = proof
    else:
        signing_args = archive_transfer.signing_arguments(archive_signing)
    run('xcodebuild', '-project', str(work / 'apps/ios/Aegis.xcodeproj'), '-scheme', 'Aegis-Release',
        '-configuration', 'Release', '-destination', 'generic/platform=iOS',
        '-archivePath', str(archive), '-derivedDataPath', str(work / 'DerivedData'),
        '-disableAutomaticPackageResolution', 'archive', *signing_args,
        'DEVELOPMENT_TEAM=' + options.team, 'MARKETING_VERSION=' + options.version,
        'CURRENT_PROJECT_VERSION=' + options.build, 'AEGIS_FIREBASE_CHANNEL=' + options.profile,
        'AEGIS_ACCESS_RELEASE_CHANNEL=' + options.profile, env=environment, log=directory / 'archive.log', timeout=2400)
    if signing:
        archive_transfer.verify_development(archive, options.team, run)
        signing.verify_archive(archive, proof, run)
    else:
        archive_transfer.verify_recorded_archive(archive, options.team, {'archiveSigning': archive_signing}, run)
        evidence['archiveSignaturesVerified'] = archive_signing
    evidence['archiveCompleted'] = True


def experiment(options, environment):
    validate_identity(options.version, options.build, options.team)
    archive_input = getattr(options, 'archive_input', None)
    manifest_sha256 = getattr(options, 'archive_manifest_sha256', None)
    if (bool(archive_input) != bool(manifest_sha256)
            or (archive_input and (options.archive_from
                or type(manifest_sha256) is not str or re.fullmatch(r'[0-9a-f]{64}', manifest_sha256) is None))):
        raise ValueError('Archive input requires its independent producer manifest digest and cannot reuse another archive')
    validate_runtime(options.runtime, environment, options.archive_from)
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
                'team': options.team, 'profile': options.profile, 'signingMode': 'cloud', 'runtime': options.runtime, 'status': 'started',
                'upload': 'not_attempted', 'deviceAcceptance': 'not_verified', 'releaseReady': False}
    temporary_key = None
    archive_signing = getattr(options, 'archive_signing', None) or 'development'
    if archive_signing not in ('development', 'ad-hoc', 'unsigned'):
        raise ValueError('Archive signing must be development, ad-hoc, or unsigned')
    evidence['archiveSigningMode'] = archive_signing
    try:
        environment = dict(environment)
        # Refuse inherited distribution secrets; this entrypoint never invokes manual signing helpers.
        if any(environment.get(k) for k in environment if 'P12' in k):
            raise ValueError('Remove inherited P12 configuration for this experiment')
        archive_transfer = module('cloud_archive_transfer', 'cloud-archive.py')
        archive_environment = archive_transfer.build_environment(environment)
        evidence['xcode'] = run('xcodebuild', '-version').decode().strip()
        reported = evidence['xcode'].splitlines()
        got = reported[0] if reported else ''
        if got != 'Xcode 27.2':
            raise ValueError(f'Xcode 27.2 is required; xcodebuild reported {got!r}')
        if options.runtime in ('github-hosted', 'self-hosted'):
            evidence.update(runId=environment['GITHUB_RUN_ID'], runAttempt=environment['GITHUB_RUN_ATTEMPT'])
        if options.runtime == 'github-hosted':
            no_distribution_identity()
            installed = sum(len(list(p.glob('*.mobileprovision'))) for p in [
                Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'])
            if installed:
                raise ValueError('Fresh hosted runner must start without installed provisioning profiles')
            evidence.update(cleanRunnerDistributionIdentityAbsent=True, initialProvisioningProfileCount=installed)
        if options.archive_from:
            previous, archive_source = reusable_archive(options.archive_from, options.version, options.build, options.team, options.profile)
            work = previous / 'work'
            evidence.update(source=archive_source, executionSource=identity, reusedArchiveFrom=options.archive_from,
                            archiveCompleted=True, distributionIdentityAbsentBeforeArchive=True,
                            archiveManifestSha256=hashlib.sha256((previous / 'archive-provenance.json').read_bytes()).hexdigest())
        elif getattr(options, 'archive_input', None):
            work = stage(directory, archive_environment, options.profile, build_core=False)
            transferred = archive_transfer.extract(options.archive_input, work / 'Aegis.xcarchive', identity,
                                     options.version, options.build, options.team, options.profile,
                                     expected_manifest_sha256=manifest_sha256)
            evidence['archiveSigningMode'] = transferred.get('archiveSigning', 'development')
            archive_transfer.verify_recorded_archive(work / 'Aegis.xcarchive', options.team, transferred, run)
            snapshot_archive(directory, identity)
            evidence.update(archiveCompleted=True, archiveTransferred=True,
                            archiveManifestSha256=hashlib.sha256((directory / 'archive-provenance.json').read_bytes()).hexdigest())
        else:
            work = stage(directory, archive_environment, options.profile)
        archive = work / 'Aegis.xcarchive'
        building = not options.archive_from and not getattr(options, 'archive_input', None)
        inline_selection = None
        if archive_signing == 'development' and building:
            # Activate in this worker's session before isolation inventories identities.
            inline_selection = prepare_inline_development(options, directory, archive_environment)
        with isolated_keychain(directory, evidence, retain_development=(archive_signing == 'development')):
            if building:
                print('Archiving with ' + archive_signing + ' signing and no Distribution identity', flush=True)
                build_inline_archive(work, directory, options, archive_signing, archive_environment, evidence,
                                     archive_transfer, inline_selection)
                snapshot_archive(directory, identity)
                evidence['archiveManifestSha256'] = hashlib.sha256((directory / 'archive-provenance.json').read_bytes()).hexdigest()
            no_distribution_identity()
            evidence['distributionIdentityAbsentBeforeExport'] = True
            environment, temporary_key = prepare_credentials(directory, options, environment)
            # The cloud key becomes available only after archive construction.
            environment.pop('AEGIS_ASC_KEY_BASE64', None)
            auth = ['-allowProvisioningUpdates', '-authenticationKeyPath', environment['AEGIS_ASC_KEY_PATH'],
                    '-authenticationKeyID', environment['AEGIS_ASC_KEY_ID'],
                    '-authenticationKeyIssuerID', environment['AEGIS_ASC_ISSUER_ID']]
            plist = directory / 'ExportOptions.plist'
            plist.write_bytes(plistlib.dumps(export_options(options.team, options.profile)))
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
            '--root', str(work / 'apps/ios/Firebase'), '--channel', options.profile, '--artifact', str(ipa))
        verifier = module('cloud_verifier', 'verify-signed-ios.py')
        verification = verifier.verify(ipa, options.version, options.build, options.profile, options.team, None, None, ROOT, cloud_poc=True)
        write(directory / 'signature-verification.json', verification)
        symbols = module('dsym_verifier', 'verify-ios-dsyms.py')
        symbol_verification = symbols.verify(archive, options.version, options.build)
        write(directory / 'dsym-verification.json', symbol_verification)
        dsym = directory / f'Aegis-cloud-poc-{options.version}-{options.build}.dSYM.zip'
        symbols.export_zip(archive, dsym)
        if source() != identity:
            raise ValueError('Source changed during experiment')
        evidence.update(status='ipa_verified', ipa=ipa.name, ipaSha256=hashlib.sha256(ipa.read_bytes()).hexdigest(),
                        bundles=verification['bundles'], dsym=dsym.name, dsymSha256=hashlib.sha256(dsym.read_bytes()).hexdigest(),
                        assets=[{'name': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'size': p.stat().st_size}
                                for p in [ipa, dsym, directory / 'signature-verification.json', directory / 'dsym-verification.json']])
    except BaseException as error:
        evidence.update(status='failed', error=str(error))
        raise
    finally:
        if temporary_key is not None:
            temporary_key.unlink(missing_ok=True)
        write(directory / 'poc-receipt.json', evidence)
        print('PoC evidence: ' + str(directory), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-mode', choices=['cloud', 'cloud-poc'], required=True)
    parser.add_argument('--runtime', choices=['local-fallback', 'github-hosted', 'self-hosted'], default='local-fallback')
    parser.add_argument('--profile', choices=['alpha', 'beta', 'release'], default='beta')
    parser.add_argument('--archive-input', type=Path, help='Development transfer from the separate credential-free archive job')
    parser.add_argument('--archive-manifest-sha256', help='Independent manifest digest from the original archive job output')
    parser.add_argument('--archive-signing', choices=['development', 'ad-hoc', 'unsigned'], default='development',
                        help='Archive identity before cloud Distribution export')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--archive-from', help='Reuse a prior source-bound archive; retry export only')
    parser.add_argument('--downloads', type=Path, default=Path.home() / 'Downloads')
    options = parser.parse_args()
    with native_session():
        experiment(options, os.environ)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        # Print to stdout so callers that capture stderr still see a useful reason.
        print(str(error), flush=True)
        sys.exit(1)
