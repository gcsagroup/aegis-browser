#!/usr/bin/env python3
"""Aegis adapter for permanent allocation, package and upload records."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

from product_delivery import GitHub, Records, allocation

REPOSITORY = 'gcsagroup/aegis-browser'
REPOSITORY_ID = 1348409663
APPLICATION = '6827988433'


def records():
    return Records(GitHub(REPOSITORY), REPOSITORY_ID, APPLICATION)


def key(version, build):
    return allocation(APPLICATION, version, build)


def source():
    return {name: subprocess.check_output(['git', 'rev-parse', ref], text=True).strip()
            for name, ref in [('sha', 'HEAD'), ('tree', 'HEAD^{tree}')]}


def jobs(api, run_id, attempt):
    result = []
    for page in range(1, 101):
        rows = api.request(f'actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}')
        result.extend(rows['jobs'])
        if len(rows['jobs']) < 100:
            if len(result) != rows['total_count']:
                raise ValueError('Incomplete job inventory')
            return result
    raise ValueError('Job inventory exceeds limit')


def producer(api, run_id, attempt, sha):
    run = api.request(f'actions/runs/{run_id}/attempts/{attempt}')
    if (run['id'] != run_id or run['run_attempt'] != attempt or run['head_sha'] != sha
            or run['repository']['id'] != REPOSITORY_ID or run['head_repository']['id'] != REPOSITORY_ID
            or run['path'] not in {'.github/workflows/ios-delivery.yml', '.github/workflows/ios-delivery-full.yml'}
            or run['event'] not in {'workflow_dispatch', 'push'}):
        raise ValueError('Package producer run differs')
    matches = [row for row in jobs(api, run_id, attempt)
               if row['name'] == 'ios-package' or row['name'].endswith(' / ios-package')]
    if (len(matches) != 1 or matches[0]['status'] != 'completed' or matches[0]['conclusion'] != 'success'
            or matches[0]['head_sha'] != sha or matches[0]['run_id'] != run_id
            or matches[0]['run_attempt'] != attempt or type(matches[0]['id']) is not int):
        raise ValueError('Original package job was not successful')
    return matches[0]


def seal(directory, environment):
    manifest = json.loads((directory / 'ios-manifest.json').read_text())
    origin = json.loads((directory / 'package-origin.json').read_text())
    spec = importlib.util.spec_from_file_location('seal_transport', Path(__file__).with_name('artifact-transport.py'))
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    transport.verify_package(directory, origin['sourceSha'], origin['sourceTree'], origin['manifestSha256'])
    if (origin.get('repository') != REPOSITORY or
            source() != dict(sha=origin['sourceSha'], tree=origin['sourceTree'])):
        raise ValueError('Sealing source differs from the exact package source')
    store = records()
    original = producer(store.api, origin['runId'], origin['attempt'], origin['sourceSha'])
    artifacts = store.api.request(f"actions/runs/{origin['runId']}/artifacts?per_page=100")
    names = {f"ios-delivery-{origin['runId']}-{origin['attempt']}",
             f"ios-package-{origin['runId']}-{origin['attempt']}"}
    rows = [row for row in artifacts['artifacts'] if row['name'] in names and not row['expired']]
    if (artifacts['total_count'] > 100 or len(rows) != 1
            or type(rows[0].get('id')) is not int or rows[0]['id'] <= 0
            or re.fullmatch(r'sha256:[0-9a-f]{64}', rows[0].get('digest', '')) is None):
        raise ValueError('Exact immutable package artifact unavailable')
    payload = dict(origin=origin, package_job_id=original['id'], artifact_id=rows[0]['id'],
                   artifact_digest=rows[0]['digest'], artifact_name=rows[0]['name'],
                   version=manifest['version'], build=manifest['build'], profile=manifest['profile'])
    budget = key(manifest['version'], manifest['build'])
    if environment.get('GITHUB_ACTIONS') == 'true':
        expected = {'version': environment['RELEASE_VERSION'], 'build': environment['RELEASE_BUILD'],
                    'profile': environment['RELEASE_PROFILE']}
        if (any(manifest[name] != value for name, value in expected.items())
                or origin['runId'] != int(environment['GITHUB_RUN_ID'])
                or origin['attempt'] != int(environment['GITHUB_RUN_ATTEMPT'])
                or origin['manifestSha256'] != environment['RELEASE_MANIFEST_SHA256']):
            raise ValueError('Sealing request differs from this workflow allocation')
    start = store.read('export-start', budget)
    if (start is None or start['source'] != dict(sha=origin['sourceSha'], tree=origin['sourceTree'])
            or start['profile'] != manifest['profile'] or start['run_id'] != str(origin['runId'])
            or start['attempt'] != str(origin['attempt'])):
        raise ValueError('Package has no matching export allocation')
    store.create('package', budget, payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['export-start', 'seal', 'upload-start', 'upload-result', 'upload-check'])
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--version')
    parser.add_argument('--build')
    parser.add_argument('--profile')
    args = parser.parse_args()
    if args.operation == 'seal':
        seal(args.directory, os.environ)
        return
    store = records()
    if args.operation == 'export-start':
        store.create('export-start', key(args.version, args.build),
                     dict(source=source(), profile=args.profile, run_id=os.environ.get('GITHUB_RUN_ID'),
                          attempt=os.environ.get('GITHUB_RUN_ATTEMPT')))
        return
    manifest = json.loads((args.directory / 'ios-manifest.json').read_text())
    budget = key(manifest['version'], manifest['build'])
    filename = 'apple-upload-started.json' if args.operation == 'upload-start' else 'apple-upload-result.json'
    value = json.loads((args.directory / filename).read_text())
    if args.operation == 'upload-start':
        value = {name: item for name, item in value.items() if name not in {'startedAt', 'outcome'}}
    if args.operation in {'upload-result', 'upload-check'}:
        if store.read('upload-start', budget) != value['intent']:
            raise ValueError('Upload terminal differs from permanent intent')
    intent = value['intent'] if args.operation in {'upload-result', 'upload-check'} else value
    if (intent.get('manifestSha256') != hashlib.sha256((args.directory / 'ios-manifest.json').read_bytes()).hexdigest()
            or any(intent.get(name) != manifest.get(name)
                   for name in ['platform', 'applicationId', 'version', 'build', 'profile', 'format'])):
        raise ValueError('Upload record does not identify this package')
    if args.operation == 'upload-check':
        if store.read('upload-result', budget) != value:
            raise ValueError('Permanent upload terminal unavailable; reconcile read-only')
    else:
        store.create(args.operation, budget, value)


if __name__ == '__main__':
    main()
