#!/usr/bin/env python3
"""Bind all three iOS target dSYMs to their archived Mach-O UUIDs."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile
import stat
import tempfile

TARGETS = {'Aegis.app': 'com.gcsa.aegis',
           'Aegis.app/PlugIns/SafariWebExtension.appex': 'com.gcsa.aegis.safari',
           'Aegis.app/PlugIns/ShareExtension.appex': 'com.gcsa.aegis.share'}


def uuids(path):
    result = subprocess.run(['xcrun', 'dwarfdump', '--uuid', str(path)], capture_output=True, text=True)
    rows = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', result.stdout, re.MULTILINE)
    if result.returncode or not rows or len(set(rows)) != len(rows):
        raise ValueError('Missing or ambiguous Mach-O UUID: ' + path.name)
    return sorted((architecture, uuid.upper()) for uuid, architecture in rows)


def verify(archive, version, build):
    archive = Path(archive)
    checked = []
    for relative, identifier in TARGETS.items():
        bundle = archive / 'Products/Applications' / relative
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (identifier, version, build):
            raise ValueError('dSYM archive identity differs: ' + identifier)
        executable = info['CFBundleExecutable']
        if not isinstance(executable, str) or Path(executable).name != executable:
            raise ValueError('Unsafe executable name')
        dwarf = archive / 'dSYMs' / (bundle.name + '.dSYM') / 'Contents/Resources/DWARF' / executable
        binary_ids, symbol_ids = uuids(bundle / executable), uuids(dwarf)
        if binary_ids != symbol_ids or not any(row[0] == 'arm64' for row in binary_ids):
            raise ValueError('dSYM UUID differs from archived executable: ' + identifier)
        checked.append({'applicationId': identifier, 'dSYM': str(dwarf.relative_to(archive / 'dSYMs')),
                        'uuids': [{'architecture': arch, 'uuid': uuid} for arch, uuid in binary_ids]})
    return {'version': version, 'build': build, 'targetCount': len(checked), 'uuidVerification': True, 'bundles': checked}


def export_zip(archive, destination):
    root = Path(archive) / 'dSYMs'
    files = sorted(root.rglob('*'))
    if not files:
        raise ValueError('No dSYMs to export')
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as output:
        for path in files:
            if path.is_symlink():
                raise ValueError('dSYM symlink refused')
            if path.is_file():
                output.write(path, str(path.relative_to(root)))


def verify_delivered(ipa, symbols, version, build):
    """Compare all architectures in the downloaded IPA with the original dSYM ZIP."""
    with tempfile.TemporaryDirectory(prefix='aegis-delivered-symbols-') as temporary:
        root = Path(temporary)
        for source, destination in [(ipa, root / 'ipa'), (symbols, root / 'symbols')]:
            with zipfile.ZipFile(source) as zipped:
                rows = zipped.infolist()
                names = [row.filename.rstrip('/') for row in rows]
                if (not rows or len(rows) > 100000 or len({name.casefold() for name in names}) != len(names)
                        or sum(row.file_size for row in rows) > 4 * 1024**3):
                    raise ValueError('Invalid delivered ZIP size or duplicate path')
                for row, name in zip(rows, names):
                    if (Path(name).is_absolute() or '\\' in name or not name
                            or any(part in ('', '.', '..') for part in name.split('/'))
                            or stat.S_IFMT(row.external_attr >> 16) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                        raise ValueError('Unsafe delivered ZIP entry')
                zipped.extractall(destination)
        checked = []
        for relative, identifier in TARGETS.items():
            bundle = root / 'ipa/Payload' / relative
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (identifier, version, build):
                raise ValueError('Delivered dSYM identity differs')
            name = info['CFBundleExecutable']
            if not isinstance(name, str) or Path(name).name != name or name in ('.', '..'):
                raise ValueError('Unsafe delivered executable')
            symbol = root / 'symbols' / (bundle.name + '.dSYM') / 'Contents/Resources/DWARF' / name
            binaries, dwarfs = uuids(bundle / name), uuids(symbol)
            if binaries != dwarfs or not any(arch == 'arm64' for arch, _ in binaries):
                raise ValueError('Delivered IPA/dSYM UUID differs: ' + identifier)
            checked.append({'applicationId': identifier, 'uuids': binaries})
        return {'downloadedIpaVerified': True, 'bundles': checked}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('version')
    parser.add_argument('build')
    options = parser.parse_args()
    print(json.dumps(verify(options.archive, options.version, options.build), indent=2))
