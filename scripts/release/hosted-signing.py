"""Install existing App Store signing assets on an ephemeral GitHub-hosted Mac."""
import base64
import binascii
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys

TARGETS = {
    'com.gcsa.aegis': 'AEGIS_IOS_APP_PROFILE_BASE64',
    'com.gcsa.aegis.safari': 'AEGIS_IOS_SAFARI_PROFILE_BASE64',
    'com.gcsa.aegis.share': 'AEGIS_IOS_SHARE_PROFILE_BASE64',
}


def check_host(environment):
    if environment.get('GITHUB_ACTIONS') != 'true' or environment.get('RUNNER_ENVIRONMENT') != 'github-hosted' or environment.get('RUNNER_OS') != 'macOS':
        raise ValueError('Signing assets require a GitHub-hosted macOS runner')


def validate_profile(profile, identifier, name, team, fingerprint):
    entitlement = profile.get('Entitlements', {})
    uuid = profile.get('UUID', '')
    expiration = profile.get('ExpirationDate')
    if (not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', uuid)
            or profile.get('Name') != name or profile.get('TeamIdentifier') != [team]
            or not isinstance(expiration, datetime.datetime) or expiration <= datetime.datetime.utcnow()
            or entitlement.get('application-identifier') != team + '.' + identifier
            or entitlement.get('get-task-allow') is not False
            or entitlement.get('com.apple.security.application-groups') != ['group.com.gcsa.aegis.ios.share-inbox']
            or 'ProvisionedDevices' in profile or 'ProvisionsAllDevices' in profile
            or not any(hashlib.sha1(c).hexdigest().upper() == fingerprint.upper() for c in profile.get('DeveloperCertificates', []))):
        raise ValueError('Invalid App Store provisioning profile for ' + identifier)
    return uuid


def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError('Signing setup command failed: ' + Path(args[0]).name)
    return result.stdout


def has_identity(output, fingerprint):
    return bool(re.search(r'\b' + re.escape(fingerprint) + r'\b[^\n]*"Apple Distribution:', output, re.IGNORECASE))


def decode(name):
    value = os.environ.pop(name, '')
    if not value:
        raise ValueError('Missing signing secret: ' + name)
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError('Invalid base64 signing secret: ' + name) from None


def paths():
    root = Path(os.environ['RUNNER_TEMP']) / 'aegis-ios-signing'
    return root, root / 'signing.keychain-db'


def cleanup():
    check_host(os.environ)
    root, keychain = paths()
    manifest = root / 'installed-profiles.json'
    if manifest.is_file():
        for path in json.loads(manifest.read_text()):
            Path(path).unlink(missing_ok=True)
    if keychain.exists():
        run('security', 'delete-keychain', str(keychain))
    shutil.rmtree(root, ignore_errors=True)


def setup():
    check_host(os.environ)
    team = os.environ['AEGIS_APPLE_TEAM_ID']
    fingerprint = os.environ['AEGIS_IOS_CERT_SHA1']
    names = json.loads(os.environ['AEGIS_IOS_PROFILES'])
    if not re.fullmatch(r'[A-Z0-9]{10}', team) or not re.fullmatch(r'[A-Fa-f0-9]{40}', fingerprint) or set(names) != set(TARGETS):
        raise ValueError('Invalid signing configuration')
    certificate = decode('AEGIS_IOS_DISTRIBUTION_P12_BASE64')
    p12_password = os.environ.pop('AEGIS_IOS_DISTRIBUTION_P12_PASSWORD', '')
    if not p12_password:
        raise ValueError('Missing P12 password')
    raw_profiles = {identifier: decode(secret) for identifier, secret in TARGETS.items()}
    root, keychain = paths()
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    os.chmod(root, 0o700)
    installed = []
    manifest = root / 'installed-profiles.json'
    manifest.write_text('[]')
    try:
        profile_dirs = [Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                        Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles']
        for identifier, raw in raw_profiles.items():
            source = root / 'profile.mobileprovision'
            source.write_bytes(raw)
            import plistlib
            profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(source)))
            uuid = validate_profile(profile, identifier, names[identifier], team, fingerprint)
            source.unlink()
            for directory in profile_dirs:
                directory.mkdir(parents=True, exist_ok=True)
                target = directory / (uuid + '.mobileprovision')
                if target.exists():
                    raise ValueError('Provisioning profile path already exists')
                with target.open('xb') as handle:
                    installed.append(str(target))
                    manifest.write_text(json.dumps(installed))
                    handle.write(raw)
                os.chmod(target, 0o600)
        password = secrets.token_urlsafe(32)
        p12 = root / 'distribution.p12'
        p12.write_bytes(certificate)
        os.chmod(p12, 0o600)
        run('security', 'create-keychain', '-p', password, str(keychain))
        run('security', 'set-keychain-settings', '-lut', '3600', str(keychain))
        run('security', 'unlock-keychain', '-p', password, str(keychain))
        run('security', 'import', str(p12), '-k', str(keychain), '-P', p12_password, '-T', '/usr/bin/codesign')
        p12.unlink()
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain))
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
        if not has_identity(identities, fingerprint):
            raise ValueError('Expected Apple Distribution signing identity is unavailable')
        run('security', 'list-keychains', '-d', 'user', '-s', str(keychain))
    except BaseException:
        cleanup()
        raise


def main():
    try:
        if sys.argv[1:] == ['setup']:
            setup()
        elif sys.argv[1:] == ['cleanup']:
            cleanup()
        else:
            raise ValueError('Expected setup or cleanup')
    except (ValueError, OSError, KeyError, TypeError):
        print(str(sys.exc_info()[1]), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
