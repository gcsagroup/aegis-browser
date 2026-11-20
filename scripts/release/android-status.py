#!/usr/bin/env python3
"""Read one Play versionCode. Status is one GET; Wait polls until VALID or its bound expires."""
import importlib.util
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import time


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


delivery = module('android_delivery', 'android-delivery.py')
play = module('android_play', 'android-play.py')
receipt = module('android_delivery_receipt', 'android-delivery-receipt.py')


def status_document(plan, remote, source, mode, observed_at):
    receipt.require_version_code(plan['version'], plan['build'])
    if mode not in {'status', 'wait', 'release-wait'}:
        raise ValueError('Unknown read-only Play query')
    if remote.get('versionCode') != int(plan['build']) or remote.get('packageName') != play.APPLICATION_ID:
        raise ValueError('Play status does not match the requested versionCode')
    return {'platform': 'android', 'applicationId': play.APPLICATION_ID, 'version': plan['version'],
            'build': plan['build'], 'queryMode': mode, 'readOnly': True, 'packageProvenanceVerified': False,
            'querySource': {'sha': source['sha'], 'tree': source['tree'], 'dirty': False},
            'remote': {**remote, 'observedAt': observed_at}}


def main():
    plan = delivery.plan_from_env()
    delivery.validate_query(plan)
    mode = os.environ.get('RELEASE_QUERY_MODE', 'status')
    source = delivery.source_identity()
    key = json.loads(os.environ['AEGIS_PLAY_JSON_KEY_DATA'])
    token = play.access_token(key, play.urllib_transport, int(time.time()))
    client = play.Play(play.urllib_transport, token)
    code = int(plan['build'])
    deadline = time.time() + (0 if mode == 'status' else min(int(os.environ.get('ANDROID_STATUS_TIMEOUT', '600')), 600))
    remote = client.status(code)
    while remote['processingState'] != 'VALID' and time.time() < deadline:
        time.sleep(min(int(os.environ.get('ANDROID_STATUS_INTERVAL', '15')), 60))
        remote = client.status(code)
    document = status_document(plan, remote, source, mode, datetime.now(timezone.utc).isoformat())
    destination = Path('.artifacts/android-status/status.json')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(document, indent=2, sort_keys=True) + '\n')
    if mode != 'status' and remote['processingState'] != 'VALID':
        raise SystemExit('Play versionCode is not VALID')


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
