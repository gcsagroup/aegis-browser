import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { McpStdioClient } from '../src/mcp-stdio-client.mjs';

test('MCP stdio 客户端完成握手并拒绝非 allowlist 工具', async (t) => {
  const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'test-support', 'fake-mcp-server.mjs');
  const client = new McpStdioClient({
    command: process.execPath,
    args: [fixture],
    cwd: path.dirname(fixture),
    env: { PATH: process.env.PATH ?? '' },
    allowedTools: ['allowed'],
    timeoutMs: 2_000,
  });
  t.after(() => client.close());
  const initialized = await client.initialize();
  assert.equal(initialized.serverInfo.name, 'fake');
  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map(({ name }) => name), ['allowed', 'forbidden']);
  const result = await client.callTool('allowed');
  assert.equal(result.content[0].text, 'called:allowed');
  await assert.rejects(() => client.callTool('forbidden'), /allowlist/);
});
