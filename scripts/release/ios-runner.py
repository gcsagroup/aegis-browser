#!/usr/bin/env python3
"""Disabled iOS signing-runner launcher: pre-execution isolation is required.

Queue snapshots and post-execution identity checks cannot authorize a signing
host. This entrypoint refuses before payload access, key probes or registration.
The remaining validation helpers are not proof of execution isolation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
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
        result = subprocess.run([str(executable), '--version'], cwd=root, env=probe_env, capture_output=True, timeout=90)
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
    path = 'repos/'+repository+('/'+endpoint if endpoint else '')
    result = subprocess.run(['gh', 'api', '-X', method, path], capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError('GitHub API failed; reconcile unknown mutation before retrying')
    return json.loads(result.stdout) if result.stdout.strip() else None


def authenticated_user():
    result = subprocess.run(['gh', 'api', 'user'], capture_output=True, text=True, check=False, timeout=30)
    if result.returncode:
        raise ValueError('Cannot verify authenticated GitHub CLI operator')
    return json.loads(result.stdout)


def authorize_operator(repository, *, api=gh, user_api=authenticated_user):
    if repository != 'gcsagroup/aegis-browser':
        raise ValueError('Signing runner requires canonical upstream')
    metadata = api(repository, '')
    if metadata.get('id') != 1348409663 or metadata.get('full_name') != repository or metadata.get('default_branch') != 'main':
        raise ValueError('Canonical repository identity changed')
    user = user_api()
    login, identity = user.get('login'), user.get('id')
    if not isinstance(login, str) or not login or not all(c.isascii() and (c.isalnum() or c == '-') for c in login) or type(identity) is not int or identity <= 0:
        raise ValueError('Invalid actual CLI operator identity')
    grant = api(repository, 'collaborators/'+login+'/permission')
    principal = grant.get('user', {})
    if grant.get('permission') != 'admin' or principal.get('id') != identity or principal.get('login', '').lower() != login.lower():
        raise ValueError('Actual GitHub CLI operator requires repository Admin permission')


def admit(repository, run_id, sha, job_id, label):
    run = gh(repository, f'actions/runs/{run_id}')
    if run['head_sha'] != sha or run['repository']['full_name'] != repository or run['path'] not in {'.github/workflows/ios-delivery.yml', '.github/workflows/ios-delivery-full.yml'}:
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
    authorize_operator(args.repository)
    raise ValueError('Signing runner launcher is disabled until fail-closed pre-execution isolation is implemented')


if __name__ == '__main__':
    main()
