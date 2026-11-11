"""Prepare local iOS signing through ASC GETs and native Keychain APIs, without UI typing."""
import argparse
import base64
import ctypes
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROFILE_NAMES = {'com.gcsa.aegis': 'App Store App',
                 'com.gcsa.aegis.safari': 'App Store Safari Extension',
                 'com.gcsa.aegis.share': 'App Store Share Extension'}
ALIASES = {'APP_STORE_CONNECT_API_KEY_KEY_ID': 'AEGIS_ASC_KEY_ID',
           'APP_STORE_CONNECT_API_KEY_ISSUER_ID': 'AEGIS_ASC_ISSUER_ID',
           'APP_STORE_CONNECT_API_KEY_KEY_FILEPATH': 'AEGIS_ASC_KEY_PATH'}


def private_file(path):
    path = Path(path)
    current = path
    while current != current.parent:
        if current.is_symlink():
            raise ValueError('Signing input cannot be a symlink')
        current = current.parent
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Credential input must be an owned private file (mode 600)')
    return path


def physical_file(path):
    return not any(current.is_symlink() for current in [path, *path.parents])


def receipt_path(directory):
    path = directory / 'signing-receipt.json'
    if not physical_file(path) or (path.exists() and not path.is_file()):
        raise ValueError('Signing receipt cannot be a symlink or non-file')
    return path


def write_receipt(directory, value):
    target = receipt_path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.signing-receipt-', dir=directory)
    try:
        with os.fdopen(descriptor, 'w') as output:
            output.write(json.dumps(value, indent=2) + '\n')
            output.flush()
            os.fsync(output.fileno())
        receipt_path(directory)
        os.replace(temporary, target)  # Replace the directory entry; never truncate its target.
    finally:
        Path(temporary).unlink(missing_ok=True)


def parse_credentials(text):
    values = {}
    for line in text.splitlines():
        tokens = shlex.split(line, comments=True)
        if tokens and tokens[0] == 'export':
            tokens = tokens[1:]
        if len(tokens) != 1 or '=' not in tokens[0]:
            continue
        name, value = tokens[0].split('=', 1)
        if name in ALIASES:
            if name in values or '$' in value or '`' in value:
                raise ValueError('Ambiguous or executable credential configuration')
            values[name] = value
    return {ALIASES[key]: value for key, value in values.items()}


def run(*args, env=None):
    result = subprocess.run(args, env=env, capture_output=True)
    if result.returncode:
        raise ValueError('Signing command failed: ' + Path(args[0]).name)
    return result.stdout


def credentials(downloads, environment):
    result = environment.copy()
    if not result.get('AEGIS_ASC_KEY_ID') or not result.get('AEGIS_ASC_ISSUER_ID'):
        files = [path for path in downloads.rglob('app-store-connect-api.env.sh') if physical_file(path)]
        if not files:
            raise ValueError('Unique shared App Store Connect credential configuration required')
        configurations = [parse_credentials(private_file(path).read_text()) for path in files]
        identities = {(value.get('AEGIS_ASC_KEY_ID'), value.get('AEGIS_ASC_ISSUER_ID')) for value in configurations}
        if len(identities) != 1:
            raise ValueError('Conflicting App Store Connect credential configurations')
        for name, value in configurations[0].items():
            result.setdefault(name, value)
    key_id = result.get('AEGIS_ASC_KEY_ID', '')
    issuer = result.get('AEGIS_ASC_ISSUER_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', issuer):
        raise ValueError('Invalid ASC key or issuer identity')
    key = Path(result.get('AEGIS_ASC_KEY_PATH', '/nonexistent'))
    if not key.is_file() or not physical_file(key):
        if environment.get('AEGIS_ASC_KEY_PATH') and key.exists():
            raise ValueError('Explicit ASC private key cannot be a symlink')
        files = [path for path in downloads.rglob('AuthKey_' + key_id + '.p8') if physical_file(path)]
        if not files or len({hashlib.sha256(private_file(path).read_bytes()).digest() for path in files}) != 1:
            raise ValueError('Unique existing ASC private key required')
        key = files[0]
    key = private_file(key)
    result['AEGIS_ASC_KEY_PATH'] = str(key)
    result['AEGIS_ASC_KEY_BASE64'] = base64.b64encode(key.read_bytes()).decode()
    return result


def signing_material(downloads, fingerprint):
    candidates = []
    for certificate in downloads.rglob('*.cer'):
        if not physical_file(certificate):
            continue
        raw = certificate.read_bytes()
        if hashlib.sha1(raw).hexdigest().upper() == fingerprint:
            password = certificate.parent / 'EXISTING-KEYCHAIN-PASSWORD.txt'
            if password.is_file():
                candidates.append((certificate, password))
    if len(candidates) != 1:
        raise ValueError('Unique matching Distribution certificate and keychain password file required')
    return candidates[0][0], private_file(candidates[0][1])


def signing_keychain(fingerprint):
    found = []
    for name in re.findall(r'"([^"\n]+)"', run('security', 'list-keychains', '-d', 'user').decode()):
        path = Path(name)
        if path.name in {'login.keychain-db', 'login.keychain', 'System.keychain'}:
            continue
        # Public certificate lookup also works when the keychain needs unlocking.
        certificates = run('security', 'find-certificate', '-a', '-Z', name).decode()
        if re.search(r'SHA-1 hash: ' + re.escape(fingerprint) + r'\b', certificates):
            found.append(path)
    if len(found) != 1:
        raise ValueError('Unique installed Distribution identity in a non-login signing keychain required')
    return found[0]


@contextmanager
def activated_keychain_from_fd(path, descriptor, *, maximum_file_bytes=1024):
    """Keep success unlocked; restore a changed lock state if activation/body fails."""
    password = bytearray(maximum_file_bytes + 1)
    security = core = None
    reference = ctypes.c_void_p()
    restore_lock = False
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077
                or info.st_nlink != 1 or not 0 < info.st_size <= maximum_file_bytes
                or os.lseek(descriptor, 0, os.SEEK_CUR) != 0):
            raise ValueError('Expected a bounded owned private password descriptor')
        count = os.readv(descriptor, [password])
        if count != info.st_size:
            raise ValueError('Signing password changed during reading')
        length = count
        while length and password[length - 1] in (10, 13):
            length -= 1
        if not 0 < length <= 1024 or any(password[index] in (0, 10, 13) for index in range(length)):
            raise ValueError('Expected a single-line signing-keychain password')
        security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
        core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        security.SecKeychainOpen.restype = ctypes.c_int32
        security.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool]
        security.SecKeychainUnlock.restype = ctypes.c_int32
        security.SecKeychainGetStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
        security.SecKeychainGetStatus.restype = ctypes.c_int32
        security.SecKeychainLock.argtypes = [ctypes.c_void_p]
        security.SecKeychainLock.restype = ctypes.c_int32
        core.CFRelease.argtypes = [ctypes.c_void_p]
        if security.SecKeychainOpen(os.fsencode(path), ctypes.byref(reference)):
            raise ValueError('Unable to open the signing keychain')
        status = ctypes.c_uint32()
        if security.SecKeychainGetStatus(reference, ctypes.byref(status)):
            raise ValueError('Unable to inspect the signing keychain lock state')
        initially_unlocked = bool(status.value & 1)
        restore_lock = not initially_unlocked
        buffer = (ctypes.c_ubyte * length).from_buffer(password)
        if security.SecKeychainUnlock(reference, length, buffer, True):
            raise ValueError('Signing-keychain unlock failed; no password retry or UI fallback')
        if security.SecKeychainGetStatus(reference, ctypes.byref(status)) or not status.value & 1:
            raise ValueError('Signing keychain remains locked')
        password[:] = b'\0' * len(password)
        yield initially_unlocked
    except BaseException as error:
        if restore_lock and reference.value and security is not None:
            if security.SecKeychainLock(reference):
                raise ValueError('Signing keychain lock restoration failed; retain state for reconciliation') from error
        raise
    finally:
        password[:] = b'\0' * len(password)
        if reference.value and core is not None:
            core.CFRelease(reference)


def unlock_keychain(path, password_file):
    # Preserve the existing manual entrypoint; the native primitive consumes one FD.
    descriptor = os.open(private_file(password_file), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        with activated_keychain_from_fd(path, descriptor, maximum_file_bytes=1026):
            pass
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--downloads', type=Path, default=Path.home() / 'Downloads')
    parser.add_argument('--state-directory', type=Path, default=ROOT / '.artifacts/ios-signing/app-store')
    parser.add_argument('--team', default=os.environ.get('AEGIS_APPLE_TEAM_ID'))
    parser.add_argument('--certificate-sha1', default=os.environ.get('AEGIS_IOS_CERT_SHA1'))
    parser.add_argument('--unlock', action='store_true', help='Unlock only the matching non-login signing keychain')
    args = parser.parse_args()
    fingerprint = (args.certificate_sha1 or '').upper()
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team or '') or not re.fullmatch(r'[0-9A-F]{40}', fingerprint):
        raise ValueError('Explicit expected Apple team and certificate fingerprint required')
    receipt_path(args.state_directory)  # Reject unsafe output before credentials or host mutations.
    environment = credentials(args.downloads, os.environ)
    environment['AEGIS_IOS_PROFILES'] = json.dumps(PROFILE_NAMES)
    certificate, password = signing_material(args.downloads, fingerprint)
    keychain = signing_keychain(fingerprint)
    downloaded = json.loads(run('bundle', 'exec', 'ruby', str(ROOT / 'scripts/release/ios-signing-profiles.rb'),
                                str(args.state_directory), env=environment))
    spec = importlib.util.spec_from_file_location('profile_validation', Path(__file__).with_name('hosted-signing.py'))
    validation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validation)
    import plistlib
    installs = []
    for profile in downloaded['profiles']:
        path = args.state_directory / profile['file']
        parsed = plistlib.loads(run('security', 'cms', '-D', '-i', str(path)))
        validation.validate_profile(parsed, profile['applicationId'], profile['name'], args.team, fingerprint)
        # Xcode's installed-profile filenames use UUIDs; the exported files retain stable channel names.
        directory = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
        target = directory / (profile['uuid'] + '.mobileprovision')
        if target.exists():
            if target.is_symlink() or target.read_bytes() != path.read_bytes():
                raise ValueError('Installed profile differs; existing signing state was preserved')
        else:
            installs.append((target, path.read_bytes()))
    for target, content in installs:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as output:
            os.chmod(target, 0o600)
            output.write(content)
    if args.unlock:
        unlock_keychain(keychain, password)
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
        if not re.search(r'\b' + re.escape(fingerprint) + r'\b[^\n]*"Apple Distribution:', identities):
            raise ValueError('Expected installed Distribution private-key identity is unavailable')
    receipt = dict(downloaded, team=args.team, certificateSha1=fingerprint, keychain=str(keychain),
                   keychainUnlocked=args.unlock, sharedAclChanged=False, searchListChanged=False)
    write_receipt(args.state_directory, receipt)
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError):
        print(str(sys.exc_info()[1]), file=sys.stderr)
        raise SystemExit(1)
