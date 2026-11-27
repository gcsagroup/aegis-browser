"""Copyable Android delivery identity pins. Never a substitute for producer checks."""
import re

VERSION = re.compile(r'(?:0|[1-9][0-9]{0,9})(?:\.(?:0|[1-9][0-9]{0,9})){2,3}\Z')
CODE = re.compile(r'[1-9][0-9]{0,9}\Z')
PROFILES = {'alpha', 'beta', 'release'}
MAX_CODE = 2100000000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_build_number(version):
    require(isinstance(version, str) and VERSION.fullmatch(version) is not None, 'Invalid Android product version')
    parts = [int(part) for part in version.split('.')]
    require(all(part <= 2147483647 for part in parts), 'Android product version is outside the supported range')
    if len(parts) == 4:
        require(parts[3] < 10000, 'Android product version is outside the supported range')
        return parts[3]
    return None


def require_version_code(version, build):
    require(isinstance(build, str) and CODE.fullmatch(build) is not None, 'Invalid Android versionCode')
    code = int(build)
    legacy_build = version_build_number(version)
    require(1 <= code <= MAX_CODE and (legacy_build is None or code % 10000 == legacy_build),
            'versionCode must stay in range and match any legacy product build number')
    return code


def decode(value):
    require(isinstance(value, str) and len(value) <= 256, 'Invalid Android delivery receipt')
    fields = value.split(':')
    same_run_draft = len(fields) == 9 and fields[0] == 'aegis-android-v2' and fields[-1] == 'draft'
    if same_run_draft:
        fields = fields[:-1]
    require(len(fields) == 8 and (fields[0] == 'aegis-android-v1' or same_run_draft),
            'Copy the complete Android delivery receipt from the last successful run summary')
    _, profile, version, build, package_run, state_run, attempt, digest = fields
    require(profile in PROFILES, 'Invalid Android delivery receipt identity')
    require_version_code(version, build)
    require(all(re.fullmatch(r'[1-9][0-9]{0,15}', item) is not None for item in (package_run, state_run, attempt)),
            'Invalid Android delivery receipt identity')
    require(re.fullmatch(r'[0-9a-f]{64}', digest) is not None, 'Invalid Android delivery receipt identity')
    require(not same_run_draft or package_run == state_run, 'Invalid same-run Android draft receipt')
    return dict(profile=profile, version=version, build=build, package_run_id=package_run,
                upload_run_id='' if state_run == package_run and not same_run_draft else state_run,
                source_attempt=attempt, manifest_sha256=digest)


def encode(profile, version, build, package_run, state_run, attempt, digest, draft=False):
    require_version_code(version, build)
    value = ':'.join(map(str, ['aegis-android-v1', profile, version, build, package_run, state_run, attempt, digest]))
    if draft and str(package_run) == str(state_run):
        value = value.replace('aegis-android-v1:', 'aegis-android-v2:', 1) + ':draft'
    decode(value)
    return value
