#!/usr/bin/env python3
"""Copy only the verified Aegis IPA, symbols and delivery evidence to Downloads."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile

from product_artifacts import digest, publish


def collect(directory, expected_manifest, root=None, draft=False):
    spec = importlib.util.spec_from_file_location('publish_transport', Path(__file__).with_name('artifact-transport.py'))
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    raw = (directory / 'ios-manifest.json').read_bytes()
    manifest = json.loads(raw)
    manifest_digest = hashlib.sha256(raw).hexdigest()
    if manifest_digest != expected_manifest:
        raise ValueError('Catalogue manifest differs from the independently retained digest')
    # The internal package format stays intact; catalogue names include build and hash.
    names = [row['name'] for row in manifest['assets']] + ['ios-manifest.json', 'ios-manifest.json.sha256']
    names += [path.name for path in directory.iterdir()
              if path.name == 'package-origin.json' or transport.RECORD.fullmatch(path.name)]
    expected = {row['name']: row['sha256'] for row in manifest['assets']}
    expected.update({name: digest(directory / name) for name in names if name not in expected})
    expected['ios-manifest.json'] = manifest_digest
    with tempfile.TemporaryDirectory(prefix='.catalogue-verify-', dir=directory.parent) as temporary:
        staged = Path(temporary)
        for name in names:
            if not transport.allowed_name(name) or (directory / name).is_symlink():
                raise ValueError('Invalid catalogue inventory')
            os.link(directory / name, staged / name)
        transport.verify_package(staged, manifest['source']['sha'], manifest['source']['tree'],
                                 manifest_digest)
    return publish([(directory / name, expected[name]) for name in names],
                   'aegis', manifest['version'], manifest['build'], 'draft' if draft else manifest['profile'], root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--draft', action='store_true')
    parser.add_argument('--root', type=Path, default=os.environ.get('GCSA_DELIVERY_ROOT'))
    args = parser.parse_args()
    print('\n'.join(collect(args.directory, args.manifest_sha256, args.root, args.draft)))


if __name__ == '__main__':
    main()
