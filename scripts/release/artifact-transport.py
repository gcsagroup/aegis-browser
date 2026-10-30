#!/usr/bin/env python3
"""Import/export a flat immutable iOS package and its stage receipts. No credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import zipfile

PACKAGE_WORKFLOWS = {'.github/workflows/ios-delivery.yml', '.github/workflows/ios-release.yml', '.github/workflows/ios-candidate.yml'}
WORKFLOWS = PACKAGE_WORKFLOWS | {'.github/workflows/ios-testflight.yml'}
RECORD = re.compile(r'(?:apple-upload|ios-(?:metadata|compliance|distribute|submit))-(?:started|result)\.json\Z')


def verify_run(run, repository, sha, run_id, attempt):
    if not (run['id'] == run_id and run['run_attempt'] == attempt and run['head_sha'] == sha
            and run['head_repository']['full_name'] == repository
            and run['repository']['full_name'] == repository
            and run['status'] == 'completed' and run['conclusion'] == 'success'
            and run['path'] in WORKFLOWS and run['event'] in {'workflow_dispatch', 'push'}):
        raise ValueError('Artifact run/repository/source/attempt is not an admitted successful delivery')


def allowed_name(name):
    return (re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) is not None and '..' not in name
            and (name.endswith(('.ipa', '.dSYM.zip')) or name in {'ios-manifest.json', 'ios-manifest.json.sha256', 'package-origin.json'}
                 or RECORD.fullmatch(name)))


def extract_flat(archive, destination):
    if destination.exists():
        raise ValueError('Import destination must be new')
    with zipfile.ZipFile(archive) as source:
        rows = source.infolist()
        names = [row.filename for row in rows]
        if not rows or len(rows) > 50 or len(names) != len(set(names)) or sum(row.file_size for row in rows) > 1024**3:
            raise ValueError('Invalid or oversized artifact ZIP')
        for row in rows:
            if not allowed_name(row.filename) or row.is_dir() or stat.S_ISLNK(row.external_attr >> 16):
                raise ValueError('Unexpected artifact member')
        destination.mkdir(mode=0o700)
        for row in rows:
            with source.open(row) as content, (destination / row.filename).open('xb') as output:
                shutil.copyfileobj(content, output)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as content:
        for chunk in iter(lambda: content.read(1024*1024), b''):
            value.update(chunk)
    return value.hexdigest()


def verify_package(directory, sha, tree, expected_digest):
    manifest = directory/'ios-manifest.json'
    if digest(manifest) != expected_digest or (directory/'ios-manifest.json.sha256').read_text() != f'{expected_digest}  ios-manifest.json\n':
        raise ValueError('Manifest digest mismatch')
    value = json.loads(manifest.read_text())
    if value.get('source') != dict(sha=sha, tree=tree, dirty=False) or value.get('repository') != 'gcsagroup/aegis-browser' or value.get('platform') != 'ios':
        raise ValueError('Package source mismatch')
    assets = value['assets']
    if len({a['name'] for a in assets}) != len(assets) or sum(a['name'].endswith('.ipa') for a in assets) != 1:
        raise ValueError('Ambiguous artifacts')
    permitted = {'ios-manifest.json', 'ios-manifest.json.sha256', 'package-origin.json'}
    for asset in assets:
        name = asset['name']
        if not allowed_name(name) or not name.endswith(('.ipa', '.dSYM.zip')):
            raise ValueError('Invalid manifest asset')
        path = directory/name
        if digest(path) != asset['sha256'] or path.stat().st_size != asset['size']:
            raise ValueError('Artifact content mismatch')
        permitted.add(name)
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file():
            raise ValueError('Package contains non-file')
        if RECORD.fullmatch(path.name):
            record = json.loads(path.read_text())
            intent = record.get('intent', record)
            identity = ['platform', 'applicationId', 'version', 'build', 'profile', 'format']
            if intent.get('manifestSha256') != expected_digest or any(intent.get(k) != value.get(k) for k in identity):
                raise ValueError('Stage receipt identity mismatch')
        elif path.name not in permitted:
            raise ValueError('Unexpected package file')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['import', 'export'])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--zip', type=Path, required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--tree', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--run-json', type=Path)
    parser.add_argument('--repository')
    parser.add_argument('--run-id', type=int)
    parser.add_argument('--attempt', type=int)
    args = parser.parse_args()
    if args.operation == 'import':
        verify_run(json.loads(args.run_json.read_text()), args.repository, args.sha, args.run_id, args.attempt)
        if args.directory.exists():
            raise ValueError('Refuse to overwrite existing package')
        args.directory.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.ios-import-', dir=args.directory.parent) as tmp:
            staged = Path(tmp)/'package'
            extract_flat(args.zip, staged)
            verify_package(staged, args.sha, args.tree, args.manifest_sha256)
            os.rename(staged, args.directory)
    else:
        # A package directory may contain rebuildable work; export only explicit delivery files.
        with tempfile.TemporaryDirectory(prefix='ios-export-') as tmp:
            staged = Path(tmp)
            for path in args.directory.iterdir():
                if allowed_name(path.name) and path.is_file() and not path.is_symlink():
                    shutil.copyfile(path, staged/path.name)
            verify_package(staged, args.sha, args.tree, args.manifest_sha256)
            with zipfile.ZipFile(args.zip, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(staged.iterdir()):
                    archive.write(path, path.name)
    print(json.dumps(dict(operation=args.operation, sourceSha=args.sha, sourceTree=args.tree, manifestSha256=args.manifest_sha256)))


if __name__ == '__main__':
    main()
