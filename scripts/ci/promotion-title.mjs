const CONVENTIONAL_TYPES = new Set([
  'build', 'chore', 'ci', 'docs', 'feat', 'fix', 'perf', 'refactor', 'release', 'revert', 'style', 'test',
]);
const CONVENTIONAL_TITLE = /^(?<type>[a-z][a-z0-9-]*)(?:\((?<scope>[^()\r\n]+)\))?(?<breaking>!)?: (?<subject>\S.*)$/u;
const PR_NUMBER_SUFFIX = /\s+\(#\d+\)$/u;

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
  const normalized = stripPrNumberSuffixes(value.trim());
  const match = CONVENTIONAL_TITLE.exec(normalized);
  if (!match?.groups || !CONVENTIONAL_TYPES.has(match.groups.type)) return null;
  return {title: normalized, type: match.groups.type};
}

export function inferPromotionTitle(subjects) {
  const candidates = (subjects ?? []).map(parseConventionalTitle).filter((entry) => entry && entry.type !== 'release');
  const feature = candidates.findLast((entry) => entry.type === 'feat');
  return feature?.title ?? candidates.at(-1)?.title ?? null;
}
