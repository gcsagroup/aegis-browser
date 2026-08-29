import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const DEFAULT_PROTOCOL_VERSION = '2025-06-18';

export class McpStdioClient {
  #nextId = 1;
  #pending = new Map();
  #stderr = [];

  constructor({ command, args, cwd, env, allowedTools, timeoutMs = 30_000 }) {
    this.allowedTools = new Set(allowedTools);
    this.timeoutMs = timeoutMs;
    this.child = spawn(command, args, {
      cwd,
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.exitPromise = new Promise((resolve) => this.child.once('exit', (code, signal) => resolve({ code, signal })));
    this.child.once('error', (error) => this.#rejectAll(error));
    this.child.once('exit', (code, signal) => {
      this.#rejectAll(new Error(`MCP 子进程提前退出：code=${code} signal=${signal}`));
    });

    const output = createInterface({ input: this.child.stdout });
    output.on('line', (line) => this.#handleLine(line));
    const errors = createInterface({ input: this.child.stderr });
    errors.on('line', (line) => {
      if (this.#stderr.length < 200) this.#stderr.push(line);
    });
  }

  get stderrLines() {
    return [...this.#stderr];
  }

  async initialize() {
    const result = await this.request('initialize', {
      protocolVersion: DEFAULT_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: 'aegis-browser-agent-v2-harness', version: '0.1.0' },
    });
    this.notify('notifications/initialized', {});
    return result;
  }

  async listTools() {
    return this.request('tools/list', {});
  }

  async callTool(name, argumentsValue = {}) {
    if (!this.allowedTools.has(name)) {
      throw new Error(`MCP 工具不在 Harness allowlist：${name}`);
    }
    return this.request('tools/call', { name, arguments: argumentsValue });
  }

  request(method, params) {
    const id = this.#nextId++;
    const message = { jsonrpc: '2.0', id, method, params };
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`MCP 请求超时：${method}`));
      }, this.timeoutMs);
      this.#pending.set(id, { resolve, reject, timeout });
      this.#write(message);
    });
  }

  notify(method, params) {
    this.#write({ jsonrpc: '2.0', method, params });
  }

  async close() {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return this.exitPromise;
    this.child.stdin.end();
    this.child.kill('SIGTERM');
    const graceful = await Promise.race([
      this.exitPromise.then((result) => ({ exited: true, result })),
      new Promise((resolve) => setTimeout(() => resolve({ exited: false }), 2_000)),
    ]);
    if (graceful.exited) return graceful.result;
    this.child.kill('SIGKILL');
    return this.exitPromise;
  }

  #write(message) {
    if (!this.child.stdin.writable) throw new Error('MCP stdin 已关闭');
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.#stderr.push(`非 JSON stdout：${line}`);
      return;
    }
    if (message.id === undefined) return;
    const pending = this.#pending.get(message.id);
    if (!pending) return;
    clearTimeout(pending.timeout);
    this.#pending.delete(message.id);
    if (message.error) {
      pending.reject(new Error(`MCP ${message.error.code}: ${message.error.message}`));
    } else {
      pending.resolve(message.result);
    }
  }

  #rejectAll(error) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.#pending.clear();
  }
}
