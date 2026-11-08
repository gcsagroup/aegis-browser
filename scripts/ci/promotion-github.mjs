import {spawnSync} from 'node:child_process';

export function command(name, args, {token, statuses = [0], cwd} = {}) {
  const env = token ? {...process.env, GH_TOKEN: token} : process.env;
  const result = spawnSync(name, args, {env, cwd, encoding: 'utf8'});
  if (result.error) throw result.error;
  if (!statuses.includes(result.status)) throw new Error(`${name} failed (${result.status}): ${result.stderr}`);
  return result.stdout.trim();
}

export const git = (...args) => command('git', args);

export function isAncestor(base, head) {
  const result = spawnSync('git', ['merge-base', '--is-ancestor', base, head], {encoding: 'utf8'});
  if (result.error) throw result.error;
  if (![0, 1].includes(result.status)) throw new Error('Cannot establish commit ancestry');
  return result.status === 0;
}

export async function githubApi(repo, path, {token, method = 'GET', body} = {}) {
  const response = await globalThis.fetch(`https://api.github.com/repos/${repo}${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : {'Content-Type': 'application/json'}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  // Do not echo request bodies or credential-bearing error responses.
  if (!response.ok) throw new Error(`GitHub ${method} ${repo}${path}: HTTP ${response.status}`);
  return response.status === 204 ? null : response.json();
}

export async function listPulls(repo, token, query = 'state=open', api = githubApi) {
  const pulls = [];
  for (let page = 1; page <= 20; page++) {
    const batch = await api(repo, `/pulls?${query}&per_page=100&page=${page}`, {token});
    if (!Array.isArray(batch)) throw new Error('Invalid pull request response');
    pulls.push(...batch);
    if (batch.length < 100) return pulls;
  }
  throw new Error('Pull request pagination limit reached; refusing an incomplete inventory');
}

export async function assertRemoteHeads(heads, api = githubApi) {
  for (const {repo, branch, sha, token} of heads) {
    const ref = await api(repo, `/git/ref/heads/${branch}`, {token});
    if (ref?.object?.sha !== sha) throw new Error(`Remote changed: ${repo}:${branch}`);
  }
}
