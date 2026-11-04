#!/usr/bin/env python3
"""Bind all three iOS target dSYMs to their archived Mach-O UUIDs."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile

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


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('version')
    parser.add_argument('build')
    options = parser.parse_args()
    print(json.dumps(verify(options.archive, options.version, options.build), indent=2))
