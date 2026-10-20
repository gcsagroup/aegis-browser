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
            '"credential.helper","core.hooksPath"]; '
            'config={key:subprocess.run(["/usr/bin/git","config","--get",key],'
            'capture_output=True,text=True).stdout.rstrip("\\n") for key in keys}; '
            'urls={url:subprocess.check_output(["/usr/bin/git","config","--get-urlmatch",'
            '"http.proxy",url],text=True).rstrip("\\n") '
            'for url in ["https://github.com/owner/repo.git","https://api.github.com/repos/owner/repo",'
            '"https://chromium.googlesource.com/chromium/src.git"]}; '
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

    def test_ci_github_download_commands_preserve_proxy_for_other_hosts(self):
        for relative in ('scripts/ci/install-ripgrep.sh', 'scripts/ci/run-shell-coverage.sh'):
            with self.subTest(script=relative):
                lines = (ROOT / relative).read_text().splitlines()
                first = next(i for i, line in enumerate(lines) if re.match(r'\s*curl --fail', line))
                last = first
                while lines[last].endswith('\\'):
                    last += 1
                command = '\n'.join(lines[first:last + 1])
                fixture_bin = self.root / ('curl-' + Path(relative).stem)
                fixture_bin.mkdir()
                curl = fixture_bin / 'curl'
                curl.write_text('#!' + sys.executable + '\nimport json,os,sys\n'
                                'print(json.dumps({"args":sys.argv[1:],"https_proxy":'
                                'os.environ.get("https_proxy")}))\n')
                curl.chmod(0o700)
                environment = {**self.environment, 'PATH': str(fixture_bin) + ':' + os.environ['PATH'],
                               'https_proxy': PROXY, 'no_proxy': 'existing-lower.invalid',
                               'NO_PROXY': 'existing-upper.invalid', 'url': 'https://github.com/fixture/repo',
                               'archive': str(self.root / 'unused.tar.gz'),
                               'source_archive': str(self.root / 'unused-source.tar.gz'),
                               'KCOV_SOURCE_URL': 'https://codeload.github.com/fixture/repo'}
                result = subprocess.run(['/bin/bash', '-c', command], env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertIn('--noproxy', value['args'])
                exclusions = value['args'][value['args'].index('--noproxy') + 1]
                self.assert_github_bypass({'no_proxy': exclusions, 'NO_PROXY': exclusions})
                self.assertEqual(value['https_proxy'], PROXY)


if __name__ == '__main__':
    unittest.main()
