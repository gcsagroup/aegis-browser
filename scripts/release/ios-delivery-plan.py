#!/usr/bin/env python3
"""Normalize simple iOS delivery inputs before scheduling protected jobs."""
import importlib.util
import json
import os
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location('ios_delivery_receipt', Path(__file__).with_name('ios-delivery-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

STAGE_INPUTS = {'operation', 'product', 'version', 'source', 'groups', 'stage_input'}
FIELDS = {'operation', 'profile', 'version', 'build', 'destination', 'tag', 'package_run_id',
          'upload_run_id', 'source_attempt', 'manifest_sha256', 'groups', 'stage_input'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'Duplicate Full option key')
        value[key] = item
    return value


def reject_constant(_value):
    raise ValueError('Non-finite Full JSON is not allowed')


def normalize(event, ref, inputs, mode='simple'):
    allowed = {'operation', 'product', 'version', 'build'}
    if mode == 'full':
        allowed |= {'source', 'groups', 'stage_input'}
    require(mode in {'simple', 'full'}, 'Unknown delivery mode')
    require(isinstance(inputs, dict) and not inputs.keys()-allowed and all(isinstance(v, str) for v in inputs.values()),
            'Unknown or invalid delivery inputs')
    if event == 'push':
        require(mode == 'simple', 'Only the canonical entrypoint accepts candidate tags')
        return _normalize_stage(event, ref, inputs)
    require(event == 'workflow_dispatch' and ref == 'refs/heads/main', 'Delivery requires main dispatch or exact candidate tag')
    operation = receipt.canonical(inputs.get('operation') or 'status', receipt.OPERATION_LABELS)
    require(mode == 'full' or operation in {'package', 'package-upload', 'status', 'wait'}, 'Use the Full workflow for upload and later stages')
    version, build = inputs.get('version', ''), inputs.get('build', '')
    if version or build or operation in {'package', 'package-upload', 'draft', 'status'} or (operation == 'wait' and not inputs.get('source')):
        require(re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', version) is not None and
                re.fullmatch(r'[1-9][0-9]{0,9}', build) is not None,
                'Enter version and build, for example 1.0.0 and 35')
    raw_input = inputs.get('stage_input') or '{}'
    require(len(raw_input.encode()) <= 64000, 'Stage input exceeds bound')
    try:
        stage_input = json.loads(raw_input, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (ValueError, RecursionError) as error:
        raise ValueError('Invalid stage JSON') from error
    require(isinstance(stage_input, dict), 'Stage input must be an object')
    receipt.canonical(inputs.get('product') or 'auto', receipt.PRODUCT_LABELS)
    if operation in {'status', 'wait'} and not inputs.get('source'):
        require(not inputs.get('source') and not inputs.get('groups') and not stage_input,
                'Status only needs version and build')
        values = {key: '' for key in FIELDS}
        values.update(operation='status-wait' if operation == 'wait' else 'status-query', version=version, build=build, destination='testflight', stage_input='{}')
        return values  # Read-only Apple lookup: no inferred package identity or mutation receipt.
    require(operation != 'status', 'Status only needs version and build')
    package_upload = operation == 'package-upload'
    if package_upload:
        require(not inputs.get('source') and not inputs.get('groups') and not stage_input, 'New package upload cannot import or distribute existing state')
        operation = 'package'
    normalized = dict(operation=operation, product=inputs.get('product', ''),
                      groups=inputs.get('groups', ''), stage_input=json.dumps(stage_input, ensure_ascii=True))
    if version:
        normalized['version'] = f'{version}({build})'
    if inputs.get('source'):
        normalized['source'] = inputs['source']
    values = _normalize_stage(event, ref, normalized)
    if package_upload:
        values.update(operation='package-upload', destination='testflight')
    return values


def _normalize_stage(event, ref, inputs):
    require(isinstance(inputs, dict) and not inputs.keys()-STAGE_INPUTS and all(isinstance(v, str) for v in inputs.values()), 'Unknown or invalid stage inputs')
    values = {key: inputs.get(key, '') for key in FIELDS}
    if event == 'push':
        require(not inputs, 'Tag delivery cannot accept manual overrides')
        require(isinstance(ref, str) and len(ref) < 130, 'Invalid candidate tag')
        match = re.fullmatch(r'refs/tags/(candidate/ios/([0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?)-(alpha|beta|release)\.([1-9][0-9]{0,9}))', ref)
        require(match is not None, 'Invalid exact iOS candidate tag')
        tag, version, profile, build = match.groups()
        values.update(operation='package', profile=profile, version=version, build=build, destination='github-draft', tag=tag)
    else:
        require(event == 'workflow_dispatch' and ref == 'refs/heads/main', 'Delivery requires main dispatch or exact candidate tag')
        operation = receipt.canonical(values['operation'] or 'package', receipt.OPERATION_LABELS)
        profile = receipt.canonical(inputs.get('product') or 'auto', receipt.PRODUCT_LABELS)
        identity = values['version']
        if identity:
            match = re.fullmatch(r'([0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?)\(([1-9][0-9]{0,9})\)', identity)
            require(match is not None, 'Use version(build), for example 1.0.0(33)')
            values['version'], values['build'] = match.groups()
        source = inputs.get('source', '')
        if operation in {'package', 'draft'}:
            require(not source, 'Package cannot import existing state')
            values.update(operation='package', profile='alpha' if profile == 'auto' else profile,
                          destination='github-draft' if operation == 'draft' else 'artifacts')
            if operation == 'draft':
                values['tag'] = f'candidate/ios/{values["version"]}-{values["profile"]}.{values["build"]}'
        else:
            pinned = receipt.decode(source)
            require(profile == 'auto' or profile == pinned['profile'], 'Profile differs from delivery receipt')
            require(all(not values[key] or values[key] == pinned[key] for key in ['version', 'build']), 'Version/build differs from delivery receipt')
            values.update(pinned)
            values['operation'] = 'distribute' if operation.startswith('distribute-') else operation
            values['destination'] = 'testflight-'+operation.removeprefix('distribute-') if operation.startswith('distribute-') else 'testflight'
    operation, profile, destination = (values[key] for key in ['operation', 'profile', 'destination'])
    require(re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', values['version']) is not None and
            re.fullmatch(r'[1-9][0-9]{0,9}', values['build']) is not None, 'Package requires valid version and unused build number')
    raw_input = values['stage_input'] or '{}'
    require(len(raw_input.encode()) <= 64000, 'Stage input exceeds bound')
    try:
        stage_input = json.loads(raw_input)
    except (ValueError, RecursionError) as error:
        raise ValueError('Invalid stage JSON') from error
    require(isinstance(stage_input, dict), 'Stage input must be an object')
    values['stage_input'] = json.dumps(stage_input, separators=(',', ':'), ensure_ascii=True)
    require(operation in {'metadata', 'compliance'} or not stage_input, 'Input is only for metadata/compliance')
    if operation == 'package':
        require(not values['groups'], 'Groups are only for distribution')
    else:
        require(profile != 'alpha' or destination != 'testflight-external', 'Alpha is internal testing only')
        require(operation not in {'metadata', 'compliance', 'distribute'} or values['upload_run_id'], 'Later mutation requires completed uploaded state receipt')
        if operation == 'distribute':
            groups = [group.strip() for group in values['groups'].split(',')]
            require(len(groups) <= 100 and len(set(groups)) == len(groups) and
                    all(group and len(group) <= 100 and not any(ord(c) < 32 or ord(c) == 127 for c in group) for group in groups),
                    'Distribution requires existing unique groups')
            values['groups'] = ','.join(groups)
        else:
            require(not values['groups'], 'Groups are only for distribute')
    require(all('\n' not in value and '\r' not in value for value in values.values()), 'Invalid multiline workflow output')
    return values


if __name__ == '__main__':
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    raw = os.environ.get('DELIVERY_INPUTS')
    require(raw is None or len(raw.encode()) <= 131072, 'Delivery inputs exceed bound')
    inputs = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant) if raw else event.get('inputs') or {}
    values = normalize(os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF'], inputs, os.environ.get('DELIVERY_MODE', 'simple'))
    require(values['operation'] != 'package-upload' or os.environ.get('GITHUB_RUN_ATTEMPT', '1') == '1',
            'New package upload cannot be rerun; reconcile the original run before selecting a new build')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in sorted(values.items()):
            output.write(key+'='+value+'\n')
