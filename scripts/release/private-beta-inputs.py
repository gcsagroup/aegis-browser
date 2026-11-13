"""Stage protected Beta inputs and require their exact presence in the exported IPA."""
import argparse
import base64
import http.client
import importlib.util
import json
import os
from pathlib import Path
import plistlib
# Runs only this checked-in helper with the current Python interpreter and fixed argv.
import subprocess  # nosec B404
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

QUOTA_TIMEOUT_SECONDS = 20


def run_live_quota(configuration):
    # A separate process bounds DNS, TLS, response headers and slow-drip bodies together.
    # Values travel only over stdin; child output and exception details remain private.
    try:
        subprocess.run(  # nosec B603
            [sys.executable, str(Path(__file__).resolve()), 'quota'],
            input=json.dumps(configuration).encode(), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=QUOTA_TIMEOUT_SECONDS, check=True)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        raise ValueError('Live quota verification failed') from None


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate quota field')
        value[key] = item
    return value


def invalid_constant(_value):
    raise ValueError('Nonstandard JSON constant')


def module(name):
    path = Path(__file__).resolve().parents[2] / 'apps/ios/scripts' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def stage(directory, environment):
    if directory.is_symlink() or not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise ValueError('Private directory required')
    for key, filename in (('AEGIS_IOS_TEST_NODE_BASE64', 'node.vless'),
                          ('AEGIS_IOS_TEST_SUBSCRIPTION_BASE64', 'subscription.json')):
        encoded = environment.get(key, '')
        if not encoded or len(encoded) > 11000:
            raise ValueError('Missing or oversized private input')
        raw = base64.b64decode(encoded, validate=True)
        if not raw or len(raw) > 8192:
            raise ValueError('Invalid private input size')
        with os.fdopen(os.open(directory / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(raw)
    # Use the exact product resource validators before invoking Xcode.
    module('private_test_node').install('beta', str(directory / 'node.vless'), directory / 'expected-node')
    module('private_test_subscription').install('beta', str(directory / 'subscription.json'),
                                              str(directory / 'node.vless'), directory / 'expected-subscription')
    for filename in ('expected-node', 'expected-subscription'):
        (directory / filename).chmod(0o600)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Quota redirects are not allowed')


def check_live_quota(configuration):
    url = configuration['subscriptionInfoURL']
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != 'https':
        raise ValueError('Quota requires HTTPS')
    # Default HTTPSHandler verifies certificates; never follow a redirect with a private URL.
    opener = urllib.request.build_opener(NoRedirect())
    # Match AccessSubscriptionClient's request headers, including the product user agent.
    request = urllib.request.Request(url, headers={
        'Accept': 'application/json', 'User-Agent': 'Aegis-Alpha/1.0'})
    with opener.open(request, timeout=20) as response:
        if (response.status != 200 or response.geturl() != url
                or response.headers.get_content_type() != 'application/json'):
            raise ValueError('Invalid quota response')
        lengths = response.headers.get_all('Content-Length', [])
        if len(lengths) > 1:
            raise ValueError('Ambiguous quota response length')
        length = None
        if lengths:
            value = lengths[0].strip()
            if not value.isascii() or not value.isdecimal() or len(value) > 5:
                raise ValueError('Invalid quota response length')
            length = int(value)
            if length > 65536 or response.headers.get('Transfer-Encoding') is not None:
                raise ValueError('Invalid quota response framing')
        raw = response.read(65537)
    if len(raw) > 65536 or (length is not None and len(raw) != length):
        raise ValueError('Oversized or incomplete quota response')
    usage = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    if not isinstance(usage, dict):
        raise ValueError('Invalid quota payload')
    maximum = (1 << 64) - 1
    for key in ('uploadByte', 'downloadByte', 'totalByte', 'expire'):
        if type(usage[key]) is not int or not 0 <= usage[key] <= maximum:
            raise ValueError('Invalid quota number')
    used = usage['uploadByte'] + usage['downloadByte']
    if (usage['sId'] != urllib.parse.unquote(parts.path.rsplit('/', 1)[-1])
            or usage['emails'] != [configuration['allowedTestClient']]
            or usage['totalByte'] != configuration['expectedQuotaBytes']
            or usage['enabled'] is not True or used >= usage['totalByte']
            or usage['expire'] > 253_402_300_799
            or (usage['expire'] != 0 and usage['expire'] <= time.time())):
        raise ValueError('Quota identity, availability or allowance mismatch')


def verify(directory, ipa, live_quota=False):
    root = 'Payload/Aegis.app/'
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate IPA members')
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        if info.get('AegisAccessReleaseChannel') != 'beta' or info.get('AegisReleaseProfile') != 'beta':
            raise ValueError('Expected Beta IPA')
        for member, expected in (('AegisPrivateTestNode.vless', 'expected-node'),
                                 ('AegisPrivateTestSubscription.json', 'expected-subscription')):
            if archive.getinfo(root + member).file_size > 8192:
                raise ValueError('Oversized private resource')
            if archive.read(root + member) != (directory / expected).read_bytes():
                raise ValueError('Private Beta resource mismatch')
        if live_quota:
            run_live_quota(json.loads(archive.read(root + 'AegisPrivateTestSubscription.json')))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('stage', 'verify', 'quota'))
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--live-quota', action='store_true')
    args = parser.parse_args()
    try:
        if args.operation != 'quota' and args.directory is None:
            raise ValueError('Directory required')
        if args.operation == 'quota':
            raw = sys.stdin.buffer.read(8193)
            if len(raw) > 8192:
                raise ValueError('Oversized quota configuration')
            check_live_quota(json.loads(raw))
        elif args.operation == 'stage':
            stage(args.directory, os.environ)
        else:
            if args.ipa is None:
                raise ValueError('IPA required')
            verify(args.directory, args.ipa, live_quota=args.live_quota)
            if args.live_quota:
                print('Private Beta IPA resources and live quota verified.')
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile,
            urllib.error.URLError, http.client.HTTPException):
        sys.exit('Private Beta input validation failed; no private values are logged.')
