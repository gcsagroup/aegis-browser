"""Bind private subscription metadata to the exact internal embedded node."""
import hashlib
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qsl, urlsplit


def install(channel, source, node_source, output):
    output.unlink(missing_ok=True)
    if channel not in ('dev', 'alpha', 'beta') or source == '/dev/null':
        return
    with open(source, 'rb') as stream:
        raw = stream.read(8193)
    if len(raw) > 8192:
        raise ValueError
    data = json.loads(raw)
    url = data['subscriptionInfoURL']
    parts = urlsplit(url)
    if (parts.scheme != 'https' or not parts.hostname or parts.username or parts.password
            or parts.fragment or parts.path in ('', '/') or parts.path.endswith('/')
            or parse_qsl(parts.query, keep_blank_values=True) != [('format', 'info')]
            or any(ch.isspace() for ch in url)
            or not isinstance(data['allowedTestClient'], str) or not data['allowedTestClient']
            or len(data['allowedTestClient'].encode()) > 256
            or type(data['expectedQuotaBytes']) is not int
            or data['expectedQuotaBytes'] != 10_000_000_000 or data['trafficReset'] != 'daily'):
        raise ValueError
    with open(node_source, 'rb') as stream:
        node = stream.read(8193)
    if len(node) > 8192:
        raise ValueError
    node = node.decode('utf-8').strip().encode('utf-8')
    if not node.startswith(b'vless://'):
        raise ValueError
    result = {key: data[key] for key in ('subscriptionInfoURL', 'allowedTestClient',
                                       'expectedQuotaBytes', 'trafficReset')}
    result['nodeSHA256'] = hashlib.sha256(node).hexdigest()
    with output.open('x') as stream:
        json.dump(result, stream)


if __name__ == '__main__':
    try:
        install(os.environ.get('AEGIS_ACCESS_RELEASE_CHANNEL'), os.environ['SCRIPT_INPUT_FILE_1'],
                os.environ['SCRIPT_INPUT_FILE_2'], Path(os.environ['SCRIPT_OUTPUT_FILE_0']))
    except (KeyError, OSError, TypeError, ValueError):
        sys.exit('Cannot package private subscription metadata. Check the private input and node files.')
