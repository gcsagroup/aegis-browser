import assert from 'node:assert/strict';
import test from 'node:test';
import {decidePrTitle, inferPrTitle, parseConventionalTitle, run} from '../pr-title-hook.mjs';

const promotionMessage = `release: promote develop through PR #46 (#49)

* docs: remove duplicate develop badges

* feat(access): add request ownership registry (#44)

* feat(access): add targeted request cancellation (#45)

* feat(access): add request dispatch block barriers (#46)

* feat(access): add request dispatch block barriers

* fix(access): satisfy dispatch barrier complexity gate

* chore: preserve upstream README mirror for PR #46 promotion

* fix(access): resolve PR 49 review findings`;

test('promotion title selects the last real feature over later review fixes', () => {
  assert.equal(inferPrTitle([promotionMessage]), 'feat(access): add request dispatch block barriers');
  assert.deepEqual(
    decidePrTitle({currentTitle: 'release: promote develop through PR #46', commitMessages: [promotionMessage]}),
    {
      action: 'update',
      title: 'feat(access): add request dispatch block barriers',
      reason: 'generic-release-title',
    },
  );
});

test('docs-only and fix-only PRs use the last non-release conventional entry', () => {
  assert.equal(inferPrTitle(['docs(ci): explain title hook (#51)']), 'docs(ci): explain title hook');
  assert.equal(
    inferPrTitle(['release: promotion wrapper\n\n* fix(ci): keep trusted base checkout (#52)']),
    'fix(ci): keep trusted base checkout',
  );
});

test('an already-correct conventional title is preserved', () => {
  assert.deepEqual(
    decidePrTitle({
      currentTitle: 'fix(access): resolve ownership race',
      commitMessages: ['feat(access): unrelated older feature'],
    }),
    {action: 'keep', title: 'fix(access): resolve ownership race', reason: 'current-title-is-conventional'},
  );
});

test('unknown or ambiguous text fails closed without mutation', () => {
  assert.equal(parseConventionalTitle('* not a conventional title (#12)'), null);
  assert.deepEqual(
    decidePrTitle({currentTitle: 'Update files', commitMessages: ['Merge branch develop', 'plain text']}),
    {action: 'keep', title: 'Update files', reason: 'no-unambiguous-candidate'},
  );
});

test('title normalization preserves parser boundaries', () => {
  assert.equal(parseConventionalTitle(null), null);
  assert.equal(parseConventionalTitle(`fix: ${'x'.repeat(252)}`), null);
  assert.equal(
    parseConventionalTitle('* fix(ci): keep title policy (#51) (#52)')?.title,
    'fix(ci): keep title policy',
  );
});

test('runner reads PR commits and updates title through the GitHub API', async () => {
  const updates = [];
  const github = {
    paginate: async (_method, args) => {
      assert.equal(args.pull_number, 15);
      return [{commit: {message: promotionMessage}}];
    },
    rest: {
      pulls: {
        listCommits: Symbol('listCommits'),
        update: async (args) => updates.push(args),
      },
    },
  };
  const logs = [];
  const decision = await run({
    github,
    context: {
      repo: {owner: 'gcsagroup', repo: 'aegis-browser'},
      payload: {pull_request: {number: 15, title: 'release: promote develop through PR #46'}},
    },
    core: {info: (message) => logs.push(message)},
  });
  assert.equal(decision.action, 'update');
  assert.deepEqual(updates, [{
    owner: 'gcsagroup',
    repo: 'aegis-browser',
    pull_number: 15,
    title: 'feat(access): add request dispatch block barriers',
  }]);
  assert.match(logs[0], /Updated PR #15 title/u);
});
