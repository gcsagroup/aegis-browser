import {parseCandidate} from './promotion-candidate.mjs';

const DISABLE_AUTO_MERGE = `
  mutation DisableSyncAutoMerge($pullRequestId: ID!) {
    disablePullRequestAutoMerge(input: {pullRequestId: $pullRequestId}) {
      pullRequest { id autoMergeRequest { mergeMethod } }
    }
  }
`;

function isSyncPull(pull, repositoryId) {
  if (!pull || pull.state !== 'open' || pull.base?.repo?.id !== repositoryId || pull.head?.repo?.id !== repositoryId) {
    return false;
  }
  const head = pull.head.ref;
  const kind = parseCandidate(head)?.kind;
  return (pull.base.ref === 'develop' && (head === 'main' || kind === 'backflow')) ||
    (pull.base.ref === 'main' && kind === 'promotion');
}

export async function run({github, context, core}) {
  if (context.eventName !== 'pull_request_target' || context.payload.action !== 'auto_merge_enabled') return;
  const {repository, pull_request: eventPull} = context.payload;
  if (!repository?.id || !isSyncPull(eventPull, repository.id)) return;

  const {owner, repo} = context.repo;
  const pullNumber = eventPull.number;
  const {data: pull} = await github.rest.pulls.get({owner, repo, pull_number: pullNumber});
  if (!isSyncPull(pull, repository.id) || pull.node_id !== eventPull.node_id || !pull.auto_merge) return;

  const method = pull.auto_merge.merge_method;
  if (method === 'merge') return;
  if (method !== 'squash' && method !== 'rebase') throw new Error('Unknown GitHub auto-merge method');

  const result = await github.graphql(DISABLE_AUTO_MERGE, {pullRequestId: pull.node_id});
  const disabled = result.disablePullRequestAutoMerge?.pullRequest;
  if (disabled?.id !== pull.node_id || disabled.autoMergeRequest !== null) {
    throw new Error('GitHub did not confirm auto-merge was disabled');
  }

  core.info(`Disabled ${method} auto-merge for sync PR #${pullNumber}`);
  await github.rest.issues.createComment({
    owner,
    repo,
    issue_number: pullNumber,
    body: `Disabled ${method} auto-merge. Sync PRs require a merge commit to preserve upstream ancestry. ` +
      'After verifying the final head has the required checks and review, use `' +
      `gh pr merge ${pullNumber} --repo ${owner}/${repo} --auto --merge` + '`.',
  });
}
