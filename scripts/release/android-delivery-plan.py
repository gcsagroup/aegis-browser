#!/usr/bin/env python3
"""Normalize Android Simple and Full delivery inputs before protected jobs."""
import importlib.util
import json
import os
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location('android_delivery_receipt', Path(__file__).with_name('android-delivery-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

SIMPLE_OPERATIONS = {
    'package': ('Package', '仅打包 / Package'),
    'package-upload': ('Package and upload', '打包并上传 / Package and upload'),
    'status': ('Status', '查询状态 / Status'),
    'wait': ('Wait', '等待状态 / Wait'),
    'release-wait': ('Release Wait', '发布核对 / Release Wait'),
}
FULL_OPERATIONS = {
    'package': ('Package', '仅打包 / Package'),
    'upload': ('Upload', '上传 Play 草稿 / Upload'),
    'status': ('Status', '查询状态 / Status'),
    'full': ('Full', '完整模式 / Full'),
}
PRODUCTS = {
    'auto': ('Auto', '自动 / Auto'),
    'alpha': ('Alpha', 'Alpha · 仅内测 / Internal only'),
    'beta': ('Beta', 'Beta · 内外测 / Internal and external'),
    'release': ('Release', 'Release · 通用 / Universal'),
}
SIMPLE_TRACK = {'alpha': 'internal', 'beta': 'beta', 'release': 'internal'}
QUERY = {'status': 'status-query', 'wait': 'status-wait', 'release-wait': 'status-release-wait'}
FIELDS = ('operation', 'profile', 'version', 'build', 'destination', 'track', 'tag',
          'package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256',
          'stage_input', 'user_fraction')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value, labels):
    if value in labels:
        return value
    for command, accepted in labels.items():
        if value in accepted:
            return command
    raise ValueError('Unknown Android operation or product')


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'Duplicate delivery JSON key')
        value[key] = item
    return value


def reject_constant(_value):
    raise ValueError('Non-finite delivery JSON is not allowed')


def candidate_tag(version, profile, build):
    return f'candidate/android/{version}-{profile}.{build}'


def blank():
    return {key: '' for key in FIELDS}


def identity_from_target(target):
    match = re.fullmatch(r'([0-9.]+)\(([1-9][0-9]{0,9})\)', target or '')
    require(match is not None, 'Enter version(versionCode), for example 7.2.0.339(2007000339)')
    version, build = match.groups()
    receipt.require_version_code(version, build)
    return version, build


def fraction(value):
    require(isinstance(value, str) and re.fullmatch(r'0\.(?:[0-9]{0,3}[1-9])', value) is not None,
            'Distribution requires an explicit user fraction below 1, without trailing zeros')
    return value


def normalize(event, ref, inputs, mode='simple', source_sha=None, attempt='1'):
    require(event == 'workflow_dispatch' and ref == 'refs/heads/main', 'Android delivery requires manual dispatch on main')
    require(mode in {'simple', 'full'}, 'Unknown Android delivery mode')
    allowed = {'operation', 'product', 'version', 'build', 'approved_source_sha'}
    if mode == 'full':
        allowed = {'operation', 'product', 'target', 'advanced', 'approved_source_sha'}
    require(isinstance(inputs, dict) and not inputs.keys() - allowed and all(isinstance(item, str) for item in inputs.values()),
            'Unknown or invalid Android delivery inputs')
    approved = inputs.get('approved_source_sha', '')
    if approved:
        require(re.fullmatch(r'[0-9a-f]{40}', approved) is not None and approved == source_sha,
                'Approved source differs from this workflow source')
    require(re.fullmatch(r'[1-9][0-9]{0,15}', str(attempt)) is not None, 'Invalid workflow attempt')
    if mode == 'simple':
        values = _simple(inputs)
    else:
        values = _full(inputs)
    if values['operation'] in {'package', 'package-upload', 'draft'}:
        require(attempt == '1', 'A new Android package cannot be rerun; reconcile the original run before selecting a new versionCode')
    require(all('\n' not in value and '\r' not in value for value in values.values()), 'Invalid multiline workflow output')
    return values


def _simple(inputs):
    operation = canonical(inputs.get('operation') or 'status', SIMPLE_OPERATIONS)
    profile = canonical(inputs.get('product') or 'alpha', PRODUCTS)
    require(profile != 'auto', 'Choose Alpha, Beta, or Release')
    version, build = inputs.get('version', ''), inputs.get('build', '')
    receipt.require_version_code(version, build)
    values = blank()
    if operation in QUERY:
        values.update(operation=QUERY[operation], profile=profile, version=version, build=build,
                      destination='play-internal', stage_input='{}')
        return values
    require(operation in {'package', 'package-upload'}, 'Unsupported Android simple operation')
    values.update(operation=operation, profile=profile, version=version, build=build, stage_input='{}',
                  destination='play-draft' if operation == 'package-upload' else 'artifacts',
                  track=SIMPLE_TRACK[profile] if operation == 'package-upload' else '')
    return values


def _full(inputs):
    operation = canonical(inputs.get('operation') or 'status', FULL_OPERATIONS)
    profile = canonical(inputs.get('product') or 'auto', PRODUCTS)
    raw = inputs.get('advanced') or '{}'
    require(len(raw.encode()) <= 64000, 'Stage input exceeds bound')
    try:
        advanced = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (ValueError, RecursionError) as error:
        raise ValueError('Invalid stage JSON') from error
    require(isinstance(advanced, dict), 'Stage input must be an object')
    target = inputs.get('target', '')
    if operation == 'full':
        require(set(advanced) <= {'operation', 'track', 'userFraction'} and isinstance(advanced.get('operation'), str),
                'Full mode requires an explicit stage')
        stages = {key: value for key, value in SIMPLE_OPERATIONS.items() if key != 'package-upload'}
        stages.update({'upload': FULL_OPERATIONS['upload'], 'distribute': ('distribute',),
                       'submit': ('submit',), 'draft': ('draft',)})
        operation = canonical(advanced['operation'], stages)
        advanced = {key: value for key, value in advanced.items() if key != 'operation'}
    else:
        require(not advanced, 'Stage JSON is only for Full mode')
    if operation in {'package', 'draft', 'status', 'wait', 'release-wait'}:
        version, build = identity_from_target(target)
        pinned = None
    else:
        pinned = receipt.decode(target)
        require(profile == 'auto' or profile == pinned['profile'], 'Product differs from the Android delivery receipt')
        version, build, profile = pinned['version'], pinned['build'], pinned['profile']
    values = blank()
    values.update(profile=profile, version=version, build=build)
    if operation in QUERY or operation in {'status', 'wait', 'release-wait'}:
        require(not advanced and pinned is None, 'Status only needs version(versionCode)')
        values.update(operation=QUERY[operation], destination='play-internal', stage_input='{}')
        return values
    if operation == 'package':
        require(profile != 'auto' and not advanced, 'Package needs an explicit product and no stage JSON')
        values.update(operation='package', destination='artifacts', stage_input='{}')
        return values
    if operation == 'draft':
        require(profile != 'auto' and not advanced, 'Draft needs an explicit product and no stage JSON')
        values.update(operation='draft', destination='github-draft', tag=candidate_tag(version, profile, build), stage_input='{}')
        return values
    if operation == 'upload':
        track = advanced.get('track', SIMPLE_TRACK[profile])
        require(set(advanced) <= {'track'} and _track_allowed(profile, track) and track != 'production',
                'Play draft upload cannot select production or another product track')
        values.update(pinned)
        values.update(operation='upload', destination='play-draft', track=track, stage_input='{}')
        return values
    require(pinned['upload_run_id'], 'Track changes require a receipt for a successful Play upload')
    if operation == 'distribute':
        track = advanced.get('track', '')
        require(set(advanced) == {'track', 'userFraction'} and _track_allowed(profile, track) and track != 'production',
                'Distribution requires its own track below production')
        values.update(pinned)
        values.update(operation='distribute', destination='play-' + track, track=track,
                      user_fraction=fraction(advanced['userFraction']), stage_input=json.dumps(
                          {'track': track, 'userFraction': advanced['userFraction']}, separators=(',', ':'), sort_keys=True))
        return values
    require(operation == 'submit', 'Unsupported Android delivery stage')
    require(profile == 'release' and advanced == {'track': 'production'},
            'Production submission requires the Release product and an explicit production track')
    values.update(pinned)
    values.update(operation='submit', destination='play-production', track='production', stage_input='{}')
    return values


def _track_allowed(profile, track):
    allowed = {'alpha': {'internal'}, 'beta': {'internal', 'beta'}, 'release': {'internal', 'beta', 'production'}}
    return track in allowed.get(profile, set())


def main():
    raw = os.environ.get('ANDROID_DELIVERY_INPUTS')
    require(raw is not None and len(raw.encode()) <= 131072, 'Android delivery inputs exceed bound')
    inputs = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    values = normalize(os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF'], inputs,
                       os.environ.get('ANDROID_DELIVERY_MODE', 'simple'), os.environ.get('GITHUB_SHA'),
                       os.environ.get('GITHUB_RUN_ATTEMPT', '1'))
    payload = json.dumps(values, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    require('\n' not in payload, 'Invalid multiline workflow output')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('plan=' + payload + '\n')


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
