import assert from 'node:assert/strict';
import test from 'node:test';
import { completionEvidenceForGoal, residualGoalAfterEntry } from '../src/m5-goals.mjs';

test('Goal Router 消费已完成的入口导航，只把剩余目标交给 Planner', () => {
  assert.equal(
    residualGoalAfterEntry(
      '从空白页开始，打开 https://127.0.0.1:9443/shop，只把测试商品加入购物车，然后完成。',
      'https://127.0.0.1:9443/shop',
    ),
    '只把测试商品加入购物车，然后完成。',
  );
  assert.equal(
    residualGoalAfterEntry('分析当前页面', 'https://127.0.0.1:9443/'),
    '分析当前页面',
  );
});

test('Result Verifier 根据浏览器证据而不是模型自述决定是否可完成', () => {
  assert.equal(completionEvidenceForGoal('确认购物车数量为 1', {
    snapshot: '购物车：空',
  }), false);
  assert.equal(completionEvidenceForGoal('确认购物车数量为 1', {
    snapshot: '购物车：测试商品 × 1',
  }), true);
  assert.equal(completionEvidenceForGoal('核对收藏夹', {
    snapshot: '收藏夹', nativeState: { bookmarksRead: false },
  }), false);
  assert.equal(completionEvidenceForGoal('核对收藏夹', {
    snapshot: '收藏夹', nativeState: { bookmarksRead: true },
  }), true);
});
