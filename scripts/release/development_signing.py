"""Select explicitly configured Development profiles without ASC credentials."""
import datetime
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

SCHEMA = 'aegis-development-signing-v1'
TARGETS = {
    'com.gcsa.aegis': ('Aegis', ''),
    'com.gcsa.aegis.safari': ('SafariWebExtension', 'PlugIns/SafariWebExtension.appex'),
    'com.gcsa.aegis.share': ('ShareExtension', 'PlugIns/ShareExtension.appex'),
}
GROUPS = ['group.com.gcsa.aegis.ios.share-inbox']
UUID = re.compile(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}')
CERTIFICATE = re.compile(r'[0-9A-F]{40}')


def require_no_acl(descriptor):
    """POSIX modes do not exclude additional macOS ACL grants."""
    if sys.platform == 'darwin':
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        library.acl_get_fd_np.restype = ctypes.c_void_p
        library.acl_free.argtypes = [ctypes.c_void_p]
        library.acl_free.restype = ctypes.c_int
        ctypes.set_errno(0)
        acl = library.acl_get_fd_np(descriptor, 0x100)  # ACL_TYPE_EXTENDED in sys/acl.h
        error = ctypes.get_errno()
        if acl:
            library.acl_free(acl)
            raise ValueError('Development configuration must not have extended ACLs')
        if error != errno.ENOENT:
            raise OSError(error, 'Cannot inspect Development configuration ACL')
    elif any(name in {'system.posix_acl_access', 'system.posix_acl_default'}
             for name in os.listxattr(descriptor)):
        raise ValueError('Development configuration must not have extended ACLs')


def read_regular(path, limit, *, private=False):
    parent_fd = None
    if private:
        parent = path.parent
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if private:
            info = os.fstat(parent_fd)
            if (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700
                    or parent.resolve() != parent):
                raise ValueError('Development configuration requires an owner-only physical directory')
            require_no_acl(parent_fd)
        descriptor = os.open(path.name if private else path,
                             os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        with os.fdopen(descriptor, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= limit
                    or (private and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600))):
                raise ValueError('Invalid Development configuration or profile file')
            if private:
                require_no_acl(stream.fileno())
            data = stream.read(limit + 1)
            if len(data) != info.st_size:
                raise ValueError('Development signing input changed during reading')
            return data
    finally:
        if parent_fd is not None:
            os.close(parent_fd)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate Development configuration field')
        value[key] = item
    return value


def resolve(team, verify_profile, *, config_path=None, profile_directories=None):
    """The opt-in file contains only a public certificate pin and profile UUIDs."""
    path = config_path or Path.home() / '.config/gcsa-aegis-signing/development-archive.json'
    try:
        config_info = path.lstat()
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise
        return ['CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development',
                'PROVISIONING_PROFILE_SPECIFIER='], {'style': 'automatic'}
    if stat.S_ISLNK(config_info.st_mode):
        raise ValueError('Development configuration symlink refused')
    raw = read_regular(path, 8192, private=True)
    config = json.loads(raw, object_pairs_hook=unique_object)
    if (type(config) is not dict or set(config) != {'schema', 'team', 'certificateSha1', 'profiles'}
            or config['schema'] != SCHEMA or config['team'] != team
            or not re.fullmatch(r'[A-Z0-9]{10}', team)
            or type(config['certificateSha1']) is not str
            or CERTIFICATE.fullmatch(config['certificateSha1']) is None
            or type(config['profiles']) is not dict or set(config['profiles']) != set(TARGETS)):
        raise ValueError('Development signing configuration differs from this product/team')
    directories = profile_directories if profile_directories is not None else [
        Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
        Path.home() / 'Library/MobileDevice/Provisioning Profiles',
    ]
    evidence = {'style': 'manual', 'certificateSha1': config['certificateSha1'],
                'configurationSha256': hashlib.sha256(raw).hexdigest(), 'profiles': {}}
    arguments = ['CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=' + config['certificateSha1'],
                 'PROVISIONING_PROFILE_SPECIFIER=$(AEGIS_DEVELOPMENT_PROFILE_$(TARGET_NAME))']
    for identifier, (target, _) in TARGETS.items():
        uuid = config['profiles'][identifier]
        if type(uuid) is not str or UUID.fullmatch(uuid) is None:
            raise ValueError('Expected Development profile UUID')
        candidates = [directory / (value + '.mobileprovision') for directory in directories
                      for value in dict.fromkeys((uuid, uuid.lower(), uuid.upper()))
                      if (directory / (value + '.mobileprovision')).exists()
                      or (directory / (value + '.mobileprovision')).is_symlink()]
        if not candidates:
            raise ValueError('Configured Development profile is not installed: ' + identifier)
        contents = [read_regular(candidate, 5 * 1024**2) for candidate in candidates]
        if any(content != contents[0] for content in contents):
            raise ValueError('Conflicting installed Development profiles')
        profile = verify_profile(contents[0])
        entitlement = profile.get('Entitlements', {})
        certificates = profile.get('DeveloperCertificates')
        devices = profile.get('ProvisionedDevices')
        expiry = profile.get('ExpirationDate')
        if (type(profile.get('UUID')) is not str or profile['UUID'].lower() != uuid.lower()
                or profile.get('TeamIdentifier') != [team]
                or not isinstance(expiry, datetime.datetime) or expiry <= datetime.datetime.utcnow()
                or type(devices) is not list or not devices or not all(type(item) is str and item for item in devices)
                or profile.get('ProvisionsAllDevices')
                or entitlement.get('application-identifier') != team + '.' + identifier
                or entitlement.get('com.apple.developer.team-identifier') != team
                or entitlement.get('get-task-allow') is not True
                or entitlement.get('com.apple.security.application-groups') != GROUPS
                or type(certificates) is not list or not certificates
                or not all(type(item) is bytes for item in certificates)
                or not any(hashlib.sha1(item).hexdigest().upper() == config['certificateSha1'] for item in certificates)):
            raise ValueError('Configured Development profile identity differs: ' + identifier)
        evidence['profiles'][identifier] = {'uuid': uuid.lower(), 'sha256': hashlib.sha256(contents[0]).hexdigest()}
        arguments.append('AEGIS_DEVELOPMENT_PROFILE_' + target + '=' + profile['UUID'])
    return arguments, evidence


def require_identity(evidence, native_run):
    if evidence['style'] == 'manual':
        identities = native_run('security', 'find-identity', '-v', '-p', 'codesigning').decode()
        if re.search(r'^\s*\d+\) ' + evidence['certificateSha1'] + r' "Apple Development:', identities, re.M) is None:
            raise ValueError('Configured Development private identity is unavailable in the isolated keychain')


def validate_evidence(evidence):
    if evidence == {'style': 'automatic'}:
        return
    if (type(evidence) is not dict or set(evidence) != {'style', 'certificateSha1', 'configurationSha256', 'profiles'}
            or evidence['style'] != 'manual' or type(evidence['certificateSha1']) is not str
            or CERTIFICATE.fullmatch(evidence['certificateSha1']) is None
            or type(evidence['configurationSha256']) is not str
            or re.fullmatch(r'[0-9a-f]{64}', evidence['configurationSha256']) is None
            or type(evidence['profiles']) is not dict or set(evidence['profiles']) != set(TARGETS)):
        raise ValueError('Invalid Development signing evidence')
    for profile in evidence['profiles'].values():
        if (type(profile) is not dict or set(profile) != {'uuid', 'sha256'}
                or type(profile['uuid']) is not str or UUID.fullmatch(profile['uuid']) is None
                or type(profile['sha256']) is not str or re.fullmatch(r'[0-9a-f]{64}', profile['sha256']) is None):
            raise ValueError('Invalid Development profile evidence')


def verify_archive(archive, evidence, native_run):
    validate_evidence(evidence)
    if evidence == {'style': 'automatic'}:
        return
    app = archive / 'Products/Applications/Aegis.app'
    with tempfile.TemporaryDirectory(prefix='development-signer-', dir=archive.parent) as temporary:
        for index, (identifier, (_, relative)) in enumerate(TARGETS.items()):
            profile = evidence['profiles'][identifier]
            bundle = app / relative
            raw = read_regular(bundle / 'embedded.mobileprovision', 5 * 1024**2)
            if hashlib.sha256(raw).hexdigest() != profile['sha256']:
                raise ValueError('Archive did not embed the configured Development profile')
            prefix = Path(temporary) / (str(index) + '-')
            native_run('codesign', '-d', '--extract-certificates=' + str(prefix), str(bundle))
            signer = read_regular(Path(str(prefix) + '0'), 1024 * 1024)
            if hashlib.sha1(signer).hexdigest().upper() != evidence['certificateSha1']:
                raise ValueError('Archive Development certificate differs from its configuration')
