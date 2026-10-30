"""Copyable identity pins; never a substitute for producer or operator verification."""
import re


def decode(value):
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError('Invalid delivery receipt')
    fields = value.split(':')
    if len(fields) != 8 or fields[0] != 'aegis-ios-v1':
        raise ValueError('Copy the complete delivery receipt from the last successful run summary')
    _, profile, version, build, package_run, state_run, attempt, digest = fields
    if (profile not in {'alpha', 'beta', 'release'} or
            re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', version) is None or
            re.fullmatch(r'[1-9][0-9]{0,9}', build) is None or
            any(re.fullmatch(r'[1-9][0-9]{0,15}', item) is None for item in [package_run, state_run, attempt]) or
            re.fullmatch(r'[0-9a-f]{64}', digest) is None):
        raise ValueError('Invalid delivery receipt identity')
    return dict(profile=profile, version=version, build=build, package_run_id=package_run,
                upload_run_id='' if state_run == package_run else state_run,
                source_attempt=attempt, manifest_sha256=digest)


def encode(profile, version, build, package_run, state_run, attempt, digest):
    value = ':'.join(map(str, ['aegis-ios-v1', profile, version, build, package_run, state_run, attempt, digest]))
    decode(value)
    return value
