"""Seal and extract one flat Android delivery package. No credentials."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import zipfile

REPOSITORY = 'gcsagroup/aegis-browser'
APPLICATION_ID = 'com.gcsa.aegis'
MAX_MEMBER = 1024 ** 3
SEALED_NAMES = {'android-manifest.json', 'android-manifest.json.sha256', 'package-origin.json',
                'signature-verification.json'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as content:
        for chunk in iter(lambda: content.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def asset_names(version, build):
    prefix = f'Aegis-{version}-{build}-android'
    return f'{prefix}.aab', f'{prefix}.symbols.zip'


def allowed_name(name):
    return (isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) is not None
            and '..' not in name and (name in SEALED_NAMES or name.endswith(('.aab', '.symbols.zip'))))


def canonical_manifest(manifest):
    return (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()


def public_manifest_payloads(manifest):
    assets = [
        {key: row[key] for key in ('name', 'size', 'sha256')}
        for row in manifest['assets'] if row['name'].endswith(('.aab', '.symbols.zip'))
    ]
    public = {key: manifest[key] for key in ('repository', 'platform', 'applicationId', 'profile', 'version', 'build')}
    public['source'] = {key: manifest['source'][key] for key in ('sha', 'tree')}
    public.update(schema='aegis-android-public-manifest-v1', assets=sorted(assets, key=lambda row: row['name']))
    payload = canonical_manifest(public)
    digest = hashlib.sha256(payload).hexdigest()
    return {'android-manifest.json': payload, 'android-manifest.json.sha256': f'{digest}  android-manifest.json\n'.encode()}


def assert_zip_members(path, required):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Android package member is missing')
    with zipfile.ZipFile(path) as zipped:
        rows = zipped.infolist()
        names = [row.filename for row in rows]
        require(rows and len(names) == len(set(names)) and sum(row.file_size for row in rows) <= MAX_MEMBER,
                'Android package member is not a bounded archive')
        for row in rows:
            require(not row.is_dir() and not stat.S_ISLNK(row.external_attr >> 16)
                    and '..' not in row.filename and not row.filename.startswith('/'),
                    'Android package member contains an unsafe path')
        require(required <= set(names), 'Android package member is missing required entries')


def assert_aab(path):
    assert_zip_members(path, {'BundleConfig.pb'})


def assert_symbols(path):
    path = Path(path)
    assert_zip_members(path, set())
    with zipfile.ZipFile(path) as zipped:
        libraries = [name for name in zipped.namelist() if name.endswith('.so')]
    require(libraries, 'Android symbols archive contains no native libraries')


def _require_bounded_flat_archive(path):
    require(path.is_file() and not path.is_symlink(), 'Sealed package archive is missing')
    require(path.stat().st_size <= MAX_MEMBER, 'Sealed Android package ZIP exceeds the archive size limit')


def extract_flat(archive, destination):
    archive, destination = Path(archive), Path(destination)
    _require_bounded_flat_archive(archive)
    require(not destination.exists() and not destination.is_symlink(), 'Import destination must be new')
    with zipfile.ZipFile(archive) as source:
        rows = source.infolist()
        names = [row.filename for row in rows]
        require(rows and len(rows) <= 20 and len(names) == len(set(names))
                and sum(row.file_size for row in rows) <= MAX_MEMBER, 'Invalid or oversized Android package ZIP')
        for row in rows:
            require(allowed_name(row.filename) and not row.is_dir() and not stat.S_ISLNK(row.external_attr >> 16),
                    'Unexpected Android package member')
        destination.mkdir(mode=0o700)
        for row in rows:
            with source.open(row) as content, (destination / row.filename).open('xb') as output:
                output.write(content.read())


def verify_package(directory, sha, tree, expected_digest):
    directory = Path(directory)
    manifest_path = directory / 'android-manifest.json'
    digest = sha256(manifest_path)
    checksum = f'{digest}  android-manifest.json\n'
    require(digest == expected_digest and (directory / 'android-manifest.json.sha256').read_text() == checksum,
            'Android manifest digest mismatch')
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get('repository') == REPOSITORY and manifest.get('platform') == 'android'
            and manifest.get('applicationId') == APPLICATION_ID
            and manifest.get('source') == {'sha': sha, 'tree': tree, 'dirty': False},
            'Android package source mismatch')
    assets = manifest.get('assets')
    require(isinstance(assets, list) and len({row.get('name') for row in assets}) == len(assets)
            and sum(isinstance(row, dict) and str(row.get('name', '')).endswith('.aab') for row in assets) == 1,
            'Android package manifest is ambiguous')
    aab_name, symbols_name = asset_names(manifest['version'], manifest['build'])
    names = {row['name'] for row in assets}
    require(aab_name in names and (manifest.get('profile') != 'release' or symbols_name in names),
            'Android package assets do not match the sealed inventory')
    for row in assets:
        name = row['name']
        path = directory / name
        require(allowed_name(name) and path.is_file() and not path.is_symlink()
                and path.resolve().parent == directory.resolve()
                and path.stat().st_size == row.get('size') and sha256(path) == row.get('sha256'),
                'Android package asset bytes differ from the manifest')
        if name.endswith('.aab'):
            assert_aab(path)
        if name.endswith('.symbols.zip'):
            assert_symbols(path)
    signature = json.loads((directory / 'signature-verification.json').read_text())
    aab = next(row for row in assets if row['name'].endswith('.aab'))
    require(signature.get('schema') == 'aegis-android-signature-v1'
            and signature.get('certificateSha256') == manifest.get('details', {}).get('certificateSha256')
            and signature.get('artifactSha256') == aab['sha256'],
            'Android signature evidence does not bind the sealed bundle')
    return manifest


def seal(directory, manifest, origin, signature, files):
    directory = Path(directory)
    require(not directory.exists() and not directory.is_symlink(), 'Sealed package directory must be new')
    payload = canonical_manifest(manifest)
    digest = hashlib.sha256(payload).hexdigest()
    origin = {**origin, 'manifestSha256': digest}
    directory.mkdir(mode=0o700)
    (directory / 'android-manifest.json').write_bytes(payload)
    (directory / 'android-manifest.json.sha256').write_text(f'{digest}  android-manifest.json\n')
    (directory / 'package-origin.json').write_text(json.dumps(origin, sort_keys=True, indent=2) + '\n')
    (directory / 'signature-verification.json').write_text(json.dumps(signature, sort_keys=True) + '\n')
    for name, source in files.items():
        require(allowed_name(name), 'Refusing to seal an unexpected Android asset')
        shutil.copyfile(source, directory / name)
    verify_package(directory, origin['sourceSha'], origin['sourceTree'], digest)
    return digest, origin


def zip_flat(directory, archive):
    directory, archive = Path(directory), Path(archive)
    require(not archive.exists() and not archive.is_symlink(), 'Refusing to overwrite a sealed Android archive')
    members = sorted(directory.iterdir())
    for path in members:
        require(path.is_file() and not path.is_symlink() and allowed_name(path.name), 'Unexpected sealed file')
    require(0 < len(members) <= 20 and sum(path.stat().st_size for path in members) <= MAX_MEMBER,
            'Sealed Android package members exceed the import limits')
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, 'x') as zipped:
        for path in members:
            zipped.write(path, path.name)
    _require_bounded_flat_archive(archive)
