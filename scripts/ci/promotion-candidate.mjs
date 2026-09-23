import {git, isAncestor} from './promotion-github.mjs';

const SHA = '[a-f0-9]{40}';
const PROMOTION = new RegExp(`^codex/promote-(${SHA})-(${SHA})$`, 'u');
const BACKFLOW = new RegExp(`^codex/backflow-(${SHA})$`, 'u');

export function parseCandidate(branch) {
  const promotion = PROMOTION.exec(branch);
  if (promotion) return {kind: 'promotion', source: promotion[1], base: promotion[2], branch};
  const backflow = BACKFLOW.exec(branch);
  if (backflow) return {kind: 'backflow', source: backflow[1], branch};
  return null;
}

export function buildCandidate(kind, source, base, ancestor = isAncestor) {
  if (![source, base].every((sha) => /^[a-f0-9]{40}$/u.test(sha))) throw new Error('Full source/base SHAs required');
  if (kind === 'promotion') {
    if (!ancestor(base, source)) throw new Error('Backflow must land before freezing a promotion');
    return {kind, source, base, branch: `codex/promote-${source}-${base}`};
  }
  if (kind === 'backflow') return {kind, source, base, branch: `codex/backflow-${source}`};
  throw new Error('Unknown candidate kind');
}

export function validateCandidate(candidate, head, ancestor = isAncestor) {
  if (!/^[a-f0-9]{40}$/u.test(head) || !ancestor(candidate.source, head)) {
    throw new Error('Candidate no longer contains its frozen source');
  }
  if (candidate.kind === 'promotion' && !ancestor(candidate.base, head)) {
    throw new Error('Candidate no longer contains its frozen upstream base');
  }
  // A reviewed fix is an ordinary descendant, not a reason to overwrite the PR.
  return head;
}

export function sameTree(left, right) {
  return git('rev-parse', `${left}^{tree}`) === git('rev-parse', `${right}^{tree}`);
}
