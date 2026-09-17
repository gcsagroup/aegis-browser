const CONVENTIONAL_TYPES = new Set([
  'build',
  'chore',
  'ci',
  'docs',
  'feat',
  'fix',
  'perf',
  'refactor',
  'release',
  'revert',
  'style',
  'test',
]);

const CONVENTIONAL_TITLE = /^(?<type>[a-z][a-z0-9-]*)(?:\((?<scope>[^()\r\n]+)\))?(?<breaking>!)?: (?<subject>\S.*)$/u;
const MARKDOWN_BULLET = /^(?:[-*+]\s+)+/u;
const PR_NUMBER_SUFFIX = /\s+\(#\d+\)$/u;
const MAX_TITLE_LENGTH = 256;

function stripPrNumberSuffixes(value) {
  let current = value;
  let previous;
  do {
    previous = current;
    current = current.replace(PR_NUMBER_SUFFIX, '').trimEnd();
  } while (current !== previous);
  return current;
}

export function parseConventionalTitle(value) {
  if (typeof value !== 'string') return null;
  const normalized = stripPrNumberSuffixes(value.trim().replace(MARKDOWN_BULLET, '').trim());
  if (!normalized || normalized.length > MAX_TITLE_LENGTH) return null;
  const match = CONVENTIONAL_TITLE.exec(normalized);
  if (!match?.groups || !CONVENTIONAL_TYPES.has(match.groups.type)) return null;
  return {
    title: normalized,
    type: match.groups.type,
    subject: match.groups.subject,
  };
}

export function inferPrTitle(commitMessages) {
  const candidates = [];
  for (const message of commitMessages ?? []) {
    for (const line of String(message ?? '').split(/\r?\n/u)) {
      const candidate = parseConventionalTitle(line);
      if (candidate && candidate.type !== 'release') candidates.push(candidate);
    }
  }
  const feature = candidates.findLast((candidate) => candidate.type === 'feat');
  return feature?.title ?? candidates.at(-1)?.title ?? null;
}

export function decidePrTitle({currentTitle, commitMessages}) {
  const current = parseConventionalTitle(currentTitle);
  if (current && current.type !== 'release') {
    return {action: 'keep', title: currentTitle, reason: 'current-title-is-conventional'};
  }
  const inferred = inferPrTitle(commitMessages);
  if (!inferred) return {action: 'keep', title: currentTitle, reason: 'no-unambiguous-candidate'};
  if (inferred === currentTitle) return {action: 'keep', title: currentTitle, reason: 'already-matches'};
  return {action: 'update', title: inferred, reason: current ? 'generic-release-title' : 'non-conventional-title'};
}

export async function run({github, context, core}) {
  const pullRequest = context.payload.pull_request;
  if (!pullRequest) throw new Error('pull_request payload is required');

  const {owner, repo} = context.repo;
  const commits = await github.paginate(github.rest.pulls.listCommits, {
    owner,
    repo,
    pull_number: pullRequest.number,
    per_page: 100,
  });
  const decision = decidePrTitle({
    currentTitle: pullRequest.title,
    commitMessages: commits.map((entry) => entry.commit?.message ?? ''),
  });

  if (decision.action === 'update') {
    await github.rest.pulls.update({
      owner,
      repo,
      pull_number: pullRequest.number,
      title: decision.title,
    });
    core.info(`Updated PR #${pullRequest.number} title to: ${decision.title}`);
  } else {
    core.info(`Kept PR #${pullRequest.number} title: ${decision.reason}`);
  }
  return decision;
}
