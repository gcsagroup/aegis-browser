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


def acl_grants_trusted_user(library, entry):
    """Resolve a Darwin ACL GUID to an explicit root/current-account UID."""
    library.acl_get_qualifier.argtypes = [ctypes.c_void_p]
    library.acl_get_qualifier.restype = ctypes.c_void_p
    library.mbr_uuid_to_id.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32),
                                      ctypes.POINTER(ctypes.c_int)]
    library.mbr_uuid_to_id.restype = ctypes.c_int
    qualifier = library.acl_get_qualifier(entry)
    if not qualifier:
        raise ValueError('Cannot inspect Development configuration ancestor ACL principal')
    try:
        identifier, kind = ctypes.c_uint32(), ctypes.c_int(-1)
        result = library.mbr_uuid_to_id(qualifier, ctypes.byref(identifier), ctypes.byref(kind))
        # membership.h: ID_TYPE_UID=0, ID_TYPE_GID=1. Groups/unknown users are untrusted.
        return result == 0 and kind.value == 0 and identifier.value in {0, os.getuid()}
    finally:
        library.acl_free(qualifier)


def check_acl(descriptor, *, readonly=False):
    """Exclude extended grants that POSIX modes alone cannot describe."""
    if sys.platform == 'darwin':
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        library.acl_get_fd_np.restype = ctypes.c_void_p
        library.acl_free.argtypes = [ctypes.c_void_p]
        library.acl_free.restype = ctypes.c_int
        ctypes.set_errno(0)
        acl = library.acl_get_fd_np(descriptor, 0x100)  # ACL_TYPE_EXTENDED in sys/acl.h
        error = ctypes.get_errno()
        if not acl and error != errno.ENOENT:
            raise OSError(error, 'Cannot inspect Development configuration ACL')
        if not acl:
            return
        try:
            if not readonly:
                raise ValueError('Development configuration must not have extended ACLs')
            library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
            library.acl_get_entry.restype = ctypes.c_int
            library.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
            library.acl_get_tag_type.restype = ctypes.c_int
            library.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
            library.acl_get_permset.restype = ctypes.c_int
            library.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            library.acl_get_perm_np.restype = ctypes.c_int
            # Darwin sys/acl.h: data/add, delete, append/add-directory, delete-child,
            # attributes, extended attributes, security and owner changes.
            mutable = [1 << bit for bit in (2, 4, 5, 6, 8, 10, 12, 13)]
            for index in range(1024):
                entry = ctypes.c_void_p()
                ctypes.set_errno(0)
                if library.acl_get_entry(acl, index, ctypes.byref(entry)):
                    if ctypes.get_errno() == errno.EINVAL:
                        return  # Darwin uses EINVAL after the last indexed entry.
                    raise OSError(ctypes.get_errno(), 'Cannot inspect ancestor ACL entry')
                tag = ctypes.c_int()
                permissions = ctypes.c_void_p()
                if library.acl_get_tag_type(entry, ctypes.byref(tag)) or tag.value not in (1, 2):
                    raise ValueError('Invalid Development configuration ancestor ACL')
                if tag.value == 2:  # ACL_EXTENDED_DENY is not a grant.
                    continue
                if library.acl_get_permset(entry, ctypes.byref(permissions)):
                    raise ValueError('Cannot inspect Development configuration ancestor ACL')
                for permission in mutable:
                    granted = library.acl_get_perm_np(permissions, permission)
                    if granted == -1:
                        raise OSError(ctypes.get_errno(), 'Cannot inspect ancestor ACL permission')
                    if granted:
                        if not acl_grants_trusted_user(library, entry):
                            raise ValueError('Development configuration ancestor has a writable extended ACL')
                        break
            raise ValueError('Development configuration ancestor ACL exceeds the entry limit')
        finally:
            library.acl_free(acl)
    elif any(name in {'system.posix_acl_access', 'system.posix_acl_default'}
             for name in os.listxattr(descriptor)):
        raise ValueError('Development configuration must not have extended ACLs')


def require_no_acl(descriptor):
    check_acl(descriptor)


def require_trusted_ancestor(descriptor):
    info = os.fstat(descriptor)
    if (info.st_uid not in {0, os.getuid()}
            or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)):
        raise ValueError('Development configuration ancestor permits untrusted directory changes')
    check_acl(descriptor, readonly=True)


def open_physical_directory(path, *, private=False):
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Expected an absolute physical Development signing directory')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = os.open(path.anchor, flags)
    try:
        if private:
            require_trusted_ancestor(descriptor)
        for part in path.parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            if private:
                require_trusted_ancestor(descriptor)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_regular(path, limit, *, private=False, directory_fd=None):
    if directory_fd is not None and (private or path != Path(path.name) or path.name in {'.', '..'}):
        raise ValueError('Expected a direct Development profile entry')
    parent_fd = open_physical_directory(path.parent, private=True) if private else directory_fd
    try:
        if private:
            info = os.fstat(parent_fd)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError('Development configuration requires an owner-only physical directory')
            require_no_acl(parent_fd)
        descriptor = os.open(path.name if parent_fd is not None else path,
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
        if private and parent_fd is not None:
            os.close(parent_fd)


def installed_profile_contents(uuid, directories):
    original = None
    matches = 0
    expected_name = uuid.lower() + '.mobileprovision'
    for directory in directories:
        try:
            descriptor = open_physical_directory(directory)
        except FileNotFoundError:
            continue
        try:
            with os.scandir(descriptor) as entries:
                for index, entry in enumerate(entries):
                    if index >= 50000:
                        raise ValueError('Development profile directory exceeds the inventory limit')
                    if entry.name.lower() == expected_name:
                        matches += 1
                        if matches > 8:
                            raise ValueError('Too many matching Development profiles')
                        candidate = read_regular(Path(entry.name), 5 * 1024**2, directory_fd=descriptor)
                        if original is None:
                            original = candidate
                        elif candidate != original:
                            raise ValueError('Conflicting installed Development profiles')
                        del candidate
        finally:
            os.close(descriptor)
    if original is None:
        raise ValueError('Configured Development profile is not installed')
    return original


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
        raw = read_regular(path, 8192, private=True)
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise
        return ['CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development',
                'PROVISIONING_PROFILE_SPECIFIER='], {'style': 'automatic'}
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
        raw_profile = installed_profile_contents(uuid, directories)
        profile = verify_profile(raw_profile)
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
        evidence['profiles'][identifier] = {'uuid': uuid.lower(), 'sha256': hashlib.sha256(raw_profile).hexdigest()}
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
