"""Activate and test the configured Development key in the actual runner session."""
import json
import os
from contextlib import contextmanager
from pathlib import Path
import re
import stat
import tempfile


def write_result(directory, name, value):
    with open(directory / name, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
        json.dump(value, output, indent=2)
        output.write('\n')


@contextmanager
def password_descriptor(directory, selection):
    """Check the optional new Development-only password without reading its bytes."""
    descriptor = selection.open_physical_directory(directory, private=True)
    password = None
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Development password requires its owner-only configuration directory')
        selection.require_no_acl(descriptor)
        try:
            password = os.open('development-keychain.password', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                               dir_fd=descriptor)
        except FileNotFoundError:
            yield None
            return
        info = os.fstat(password)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= 1024):
            raise ValueError('Invalid owned Development password file')
        selection.require_no_acl(password)
        yield password
    finally:
        if password is not None:
            os.close(password)
        os.close(descriptor)


def check_keychain(path, selection):
    descriptor = selection.open_physical_directory(path.parent, private=True)
    try:
        keychain = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        try:
            info = os.fstat(keychain)
            # Native keychain databases are encrypted and normally mode0644.
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size <= 0):
                raise ValueError('Development keychain must be an owned physical database')
            selection.check_acl(keychain, readonly=True)
        finally:
            os.close(keychain)
    finally:
        os.close(descriptor)


def prepare(evidence, native, directory, *, configuration_directory=None):
    """Caller holds native_session; never unlock login or change a key's ACL."""
    result = {'status': 'preunlocked_required', 'passwordLogged': False}
    record_attempted = False
    try:
        if evidence['style'] == 'automatic':
            result['status'] = 'automatic_unchanged'
            return None
        selection = native.module('development_access_selection', 'development_signing.py')
        selection.validate_evidence(evidence)
        result.update(certificateSha1=evidence['certificateSha1'],
                      configurationSha256=evidence['configurationSha256'])
        configuration_directory = configuration_directory or Path.home() / '.config/gcsa-aegis-signing'
        with password_descriptor(configuration_directory, selection) as password:
            if password is None:
                return None
            paths = native.keychains()
            if len(paths) > 64:
                raise ValueError('Development keychain inventory exceeds the limit')
            matches = []
            for value in paths:
                path = Path(value)
                if native.unretainable_keychain(path):
                    continue
                certificates = native.run('/usr/bin/security', 'find-certificate', '-a', '-Z', str(path)).decode()
                if re.search(r'SHA-1 hash: ' + re.escape(evidence['certificateSha1']) + r'\b', certificates):
                    check_keychain(path, selection)
                    if native.keychain_has_distribution(str(path)):
                        raise ValueError('Configured Development keychain contains a Distribution identity')
                    matches.append(path)
            if len(matches) != 1:
                raise ValueError('Unique owned dedicated Development keychain required')
            keychain = matches[0]
            result['keychain'] = keychain.name
            unlock = native.module('development_access_unlock', 'local-ios-signing.py')
            with unlock.activated_keychain_from_fd(keychain, password) as initially_unlocked:
                if native.keychain_has_distribution(str(keychain)):
                    raise ValueError('Unlocked Development keychain contains a Distribution identity')
                result.update(status='unlocked_in_runner', initiallyUnlocked=initially_unlocked)
                # Publishing failure is also an activation failure, while the native ref is alive.
                record_attempted = True
                write_result(directory, 'development-keychain-activation.json', result)
            return keychain
    except BaseException:
        result['status'] = 'failed'
        raise
    finally:
        if not record_attempted:
            write_result(directory, 'development-keychain-activation.json', result)


def public_environment(environment):
    return {name: environment[name] for name in (
        'PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL')
        if name in environment}


def verify(evidence, native, directory, environment, keychain=None):
    """Probe the private signing operation inside the same isolation as the archive."""
    result = {'status': 'automatic_not_probed', 'stage': 'selection', 'passwordLogged': False}
    try:
        if evidence['style'] == 'automatic':
            return
        native.module('development_probe_selection', 'development_signing.py').validate_evidence(evidence)
        if keychain is not None and str(keychain) not in native.keychains():
            raise ValueError('Activated Development keychain is absent from archive isolation')
        public_env = public_environment(environment)
        with tempfile.TemporaryDirectory(prefix='development-key-probe-', dir=directory) as temporary:
            root = Path(temporary)
            source, binary = root / 'probe.c', root / 'probe'
            source.write_text('int main(void) { return 0; }\n')
            result['stage'] = 'compile_probe'
            native.run('/usr/bin/xcrun', '--sdk', 'macosx', 'clang', str(source), '-o', str(binary), env=public_env,
                       log=directory / 'development-key-probe-clang.log', timeout=60)
            if not binary.is_file() or binary.is_symlink():
                raise ValueError('Development signing probe compiler produced no regular binary')
            result['stage'] = 'sign_probe'
            arguments = ['/usr/bin/codesign', '--force', '--sign', evidence['certificateSha1'], '--timestamp=none']
            if keychain is not None:
                arguments += ['--keychain', str(keychain)]
            native.run(*arguments, str(binary), env=public_env,
                       log=directory / 'development-key-probe-codesign.log', timeout=30)
            result['stage'] = 'verify_probe'
            native.run('/usr/bin/codesign', '--verify', '--strict', str(binary), env=public_env,
                       log=directory / 'development-key-probe-verify.log', timeout=30)
        result.update(status='verified_in_runner', stage='complete', certificateSha1=evidence['certificateSha1'])
    except BaseException as error:
        result['status'] = 'failed'
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise ValueError('Development private-key probe failed in this runner session; see retained preflight diagnostics') from error
    finally:
        write_result(directory, 'development-key-access.json', result)
