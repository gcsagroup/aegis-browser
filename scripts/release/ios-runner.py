#!/usr/bin/env python3
"""Run one verified queued iOS signing job on an existing task-owned runner payload.

Supply a new private directory containing the verified official runner payload.
This helper never downloads code, exports a key, unlocks a keychain or changes ACLs.
An unknown registration requires manual readback before another registration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import tarfile


def validate_payload(root, archive=None, expected_digest=None):
    required = ['config.sh', 'run.sh', 'env.sh', 'run-helper.sh.template', 'safe_sleep.sh', 'bin/Runner.Listener', 'bin/Runner.Worker']
    for name in required:
        path = root/name
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise ValueError('Incomplete runner payload: '+name)
        if name != 'env.sh' and not os.access(path, os.X_OK):
            raise ValueError('Runner entrypoint is not executable: '+name)
    nodes = list((root/'externals').glob('node*/bin/node'))
    if not nodes or any(not p.is_file() or not os.access(p, os.X_OK) for p in nodes):
        raise ValueError('Incomplete runner Node runtimes')
    if archive is None or expected_digest is None:
        raise ValueError('Checksum-pinned official payload archive is required')
    def sha(stream):
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            value.update(chunk)
        return value.hexdigest()
    with archive.open('rb') as content:
        if sha(content) != expected_digest:
            raise ValueError('Runner archive checksum mismatch')
    with tarfile.open(archive) as source:
        for member in source:
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe official payload inventory')
            target = root/relative
            if member.isfile():
                if target.is_symlink() or not target.is_file() or target.stat().st_size != member.size:
                    raise ValueError('Runner payload inventory mismatch: '+member.name)
                with source.extractfile(member) as original, target.open('rb') as actual:
                    if sha(original) != sha(actual) or bool(member.mode & 0o111) != bool(target.stat().st_mode & 0o111):
                        raise ValueError('Runner payload content/mode mismatch: '+member.name)
            elif member.issym():
                if not target.is_symlink() or os.readlink(target) != member.linkname or not target.resolve().is_relative_to(root):
                    raise ValueError('Runner payload link mismatch')
            elif not member.isdir():
                raise ValueError('Unsupported runner payload inventory member')
    # Exercise managed and JavaScript runtimes without credentials or registration.
    probe_env = {k: v for k, v in os.environ.items() if k in {'HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR', 'LANG'}}
    for executable in [root/'bin/Runner.Listener', *nodes]:
        result = subprocess.run([str(executable), '--version'], cwd=root, env=probe_env, capture_output=True, timeout=30)
        if result.returncode:
            raise ValueError('Runner runtime startup probe failed')


def compatible_job(job, registered_labels):
    requested = {label.lower() for label in job.get('labels', [])}
    return requested <= {label.lower() for label in registered_labels}


def validate_job(job, job_id, label, *, run_id, sha, attempt):
    if not (job['id'] == job_id and (job['name'] == 'ios-package' or job['name'].endswith(' / ios-package')) and job['status'] == 'queued'
            and {v.lower() for v in job['labels']} == {label.lower()} and job.get('run_id') == run_id
            and job.get('head_sha') == sha and job.get('run_attempt') == attempt):
        raise ValueError('Expected exact run/source/attempt iOS signing job is not queued')


def validate_start(previous, internal_free, external_free):
    if previous is not None:
        raise ValueError('Prior registration intent exists; reconcile instead of retrying')
    if internal_free < 8*1024**3 or external_free < 15*1024**3:
        raise ValueError('Real disk reserve is insufficient')


def gh(repository, endpoint, method='GET'):
    result = subprocess.run(['gh', 'api', '-X', method, 'repos/'+repository+'/'+endpoint], capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError('GitHub API failed; reconcile unknown mutation before retrying')
    return json.loads(result.stdout) if result.stdout.strip() else None


def write_new(path, value):
    with path.open('x') as output:
        path.chmod(0o600)
        json.dump(value, output, indent=2)


def admit(repository, run_id, sha, job_id, label):
    run = gh(repository, f'actions/runs/{run_id}')
    if run['head_sha'] != sha or run['repository']['full_name'] != repository or run['path'] not in {'.github/workflows/ios-release.yml', '.github/workflows/ios-candidate.yml'}:
        raise ValueError('Wrong repository/source/workflow')
    attempt = run['run_attempt']
    jobs = gh(repository, f'actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100')
    matches = [j for j in jobs['jobs'] if j['id'] == job_id]
    if jobs['total_count'] > 100 or len(matches) != 1:
        raise ValueError('Job is not in the exact current run attempt')
    validate_job(matches[0], job_id, label, run_id=run_id, sha=sha, attempt=attempt)
    for status in ['queued', 'in_progress']:
        runs = gh(repository, f'actions/runs?status={status}&per_page=100')
        if runs['total_count'] > 100:
            raise ValueError('Cannot prove exclusive signing queue')
        for other in runs['workflow_runs']:
            jobs = gh(repository, f'actions/runs/{other["id"]}/jobs?per_page=100')
            if jobs['total_count'] > 100:
                raise ValueError('Cannot prove exclusive signing queue')
            for job in jobs['jobs']:
                if compatible_job(job, {label}) and job['status'] != 'completed' and job['id'] != job_id:
                    raise ValueError('Another job could claim this runner')
    final = gh(repository, f'actions/runs/{run_id}')
    if final['head_sha'] != sha or final['run_attempt'] != attempt:
        raise ValueError('Run source/attempt changed during admission')
    return attempt


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['repository', 'sha', 'label', 'name', 'keychain', 'certificate_sha1']:
        p.add_argument('--'+name.replace('_', '-'), required=True)
    for name in ['run_id', 'job_id']:
        p.add_argument('--'+name.replace('_', '-'), type=int, required=True)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--external-volume', type=Path, required=True)
    p.add_argument('--payload-archive', type=Path, required=True)
    p.add_argument('--payload-sha256', required=True)
    args = p.parse_args()
    root = args.root.resolve(strict=True)
    if args.root.is_symlink() or root.stat().st_mode & 0o077:
        raise ValueError('Runner directory must be task-owned and private')
    validate_payload(root, args.payload_archive, args.payload_sha256)
    intent_path = root/'registration-started.json'
    validate_start(json.loads(intent_path.read_text()) if intent_path.exists() else None,
                   shutil.disk_usage(Path.home()).free, shutil.disk_usage(args.external_volume).free)
    if any((root/name).exists() for name in ['.runner', '.credentials']):
        raise ValueError('Existing registration requires readback')
    attempt = admit(args.repository, args.run_id, args.sha, args.job_id, args.label)
    runners = gh(args.repository, 'actions/runners?per_page=100')
    if runners['total_count'] > 100 or any(r['name'] == args.name for r in runners['runners']):
        raise ValueError('Runner name already exists or inventory incomplete')
    probe = root/'signing-probe'
    shutil.copyfile('/usr/bin/true', probe)
    probe.chmod(0o700)
    signed = subprocess.run(['codesign', '--force', '--sign', args.certificate_sha1, '--keychain', args.keychain,
                             '--timestamp=none', str(probe)], capture_output=True, timeout=30)
    if signed.returncode:
        raise ValueError('Installed-key signing probe failed; no registration performed')
    intent = dict(repository=args.repository, runId=args.run_id, jobId=args.job_id, sourceSha=args.sha,
                  name=args.name, label=args.label, root=str(root), ephemeral=True, attempt=attempt, outcome='unknown')
    write_new(intent_path, intent)
    token = gh(args.repository, 'actions/runners/registration-token', 'POST')['token']
    # No local gh credentials, ASC secrets or registration token reach the job process.
    environment = {k: v for k, v in os.environ.items() if k in {'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG', 'PATH', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'}}
    empty = root/'.gh-empty'
    empty.mkdir(mode=0o700)
    environment.update(GH_CONFIG_DIR=str(empty), GH_PROMPT_DISABLED='1')
    with (root/'config.log').open('x') as log:
        (root/'config.log').chmod(0o600)
        result = subprocess.run(['./config.sh', '--unattended', '--url', 'https://github.com/'+args.repository,
                                 '--name', args.name, '--labels', args.label, '--no-default-labels', '--work', '_work', '--ephemeral', '--disableupdate'],
                                cwd=root, env=dict(environment, ACTIONS_RUNNER_INPUT_TOKEN=token), stdout=log, stderr=subprocess.STDOUT, timeout=180)
    token = None
    if result.returncode:
        raise ValueError('Registration result uncertain; inspect private state and remote inventory')
    settings = json.loads((root/'.runner').read_text(encoding='utf-8-sig'))
    if settings['agentName'] != args.name or settings.get('ephemeral') is not True:
        raise ValueError('Unexpected runner identity')
    runner_id = settings['agentId']
    for name in ['.runner', '.credentials', '.credentials_rsaparams', '.env', '.path']:
        if (root/name).exists():
            (root/name).chmod(0o600)
    registered = gh(args.repository, f'actions/runners/{runner_id}')
    if {r['name'].lower() for r in registered['labels']} != {args.label.lower()}:
        raise ValueError('Runner registration includes unexpected routing labels')
    write_new(root/'registration-result.json', dict(intent, runnerId=runner_id, outcome='registered', privateKeyExported=False))
    # Re-read queued job after registration, before the listener can claim anything.
    if admit(args.repository, args.run_id, args.sha, args.job_id, args.label) != attempt:
        raise ValueError('Run attempt changed before listener startup')
    with (root/'runner.log').open('x') as log:
        (root/'runner.log').chmod(0o600)
        process = subprocess.Popen(['./run.sh'], cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            if shutil.disk_usage(Path.home()).free < 8*1024**3 or shutil.disk_usage(args.external_volume).free < 15*1024**3:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise ValueError('Disk reserve breached; owned listener stopped; reconcile job outcome')
            time.sleep(5)
    inventory = gh(args.repository, 'actions/runners?per_page=100')
    if inventory['total_count'] > 100:
        raise ValueError('Runner inventory incomplete')
    remaining = [r for r in inventory['runners'] if r['id'] == runner_id]
    if remaining:
        if remaining[0]['name'] != args.name or remaining[0]['busy'] or remaining[0]['status'] != 'offline':
            raise ValueError('Runner outcome is not safely idle; reconcile before removal')
        gh(args.repository, f'actions/runners/{runner_id}', 'DELETE')
    job = gh(args.repository, f'actions/jobs/{args.job_id}')
    if job.get('runner_name') != args.name or job.get('run_id') != args.run_id or job.get('head_sha') != args.sha or job.get('run_attempt') != attempt:
        raise ValueError('Target job was not claimed by this runner')
    result = dict(intent, runnerId=runner_id, jobStatus=job['status'], jobConclusion=job['conclusion'], listenerExit=process.returncode, runnerDeregistered=True)
    write_new(root/'execution-result.json', result)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
