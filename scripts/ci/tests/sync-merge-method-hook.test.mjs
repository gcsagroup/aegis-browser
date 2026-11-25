import assert from 'node:assert/strict';
import test from 'node:test';

const repository = {id: 100, full_name: 'example/aegis-browser'};
const otherRepository = {id: 101, full_name: 'other/aegis-browser'};
const backflow = `codex/backflow-${'a'.repeat(40)}`;
const promotion = `codex/promote-${'a'.repeat(40)}-${'b'.repeat(40)}`;

function pull({head = backflow, base = 'develop', headRepository = repository, method = 'squash', state = 'open'} = {}) {
  return {
    number: 424,
    node_id: 'PR_example',
    state,
    base: {ref: base, repo: repository},
    head: {ref: head, repo: headRepository},
    auto_merge: method === null ? null : {merge_method: method},
  };
}

async function invoke(eventPull, currentPull = eventPull, mutationError, action = 'auto_merge_enabled') {
  const {run} = await import('../sync-merge-method-hook.mjs');
  const calls = [];
  const github = {
    rest: {
      pulls: {get: async (params) => {
        calls.push(['read', params]);
        return {data: currentPull};
      }},
      issues: {createComment: async (params) => { calls.push(['comment', params]); }},
    },
    graphql: async (query, params) => {
      assert.match(query, /disablePullRequestAutoMerge/u);
      calls.push(['disable', params]);
      if (mutationError) throw mutationError;
      return {disablePullRequestAutoMerge: {pullRequest: {id: params.pullRequestId, autoMergeRequest: null}}};
    },
  };
  const context = {
    repo: {owner: 'example', repo: 'aegis-browser'},
    eventName: 'pull_request_target',
    payload: {action, repository, pull_request: eventPull},
  };
  const core = {info() {}};
  return {calls, execute: () => run({github, context, core})};
}

test('clears squash or rebase auto-merge on the supported same-repository sync routes', async () => {
  for (const candidate of [pull(), pull({head: 'main', method: 'rebase'}), pull({head: promotion, base: 'main'})]) {
    const {calls, execute} = await invoke(candidate);
    await execute();
    assert.deepEqual(calls.map(([name]) => name), ['read', 'disable', 'comment']);
    assert.deepEqual(calls[1][1], {pullRequestId: candidate.node_id});
    assert.equal(calls[2][1].issue_number, candidate.number);
    assert.match(calls[2][1].body, /gh pr merge 424 --repo example\/aegis-browser --auto --merge/u);
  }
});

test('ignores ordinary branches, other repositories, and unsupported directions', async () => {
  for (const candidate of [
    pull({head: 'feat/browser'}), pull({head: 'codex/backflow-short'}), pull({head: promotion}),
    pull({base: 'main'}), pull({headRepository: otherRepository}), pull({headRepository: null}),
  ]) {
    const {calls, execute} = await invoke(candidate);
    await execute();
    assert.deepEqual(calls, []);
  }
});

test('rechecks live PR state, preserving correct auto-merge and ignoring stale events', async () => {
  for (const current of [
    pull({method: 'merge'}), pull({method: null}), pull({state: 'closed'}), pull({base: 'main'}),
    {...pull(), node_id: 'PR_different'},
  ]) {
    const {calls, execute} = await invoke(pull(), current);
    await execute();
    assert.deepEqual(calls.map(([name]) => name), ['read']);
  }
});

test('other events have no side effects and API failures do not post a success comment', async () => {
  const unrelated = await invoke(pull(), pull(), undefined, 'synchronize');
  await unrelated.execute();
  assert.deepEqual(unrelated.calls, []);

  const error = new Error('Resource not accessible by integration');
  const {calls, execute} = await invoke(pull(), pull(), error);
  await assert.rejects(execute(), error);
  assert.deepEqual(calls.map(([name]) => name), ['read', 'disable']);
});
