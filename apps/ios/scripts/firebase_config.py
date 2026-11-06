#!/usr/bin/env python3
"""Select one source-bound Firebase registration for an Aegis iOS build."""
import argparse
import base64
import binascii
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import sys
import zipfile

CHANNELS = {'dev': 'dev', 'alpha': 'dev', 'beta': 'dev', 'release': 'prod'}
BUNDLE_ID = 'com.gcsa.aegis'
RESOURCE = 'AegisFirebase.plist'
UPSTREAM_NAME = 'GoogleService-Info.plist'
MAX_PLIST_BYTES = 64 * 1024
APP_ID = re.compile(r'1:([0-9]+):ios:[a-f0-9]+')
PROJECT_ID = re.compile(r'[a-z][a-z0-9-]{4,28}[a-z0-9]')


def environment(channel):
    if channel not in CHANNELS:
        raise ValueError('Expected Firebase channel dev, alpha, beta, or release')
    return CHANNELS[channel]


def validate(raw, identities, channel):
    if not isinstance(identities, dict) or set(identities) != {'dev', 'prod'}:
        raise ValueError('Expected exactly two Firebase identities, dev and prod')
    senders = {}
    for tier, identity in identities.items():
        if not isinstance(identity, dict) or set(identity) != {'project', 'app'}:
            raise ValueError(f'Invalid Firebase identity for {tier}')
        project, app = identity['project'], identity['app']
        match = APP_ID.fullmatch(app) if isinstance(app, str) else None
        if not isinstance(project, str) or not PROJECT_ID.fullmatch(project) or not match:
            raise ValueError(f'Invalid Firebase project or iOS App ID for {tier}')
        senders[tier] = match[1]
    if identities['dev']['project'] == identities['prod']['project'] or senders['dev'] == senders['prod']:
        raise ValueError('Firebase DEV and PROD must be separate projects')

    if not raw or len(raw) > MAX_PLIST_BYTES:
        raise ValueError('Missing or oversized Firebase registration')
    config = plistlib.loads(raw)
    tier = environment(channel)
    identity = identities[tier]
    expected = {
        'BUNDLE_ID': BUNDLE_ID,
        'PROJECT_ID': identity['project'],
        'GOOGLE_APP_ID': identity['app'],
        'GCM_SENDER_ID': senders[tier],
    }
    if not isinstance(config, dict):
        raise ValueError('Firebase registration must be a plist dictionary')
    for key, value in expected.items():
        if type(config.get(key)) is not type(value) or config[key] != value:
            raise ValueError(f'Firebase registration {key} does not match {tier}')
    api_key = config.get('API_KEY')
    if not isinstance(api_key, str) or not api_key.strip():
        raise ValueError('Firebase registration requires an API key')
    return config


def read(path):
    with path.open('rb') as stream:
        return stream.read(MAX_PLIST_BYTES + 1)


def source_paths(root, channel):
    return root / 'identities.json', root / environment(channel) / UPSTREAM_NAME


def stage(root, channel):
    identities_path, config_path = source_paths(root, channel)
    key = f'AEGIS_IOS_FIREBASE_{environment(channel).upper()}_PLIST_BASE64'
    encoded = os.environ.get(key, '')
    if not encoded or len(encoded) > (MAX_PLIST_BYTES + 2) // 3 * 4:
        raise ValueError(f'Missing or oversized {key}')
    raw = base64.b64decode(encoded, validate=True)
    identities = json.loads(read(identities_path))
    validate(raw, identities, channel)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_bytes(raw)


def install(root, destination, channel):
    destination.unlink(missing_ok=True)
    if channel == 'disabled':
        return
    identities, source = source_paths(root, channel)
    if channel == 'dev' and not source.exists():
        return
    raw = read(source)
    validate(raw, json.loads(read(identities)), channel)
    destination.write_bytes(raw)


def verify_ipa(root, ipa, channel):
    identities, source = source_paths(root, channel)
    expected = read(source)
    validate(expected, json.loads(read(identities)), channel)

    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        infos = [name for name in names if name.startswith('Payload/') and
                 name.endswith('.app/Info.plist') and name.count('/') == 2]
        if len(infos) != 1 or len(names) != len(set(names)):
            raise ValueError('Expected a single unambiguous IPA app')
        app_root = infos[0].removesuffix('Info.plist')
        registration_names = {RESOURCE.casefold(), UPSTREAM_NAME.casefold()}
        resources = [name for name in names if PurePosixPath(name).name.casefold() in registration_names]
        if resources != [app_root + RESOURCE]:
            raise ValueError('IPA must contain only the main app Firebase registration')
        with archive.open(infos[0]) as info_plist:
            info = plistlib.loads(info_plist.read(MAX_PLIST_BYTES + 1))
        if not isinstance(info, dict):
            raise ValueError('IPA app Info.plist must be a dictionary')
        if (info.get('CFBundleIdentifier'), info.get('AegisReleaseProfile'), info.get('AegisFirebaseChannel')) != (
            BUNDLE_ID, channel, channel
        ):
            raise ValueError('IPA app identity or Firebase channel mismatch')
        with archive.open(resources[0]) as resource:
            if resource.read(MAX_PLIST_BYTES + 1) != expected:
                raise ValueError('IPA Firebase registration differs from the selected input')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('stage', 'install', 'verify-ipa'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--channel', required=True)
    parser.add_argument('--artifact', type=Path)
    args = parser.parse_args()
    if args.operation == 'stage':
        stage(args.root, args.channel)
    else:
        if args.artifact is None:
            parser.error('--artifact is required')
        operation = install if args.operation == 'install' else verify_ipa
        operation(args.root, args.artifact, args.channel)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, binascii.Error, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        sys.exit(f'Firebase configuration error: {error}')
