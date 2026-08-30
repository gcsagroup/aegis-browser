import assert from 'node:assert/strict';
import test from 'node:test';
import { createLocalOpenAiStagehandModel, testing } from '../src/stagehand-local-model.mjs';

test('本地 Stagehand 模型只允许数值 loopback', () => {
  assert.throws(() => createLocalOpenAiStagehandModel({
    baseUrl: 'http://localhost:8080/v1',
    model: 'fixture-model',
  }), /数值 loopback/);
  assert.throws(() => createLocalOpenAiStagehandModel({
    baseUrl: 'https://models.example.test/v1',
    model: 'fixture-model',
  }), /数值 loopback/);
});

test('解析本地模型的 thinking、代码围栏和结构化 JSON', () => {
  assert.deepEqual(testing.parseStructuredContent('<think>hidden</think>```json\n{"ok":true}\n```'), { ok: true });
  assert.deepEqual(testing.parseStructuredContent('说明文字 ["a","b"] 完成'), ['a', 'b']);
});

test('client LLM 发送 schema 并返回 Stagehand 结构', async () => {
  let requestBody;
  const model = createLocalOpenAiStagehandModel({
    baseUrl: 'http://127.0.0.1:8080/v1',
    model: 'fixture-model',
    fetchImpl: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return new Response(JSON.stringify({
        choices: [{ message: { content: '{"selector":"#refresh"}' }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 12, completion_tokens: 5, total_tokens: 17 },
      }));
    },
  });
  const result = await model.client.generate({
    messages: [{ role: 'user', content: [{ type: 'text', text: 'click refresh' }] }],
    responseFormat: { schema: { type: 'object', required: ['selector'] } },
  });
  assert.equal(model.calls, 1);
  assert.equal(requestBody.chat_template_kwargs.enable_thinking, false);
  assert.deepEqual(result.structuredContent, { selector: '#refresh' });
  assert.equal(result.usage.totalTokens, 17);
});
