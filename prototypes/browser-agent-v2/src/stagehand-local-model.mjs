function textFromContent(content) {
  if (typeof content === 'string') return content;
  const blocks = Array.isArray(content) ? content : [content];
  if (blocks.some((block) => block?.type === 'image')) {
    throw new Error('本地文本模型原型拒绝 Stagehand 截图输入');
  }
  return blocks
    .filter((block) => block?.type === 'text')
    .map((block) => block.text)
    .join('\n');
}

function parseStructuredContent(raw) {
  const withoutThinking = raw.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  const withoutFence = withoutThinking
    .replace(/^```(?:json)?\s*/i, '')
    .replace(/\s*```$/i, '')
    .trim();
  try {
    return JSON.parse(withoutFence);
  } catch {
    const objectStart = withoutFence.indexOf('{');
    const objectEnd = withoutFence.lastIndexOf('}');
    const arrayStart = withoutFence.indexOf('[');
    const arrayEnd = withoutFence.lastIndexOf(']');
    if (arrayStart >= 0 && (objectStart < 0 || arrayStart < objectStart) && arrayEnd > arrayStart) {
      return JSON.parse(withoutFence.slice(arrayStart, arrayEnd + 1));
    }
    if (objectStart >= 0 && objectEnd > objectStart) {
      return JSON.parse(withoutFence.slice(objectStart, objectEnd + 1));
    }
    throw new Error('本地模型没有返回可解析 JSON');
  }
}

export function createLocalOpenAiStagehandModel({ baseUrl, model, fetchImpl = fetch }) {
  const endpoint = new URL('chat/completions', `${baseUrl.replace(/\/$/, '')}/`);
  if (endpoint.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(endpoint.hostname)) {
    throw new Error('Stagehand 本地模型只允许数值 loopback HTTP');
  }
  let calls = 0;

  const client = Object.freeze({
    async generate(input) {
      calls += 1;
      const schema = input.responseFormat?.schema ?? input.structuredContent;
      const outputFormat = schema ? 'json_schema' : 'text';
      const messages = input.messages.map(({ role, content }) => ({
        role,
        content: textFromContent(content),
      }));
      if (input.systemPrompt) messages.unshift({ role: 'system', content: input.systemPrompt });
      if (schema) {
        messages.unshift({
          role: 'system',
          content: `只返回一个符合下列 JSON Schema 的 JSON 值，不要 Markdown，不要解释：\n${JSON.stringify(schema)}`,
        });
      }
      const response = await fetchImpl(endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          model,
          messages,
          temperature: 0,
          max_tokens: 1024,
          seed: 7,
          chat_template_kwargs: { enable_thinking: false },
        }),
      });
      if (!response.ok) throw new Error(`本地模型请求失败：HTTP ${response.status}`);
      const payload = await response.json();
      const content = payload.choices?.[0]?.message?.content;
      if (typeof content !== 'string') throw new Error('本地模型响应缺少 assistant content');
      const usage = {
        inputTokens: payload.usage?.prompt_tokens ?? 0,
        outputTokens: payload.usage?.completion_tokens ?? 0,
        totalTokens: payload.usage?.total_tokens ?? 0,
      };
      if (schema) {
        return {
          role: 'assistant',
          content: [{ type: 'text', text: content }],
          stopReason: payload.choices?.[0]?.finish_reason ?? 'stop',
          usage,
          outputFormat,
          structuredContent: parseStructuredContent(content),
        };
      }
      return {
        role: 'assistant',
        content: [{ type: 'text', text: content }],
        stopReason: payload.choices?.[0]?.finish_reason ?? 'stop',
        usage,
        outputFormat,
      };
    },
  });
  return Object.freeze({
    client,
    get calls() { return calls; },
  });
}

export const testing = Object.freeze({ parseStructuredContent, textFromContent });
