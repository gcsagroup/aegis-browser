#!/usr/bin/env python3
"""Normalize explicit iOS delivery routes before scheduling protected jobs."""
import json
import os
from pathlib import Path
import re

FIELDS = {'operation', 'profile', 'version', 'build', 'destination', 'tag', 'package_run_id',
          'upload_run_id', 'source_attempt', 'manifest_sha256', 'groups', 'stage_input'}
OPERATIONS = {'package', 'upload', 'wait', 'status', 'metadata', 'compliance', 'distribute'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive(value):
    return re.fullmatch(r'[1-9][0-9]{0,15}', value) is not None


def normalize(event, ref, inputs):
    require(isinstance(inputs, dict) and not inputs.keys()-FIELDS and all(isinstance(v, str) for v in inputs.values()), 'Unknown or invalid delivery inputs')
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
        values['operation'] = values['operation'] or 'package'
        values['profile'] = values['profile'] or 'alpha'
        values['destination'] = values['destination'] or 'auto'
        if values['destination'] == 'auto':
            values['destination'] = 'artifacts' if values['operation'] == 'package' else 'testflight'
    operation, profile, destination = (values[key] for key in ['operation', 'profile', 'destination'])
    require(operation in OPERATIONS and profile in {'alpha', 'beta', 'release'}, 'Unknown operation or audience')
    require(re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', values['version']) is not None and
            re.fullmatch(r'[1-9][0-9]{0,9}', values['build']) is not None, 'Invalid package version/build')
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
        require(destination in {'artifacts', 'github-draft'}, 'Package route cannot upload or distribute')
        require(not any(values[key] for key in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256', 'groups']), 'Package route cannot import store state')
        require(values['tag'] == (f'candidate/ios/{values["version"]}-{profile}.{values["build"]}' if destination == 'github-draft' else ''), 'Draft requires exact matching tag; artifacts cannot use a tag')
    else:
        require(destination in {'testflight', 'testflight-internal', 'testflight-external'} and not values['tag'], 'Store route requires TestFlight destination without tag')
        require(profile != 'alpha' or destination != 'testflight-external', 'Alpha is internal testing only')
        require(positive(values['package_run_id']) and positive(values['source_attempt']) and
                re.fullmatch(r'[0-9a-f]{64}', values['manifest_sha256']) is not None, 'Exact producer run/attempt/manifest required')
        require(not values['upload_run_id'] or positive(values['upload_run_id']), 'Invalid store-state run')
        require(operation not in {'metadata', 'compliance', 'distribute'} or values['upload_run_id'], 'Later mutation requires completed uploaded state')
        if operation == 'distribute':
            groups = [group.strip() for group in values['groups'].split(',')]
            require(destination in {'testflight-internal', 'testflight-external'} and len(groups) <= 100 and
                    len(set(groups)) == len(groups) and all(group and len(group) <= 100 and not any(ord(c) < 32 or ord(c) == 127 for c in group) for group in groups),
                    'Distribution requires explicit destination and existing unique groups')
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
