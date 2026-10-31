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

INPUTS = {'operation', 'product', 'target', 'advanced'}
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


def normalize(event, ref, inputs):
    require(isinstance(inputs, dict) and not inputs.keys()-INPUTS and all(isinstance(v, str) for v in inputs.values()), 'Unknown or invalid delivery inputs')
    if event == 'push':
        return _normalize_stage(event, ref, inputs)
    require(event == 'workflow_dispatch' and ref == 'refs/heads/main', 'Delivery requires main dispatch or exact candidate tag')
    raw_options = inputs.get('advanced') or '{}'
    require(len(raw_options.encode()) <= 64000, 'Full options exceed bound')
    try:
        options = json.loads(raw_options, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (ValueError, RecursionError) as error:
        raise ValueError('Invalid Full options JSON') from error
    require(isinstance(options, dict) and not options.keys()-{'operation', 'groups', 'stage_input'}, 'Unknown Full options')
    selected = inputs.get('operation') or 'package'
    if selected in {'full', '完整模式 / Full'}:
        require(isinstance(options.get('operation'), str), 'Full mode requires an explicit operation')
        operation = receipt.canonical(options['operation'], receipt.OPERATION_LABELS)
        require(isinstance(options.get('groups', ''), str) and isinstance(options.get('stage_input', {}), dict), 'Invalid Full groups or stage input')
    else:
        require(not options, 'Select Full mode to use advanced options')
        operation = receipt.canonical(selected, receipt.OPERATION_LABELS)
        require(operation in {'package', 'upload', 'status'}, 'Select Full mode for this operation')
    normalized = dict(operation=operation, product=inputs.get('product', ''),
                      groups=options.get('groups', ''), stage_input=json.dumps(options.get('stage_input', {}), ensure_ascii=True))
    normalized['version' if operation in {'package', 'draft'} else 'source'] = inputs.get('target', '')
    return _normalize_stage(event, ref, normalized)


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
    values = normalize(os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF'], event.get('inputs') or {})
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in sorted(values.items()):
            output.write(key+'='+value+'\n')
