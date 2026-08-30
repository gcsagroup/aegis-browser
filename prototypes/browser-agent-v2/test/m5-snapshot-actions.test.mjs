import assert from 'node:assert/strict';
import test from 'node:test';
import { actionsFromSnapshot } from '../src/m5-aegis-agent-worker.mjs';

test('Accessibility snapshot 确定性生成可点击动作且保留预检 URL', () => {
  const actions = actionsFromSnapshot({
    formattedTree: '[0-1] RootWebArea: fixture\n  [0-2] link: 开始研究\n  [0-3] button: 最终下单\n  [0-4] textbox: 密码',
    xpathMap: { '0-2': '/html/body/a', '0-3': '/html/body/button', '0-4': '/html/body/input' },
    urlMap: { '0-2': 'https://127.0.0.1:9443/research' },
  });
  assert.deepEqual(actions, [
    {
      selector: '/html/body/a', description: 'link: 开始研究', method: 'click', arguments: [],
      targetUrl: 'https://127.0.0.1:9443/research',
    },
    {
      selector: '/html/body/button', description: 'button: 最终下单', method: 'click', arguments: [],
      targetUrl: null,
    },
  ]);
});
