import { createInterface } from 'node:readline';

const input = createInterface({ input: process.stdin });
input.on('line', (line) => {
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  let result;
  if (message.method === 'initialize') {
    result = { protocolVersion: message.params.protocolVersion, capabilities: {}, serverInfo: { name: 'fake', version: '1' } };
  } else if (message.method === 'tools/list') {
    result = { tools: [{ name: 'allowed', inputSchema: { type: 'object' } }, { name: 'forbidden', inputSchema: { type: 'object' } }] };
  } else if (message.method === 'tools/call') {
    result = { content: [{ type: 'text', text: `called:${message.params.name}` }] };
  } else {
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'missing' } })}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, result })}\n`);
});
