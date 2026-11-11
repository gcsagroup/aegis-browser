"""Product-owned, create-only delivery records. No Apple credentials or retries."""
import hashlib
import json
import re
import subprocess

EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
SCHEMA = 'ios-product-delivery-v1'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def allocation(application, version, build):
    if (not isinstance(application, str) or not application
            or not re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', version)
            or not re.fullmatch(r'[1-9][0-9]{0,9}', build)):
        raise ValueError('Invalid delivery allocation')
    parts = [str(int(item)) for item in version.split('.')]
    normalized = '.'.join(parts + ['0'] * (3 - len(parts)))
    return hashlib.sha256(canonical([application, 'IOS', normalized, build]).encode()).hexdigest()


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def request(self, path, payload=None, missing=False):
        args = ['gh', 'api', '-H', 'Accept: application/vnd.github+json',
                'repos/' + self.repository + '/' + path]
        body = None
        if payload is not None:
            args += ['--method', 'POST', '--input', '-']
            body = canonical(payload)
        result = subprocess.run(args, input=body, text=True, capture_output=True, timeout=60)
        if result.returncode:
            if missing:
                try:
                    if str(json.loads(result.stdout).get('status')) == '404':
                        return None
                except (ValueError, AttributeError):
                    pass
            # A failed mutation may have committed. Never retry here.
            raise ValueError('Delivery record outcome unavailable; retain state and reconcile')
        return json.loads(result.stdout)


class Records:
    def __init__(self, api, repository_id, application):
        self.api, self.repository_id, self.application = api, repository_id, application
        repo = api.request('')
        if repo.get('id') != repository_id:
            raise ValueError('Delivery repository identity differs')

    def path(self, kind, key):
        if kind not in {'export-start', 'package', 'upload-start', 'upload-result'} or not re.fullmatch(r'[0-9a-f]{64}', key):
            raise ValueError('Invalid delivery record path')
        return 'heads/ios-delivery/' + kind + '/' + key

    def read(self, kind, key):
        path = self.path(kind, key)
        ref = self.api.request('git/ref/' + path, missing=True)
        if ref is None:
            return None
        if ref.get('ref') != 'refs/' + path or ref.get('object', {}).get('type') != 'commit':
            raise ValueError('Invalid delivery record ref')
        commit = self.api.request('git/commits/' + ref['object']['sha'])
        if (commit.get('sha') != ref['object']['sha'] or commit.get('parents') != []
                or commit.get('tree', {}).get('sha') != EMPTY_TREE):
            raise ValueError('Invalid delivery record commit')
        value = json.loads(commit['message'])
        if (canonical(value) != commit['message'] or set(value) !=
                {'schema', 'repository_id', 'application', 'kind', 'allocation', 'payload'}
                or value['schema'] != SCHEMA or value['repository_id'] != self.repository_id
                or value['application'] != self.application or value['kind'] != kind
                or value['allocation'] != key or not isinstance(value['payload'], dict)):
            raise ValueError('Delivery record identity differs')
        return value['payload']

    def create(self, kind, key, payload):
        """Read, create without update, then compare the original committed bytes."""
        if self.read(kind, key) is not None:
            raise ValueError('Allocation already recorded; reconcile instead of replaying')
        value = dict(schema=SCHEMA, repository_id=self.repository_id, application=self.application,
                     kind=kind, allocation=key, payload=payload)
        message = canonical(value)
        if len(message.encode()) > 256 * 1024:
            raise ValueError('Delivery record exceeds size limit')
        commit = self.api.request('git/commits', dict(message=message, tree=EMPTY_TREE, parents=[]))
        if not re.fullmatch(r'[0-9a-f]{40}', commit.get('sha', '')):
            raise ValueError('Unknown record creation outcome')
        self.api.request('git/refs', dict(ref='refs/' + self.path(kind, key), sha=commit['sha']))
        if self.read(kind, key) != payload:
            raise ValueError('Unknown record readback; no side effect is authorized')
        return payload
