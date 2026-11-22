"""Product-owned, create-only Android delivery records. No Play credentials or retries."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess

_spec = importlib.util.spec_from_file_location('android_delivery_receipt', Path(__file__).with_name('android-delivery-receipt.py'))
_receipt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_receipt)
require_version_code = _receipt.require_version_code

EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
SCHEMA = 'android-product-delivery-v2'
APPLICATION_ID = 'com.gcsa.aegis'
LEGACY_REFS = 'git/matching-refs/heads/android-delivery/'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def allocation(application, version, build):
    if application != APPLICATION_ID:
        raise ValueError('Invalid Android delivery allocation')
    version_code = require_version_code(version, build)
    return hashlib.sha256(canonical([application, 'ANDROID', version_code]).encode()).hexdigest()


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def request(self, path, payload=None, missing=False):
        args = ['gh', 'api', '-H', 'Accept: application/vnd.github+json',
                'repos/' + self.repository + ('/' + path if path else '')]
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
            raise ValueError('Delivery record outcome unavailable; retain state and reconcile')
        return json.loads(result.stdout)


class Records:
    def __init__(self, api, repository_id, application):
        self.api, self.repository_id, self.application = api, repository_id, application
        if application != APPLICATION_ID:
            raise ValueError('Android delivery application differs')
        repo = api.request('')
        if repo.get('id') != repository_id:
            raise ValueError('Delivery repository identity differs')
        self.require_clear_legacy()

    def require_clear_legacy(self):
        # Previously the product version was part of the key. Preserve any
        # such records and require reconciliation before using the new keys.
        if self.api.request(LEGACY_REFS) != []:
            raise ValueError('Legacy Android delivery records require reconciliation before allocation')

    def path(self, kind, key):
        if kind not in {'package', 'upload-start', 'upload-result'} or not re.fullmatch(r'[0-9a-f]{64}', key):
            raise ValueError('Invalid Android delivery record path')
        return 'heads/android-delivery-v2/' + kind + '/' + key

    def read(self, kind, key):
        path = self.path(kind, key)
        ref = self.api.request('git/ref/' + path, missing=True)
        if ref is None:
            return None
        if ref.get('ref') != 'refs/' + path or ref.get('object', {}).get('type') != 'commit':
            raise ValueError('Invalid Android delivery record ref')
        commit = self.api.request('git/commits/' + ref['object']['sha'])
        if (commit.get('sha') != ref['object']['sha'] or commit.get('parents') != []
                or commit.get('tree', {}).get('sha') != EMPTY_TREE):
            raise ValueError('Invalid Android delivery record commit')
        value = json.loads(commit['message'])
        if (canonical(value) != commit['message'] or set(value) !=
                {'schema', 'repository_id', 'application', 'kind', 'allocation', 'payload'}
                or value['schema'] != SCHEMA or value['repository_id'] != self.repository_id
                or value['application'] != self.application or value['kind'] != kind
                or value['allocation'] != key or not isinstance(value['payload'], dict)):
            raise ValueError('Android delivery record identity differs')
        return value['payload']

    def create(self, kind, key, payload, *, authorize_create=None):
        """Read, create without update, then compare the original committed bytes."""
        self.require_clear_legacy()
        if self.read(kind, key) is not None:
            raise ValueError('Allocation already recorded; reconcile instead of replaying')
        value = dict(schema=SCHEMA, repository_id=self.repository_id, application=self.application,
                     kind=kind, allocation=key, payload=payload)
        message = canonical(value)
        if len(message.encode()) > 256 * 1024:
            raise ValueError('Android delivery record exceeds size limit')
        commit = self.api.request('git/commits', dict(message=message, tree=EMPTY_TREE, parents=[]))
        if not re.fullmatch(r'[0-9a-f]{40}', commit.get('sha', '')):
            raise ValueError('Unknown Android record creation outcome')
        if authorize_create is not None:
            authorize_create()
        self.api.request('git/refs', dict(ref='refs/' + self.path(kind, key), sha=commit['sha']))
        if self.read(kind, key) != payload:
            raise ValueError('Unknown Android record readback; no side effect is authorized')
        return payload
