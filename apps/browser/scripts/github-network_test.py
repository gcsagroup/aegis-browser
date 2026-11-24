"""Local Git/GitHub proxy policy checks; no remote requests or releases."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.request


ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'apps/browser/scripts'
spec = importlib.util.spec_from_file_location('github_network_release', SCRIPTS / 'release-github.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
DOMAINS = {'github.com', '.github.com', 'githubusercontent.com', '.githubusercontent.com'}
PROXY = 'http://127.0.0.1:7890'


class GitHubNetworkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='aegis-github-network-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ)
        for key in list(self.environment):
            if key.lower().endswith('_proxy') or key.startswith('GIT_CONFIG_'):
                self.environment.pop(key)
        self.environment.update(HOME=str(self.root), GIT_CONFIG_NOSYSTEM='1',
                                GIT_CONFIG_GLOBAL=str(self.root / 'gitconfig'))
        (self.root / 'gitconfig').write_text(
            '[http]\n proxy = ' + PROXY + '\n[https]\n proxy = ' + PROXY + '\n'
            '[http "https://github.com/"]\n proxy = ' + PROXY + '\n'
            '[http "https://api.github.com/"]\n proxy = ' + PROXY + '\n'
            '[credential]\n helper = fixture-credential-helper\n')

    def configured_environment(self, *, system=False, repeat=False, **values):
        environment = {**self.environment, **values}
        # The fixture never reads the workstation's system proxy configuration.
        script = 'source "$1"\nscutil() { ' + (
            "printf 'HTTPSProxy : 127.0.0.1\\nHTTPSPort : 7890\\n'; }\n"
            if system else 'return 0; }\n')
        script += 'configure_git_for_chromium_fetch >/dev/null\n'
        if repeat:
            script += 'configure_git_for_chromium_fetch >/dev/null\n'
        script += '"$2" -c ' + "'" + (
            'import json, os, subprocess; '
            'keys=["protocol.version","http.version","http.proxy","https.proxy",'
            '"credential.helper","core.hooksPath","http.https://unrelated.invalid/project.proxy"]; '
            'config={key:subprocess.run(["/usr/bin/git","config","--get",key],'
            'capture_output=True,text=True).stdout.rstrip("\\n") for key in keys}; '
            'urls={url:subprocess.check_output(["/usr/bin/git","config","--get-urlmatch",'
            '"http.proxy",url],text=True).rstrip("\\n") '
            'for url in ["https://github.com/owner/repo.git","https://api.github.com/repos/owner/repo",'
            '"https://chromium.googlesource.com/chromium/src.git",os.environ.get("CHROMIUM_SRC_URL","https://chromium.googlesource.com/chromium/src.git")]}; '
            'print(json.dumps({"config":config,"urls":urls,"session":'
            '[[os.environ.get("GIT_CONFIG_KEY_"+str(i)),os.environ.get("GIT_CONFIG_VALUE_"+str(i))] '
            'for i in range(int(os.environ["GIT_CONFIG_COUNT"]))],"env":'
            '{key:os.environ.get(key) for key in ["http_proxy","https_proxy","HTTP_PROXY",'
            '"HTTPS_PROXY","ALL_PROXY","no_proxy","NO_PROXY","GIT_TERMINAL_PROMPT"]}}))'
        ) + "'\n"
        result = subprocess.run(['/bin/bash', '-c', script, 'proxy-fixture',
                                 str(SCRIPTS / 'common.sh'), sys.executable],
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_direct_git(self, result):
        self.assertEqual(result['config']['http.proxy'], '')
        self.assertEqual(result['config']['https.proxy'], '')
        self.assertEqual(set(result['urls'].values()), {''})
        self.assertEqual(result['config']['protocol.version'], '2')
        self.assertEqual(result['config']['http.version'], 'HTTP/1.1')
        self.assertEqual(result['config']['credential.helper'], 'fixture-credential-helper')
        self.assertEqual(result['env']['GIT_TERMINAL_PROMPT'], '0')

    def assert_github_bypass(self, environment):
        self.assertEqual(environment['no_proxy'], environment['NO_PROXY'])
        exclusions = set(environment['no_proxy'].split(','))
        self.assertTrue(DOMAINS <= exclusions)
        self.assertTrue({'existing-lower.invalid', 'existing-upper.invalid'} <= exclusions)
        self.assertNotIn('*', exclusions)
        proxies = {'https': PROXY, 'no': environment['no_proxy']}
        for host in ('github.com', 'api.github.com', 'codeload.github.com',
                     'objects.githubusercontent.com'):
            self.assertTrue(urllib.request.proxy_bypass_environment(host, proxies), host)
        self.assertFalse(urllib.request.proxy_bypass_environment('pypi.org', proxies))
        self.assertFalse(urllib.request.proxy_bypass_environment('chromium.googlesource.com', proxies))

    def test_explicit_proxy_is_retained_for_non_git_tools_only(self):
        result = self.configured_environment(http_proxy=PROXY, https_proxy=PROXY)
        self.assert_direct_git(result)
        self.assertEqual(result['env']['http_proxy'], PROXY)
        self.assertEqual(result['env']['https_proxy'], PROXY)

    def test_system_proxy_is_retained_for_non_git_tools_only(self):
        result = self.configured_environment(system=True)
        self.assert_direct_git(result)
        self.assertEqual(result['env']['http_proxy'], PROXY)
        self.assertEqual(result['env']['https_proxy'], PROXY)

    def test_git_masks_existing_config_without_configured_environment_proxy(self):
        result = self.configured_environment()
        self.assert_direct_git(result)
        self.assertIsNone(result['env']['http_proxy'])
        self.assertIsNone(result['env']['https_proxy'])

    def test_inherited_non_proxy_git_settings_are_preserved(self):
        result = self.configured_environment(GIT_CONFIG_COUNT='1',
                                             GIT_CONFIG_KEY_0='core.hooksPath',
                                             GIT_CONFIG_VALUE_0='/fixture/hooks')
        self.assertEqual(result['config']['core.hooksPath'], '/fixture/hooks')
        self.assert_direct_git(result)


    def test_file_scoped_chromium_proxy_is_overridden_at_the_fetch_url(self):
        config_file = self.root / 'gitconfig'
        original = config_file.read_text()
        scopes = [
            'https://chromium.googlesource.com/',
            'https://chromium.googlesource.com/chromium/',
            'https://chromium.googlesource.com/chromium/src.git',
            'https://chromium.googlesource.com:443/chromium/src.git',
        ]
        for scope in scopes:
            with self.subTest(scope=scope):
                contents = (original + '[http "' + scope + '"]\n proxy = ' + PROXY + '\n'
                            '[http "https://unrelated.invalid/project"]\n proxy = fixture-unrelated\n')
                config_file.write_text(contents)
                result = self.configured_environment(
                    GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='core.hooksPath',
                    GIT_CONFIG_VALUE_0='/fixture/hooks',
                    GIT_CONFIG_KEY_1='http.https://unrelated.invalid/.proxy',
                    GIT_CONFIG_VALUE_1=PROXY)
                self.assert_direct_git(result)
                self.assertEqual(result['config']['core.hooksPath'], '/fixture/hooks')
                self.assertEqual(result['config']['http.https://unrelated.invalid/project.proxy'],
                                 'fixture-unrelated')
                self.assertEqual(config_file.read_text(), contents)

    def test_configured_fetch_url_beats_longer_file_proxy_paths(self):
        target = 'https://chromium.googlesource.com/custom/deep/src.git'
        config_file = self.root / 'gitconfig'
        contents = (config_file.read_text()
                    + '[http "https://chromium.googlesource.com/custom/deep/"]\n proxy = ' + PROXY + '\n'
                    + '[http "' + target + '"]\n proxy = ' + PROXY + '\n')
        config_file.write_text(contents)
        result = self.configured_environment(CHROMIUM_SRC_URL=target)
        self.assertEqual(result['urls'][target], '')
        self.assert_direct_git(result)
        self.assertEqual(config_file.read_text(), contents)

    def test_eight_override_count_boundary_rejects_overflow_before_inherited_scan(self):
        for count, message in [('2147483640', 'Invalid GIT_CONFIG_COUNT'),
                               ('2147483639', 'Invalid inherited Git configuration')]:
            with self.subTest(count=count):
                script = ('source "$1"\ndetect_and_export_proxy() { :; }\n'
                          'configure_git_for_chromium_fetch\n')
                result = subprocess.run(['/bin/bash', '-c', script, 'count-boundary',
                                         str(SCRIPTS / 'common.sh')],
                                        env={**self.environment, 'GIT_CONFIG_COUNT': count},
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_inherited_url_scoped_proxy_cannot_override_direct_fetch(self):
        result = self.configured_environment(
            GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='http.https://chromium.googlesource.com/.proxy',
            GIT_CONFIG_VALUE_0=PROXY, GIT_CONFIG_KEY_1='core.hooksPath',
            GIT_CONFIG_VALUE_1='/fixture/hooks')
        self.assert_direct_git(result)
        self.assertEqual(result['session'][0], ['http.https://chromium.googlesource.com/.proxy', ''])
        self.assertEqual(result['config']['core.hooksPath'], '/fixture/hooks')

    def test_inherited_proxy_key_variants_preserve_unrelated_values(self):
        variants = ['hTtP.PrOxY', 'HTTPS.PROXY',
                    'HTTP.https://chromium.googlesource.com/.PrOxY',
                    'hTtPs.https://chromium.googlesource.com/.pRoXy',
                    'remote.origin.proxy', 'REMOTE.My.Mirror.PrOxY']
        for key in variants:
            with self.subTest(key=key):
                result = self.configured_environment(
                    GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0=key, GIT_CONFIG_VALUE_0=PROXY,
                    GIT_CONFIG_KEY_1='http.proxyAuthMethod', GIT_CONFIG_VALUE_1='basic')
                self.assert_direct_git(result)
                self.assertEqual(result['session'][:2], [[key, ''], ['http.proxyAuthMethod', 'basic']])

    def test_leading_zero_git_count_preserves_settings(self):
        result = self.configured_environment(GIT_CONFIG_COUNT='0001',
                                             GIT_CONFIG_KEY_0='core.hooksPath',
                                             GIT_CONFIG_VALUE_0='/fixture/hooks')
        self.assertEqual(result['config']['core.hooksPath'], '/fixture/hooks')
        self.assert_direct_git(result)

    def test_invalid_git_counts_and_missing_entries_fail_closed(self):
        cases = [{'GIT_CONFIG_COUNT': count} for count in
                 ['-1', 'invalid', '2147483647', '18446744073709551616']]
        cases.extend([{'GIT_CONFIG_COUNT': '1'},
                      {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.hooksPath'}])
        for values in cases:
            with self.subTest(values=values):
                script = ('source "$1"\ndetect_and_export_proxy() { :; }\n'
                          'configure_git_for_chromium_fetch\n')
                result = subprocess.run(['/bin/bash', '-c', script, 'count-fixture',
                                         str(SCRIPTS / 'common.sh')],
                                        env={**self.environment, **values},
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)

    def test_shell_github_exclusions_preserve_both_cases_and_are_idempotent(self):
        values = dict(http_proxy=PROXY, https_proxy=PROXY,
                      no_proxy='existing-lower.invalid', NO_PROXY='existing-upper.invalid')
        once = self.configured_environment(**values)
        twice = self.configured_environment(repeat=True, **values)
        self.assert_github_bypass(once['env'])
        self.assertEqual(once['env']['no_proxy'], twice['env']['no_proxy'])

    def test_release_cli_child_preserves_parent_and_non_github_proxies(self):
        environment = {'http_proxy': PROXY, 'https_proxy': PROXY,
                       'no_proxy': 'existing-lower.invalid', 'NO_PROXY': 'existing-upper.invalid'}
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(release.shutil, 'which', return_value=sys.executable), \
                mock.patch.object(release.subprocess, 'run',
                                  return_value=SimpleNamespace(returncode=0, stdout='[]')) as run:
            before = dict(os.environ)
            release.GitHub().releases()
            self.assertEqual(dict(os.environ), before)
            child = run.call_args.kwargs.get('env', before)
            self.assert_github_bypass(child)
            self.assertEqual(child['https_proxy'], PROXY)
            self.assertEqual(run.call_args.kwargs['timeout'], 600)
            self.assertFalse(run.call_args.kwargs['shell'])

    def test_promotion_git_and_gh_children_bypass_github_only(self):
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node is required for the promotion adapter fixture')
        fixture_bin = self.root / 'bin'
        fixture_bin.mkdir()
        for name in ('git', 'gh', 'other-tool'):
            executable = fixture_bin / name
            executable.write_text('#!' + str(Path(node).resolve()) + '\n'
                                  'console.log(JSON.stringify(Object.fromEntries('
                                  '["https_proxy","no_proxy","NO_PROXY","GH_TOKEN"]'
                                  '.map(k => [k,process.env[k]]))));\n')
            executable.chmod(0o700)
        environment = {**self.environment, 'PATH': str(fixture_bin) + ':' + os.environ['PATH'],
                       'https_proxy': PROXY, 'no_proxy': 'existing-lower.invalid',
                       'NO_PROXY': 'existing-upper.invalid'}
        module = (ROOT / 'scripts/ci/promotion-github.mjs').as_uri()
        script = ('import {command} from ' + json.dumps(module) + ';'
                  'const before=JSON.stringify(process.env);'
                  'const rows=["git","gh","other-tool"].map(name=>'
                  'JSON.parse(command(name,["fixture"],{token:"fixture-token"})));'
                  'console.log(JSON.stringify({rows,unchanged:before===JSON.stringify(process.env)}));')
        result = subprocess.run([node, '--input-type=module', '-e', script],
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertTrue(value['unchanged'])
        for child in value['rows'][:2]:
            self.assert_github_bypass(child)
            self.assertEqual(child['https_proxy'], PROXY)
            self.assertEqual(child['GH_TOKEN'], 'fixture-token')
        self.assertEqual(value['rows'][2]['no_proxy'], 'existing-lower.invalid')
        self.assertEqual(value['rows'][2]['NO_PROXY'], 'existing-upper.invalid')

    def test_ci_github_download_schedule_direct2_proxy2_direct1(self):
        helper = ROOT / 'scripts/ci/curl-direct-then-proxy.sh'
        log = self.root / 'curl-log.jsonl'
        output = self.root / 'download.bin'
        fixture_bin = self.root / 'curl-bin'
        fixture_bin.mkdir()
        curl = fixture_bin / 'curl'
        # Succeed only on the final direct attempt (5th).
        curl.write_text(
            '#!' + sys.executable + '\n'
            'import json, os, pathlib, sys\n'
            'log = pathlib.Path(os.environ["CURL_LOG"])\n'
            'with log.open("a", encoding="utf-8") as handle:\n'
            '    handle.write(json.dumps({"args": sys.argv[1:]}) + "\\n")\n'
            'count = sum(1 for _ in log.open(encoding="utf-8"))\n'
            'path = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])\n'
            'if count < 5:\n'
            '    path.write_bytes(b"")\n'
            '    raise SystemExit(7)\n'
            'path.write_bytes(b"ok")\n'
            'raise SystemExit(0)\n'
        )
        curl.chmod(0o700)
        environment = {
            **self.environment,
            'PATH': str(fixture_bin) + ':' + os.environ['PATH'],
            'CURL_LOG': str(log),
            'CURL_CI_BACKOFF_BASE_SECONDS': '0',
            'https_proxy': PROXY,
            'HTTPS_PROXY': PROXY,
            'no_proxy': 'existing-lower.invalid',
            'NO_PROXY': 'existing-upper.invalid',
        }
        script = (
            'source "$1"\n'
            'curl_ci_download "$2" "https://github.com/fixture/repo/archive.tar.gz"\n'
        )
        result = subprocess.run(  # nosec B603 - fixed /bin/bash, fixture-owned paths, no untrusted input.
            ['/bin/bash', '-c', script, 'download-fixture', str(helper), str(output)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b'ok')
        rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
        self.assertEqual(len(rows), 5)
        expected = [
            ('', '*'),
            ('', '*'),
            (PROXY, ''),
            (PROXY, ''),
            ('', '*'),
        ]
        for row, (proxy, noproxy) in zip(rows, expected):
            self.assertEqual(row['args'][row['args'].index('--proxy') + 1], proxy)
            self.assertEqual(row['args'][row['args'].index('--noproxy') + 1], noproxy)
        for relative in ('scripts/ci/install-ripgrep.sh', 'scripts/ci/run-shell-coverage.sh'):
            with self.subTest(script=relative):
                text = (ROOT / relative).read_text(encoding='utf-8')
                self.assertIn('curl_ci_download', text)
                self.assertNotIn(
                    'github.com,.github.com,githubusercontent.com,.githubusercontent.com',
                    text,
                )

    def run_download(self, succeed_at, proxy=None, extra=()):
        helper = ROOT / 'scripts/ci/curl-direct-then-proxy.sh'
        log = self.root / 'curl-log-matrix.jsonl'
        output = self.root / 'download-matrix.bin'
        fixture_bin = self.root / 'curl-bin-matrix'
        fixture_bin.mkdir()
        body = '''import json, os, pathlib, sys
log = pathlib.Path(os.environ['CURL_LOG'])
with log.open('a', encoding='utf-8') as handle:
    handle.write(json.dumps({'args': sys.argv[1:]}) + chr(10))
count = sum(1 for _ in log.open(encoding='utf-8'))
if count < int(os.environ['SUCCEED_AT']):
    raise SystemExit(7)
pathlib.Path(sys.argv[sys.argv.index('--output') + 1]).write_bytes(b'ok')
'''
        curl = fixture_bin / 'curl'
        curl.write_text('#!' + sys.executable + chr(10) + body, encoding='utf-8')
        curl.chmod(0o700)
        environment = {
            **self.environment,
            'PATH': str(fixture_bin) + ':' + os.environ['PATH'],
            'CURL_LOG': str(log),
            'SUCCEED_AT': str(succeed_at),
            'CURL_CI_BACKOFF_BASE_SECONDS': '0',
        }
        if proxy:
            environment['https_proxy'] = proxy
        script = (
            'set -euo pipefail\n'
            'source "$1"\n'
            'curl_ci_download "$2" "$3" "${@:4}"\n'
        )
        result = subprocess.run(  # nosec B603 - fixed /bin/bash, fixture-owned paths, no untrusted input.
            ['/bin/bash', '-c', script, 'download-matrix', str(helper), str(output),
             'https://github.com/fixture/repo/archive.tar.gz', *extra],
            env=environment, capture_output=True, text=True, timeout=10)
        rows = []
        if log.exists():
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
        return result, rows, output

    def test_ci_github_download_without_proxy_skips_proxy_attempts(self):
        result, rows, output = self.run_download(succeed_at=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b'ok')
        self.assertEqual(len(rows), 3)
        for row in rows:
            args = row['args']
            self.assertEqual(args[args.index('--proxy') + 1], '')
            self.assertEqual(args[args.index('--noproxy') + 1], '*')
        self.assertEqual(result.stderr.count('Skipping proxy attempt'), 2)

    def test_ci_github_download_forwards_extra_arguments_under_nounset(self):
        result, rows, _output = self.run_download(
            succeed_at=1, proxy=PROXY, extra=('--silent', '--show-error'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        args = rows[0]['args']
        self.assertIn('--silent', args)
        self.assertIn('--show-error', args)
        self.assertEqual(args[-1], 'https://github.com/fixture/repo/archive.tar.gz')

    def test_ci_github_download_without_extra_arguments_under_nounset(self):
        result, rows, output = self.run_download(succeed_at=1, proxy=PROXY)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(output.read_bytes(), b'ok')

    def test_ci_github_download_fails_after_all_five_attempts(self):
        result, rows, _output = self.run_download(succeed_at=99, proxy=PROXY)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(rows), 5)
        self.assertIn('Download failed after', result.stderr)

    def test_ci_github_download_worst_case_fits_install_step_timeout(self):
        workflow = (ROOT / '.github/workflows/quality.yml').read_text(encoding='utf-8')
        start = workflow.index('name: Install fixed ripgrep')
        after = workflow[start:start + 300]
        marker = 'timeout-minutes:'
        self.assertIn(marker, after)
        budget = int(after.split(marker)[1].split()[0]) * 60
        result, rows, _output = self.run_download(succeed_at=99, proxy=PROXY)
        self.assertEqual(result.returncode, 1)
        limits = [int(row['args'][row['args'].index('--max-time') + 1]) for row in rows]
        self.assertEqual(len(limits), 5)
        backoff = sum(1 << index for index in range(4))
        self.assertLessEqual(sum(limits) + backoff, budget)


if __name__ == '__main__':
    unittest.main()
