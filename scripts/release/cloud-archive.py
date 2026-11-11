#!/usr/bin/env python3
"""Development-only archive transfer for the product-owned cloud export job."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import zipfile


def engine():
    spec = importlib.util.spec_from_file_location('archive_cloud_engine', Path(__file__).with_name('cloud-signing-poc.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def build_environment(environment):
    """Build phases receive development signing only, including direct CLI use."""
    return {key: value for key, value in environment.items()
            if not (key.startswith(('AEGIS_ASC_', 'APP_STORE_CONNECT_', 'ASC_'))
                    or key in {'GH_TOKEN', 'GITHUB_TOKEN'})}


def verify_development(archive, team, native_run):
    app = archive / 'Products/Applications/Aegis.app'
    for target in (app, app / 'PlugIns/SafariWebExtension.appex', app / 'PlugIns/ShareExtension.appex'):
        native_run('codesign', '--verify', '--deep', '--strict', str(target))
        # codesign writes its description to stderr.
        result = subprocess.run(['codesign', '-d', '--verbose=4', str(target)], capture_output=True, timeout=30)
        if (result.returncode or b'Authority=Apple Development:' not in result.stderr
                or ('TeamIdentifier=' + team).encode() not in result.stderr):
            raise ValueError('Expected the exact team Development archive')


def create(output, version, build, team, profile, environment):
    native = engine()
    native.validate_identity(version, build, team)
    identity = native.source()
    if native.run('xcodebuild', '-version').splitlines()[0] != b'Xcode 26.6':
        raise ValueError('Fixed Xcode 26.6 is required')
    if any(environment.get(key) for key in environment
           if key.startswith(('AEGIS_ASC_', 'APP_STORE_CONNECT_', 'ASC_')) or 'P12' in key):
        raise ValueError('Archive job must not load ASC or distribution credentials')
    output.mkdir(parents=True, mode=0o700)
    build_env = build_environment(environment)
    work = native.stage(output, build_env, profile)
    archive = work / 'Aegis.xcarchive'
    signing = native.module('development_signing', 'development_signing.py')
    signing_args, signing_evidence = signing.resolve(
        team, native.module('development_profile_trust', 'verify-signed-ios.py').verified_profile)
    evidence = {}
    with native.isolated_keychain(output, evidence, retain_development=True):
        signing.require_identity(signing_evidence, native.run)
        native.run('xcodebuild', '-project', str(work / 'apps/ios/Aegis.xcodeproj'),
                   '-scheme', 'Aegis-Release', '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                   '-archivePath', str(archive), '-derivedDataPath', str(work / 'DerivedData'),
                   '-disableAutomaticPackageResolution', 'archive', *signing_args,
                   'DEVELOPMENT_TEAM=' + team, 'MARKETING_VERSION=' + version,
                   'CURRENT_PROJECT_VERSION=' + build, 'AEGIS_FIREBASE_CHANNEL=' + profile,
                   env=build_env, log=output / 'archive.log', timeout=2400)
        verify_development(archive, team, native.run)
        signing.verify_archive(archive, signing_evidence, native.run)
    native.module('archive_structure', 'verify-ios-archive.py').verify(archive, version, build)
    if native.source() != identity:
        raise ValueError('Source changed during Development archive construction')
    manifest = {'schema': 'aegis-development-archive-v2', 'source': identity, 'version': version,
                'build': build, 'team': team, 'profile': profile, 'files': native.archive_files(archive),
                'keychainRestored': evidence['keychainRestored'], 'developmentSigning': signing_evidence}
    archive_zip = output / 'archive.zip'
    with zipfile.ZipFile(archive_zip, 'x', compression=zipfile.ZIP_DEFLATED) as transfer:
        for path in sorted(archive.rglob('*')):
            if path.is_file():
                transfer.write(path, path.relative_to(archive).as_posix())
    manifest['archive_sha256'] = native.module('archive_digest', 'artifact-transport.py').digest(archive_zip)
    return write_manifest(output / 'archive-manifest.json', manifest)


def write_manifest(path, manifest):
    """Bind the independent output to the exact bytes produced, without rereading a path."""
    raw = (json.dumps(manifest, indent=2) + '\n').encode()
    if len(raw) > 16 * 1024**2:
        raise ValueError('Development archive manifest exceeds the size limit')
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(raw)
    return hashlib.sha256(raw).hexdigest()


def extract(source, output, identity, version, build, team, profile, *, expected_manifest_sha256):
    """Authenticate the complete transfer before creating any extracted file."""
    native = engine()
    manifest_path = source / 'archive-manifest.json'
    signing = native.module('development_signing', 'development_signing.py')
    raw = signing.read_regular(manifest_path, 16 * 1024**2)
    if (type(expected_manifest_sha256) is not str
            or re.fullmatch(r'[0-9a-f]{64}', expected_manifest_sha256) is None
            or hashlib.sha256(raw).hexdigest() != expected_manifest_sha256):
        raise ValueError('Development archive manifest differs from its producer job output')
    manifest = json.loads(raw)
    expected = {'schema': 'aegis-development-archive-v2', 'source': identity, 'version': version,
                'build': build, 'team': team, 'profile': profile, 'keychainRestored': True}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError('Development archive identity differs')
    signing.validate_evidence(manifest.get('developmentSigning'))
    archive_zip = source / 'archive.zip'
    if (archive_zip.is_symlink() or archive_zip.stat().st_size > 2 * 1024**3
            or hashlib.sha256(archive_zip.read_bytes()).hexdigest() != manifest['archive_sha256']):
        raise ValueError('Development archive bytes differ')
    if output.exists():
        raise ValueError('Archive extraction must use a new directory')
    with zipfile.ZipFile(archive_zip) as transfer:
        rows = transfer.infolist()
        names = [row.filename for row in rows]
        if (not rows or len(rows) > 50000 or len(set(names)) != len(names)
                or sum(row.file_size for row in rows) > 2 * 1024**3):
            raise ValueError('Invalid archive inventory')
        for row in rows:
            name = PurePosixPath(row.filename)
            if (name.is_absolute() or '..' in name.parts or '\\' in row.filename or row.is_dir()
                    or stat.S_ISLNK(row.external_attr >> 16) or str(name) != row.filename):
                raise ValueError('Unsafe archive member')
        output.mkdir(parents=True, mode=0o700)
        for row in rows:
            target = output / row.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            with transfer.open(row) as content, target.open('xb') as sink:
                shutil.copyfileobj(content, sink)
            target.chmod((row.external_attr >> 16) & 0o755)
    if native.archive_files(output) != manifest['files']:
        raise ValueError('Extracted archive differs from its original manifest')
    signing.verify_archive(output, manifest.get('developmentSigning'), native.run)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--profile', choices=['alpha', 'beta', 'release'], required=True)
    parser.add_argument('--github-output', type=Path, help='Publish the manifest digest independently of artifact bytes')
    args = parser.parse_args()
    with engine().native_session():
        digest = create(args.output, args.version, args.build, args.team, args.profile, os.environ)
    if args.github_output:
        with args.github_output.open('a') as stream:
            stream.write('manifest_sha256=' + digest + '\n')


if __name__ == '__main__':
    main()
