"""Confine and verify private Alpha inputs and the exact signed TestFlight package."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

RELEASE = Path(__file__).resolve().parent
ROOT = RELEASE.parents[1]
NODE = 'AegisPrivateTestNode.vless'
QUOTA = 'AegisPrivateTestSubscription.json'
INPUTS = ('AEGIS_IOS_ALPHA_NODES_BASE64', 'AEGIS_IOS_TEST_NODE_BASE64', 'AEGIS_IOS_TEST_SUBSCRIPTION_BASE64')
ASC = ('AEGIS_ASC_KEY_ID', 'AEGIS_ASC_ISSUER_ID', 'AEGIS_ASC_KEY_BASE64', 'AEGIS_ASC_KEY_PATH')
MANIFEST = 'ios-manifest.json'
HANDOFF = 'handoff.json'
ROUTE = {
    'GITHUB_ACTIONS': 'true',
    'GITHUB_REPOSITORY': 'gcsagroup/aegis-browser',
    'GITHUB_EVENT_NAME': 'workflow_dispatch',
    'GITHUB_REF': 'refs/heads/main',
    'GITHUB_WORKFLOW_REF': 'gcsagroup/aegis-browser/.github/workflows/ios-delivery.yml@refs/heads/main',
    'GITHUB_RUN_ATTEMPT': '1',
    'DELIVERY_MODE': 'simple',
    'RUNNER_OS': 'macOS',
    'RUNNER_ENVIRONMENT': 'self-hosted',
    'RELEASE_OPERATION': 'package-upload',
    'RELEASE_PROFILE': 'alpha',
    'RELEASE_SIGNING_MODE': 'manual',
    'RELEASE_DESTINATION': 'testflight',
    'AEGIS_IOS_ALPHA_NODES_ENABLED': 'true',
}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def alpha_nodes():
    return load('private_alpha_nodes', ROOT / 'apps/ios/scripts/private_alpha_nodes.py')


def legacy():
    return load('private_beta_inputs', RELEASE / 'private-beta-inputs.py')


def require_route(env):
    if (any(env.get(key) != value for key, value in ROUTE.items())
            or not re.fullmatch(r'[1-9][0-9]{0,19}', env.get('GITHUB_RUN_ID', ''))
            or env.get('RELEASE_RUN_ID') != f"ios-gh-{env['GITHUB_RUN_ID']}-1"
            or not re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', env.get('RELEASE_VERSION', ''))
            or not re.fullmatch(r'[1-9][0-9]{0,9}', env.get('RELEASE_BUILD', ''))):
        raise ValueError('Private Alpha route refused')


def runner_location(env):
    parent = Path(env['RUNNER_TEMP']).resolve(strict=True)
    if not parent.is_dir() or parent.is_relative_to(ROOT):
        raise ValueError('Private Alpha requires runner temporary storage outside the checkout')
    return parent, f"aegis-private-alpha-{env['GITHUB_RUN_ID']}-1-"


def acl_entries(path):
    if sys.platform != 'darwin':
        return []
    # The fixed ls operation treats the path after -- as one literal operand.
    listing = subprocess.check_output(  # nosec B603
        ['/bin/ls', '-lde', '--', str(path)], shell=False, text=True, timeout=10)
    return [line for line in listing.splitlines()[1:] if re.match(r'\s*\d+:\s', line)]


def require_private_dir(path):
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
            or info.st_uid != os.geteuid() or acl_entries(path)):
        raise ValueError('Private Alpha directory must be owner-only')


def existing_directory(env):
    parent, prefix = runner_location(env)
    directory = Path(env['AEGIS_PRIVATE_ALPHA_DIRECTORY'])
    if directory.parent != parent or re.fullmatch(re.escape(prefix) + r'[a-z0-9_]{8}', directory.name) is None:
        raise ValueError('Private Alpha directory does not belong to this run')
    require_private_dir(directory)
    return directory


def output(name, value):
    value = str(value)
    if '\n' in value or '\r' in value:
        raise ValueError('Invalid private Alpha output')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write(f'{name}={value}\n')


def decode(value, maximum):
    if not value or len(value) > 4 * ((maximum + 2) // 3):
        raise ValueError('Missing or oversized private Alpha input')
    raw = base64.b64decode(value, validate=True)
    if not 0 < len(raw) <= maximum:
        raise ValueError('Invalid private Alpha input size')
    return raw


def quota_config(raw, validator):
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=validator.unique_object,
                       parse_constant=validator.invalid_constant)
    if not isinstance(value, dict):
        raise ValueError('Invalid private Alpha quota descriptor')
    return value


def stage(env):
    nodes, validator = alpha_nodes(), legacy()
    raw_list, raw_node, raw_quota = (decode(env.pop(key, ''), maximum)
                                   for key, maximum in zip(INPUTS, (nodes.MAX_JSON_BYTES, 8192, 8192)))
    source_quota = quota_config(raw_quota, validator)
    parent, prefix = runner_location(env)
    directory = Path(tempfile.mkdtemp(dir=parent, prefix=prefix))
    try:
        # An inherited runner-temp ACL would extend to every private file below.
        require_private_dir(directory)
        # Publish only this nonsecret path, before writing any private bytes, for always() cleanup.
        output('directory', directory)
        inputs = directory / 'inputs'
        inputs.mkdir(mode=0o700)
        require_private_dir(inputs)
        with tempfile.TemporaryDirectory(dir=directory, prefix='decode-') as work:
            require_private_dir(Path(work))
            node, quota = Path(work) / 'node', Path(work) / 'quota'
            nodes.write_private(node, raw_node)
            nodes.write_private(quota, raw_quota)
            # Use the same product validators as Beta and the Xcode phases.
            validator.module('private_test_node').install('alpha', str(node), inputs / NODE)
            validator.module('private_test_subscription').install('alpha', str(quota), str(node), inputs / QUOTA)
        anchor = nodes.read_private(inputs / NODE, 8192)
        if 'nodeSHA256' in source_quota and source_quota['nodeSHA256'] != hashlib.sha256(anchor).hexdigest():
            raise ValueError('Private Alpha descriptor does not bind the anchored node')
        anchor_identity = nodes.validate_transport(anchor.decode('utf-8'), anchor=True)
        canonical = nodes.canonicalize(raw_list, anchor_identity)
        nodes.write_private(inputs / nodes.RESOURCE, canonical)
        checked_inputs(inputs)
    except BaseException:
        shutil.rmtree(directory)
        raise


def checked_inputs(directory):
    require_private_dir(directory)
    nodes = alpha_nodes()
    expected = {name: nodes.read_private(directory / name, maximum) for name, maximum in
                ((NODE, 8192), (QUOTA, 8192), (nodes.RESOURCE, nodes.MAX_RESOURCE_BYTES))}
    expected_list = expected[nodes.RESOURCE]
    anchor_identity = nodes.validate_transport(expected[NODE].decode('utf-8'), anchor=True)
    if nodes.canonicalize(expected_list, anchor_identity) != expected_list:
        raise ValueError('Private Alpha staged list is not canonical')
    configuration = quota_config(expected[QUOTA], legacy())
    if configuration['nodeSHA256'] != hashlib.sha256(expected[NODE]).hexdigest():
        raise ValueError('Private Alpha quota binding differs from the anchored node')
    return expected, configuration


def verify_resources(archive, root, info, directory):
    if (root != 'Payload/Aegis.app/' or info.get('AegisAccessReleaseChannel') != 'alpha'
            or info.get('AegisReleaseProfile') != 'alpha' or info.get('TFInternalTestingOnly') is not True):
        raise ValueError('Private Alpha requires an internal-only Alpha IPA')
    expected, _ = checked_inputs(directory)
    for resource, raw in expected.items():
        matches = [item for item in archive.infolist() if
                   item.filename.replace('\\', '/').rstrip('/').rsplit('/', 1)[-1].casefold() == resource.casefold()]
        if len(matches) != 1 or matches[0].orig_filename != root + resource:
            raise ValueError('Private Alpha resource is missing, duplicated, or outside the app root')
        member = matches[0]
        if (stat.S_IFMT(member.external_attr >> 16) not in (0, stat.S_IFREG)
                or member.file_size != len(raw) or archive.read(member) != raw):
            raise ValueError('Private Alpha resource bytes differ from verified input')


def run_private(operation, directory):
    environment = os.environ.copy()
    temp = directory / 'tmp'
    temp.mkdir(mode=0o700, exist_ok=True)
    require_private_dir(temp)
    environment.update(TMPDIR=str(temp), GYM_SUPPRESS_XCODE_OUTPUT='true')
    subprocess.run(['bundle', 'exec', 'ruby', str(RELEASE / 'ios-private-alpha.rb'), operation, str(directory)],
                   cwd=ROOT, env=environment, umask=0o022, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def admitted_source(action):
    sha, tree = action.source()
    if sha != os.environ['GITHUB_SHA']:
        raise ValueError('Private Alpha package source differs from the workflow')
    return sha, tree


def checked_package(directory, expected_digest, *, retained=False):
    package = directory / 'package'
    require_private_dir(package)
    if not re.fullmatch(r'[0-9a-f]{64}', expected_digest):
        raise ValueError('Private Alpha package digest is missing')
    for member in package.iterdir():
        info = member.lstat()
        if not stat.S_ISREG(info.st_mode) or (retained and (
                info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1)):
            raise ValueError('Invalid private Alpha package file')
    action = load('ios_action', RELEASE / 'ios-action.py')
    sha, tree = admitted_source(action)
    manifest = action.transport.verify_package(package, sha, tree, expected_digest)
    details = manifest['details']
    if (manifest.get('schemaVersion') != 1 or manifest.get('releaseReady') is not False
            or manifest.get('format') != 'ipa' or manifest.get('applicationId') != 'com.gcsa.aegis'
            or (manifest['profile'], manifest['version'], manifest['build']) !=
                ('alpha', os.environ['RELEASE_VERSION'], os.environ['RELEASE_BUILD'])
            or len(manifest['assets']) != 1 or details.get('privateAlphaNodes') is not True
            or details.get('signingMode') != 'manual'
            or details.get('testFlightInternalTestingOnly') is not True):
        raise ValueError('Private Alpha manifest identity differs')
    ipa = package / manifest['assets'][0]['name']
    verifier = load('verify_private_alpha_ipa', RELEASE / 'verify-ipa.py')
    verifier.verify(ipa, manifest['version'], manifest['build'], 'alpha', private_alpha_directory=directory / 'inputs')
    return action, ipa


def handoff(digest, *, create=False):
    runner = os.environ['RUNNER_NAME']
    if not runner or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('Private Alpha handoff requires a runner and a package digest')
    base = Path.home() / '.local/share/aegis-private-alpha'
    # RUNNER_TEMP is cleared between jobs. Keep only the transfer under the runner account.
    if base.resolve() != base or base.is_relative_to(ROOT):
        raise ValueError('Aliased or in-checkout private Alpha handoff root')
    if create:
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
    require_private_dir(base)
    sha, tree = admitted_source(load('ios_action', RELEASE / 'ios-action.py'))
    identity = dict(repository=os.environ['GITHUB_REPOSITORY'], runId=os.environ['GITHUB_RUN_ID'],
                    attempt=os.environ['GITHUB_RUN_ATTEMPT'], runner=runner, sourceSha=sha,
                    sourceTree=tree, manifestSha256=digest)
    return base / os.environ['RELEASE_RUN_ID'], identity


def retain(directory, digest):
    _, ipa = checked_package(directory, digest)
    retained, identity = handoff(digest, create=True)
    retained.mkdir(mode=0o700)
    try:
        require_private_dir(retained)
        expected, _ = checked_inputs(directory / 'inputs')
        nodes = alpha_nodes()
        # Save the binding before copying private bytes so cancellation cleanup can check ownership.
        nodes.write_private(retained / HANDOFF, json.dumps(identity).encode())
        inputs = retained / 'inputs'
        inputs.mkdir(mode=0o700)
        require_private_dir(inputs)
        for name, raw in expected.items():
            nodes.write_private(inputs / name, raw)
        package = retained / 'package'
        package.mkdir(mode=0o700)
        require_private_dir(package)
        for name in (MANIFEST, MANIFEST + '.sha256', ipa.name):
            with (ipa.parent / name).open('rb') as original, (package / name).open('xb') as copy:
                shutil.copyfileobj(original, copy)
        checked_package(retained, digest, retained=True)
        output('manifest_sha256', digest)
    except BaseException:
        shutil.rmtree(retained)
        raise


def check_handoff(directory, identity):
    require_private_dir(directory)
    if json.loads(alpha_nodes().read_private(directory / HANDOFF, 4096)) != identity:
        raise ValueError('Private Alpha handoff belongs to a different source, run or runner')


def cleanup_handoff(digest):
    try:
        directory, identity = handoff(digest)
        require_private_dir(directory)
    except FileNotFoundError:
        return
    check_handoff(directory, identity)
    # Keep the binding until the private bytes are gone, even if cleanup is interrupted.
    marker = directory / HANDOFF
    for member in directory.iterdir():
        if member == marker:
            continue
        if not member.is_symlink() and member.is_dir():
            shutil.rmtree(member)
        else:
            member.unlink()
    marker.unlink()
    directory.rmdir()


def require_preflight(digest):
    if (not re.fullmatch(r'[0-9a-f]{64}', digest)
            or os.environ.get('AEGIS_PRIVATE_ALPHA_VERIFIED_MANIFEST_SHA256') != digest):
        raise ValueError('Private Alpha requires completed quota verification for this IPA')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('stage', 'package', 'retain', 'preflight',
                                              'require-preflight', 'upload', 'cleanup', 'cleanup-handoff'))
    operation = parser.parse_args().operation
    # Do not let generated files inherit a permissive runner umask, including legacy Xcode inputs.
    os.umask(0o077)
    try:
        require_route(os.environ)
        if operation != 'stage' and any(os.environ.get(key) for key in INPUTS):
            raise ValueError('Private Alpha input secrets are only allowed during staging')
        if operation != 'upload' and any(os.environ.get(key) for key in ASC):
            raise ValueError('ASC credentials are only allowed during private Alpha upload')
        if operation == 'stage':
            stage(os.environ)
        elif operation == 'cleanup':
            if os.environ.get('AEGIS_PRIVATE_ALPHA_DIRECTORY'):
                try:
                    shutil.rmtree(existing_directory(os.environ))
                except FileNotFoundError:
                    pass  # Staging may already have removed its own directory after validation failed.
        elif operation == 'package':
            directory = existing_directory(os.environ)
            checked_inputs(directory / 'inputs')
            run_private(operation, directory)
            digest = hashlib.sha256(alpha_nodes().read_private(directory / 'package' / MANIFEST, 65536)).hexdigest()
            checked_package(directory, digest)
            output('manifest_sha256', digest)
            print('Private Alpha signed IPA and exact bundle resources verified.')
        else:
            digest = os.environ['RELEASE_MANIFEST_SHA256']
            if operation == 'retain':
                retain(existing_directory(os.environ), digest)
            elif operation == 'cleanup-handoff':
                cleanup_handoff(digest)
            elif operation == 'require-preflight':
                require_preflight(digest)
            else:
                if operation == 'upload':
                    require_preflight(digest)
                    if not all(os.environ.get(key) for key in ASC[:3]) or os.environ.get(ASC[3]):
                        raise ValueError('Private Alpha requires the protected ASC upload key')
                directory, identity = handoff(digest)
                check_handoff(directory, identity)
                action, _ = checked_package(directory, digest, retained=True)
                action.check_new_upload_runs()
                if operation == 'preflight':
                    _, configuration = checked_inputs(directory / 'inputs')
                    legacy().run_live_quota(configuration)
                    output('manifest_sha256', digest)
                    print('Private Alpha live quota and identity verified.')
                else:
                    run_private(operation, directory)
                    print('Private Alpha upload accepted for processing; processing remains unverified.')
    except (KeyError, OSError, ValueError, TypeError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError):
        sys.exit(f'Private Alpha {operation} failed. Check the admitted route, protected inputs, and release state.')


if __name__ == '__main__':
    main()
