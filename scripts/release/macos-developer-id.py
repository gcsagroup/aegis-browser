#!/usr/bin/env python3
"""Import a Developer ID identity into a job-local keychain.

Does not replace the user keychain search list and does not notarize.
"""
import base64
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys


class SigningError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise SigningError(message)


def check_host(environment):
    require(environment.get('GITHUB_ACTIONS') == 'true', 'Developer ID import only runs in Actions')
    require(environment.get('RUNNER_ENVIRONMENT') == 'self-hosted', 'Developer ID import only runs on the self-hosted Mac')
    require(environment.get('RUNNER_OS') == 'macOS', 'Developer ID import only runs on macOS')


def decode_p12(value):
    try:
        decoded = base64.b64decode(value.encode(), validate=True)
    except (ValueError, AttributeError) as error:
        raise SigningError('Developer ID P12 is not valid base64') from error
    require(decoded.startswith(b'0\x82') or decoded[:1] == b'\x30', 'Developer ID P12 payload is not a PKCS#12 object')
    return decoded


def identity_from_find_output(text, team):
    matches = re.findall(r'"((?:Developer ID Application:) [^"]+)"', text)
    require(len(matches) == 1, 'Expected exactly one Developer ID Application identity')
    identity = matches[0]
    if team:
        require(re.fullmatch(r'[A-Z0-9]{10}', team) is not None, 'Invalid Apple team id')
        require(f'({team})' in identity, 'Developer ID identity is not for the configured team')
    return identity


def _run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise SigningError(Path(args[0]).name + ' failed')
    return result.stdout


def setup(environment=None, runner=_run):
    environment = dict(os.environ if environment is None else environment)
    check_host(environment)
    material = decode_p12(environment.get('AEGIS_MACOS_DEVELOPER_ID_P12_BASE64', ''))
    password = environment.get('AEGIS_MACOS_DEVELOPER_ID_P12_PASSWORD', '')
    require(password and '\n' not in password and '\x00' not in password, 'Missing Developer ID P12 password')
    root = Path(environment.get('RUNNER_TEMP', '')) / 'aegis-macos-developer-id'
    require(root.is_absolute() and not root.exists(), 'RUNNER_TEMP already contains a Developer ID directory')
    root.mkdir(mode=0o700)
    keychain = root / 'developer-id.keychain-db'
    p12 = root / 'developer-id.p12'
    keychain_password = secrets.token_urlsafe(32)
    try:
        p12.write_bytes(material)
        os.chmod(p12, 0o600)
        runner(['security', 'create-keychain', '-p', keychain_password, str(keychain)])
        runner(['security', 'set-keychain-settings', '-lut', '3600', str(keychain)])
        runner(['security', 'unlock-keychain', '-p', keychain_password, str(keychain)])
        runner(['security', 'import', str(p12), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
        p12.unlink()
        runner(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, str(keychain)])
        found = runner(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)]).decode()
        identity = identity_from_find_output(found, environment.get('AEGIS_APPLE_TEAM_ID', ''))
        output = environment.get('GITHUB_OUTPUT')
        if output:
            Path(output).write_text(f'identity={identity}\nkeychain={keychain}\n')
        return {'identity': identity, 'keychain': str(keychain)}
    except BaseException:
        cleanup(environment, runner)
        raise


def cleanup(environment=None, runner=_run):
    environment = os.environ if environment is None else environment
    root = Path(environment.get('RUNNER_TEMP', '')) / 'aegis-macos-developer-id'
    keychain = root / 'developer-id.keychain-db'
    if keychain.exists():
        runner(['security', 'delete-keychain', str(keychain)])
    if root.exists():
        for child in root.iterdir():
            child.unlink()
        root.rmdir()


def main(argv):
    try:
        if argv == ['setup']:
            setup()
            return 0
        if argv == ['cleanup']:
            cleanup()
            return 0
        raise SigningError('Expected setup or cleanup')
    except (SigningError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
