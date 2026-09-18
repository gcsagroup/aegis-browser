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
  const normalized = normalizeTitle(value);
  if (!normalized) return null;
  const match = CONVENTIONAL_TITLE.exec(normalized);
  if (!isSupportedConventionalMatch(match)) return null;
  return {
    title: normalized,
    type: match.groups.type,
    subject: match.groups.subject,
  };
}

function normalizeTitle(value) {
  if (typeof value !== 'string') return null;
  const normalized = stripPrNumberSuffixes(value.trim().replace(MARKDOWN_BULLET, '').trim());
  return normalized && normalized.length <= MAX_TITLE_LENGTH ? normalized : null;
}

function isSupportedConventionalMatch(match) {
  return Boolean(match?.groups) && CONVENTIONAL_TYPES.has(match.groups.type);
}

function conventionalCandidates(commitMessages) {
  return (commitMessages ?? [])
    .flatMap((message) => String(message ?? '').split(/\r?\n/u))
    .map(parseConventionalTitle)
    .filter((candidate) => candidate && candidate.type !== 'release');
}

export function inferPrTitle(commitMessages) {
  const candidates = conventionalCandidates(commitMessages);
  const feature = candidates.findLast((candidate) => candidate.type === 'feat');
  return feature?.title ?? candidates.at(-1)?.title ?? null;
}

export function decidePrTitle({currentTitle, commitMessages}) {
  const current = parseConventionalTitle(currentTitle);
  return current?.type !== 'release' && current
    ? keepTitle(currentTitle, 'current-title-is-conventional')
    : inferTitleDecision(current, currentTitle, commitMessages);
}

function keepTitle(title, reason) {
  return {action: 'keep', title, reason};
}

function inferTitleDecision(current, currentTitle, commitMessages) {
  const inferred = inferPrTitle(commitMessages);
  if (!inferred) return keepTitle(currentTitle, 'no-unambiguous-candidate');
  if (inferred === currentTitle) return keepTitle(currentTitle, 'already-matches');
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
