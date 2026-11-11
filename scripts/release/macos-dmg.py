#!/usr/bin/env python3
"""Plan and build an unnotarized macOS DMG from an existing .app.

Early delivery only. This does not call notarytool, staple a ticket, or
publish a GitHub Release. The .app must already exist on the Mac runner.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

VERSION = re.compile(r'(?:0|[1-9][0-9]{0,9})(?:\.(?:0|[1-9][0-9]{0,9})){1,3}')
SIGNING_MODES = frozenset({'ad-hoc', 'developer-id'})
ALLOWED_REPOSITORIES = frozenset({'quinn521/aegis-browser', 'gcsagroup/aegis-browser'})
BUNDLE_SUFFIXES = ('.app', '.framework', '.xpc', '.appex', '.plugin')
NOTARIZE_TOOLS = frozenset({'notarytool', 'stapler', 'altool'})


class DeliveryError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise DeliveryError(message)


def resolve_runner_label(environment):
    for key in ('AEGIS_MACOS_RUNNER_LABEL', 'AEGIS_IOS_RUNNER_LABEL'):
        label = environment.get(key, '')
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', label):
            return label
    raise DeliveryError('Set AEGIS_MACOS_RUNNER_LABEL or keep the existing self-hosted AEGIS_IOS_RUNNER_LABEL')


def normalize(environment):
    repository = environment.get('GITHUB_REPOSITORY', '')
    event = environment.get('GITHUB_EVENT_NAME', '')
    operation = environment.get('MACOS_OPERATION', '') or 'access'
    version = environment.get('MACOS_VERSION', '')
    signing_mode = environment.get('MACOS_SIGNING_MODE', '') or environment.get('AEGIS_MACOS_REHEARSAL_SIGNING_MODE', '') or 'ad-hoc'
    if signing_mode == 'temporary-ad-hoc':
        signing_mode = 'ad-hoc'
    notarize = environment.get('MACOS_NOTARIZE', '')
    require(repository in ALLOWED_REPOSITORIES, 'macOS delivery is limited to the fork and upstream repository')
    require(event == 'workflow_dispatch', 'macOS delivery only runs from a manual dispatch')
    require(operation in {'access', 'package'}, 'Operation must be access or package')
    require(notarize in {'', 'false', '0'}, 'Notarization is not part of this early delivery')
    require(VERSION.fullmatch(version) is not None, 'Version must be two to four numeric components, for example 6.1.0.266')
    require(signing_mode in SIGNING_MODES, 'Signing mode must be ad-hoc or developer-id')
    runner_label = resolve_runner_label(environment)
    arch = machine_arch(environment.get('MACOS_ARCH', '') or 'arm64')
    require(arch == 'arm64', 'This delivery runner/build supports arm64 only')
    identity = '-' if signing_mode == 'ad-hoc' else environment.get('AEGIS_MACOS_DEVELOPER_ID', '')
    if signing_mode == 'developer-id':
        require(identity.startswith('Developer ID Application:'), 'Developer ID identity is required for developer-id signing')
        require('notary' not in identity.lower(), 'Developer ID identity must not select a notarization tool')
    app = ''
    app_root = ''
    dmg_name = ''
    if operation == 'package':
        app_root = environment.get('AEGIS_MACOS_APP_ROOT', '')
        app = admit_app_shape(environment.get('MACOS_APP_PATH', ''), app_root)
        dmg_name = f'GCSA-aegis-{version}-mac-{arch}.dmg'
    else:
        require(not environment.get('MACOS_APP_PATH'), 'Access tests do not accept an app path')
    return {
        'repository': repository,
        'operation': operation,
        'version': version,
        'signing_mode': signing_mode,
        'identity': identity,
        'app': app,
        'app_root': app_root,
        'runner_label': runner_label,
        'runner': json.dumps(['self-hosted', 'macOS', 'ARM64', runner_label]),
        'arch': arch,
        'notarized': False,
        'dmg_name': dmg_name,
    }


def machine_arch(value):
    normalized = {'arm64': 'arm64', 'ARM64': 'arm64', 'x64': 'x64', 'x86_64': 'x64', 'X64': 'x64'}.get(value, '')
    require(normalized in {'arm64', 'x64'}, 'Runner architecture must be arm64 or x64')
    return normalized


def admit_app_shape(app_path, app_root):
    require(isinstance(app_path, str) and app_path.startswith('/') and '\x00' not in app_path and '\n' not in app_path,
            'App path must be absolute')
    require(isinstance(app_root, str) and app_root.startswith('/') and '\n' not in app_root and '\x00' not in app_root,
            'AEGIS_MACOS_APP_ROOT must be an absolute path')
    require('..' not in Path(app_path).parts and '..' not in Path(app_root).parts, 'App path cannot contain parent segments')
    root = os.path.abspath(app_root)
    app = os.path.abspath(app_path)
    require(app.endswith('.app'), 'App path must be a .app bundle')
    require(os.path.commonpath([root, app]) == root and app != root, 'App must be a strict child of AEGIS_MACOS_APP_ROOT')
    return app


def admit_app(app_path, app_root):
    admit_app_shape(app_path, app_root)
    root = Path(app_root)
    app = Path(app_path)
    require(root.is_dir() and not root.is_symlink(), 'App root must be a real directory')
    require(app.is_dir() and not app.is_symlink() and app.name.endswith('.app'), 'App path must be a real .app bundle')
    root_real = root.resolve()
    app_real = app.resolve()
    require(app_real == app, 'App path must already be canonical')
    require(os.path.commonpath([str(root_real), str(app_real)]) == str(root_real) and app_real != root_real,
            'App must be a strict child of AEGIS_MACOS_APP_ROOT')
    require((app_real / 'Contents' / 'Info.plist').is_file(), 'App bundle is missing Contents/Info.plist')
    return app_real


def sign_plan(app, identity, keychain=''):
    require(identity == '-' or identity.startswith('Developer ID Application:'), 'Refusing an unexpected signing identity')
    if identity != '-':
        require(keychain and Path(keychain).is_absolute() and Path(keychain).is_file(),
                'Verified job-local signing keychain is required for Developer ID')
    bundles = []
    for dirpath, dirnames, _filenames in os.walk(app, followlinks=False):
        current = Path(dirpath)
        kept = []
        for name in dirnames:
            path = current / name
            if path.is_symlink():
                continue
            kept.append(name)
            if name.endswith(BUNDLE_SUFFIXES) and path != app:
                bundles.append(path)
        dirnames[:] = kept
    ordered = sorted(bundles, key=lambda path: len(path.parts), reverse=True)
    ordered.append(Path(app))
    commands = []
    for path in ordered:
        command = ['/usr/bin/codesign', '--force', '--sign', identity]
        if identity != '-':
            command.extend(['--keychain', keychain])
        commands.append(command + ['--timestamp=none', str(path)])
    commands.append(['/usr/bin/codesign', '--verify', '--strict', str(app)])
    for command in commands:
        require(NOTARIZE_TOOLS.isdisjoint(Path(part).name for part in command), 'Notarization commands are refused')
        require('--deep' not in command, 'Delivery signing does not use codesign --deep')
    return commands


def dmg_plan(stage, dmg):
    command = ['/usr/bin/hdiutil', 'create', '-volname', 'GCSA-aegis', '-srcfolder', str(stage),
               '-ov', '-format', 'UDZO', str(dmg)]
    require(NOTARIZE_TOOLS.isdisjoint(Path(part).name for part in command), 'DMG creation cannot notarize')
    return command


def write_github_output(plan, output_path):
    if not output_path:
        print(json.dumps(plan, sort_keys=True))
        return
    fields = ('operation', 'version', 'signing_mode', 'dmg_name', 'arch', 'runner_label', 'runner')
    lines = [f'{key}={plan[key]}' for key in fields]
    lines.append('notarized=false')
    Path(output_path).write_text('\n'.join(lines) + '\n')


def _run(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise DeliveryError(Path(command[0]).name + ' failed')
    return result


def verify_app_identity(app, environment):
    out = app.parent
    manifest = out / '.aegis' / 'build-manifest.json'
    require(manifest.is_file() and not manifest.is_symlink() and
            not manifest.parent.is_symlink(), 'Finalized app build identity required')
    expected = environment.get('MACOS_EXPECTED_SOURCE_SHA') or environment.get('GITHUB_SHA', '')
    require(re.fullmatch(r'[0-9a-f]{40}', expected) is not None, 'Expected app source identity SHA required')
    # The verifier's own checkout is part of the build identity. An explicit
    # existing product checkout is needed when it differs from the wrapper.
    product_root = Path(environment.get('MACOS_PRODUCT_CHECKOUT') or
                        Path(__file__).resolve().parents[2]).resolve()
    verifier = product_root / 'apps/browser/scripts/write-build-identity.mjs'
    require(verifier.is_file() and not verifier.is_symlink(),
            'Product checkout build identity verifier required')
    # Formal app builds live under this exact src/out layout. Do not inherit
    # the packaging shell's unrelated Chromium root or guess another checkout.
    chromium_src = out.parent.parent
    require(out.name == 'AegisRelease' and out.parent.name == 'out' and
            (chromium_src / 'chrome/BUILD.gn').is_file() and
            (chromium_src / 'build').is_dir(),
            'App output must belong to its Chromium src/out/AegisRelease')
    try:
        product_head = subprocess.run(['git', '-C', str(product_root), 'rev-parse', 'HEAD'],
            capture_output=True, text=True, check=True).stdout.strip()
        product_status = subprocess.run(['git', '-C', str(product_root), 'status',
            '--porcelain', '--untracked-files=normal'],
            capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise DeliveryError('Product checkout HEAD validation failed') from error
    require(product_head == expected,
            'Product checkout must match expected SHA; set MACOS_PRODUCT_CHECKOUT for a separate product')
    require(not product_status, 'Product checkout must be clean before running its verifier')
    try:
        verify_env = dict(os.environ, CHROMIUM_SRC=str(chromium_src),
                          CHROMIUM_ROOT=str(chromium_src.parent))
        result = subprocess.run(['node', str(verifier), '--phase', 'verify',
            '--manifest', str(manifest), '--out-dir', str(out), '--artifact', str(app)],
            capture_output=True, text=True, check=True, env=verify_env)
        identity = json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        raise DeliveryError('App build identity verification failed') from error
    require(identity.get('verified') is True and identity.get('localCandidate') is True,
            'App build identity is not a verified local candidate')
    checks = identity.get('checks', {})
    require(all(checks.get(key) is True for key in
                ('patchLineageMatches', 'overlayMatches', 'gnArgsMatch')),
            'App patched lineage, overlay and GN identity must be verified')
    require(identity.get('source', {}).get('root', {}).get('sha') == expected,
            'App build identity does not match the requested product SHA')
    return identity


@contextmanager
def app_build_lock(app, environment):
    identity_dir = app.parent / '.aegis'
    require(identity_dir.is_dir() and not identity_dir.is_symlink(),
            'App build identity directory required')
    lock = identity_dir / 'build.lock'
    inherited = environment.get('AEGIS_MACOS_BUILD_LOCK_PID', '')
    if inherited:
        require(inherited.isdecimal() and int(inherited) > 1 and
                lock.is_dir() and not lock.is_symlink() and
                (lock / 'package-owner').is_file() and
                not (lock / 'package-owner').is_symlink() and
                (lock / 'package-owner').read_text().strip() == inherited,
                'Invalid inherited app build lock')
        try:
            os.kill(int(inherited), 0)
        except OSError as error:
            raise DeliveryError('Inherited app build lock owner is not alive') from error
        yield
        return
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise DeliveryError('Another build or package operation holds the app lock') from error
    try:
        yield
    finally:
        lock.rmdir()


def package(environment, runner=_run):
    plan = normalize(dict(environment, MACOS_OPERATION='package'))
    plan['keychain'] = environment.get('AEGIS_MACOS_SIGNING_KEYCHAIN', '')
    if plan['signing_mode'] == 'developer-id':
        require(plan['keychain'] and Path(plan['keychain']).is_absolute() and
                Path(plan['keychain']).is_file(),
                'Verified job-local signing keychain is required for Developer ID')
    app = admit_app(environment.get('MACOS_APP_PATH', ''), environment.get('AEGIS_MACOS_APP_ROOT', ''))
    with app_build_lock(app, environment):
        return package_locked(environment, runner, plan)


def package_locked(environment, runner, plan):
    app = admit_app(environment.get('MACOS_APP_PATH', ''), environment.get('AEGIS_MACOS_APP_ROOT', ''))
    plan['app'] = str(app)
    actual = environment.get('MACOS_ACTUAL_ARCH', '')
    if actual:
        require(machine_arch(actual) == plan['arch'], 'Runner architecture does not match the requested DMG architecture')
    identity = verify_app_identity(app, environment)
    output = Path(environment.get('MACOS_OUTPUT_DIR', ''))
    require(output.is_absolute() and not output.exists(), 'MACOS_OUTPUT_DIR must be a new absolute directory')
    output.mkdir(mode=0o700)
    stage = output / 'stage'
    stage.mkdir(mode=0o700)
    app_name = Path(plan['app']).name
    staged_app = stage / app_name
    shutil.copytree(plan['app'], staged_app, symlinks=True)
    # Recheck source after copying so a concurrent modification cannot silently
    # turn an admitted identity into a different package input.
    require(verify_app_identity(app, environment) == identity,
            'App build identity changed while staging')
    (stage / 'Applications').symlink_to('/Applications')
    (stage / 'README.txt').write_text(
        'GCSA-aegis macOS delivery\n'
        f'Version: {plan["version"]}\n'
        f'Signing: {plan["signing_mode"]}\n'
        'Notarization: not performed. Gatekeeper may refuse this disk image.\n')
    for command in sign_plan(staged_app, plan['identity'], plan['keychain']):
        runner(command)
    dmg = output / plan['dmg_name']
    runner(dmg_plan(stage, dmg))
    require(dmg.is_file() and not dmg.is_symlink(), 'DMG was not created')
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    receipt = {
        'schemaVersion': 1,
        'product': 'macos-dmg',
        'version': plan['version'],
        'sourceSha': identity['source']['root']['sha'],
        'packagingSourceSha': environment.get('GITHUB_SHA', ''),
        'appBuildIdentity': identity,
        'signingMode': plan['signing_mode'],
        'notarized': False,
        'notarization': 'skipped',
        'arch': plan['arch'],
        'dmg': {'name': plan['dmg_name'], 'sha256': digest},
    }
    require(re.fullmatch(r'[0-9a-f]{40}', receipt['sourceSha']) is not None, 'Full source SHA required')
    (output / 'macos-delivery-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main(argv):
    try:
        if argv == ['plan']:
            write_github_output(normalize(os.environ), os.environ.get('GITHUB_OUTPUT'))
            return 0
        if argv == ['package']:
            package(os.environ)
            return 0
        raise DeliveryError('Expected plan or package')
    except DeliveryError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
