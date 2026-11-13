"""Stage protected Beta inputs and require their exact presence in the exported IPA."""
import argparse
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import zipfile


def module(name):
    path = Path(__file__).resolve().parents[2] / 'apps/ios/scripts' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def stage(directory, environment):
    if directory.is_symlink() or not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise ValueError('Private directory required')
    for key, filename in (('AEGIS_IOS_TEST_NODE_BASE64', 'node.vless'),
                          ('AEGIS_IOS_TEST_SUBSCRIPTION_BASE64', 'subscription.json')):
        encoded = environment.get(key, '')
        if not encoded or len(encoded) > 11000:
            raise ValueError('Missing or oversized private input')
        raw = base64.b64decode(encoded, validate=True)
        if not raw or len(raw) > 8192:
            raise ValueError('Invalid private input size')
        with os.fdopen(os.open(directory / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(raw)
    # Use the exact product resource validators before invoking Xcode.
    module('private_test_node').install('beta', str(directory / 'node.vless'), directory / 'expected-node')
    module('private_test_subscription').install('beta', str(directory / 'subscription.json'),
                                              str(directory / 'node.vless'), directory / 'expected-subscription')
    for filename in ('expected-node', 'expected-subscription'):
        (directory / filename).chmod(0o600)


def verify(directory, ipa):
    root = 'Payload/Aegis.app/'
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate IPA members')
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        if info.get('AegisAccessReleaseChannel') != 'beta' or info.get('AegisReleaseProfile') != 'beta':
            raise ValueError('Expected Beta IPA')
        for member, expected in (('AegisPrivateTestNode.vless', 'expected-node'),
                                 ('AegisPrivateTestSubscription.json', 'expected-subscription')):
            if archive.getinfo(root + member).file_size > 8192:
                raise ValueError('Oversized private resource')
            if archive.read(root + member) != (directory / expected).read_bytes():
                raise ValueError('Private Beta resource mismatch')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('stage', 'verify'))
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--ipa', type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'stage':
            stage(args.directory, os.environ)
        else:
            if args.ipa is None:
                raise ValueError('IPA required')
            verify(args.directory, args.ipa)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile):
        sys.exit('Private Beta input validation failed; no private values are logged.')
