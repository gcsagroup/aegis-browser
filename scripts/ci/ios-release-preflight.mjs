import {pathToFileURL} from 'node:url';
import {githubApi} from './promotion-github.mjs';
import {requireGreenQuality} from './promotion-quality.mjs';

export const IOS_REPOSITORY = 'gcsagroup/aegis-browser';
export const IOS_REPOSITORY_ID = '1348409663';
export async function iosReleasePreflight(sha, {environment = process.env, api = githubApi, quality = requireGreenQuality} = {}) {
  if (!/^[0-9a-f]{40}$/u.test(sha ?? '')) throw new Error('Full source SHA required');
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  if (!token || environment.AEGIS_IOS_RELEASE_ENABLED !== 'true') throw new Error('iOS release must be explicitly enabled with an admission token');
  const repository = environment.GITHUB_REPOSITORY || IOS_REPOSITORY;
  const candidate = environment.GITHUB_EVENT_NAME === 'push' && environment.GITHUB_REF === `refs/tags/${environment.RELEASE_TAG}` && environment.RELEASE_DESTINATION === 'github-draft';
  if (environment.GITHUB_ACTIONS === 'true' && (environment.GITHUB_SHA !== sha || (!candidate && environment.GITHUB_EVENT_NAME !== 'workflow_dispatch' &&
      !(repository !== IOS_REPOSITORY && environment.GITHUB_EVENT_NAME === 'push' && environment.GITHUB_REF === environment.AEGIS_IOS_FORK_REF)))) {
    throw new Error('iOS release requires exact-source dispatch or candidate tag');
  }
  const repo = await api(repository, '', {token});
  const assertTag = async () => {
    if (environment.RELEASE_DESTINATION !== 'github-draft') return;
    const tag = environment.RELEASE_TAG;
    const match = /^candidate\/ios\/[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?-(?:alpha|beta|release)\.[1-9][0-9]{0,9}$/u.exec(tag ?? '');
    if (!match || match[0] !== tag) throw new Error('Exact iOS candidate tag required');
    const tagged = await api(repository, `/commits/${encodeURIComponent(tag)}`, {token});
    if (tagged?.sha !== sha) throw new Error('Candidate tag changed or points to another source');
  };
  if (repository !== IOS_REPOSITORY) {
    if (environment.AEGIS_IOS_FORK_REHEARSAL !== 'true' || !repo?.fork || repo?.parent?.full_name !== IOS_REPOSITORY ||
        String(repo.id) !== environment.AEGIS_IOS_FORK_REPOSITORY_ID || String(repo.id) !== environment.GITHUB_REPOSITORY_ID ||
        !['artifacts', 'github-draft', 'testflight', 'testflight-internal'].includes(environment.RELEASE_DESTINATION) ||
        (!candidate && (environment.GITHUB_REF !== environment.AEGIS_IOS_FORK_REF || !/^refs\/heads\/codex\/ios-release-/u.test(environment.GITHUB_REF ?? '')))) {
      throw new Error('Fork rehearsal requires explicit identity, upstream parent and exact configured iOS ref');
    }
    const runs = await api(repository, `/actions/workflows/ios-release-validation.yml/runs?event=push&head_sha=${sha}&per_page=100`, {token});
    const selected = (runs?.workflow_runs ?? []).filter(r => r.head_sha === sha && r.head_branch === environment.AEGIS_IOS_FORK_REF?.replace('refs/heads/', '') && r.event === 'push')
      .sort((a, b) => Number(b.id) - Number(a.id))[0];
    if (!selected) throw new Error('Exact-source iOS validation missing');
    const run = await api(repository, `/actions/runs/${selected.id}`, {token});
    const valid = r => r?.id === selected.id && r?.head_sha === sha && r?.repository?.full_name === repository &&
      r?.path === '.github/workflows/ios-release-validation.yml' && r?.status === 'completed' && r?.conclusion === 'success' &&
      r?.event === 'push' && r?.head_branch === selected.head_branch && Number.isInteger(r?.run_attempt) && r.run_attempt >= 1;
    if (!valid(run)) throw new Error('Latest iOS validation attempt is not terminal successful');
    const jobs = await api(repository, `/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`, {token});
    if (jobs.total_count > 100) throw new Error('Incomplete validation job inventory');
    for (const name of ['contracts', 'ios-archive']) {
      const rows = (jobs?.jobs ?? []).filter(j => j.name === name);
      if (rows.length !== 1 || rows[0].head_sha !== sha || rows[0].run_id !== run.id || rows[0].run_attempt !== run.run_attempt ||
          rows[0].status !== 'completed' || rows[0].conclusion !== 'success') throw new Error(`iOS validation has not passed: ${name}`);
    }
    const finalRun = await api(repository, `/actions/runs/${run.id}`, {token});
    if (!valid(finalRun) || finalRun.run_attempt !== run.run_attempt) throw new Error('iOS validation attempt changed');
    await assertTag();
    return {repository, sha, admission: 'fork_rehearsal_only', releaseReady: false};
  }
  if (String(repo?.id) !== IOS_REPOSITORY_ID || repo?.default_branch !== 'main' ||
      (environment.GITHUB_ACTIONS === 'true' && (environment.GITHUB_REPOSITORY_ID !== IOS_REPOSITORY_ID || (!candidate && environment.GITHUB_REF !== 'refs/heads/main')))) {
    throw new Error('Upstream identity/default main/dispatch changed');
  }
  const assertMain = async () => {
    const main = await api(repository, '/git/ref/heads/main', {token});
    if (main?.object?.sha !== sha) throw new Error('Source must equal current upstream main');
  };
  await assertMain();
  await assertTag();
  if (!await quality(repository, 'main', sha, token, api)) throw new Error('Latest exact-source upstream quality has not passed');
  await assertMain();
  await assertTag();
  return {repository, sha, admission: 'upstream_quality_verified', releaseReady: false};
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 4 || process.argv[2] !== '--sha') throw new Error('Usage: ios-release-preflight.mjs --sha SHA');
    console.log(JSON.stringify(await iosReleasePreflight(process.argv[3])));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
