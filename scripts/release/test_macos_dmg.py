#!/usr/bin/env python3
import ast
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import importlib.util
spec = importlib.util.spec_from_file_location('macos_dmg', Path(__file__).with_name('macos-dmg.py'))
dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dmg)

SHA = 'a' * 40
ROOT = Path(__file__).resolve().parents[2]


def environment(**extra):
    base = {
        'GITHUB_REPOSITORY': 'quinn521/aegis-browser',
        'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'MACOS_OPERATION': 'access',
        'MACOS_VERSION': '6.1.0.266',
        'MACOS_SIGNING_MODE': 'ad-hoc',
        'AEGIS_IOS_RUNNER_LABEL': 'aegis-ios-upstream-migration',
        'MACOS_ARCH': 'arm64',
        'GITHUB_SHA': SHA,
    }
    base.update(extra)
    return base


class MacosDmgTests(unittest.TestCase):
    def package_fixture(self, root):
        src = root / 'chromium/src'
        (src / 'chrome').mkdir(parents=True)
        (src / 'chrome/BUILD.gn').touch()
        (src / 'build').mkdir()
        app = src / 'out/AegisRelease/GCSA-aegis.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents' / 'Info.plist').write_text('plist')
        identity = app.parent / '.aegis'
        identity.mkdir()
        (identity / 'build-manifest.json').write_text('{}')
        report = {'verified': True, 'localCandidate': True,
                  'checks': {'patchLineageMatches': True, 'overlayMatches': True, 'gnArgsMatch': True},
                  'source': {'root': {'sha': SHA}}}
        calls = []

        def runner(command):
            calls.append(command)
            if command[0].endswith('hdiutil'):
                Path(command[-1]).write_bytes(b'fixture-dmg')

        env = environment(MACOS_APP_PATH=str(app), AEGIS_MACOS_APP_ROOT=str(app.parent),
                          MACOS_OUTPUT_DIR=str(root / 'output'), GITHUB_SHA='b' * 40,
                          MACOS_EXPECTED_SOURCE_SHA=SHA)
        return app, env, report, calls, runner

    def fake_verifier(self, report):
        def run(command, **kwargs):
            value = ('' if 'status' in command else SHA + '\n') if command[0] == 'git' else json.dumps(report)
            return subprocess.CompletedProcess(command, 0, value, '')
        return patch.object(dmg.subprocess, 'run', side_effect=run)

    def test_receipt_uses_verified_app_source_and_separate_wrapper_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app, env, report, calls, runner = self.package_fixture(root)
            with self.fake_verifier(report) as verify:
                receipt = dmg.package(env, runner=runner)
            self.assertEqual(receipt['sourceSha'], SHA)
            self.assertEqual(receipt['packagingSourceSha'], 'b' * 40)
            self.assertEqual(receipt['appBuildIdentity'], report)
            self.assertGreaterEqual(verify.call_count, 2)
            self.assertIn(str(app), verify.call_args.args[0])
            self.assertTrue(calls)

    def test_existing_build_lock_rejects_package_before_output_or_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app, env, report, calls, runner = self.package_fixture(root)
            lock = app.parent / '.aegis' / 'build.lock'
            lock.mkdir()
            with self.fake_verifier(report) as verify:
                with self.assertRaisesRegex(dmg.DeliveryError, 'holds'):
                    dmg.package(env, runner=runner)
            self.assertFalse(Path(env['MACOS_OUTPUT_DIR']).exists())
            self.assertEqual(calls, [])
            self.assertTrue(lock.is_dir())

    def test_developer_id_signs_every_bundle_with_verified_job_keychain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app, env, report, calls, runner = self.package_fixture(root)
            helper = app / 'Contents/Frameworks/Helper.app'
            helper.mkdir(parents=True)
            keychain = root / 'developer-id.keychain-db'
            keychain.touch()
            env.update(MACOS_SIGNING_MODE='developer-id',
                       AEGIS_MACOS_DEVELOPER_ID='Developer ID Application: Example (ABCDE12345)',
                       AEGIS_MACOS_SIGNING_KEYCHAIN=str(keychain))
            with self.fake_verifier(report):
                dmg.package(env, runner=runner)
            signing = [call for call in calls if '--sign' in call]
            self.assertEqual(len(signing), 2)
            for call in signing:
                self.assertIn('--keychain', call)
                self.assertEqual(call[call.index('--keychain') + 1], str(keychain))

    def test_developer_id_without_verified_keychain_cannot_sign(self):
        with tempfile.TemporaryDirectory() as directory:
            app, env, report, calls, runner = self.package_fixture(Path(directory).resolve())
            env.update(MACOS_SIGNING_MODE='developer-id',
                       AEGIS_MACOS_DEVELOPER_ID='Developer ID Application: Example (ABCDE12345)')
            with self.fake_verifier(report), self.assertRaisesRegex(dmg.DeliveryError, 'keychain'):
                dmg.package(env, runner=runner)
            self.assertEqual(calls, [])

    def test_workflow_passes_setup_verified_keychain_to_package(self):
        workflow = (ROOT / '.github/workflows/macos-delivery.yml').read_text()
        self.assertIn('AEGIS_MACOS_SIGNING_KEYCHAIN: ${{ steps.identity.outputs.keychain }}',
                      workflow)

    def test_access_plan_reuses_existing_self_hosted_label_and_skips_dmg(self):
        plan = dmg.normalize(environment())
        self.assertEqual(plan['operation'], 'access')
        self.assertEqual(plan['dmg_name'], '')
        self.assertEqual(json.loads(plan['runner']),
                         ['self-hosted', 'macOS', 'ARM64', 'aegis-ios-upstream-migration'])
        self.assertNotIn('macos-26', plan['runner'])

    def test_dedicated_mac_label_wins_without_falling_back_to_github_hosted(self):
        plan = dmg.normalize(environment(AEGIS_MACOS_RUNNER_LABEL='aegis-mac-arm64'))
        self.assertEqual(plan['runner_label'], 'aegis-mac-arm64')

    def test_refuses_notarization_and_missing_runner(self):
        with self.assertRaises(dmg.DeliveryError):
            dmg.normalize(environment(MACOS_NOTARIZE='true'))
        with self.assertRaises(dmg.DeliveryError):
            dmg.normalize(environment(AEGIS_IOS_RUNNER_LABEL='', AEGIS_MACOS_RUNNER_LABEL=''))

    def test_package_signs_inside_out_without_deep_or_notary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'apps'
            app = root / 'GCSA-aegis.app'
            helper = app / 'Contents' / 'Frameworks' / 'Helper.app'
            helper.mkdir(parents=True)
            (app / 'Contents' / 'Info.plist').write_text('plist')
            (helper / 'Info.plist').write_text('helper')
            commands = dmg.sign_plan(app, '-')
            self.assertTrue(all('--keychain' not in command for command in commands))
            signed = [Path(command[-1]) for command in commands if command[1] == '--force']
            self.assertEqual(signed, [helper, app])
            self.assertTrue(all('--deep' not in command and 'notarytool' not in command for command in commands))
            output = Path(temporary).resolve() / 'out'
            (root / '.aegis').mkdir()
            calls = []

            def runner(command):
                calls.append(command)
                if command[0].endswith('hdiutil'):
                    Path(command[-1]).write_bytes(b'dmg-bytes')

            with patch.object(dmg, 'verify_app_identity', return_value={
                    'source': {'root': {'sha': SHA}}}):
                receipt = dmg.package(environment(
                MACOS_OPERATION='package',
                MACOS_APP_PATH=str(app),
                AEGIS_MACOS_APP_ROOT=str(root),
                MACOS_OUTPUT_DIR=str(output),
                MACOS_ACTUAL_ARCH='arm64',
                GITHUB_SHA='b' * 40,
                MACOS_EXPECTED_SOURCE_SHA=SHA,
            ), runner=runner)
            self.assertEqual(receipt['sourceSha'], SHA)
            self.assertEqual(receipt['packagingSourceSha'], 'b' * 40)
            self.assertFalse(receipt['notarized'])
            self.assertEqual(receipt['notarization'], 'skipped')
            self.assertEqual(receipt['dmg']['sha256'], hashlib.sha256(b'dmg-bytes').hexdigest())
            self.assertTrue(any(command[0].endswith('codesign') for command in calls))


    def test_package_plan_accepts_a_remote_app_path_and_fork_ad_hoc_mode(self):
        plan = dmg.normalize(environment(
            MACOS_OPERATION='package',
            MACOS_SIGNING_MODE='',
            AEGIS_MACOS_REHEARSAL_SIGNING_MODE='temporary-ad-hoc',
            MACOS_APP_PATH='/opt/aegis-apps/GCSA-aegis.app',
            AEGIS_MACOS_APP_ROOT='/opt/aegis-apps',
        ))
        self.assertEqual(plan['signing_mode'], 'ad-hoc')
        self.assertEqual(plan['dmg_name'], 'GCSA-aegis-6.1.0.266-mac-arm64.dmg')
        self.assertFalse(Path('/opt/aegis-apps/GCSA-aegis.app').exists())

    def test_package_rejects_architecture_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'apps'
            app = root / 'GCSA-aegis.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents' / 'Info.plist').write_text('plist')
            (root / '.aegis').mkdir()
            with self.assertRaisesRegex(dmg.DeliveryError, 'architecture'):
                dmg.package(environment(
                    MACOS_OPERATION='package',
                    MACOS_APP_PATH=str(app),
                    AEGIS_MACOS_APP_ROOT=str(root),
                    MACOS_OUTPUT_DIR=str(Path(temporary) / 'out'),
                    MACOS_ACTUAL_ARCH='x86_64',
                ), runner=lambda command: None)

    def test_unidentified_app_is_rejected_before_output_or_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'apps'
            app = root / 'GCSA-aegis.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents' / 'Info.plist').write_text('plist')
            output = Path(temporary).resolve() / 'out'
            (root / '.aegis').mkdir()
            calls = []
            def runner(command):
                calls.append(command)
                if command[0].endswith('hdiutil'):
                    Path(command[-1]).write_bytes(b'dmg')
            with self.assertRaisesRegex(dmg.DeliveryError, 'identity'):
                dmg.package(environment(MACOS_APP_PATH=str(app),
                    AEGIS_MACOS_APP_ROOT=str(root), MACOS_OUTPUT_DIR=str(output)), runner=runner)
            self.assertFalse(output.exists())
            self.assertEqual(calls, [])

    def test_identity_rejects_wrong_product_even_when_verifier_succeeds(self):
        with tempfile.TemporaryDirectory() as directory:
            app, env, report, _, _ = self.package_fixture(Path(directory).resolve())
            report['source']['root']['sha'] = 'b' * 40
            with self.fake_verifier(report):
                with self.assertRaisesRegex(dmg.DeliveryError, 'requested product SHA'):
                    dmg.verify_app_identity(app, env)

    def test_identity_requires_verified_patch_lineage_overlay_and_gn(self):
        with tempfile.TemporaryDirectory() as directory:
            app, env, report, _, _ = self.package_fixture(Path(directory).resolve())
            for field in ('patchLineageMatches', 'overlayMatches', 'gnArgsMatch'):
                altered = dict(report, checks=dict(report['checks'], **{field: False}))
                with self.subTest(field=field), self.fake_verifier(altered):
                    with self.assertRaisesRegex(dmg.DeliveryError, 'lineage, overlay and GN'):
                        dmg.verify_app_identity(app, env)

    def test_dirty_or_wrong_product_checkout_cannot_run_verifier(self):
        with tempfile.TemporaryDirectory() as directory:
            app, env, report, _, _ = self.package_fixture(Path(directory).resolve())
            for head, status, expected in ((SHA, ' M verifier', 'must be clean'),
                                           ('b' * 40, '', 'must match expected SHA')):
                with self.subTest(reason=expected), patch.object(dmg.subprocess, 'run') as run:
                    run.side_effect = [subprocess.CompletedProcess([], 0, head, ''),
                                       subprocess.CompletedProcess([], 0, status, '')]
                    with self.assertRaisesRegex(dmg.DeliveryError, expected):
                        dmg.verify_app_identity(app, env)
                    self.assertEqual(run.call_count, 2)

    def test_package_lock_excludes_competing_operation_and_releases_on_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / 'GCSA-aegis.app'
            (root / '.aegis').mkdir()
            with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
                with dmg.app_build_lock(app, {}):
                    self.assertTrue((root / '.aegis/build.lock').is_dir())
                    with self.assertRaisesRegex(dmg.DeliveryError, 'holds'):
                        with dmg.app_build_lock(app, {}):
                            self.fail('competing operation acquired lock')
                    raise RuntimeError('fixture failure')
            self.assertFalse((root / '.aegis/build.lock').exists())

    def test_inherited_lock_requires_live_matching_owner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / 'GCSA-aegis.app'
            lock = root / '.aegis/build.lock'
            lock.mkdir(parents=True)
            (lock / 'package-owner').write_text(str(os.getpid()))
            with dmg.app_build_lock(app, {'AEGIS_MACOS_BUILD_LOCK_PID': str(os.getpid())}):
                self.assertTrue(lock.exists())
            self.assertTrue(lock.exists())
            with self.assertRaisesRegex(dmg.DeliveryError, 'Invalid inherited'):
                with dmg.app_build_lock(app, {'AEGIS_MACOS_BUILD_LOCK_PID': '2'}):
                    self.fail('wrong owner acquired lock')






class VerificationContextTests(unittest.TestCase):
    def check_context(self, separate_product):
        # Execute a real Node verifier boundary from a real, separate Git
        # checkout. The fixture models source-root sensitivity without building
        # or signing an app, and does not claim full build-identity acceptance.
        with tempfile.TemporaryDirectory(prefix='aegis-verify-context-') as directory:
            root = Path(directory).resolve()
            product = root / 'product'
            verifier = product / 'apps/browser/scripts/write-build-identity.mjs'
            verifier.parent.mkdir(parents=True)
            verifier.write_text("""import {execFileSync} from 'node:child_process';
import {dirname, resolve} from 'node:path';
import {realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const out = process.argv[process.argv.indexOf('--out-dir') + 1];
if (!process.env.CHROMIUM_SRC || realpathSync(process.env.CHROMIUM_SRC) !== realpathSync(resolve(out, '../..'))) process.exit(42);
const sha = execFileSync('git', ['rev-parse', 'HEAD'], {cwd: root, encoding: 'utf8'}).trim();
console.log(JSON.stringify({verified:true, localCandidate:true, source:{root:{sha}}, checks:{patchLineageMatches:true, overlayMatches:true, gnArgsMatch:true}}));
""")
            subprocess.run(['git', 'init', '-q', str(product)], check=True)
            subprocess.run(['git', '-C', str(product), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(product), '-c', 'user.name=Fixture', '-c',
                            'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            head = subprocess.check_output(['git', '-C', str(product), 'rev-parse', 'HEAD'], text=True).strip()
            src = root / 'chromium/src'
            (src / 'chrome').mkdir(parents=True)
            (src / 'chrome/BUILD.gn').touch()
            (src / 'build').mkdir()
            app = src / 'out/AegisRelease/GCSA Aegis.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').touch()
            (app.parent / '.aegis').mkdir()
            (app.parent / '.aegis/build-manifest.json').write_text('{}')
            env = environment(MACOS_EXPECTED_SOURCE_SHA=head)
            if separate_product:
                env['MACOS_PRODUCT_CHECKOUT'] = str(product)
                with patch.dict(os.environ, {'CHROMIUM_SRC': str(src)}):
                    report = dmg.verify_app_identity(app, env)
            else:
                unrelated = root / 'unrelated/src'
                unrelated.mkdir(parents=True)
                with patch.object(dmg, '__file__', str(product / 'scripts/release/macos-dmg.py')), \
                        patch.dict(os.environ, {'CHROMIUM_SRC': str(unrelated)}):
                    report = dmg.verify_app_identity(app, env)
            self.assertEqual(report['source']['root']['sha'], head)

    def test_verifier_belongs_to_selected_product_checkout(self):
        self.check_context(True)

    def test_verifier_uses_discovered_apps_chromium_not_ambient_root(self):
        self.check_context(False)

    def test_manual_x64_wrappers_reject_before_looking_for_a_checkout(self):
        for name in ('macos-rebuild-dmg.sh', 'macos-internal-dmg.sh'):
            with self.subTest(script=name):
                result = subprocess.run(['bash', str(ROOT / 'scripts/release' / name), '0.8.0', 'x64'],
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        env=dict(os.environ, CHROMIUM_ROOT='/nonexistent/fixture'), timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn('arm64 only', result.stdout)

    def test_x64_request_is_rejected_during_admission(self):
        with self.assertRaisesRegex(dmg.DeliveryError, 'arm64'):
            dmg.normalize(environment(MACOS_ARCH='x64'))


class BuildLifecycleLockTests(unittest.TestCase):
    def exercise_rebuild(self, package_status):
        with tempfile.TemporaryDirectory(prefix='aegis-dmg-lock-') as directory:
            root = Path(directory).resolve()
            browser = root / 'apps/browser'
            release = root / 'scripts/release'
            depot = root / 'depot_tools'
            src = root / 'chromium/src'
            for path in (browser / 'scripts', browser / 'args', release, depot,
                         src / 'chrome', src / 'build'):
                path.mkdir(parents=True, exist_ok=True)
            for relative in ('apps/browser/scripts/build-release.sh',
                             'scripts/release/macos-rebuild-dmg.sh'):
                shutil.copyfile(ROOT / relative, root / relative)
            (src / 'chrome/BUILD.gn').touch()
            (browser / 'args/aegis-release.gn').write_text('is_component_build=false\n')
            (browser / 'scripts/common.sh').write_text('''ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ensure_depot_tools_on_path() { :; }
detect_and_export_proxy() { :; }
desktop_app_path() { printf '%s/GCSA Aegis.app\\n' "$1"; }
''')
            check = '''#!/bin/bash
set -euo pipefail
lock="$FAKE_OUT/.aegis/build.lock"
[[ -d "$lock" ]] || exit 91
if mkdir "$lock" 2>/dev/null; then exit 92; fi
printf '%s\\n' "$1" >> "$FAKE_PHASE_LOG"
'''
            scripts = {
                depot / 'check-lock': check,
                depot / 'gn': '#!/bin/bash\n"$FAKE_DEPOT/check-lock" gn\n',
                depot / 'autoninja': '''#!/bin/bash
set -euo pipefail
"$FAKE_DEPOT/check-lock" compile
mkdir -p "$FAKE_OUT/GCSA Aegis.app/Contents"
touch "$FAKE_OUT/GCSA Aegis.app/Contents/Info.plist"
''',
                depot / 'node': '''#!/bin/bash
set -euo pipefail
for ((i=1; i<=$#; ++i)); do
  if [[ "${!i}" == --phase ]]; then
    ((++i)); "$FAKE_DEPOT/check-lock" "${!i}"; break
  fi
done
''',
                depot / 'df': "#!/bin/bash\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 99999999 0 99999999 0%% /\\n'\n",
                browser / 'scripts/sign-chromium-app.sh': '#!/bin/bash\n"$FAKE_DEPOT/check-lock" sign\n',
                release / 'macos-internal-dmg.sh': '''#!/bin/bash
set -euo pipefail
"$FAKE_DEPOT/check-lock" package
[[ "$(cat "$FAKE_OUT/.aegis/build.lock/package-owner")" == "$AEGIS_MACOS_BUILD_LOCK_PID" ]]
kill -0 "$AEGIS_MACOS_BUILD_LOCK_PID"
exit "$FAKE_PACKAGE_STATUS"
''',
            }
            for path, content in scripts.items():
                path.write_text(content)
                path.chmod(0o700)
            out = src / 'out/AegisRelease'
            log = root / 'phases'
            env = dict(os.environ, CHROMIUM_ROOT=str(src.parent), DEPOT_TOOLS_DIR=str(depot),
                       PATH=str(depot) + os.pathsep + os.environ['PATH'], FAKE_OUT=str(out),
                       FAKE_DEPOT=str(depot), FAKE_PHASE_LOG=str(log),
                       FAKE_PACKAGE_STATUS=str(package_status))
            for key in ('OUT_DIR', 'AEGIS_ALLOW_DIRTY_IDENTITY', 'MACOS_OUTPUT_DIR'):
                env.pop(key, None)
            result = subprocess.run(['bash', str(release / 'macos-rebuild-dmg.sh'), '0.8.0', 'arm64'],
                                    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=20)
            self.assertEqual(result.returncode, package_status, result.stdout)
            phases = ['gn', 'begin', 'compile']
            if platform.system() == 'Darwin':
                phases.append('sign')
            self.assertEqual(log.read_text().splitlines(), phases + ['finalize', 'package'])
            self.assertFalse((out / '.aegis/build.lock').exists())

    def test_rebuild_keeps_one_exclusive_lock_from_gn_through_package(self):
        self.exercise_rebuild(0)

    def test_failed_package_releases_the_original_build_lock(self):
        self.exercise_rebuild(23)


class WorkflowContractTests(unittest.TestCase):
    def test_delivery_workflow_keeps_self_hosted_runner_and_access_tests(self):
        text = (ROOT / '.github/workflows/macos-delivery.yml').read_text()
        self.assertNotIn('macos-26', text)
        self.assertNotIn('notarytool', text)
        self.assertIn('macos-access-tests.sh', text)
        self.assertIn('AEGIS_IOS_RUNNER_LABEL', text)
        self.assertNotIn('secrets: inherit', text)
        self.assertIn('Internal DMG', text)
        self.assertIn('macos-internal-dmg.sh', text)
        self.assertIn('macos-rebuild-dmg.sh', text)
        self.assertIn('Rebuild DMG', text)

    def test_internal_dmg_requires_access_success_except_explicit_rebuild_skip(self):
        workflow = (ROOT / '.github/workflows/macos-delivery.yml').read_text()
        job = workflow.split('\n  internal-dmg:\n', 1)[1]
        condition = re.search(r'^    if: \$\{\{ (.+) \}\}$', job, re.M)[1]

        def evaluate(node):
            if isinstance(node, ast.Constant):
                return node.value
            if isinstance(node, ast.BoolOp):
                values = [evaluate(value) for value in node.values]
                return all(values) if isinstance(node.op, ast.And) else any(values)
            if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq):
                return evaluate(node.left) == evaluate(node.comparators[0])
            self.fail(f'Unsupported workflow condition: {ast.dump(node)}')

        for operation in ('Internal DMG', 'Rebuild DMG', 'Access tests'):
            for access in ('success', 'failure', 'cancelled', 'skipped'):
                for admission in ('success', 'failure'):
                    for event in ('workflow_dispatch', 'push'):
                        with self.subTest(operation=operation, access=access, admission=admission, event=event):
                            expression = condition.replace('always()', 'True')
                            for key, value in {
                                'inputs.operation': operation, 'needs.access-tests.result': access,
                                'needs.admission.result': admission, 'github.event_name': event,
                            }.items():
                                expression = expression.replace(key, repr(value))
                            expression = expression.replace('&&', ' and ').replace('||', ' or ')
                            permitted = (event == 'workflow_dispatch' and admission == 'success' and
                                (operation == 'Internal DMG' and access == 'success' or
                                 operation == 'Rebuild DMG' and access in ('success', 'skipped')))
                            self.assertEqual(evaluate(ast.parse(expression, mode='eval').body), permitted)


if __name__ == '__main__':
    unittest.main()
