#!/usr/bin/env python3
"""Development-only archive transfer for the product-owned cloud export job."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
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
    evidence = {}
    with native.isolated_keychain(output, evidence, retain_development=True):
        native.run('xcodebuild', '-project', str(work / 'apps/ios/Aegis.xcodeproj'),
                   '-scheme', 'Aegis-Release', '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                   '-archivePath', str(archive), '-derivedDataPath', str(work / 'DerivedData'),
                   '-disableAutomaticPackageResolution', 'archive', 'CODE_SIGN_STYLE=Automatic',
                   'CODE_SIGN_IDENTITY=Apple Development', 'PROVISIONING_PROFILE_SPECIFIER=',
                   'DEVELOPMENT_TEAM=' + team, 'MARKETING_VERSION=' + version,
                   'CURRENT_PROJECT_VERSION=' + build, 'AEGIS_FIREBASE_CHANNEL=' + profile,
                   env=build_env, log=output / 'archive.log', timeout=2400)
        verify_development(archive, team, native.run)
    native.module('archive_structure', 'verify-ios-archive.py').verify(archive, version, build)
    if native.source() != identity:
        raise ValueError('Source changed during Development archive construction')
    manifest = {'schema': 'aegis-development-archive-v1', 'source': identity, 'version': version,
                'build': build, 'team': team, 'profile': profile, 'files': native.archive_files(archive),
                'keychainRestored': evidence['keychainRestored']}
    archive_zip = output / 'archive.zip'
    with zipfile.ZipFile(archive_zip, 'x', compression=zipfile.ZIP_DEFLATED) as transfer:
        for path in sorted(archive.rglob('*')):
            if path.is_file():
                transfer.write(path, path.relative_to(archive).as_posix())
    manifest['archive_sha256'] = native.module('archive_digest', 'artifact-transport.py').digest(archive_zip)
    native.write(output / 'archive-manifest.json', manifest)


def extract(source, output, identity, version, build, team, profile):
    """Authenticate the complete transfer before creating any extracted file."""
    native = engine()
    manifest_path = source / 'archive-manifest.json'
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 16 * 1024**2:
        raise ValueError('Invalid archive manifest')
    manifest = json.loads(manifest_path.read_text())
    expected = {'schema': 'aegis-development-archive-v1', 'source': identity, 'version': version,
                'build': build, 'team': team, 'profile': profile, 'keychainRestored': True}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError('Development archive identity differs')
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
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--profile', choices=['alpha', 'beta', 'release'], required=True)
    args = parser.parse_args()
    create(args.output, args.version, args.build, args.team, args.profile, os.environ)


if __name__ == '__main__':
    main()
