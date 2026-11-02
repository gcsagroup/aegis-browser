import {mkdirSync, readFileSync, readdirSync, realpathSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {stopCoverage, takeCoverage} from 'node:v8';

// Vitest 4 acknowledges fork teardown over IPC before its parent sends SIGTERM.
// Preload before its process.exit interception, only in that exact worker.
let workerEntry;
const isEval = process.execArgv.some(arg => arg.startsWith('-e') || arg.startsWith('-p') ||
  arg === '--eval' || arg.startsWith('--eval=') || arg === '--print' || arg.startsWith('--print='));
if (!isEval && process.env.NODE_V8_COVERAGE && typeof process.send === 'function' && process.argv[1]) {
  try {
    const entry = realpathSync(process.argv[1]);
    if (entry === realpathSync(new URL('./node_modules/vitest/dist/workers/forks.js', import.meta.url))) {
      workerEntry = entry;
    }
  } catch {
    // An argument or unavailable path is not proof of the target worker identity.
  }
}
if (workerEntry) {
  const exit = process.exit.bind(process);
  const send = process.send;
  const directory = resolve(process.env.NODE_V8_COVERAGE);
  const ownReport = name => name.startsWith(`coverage-${process.pid}-`) && name.endsWith('-0.json');
  const handoffCoverage = () => {
    mkdirSync(directory, {recursive: true});
    const before = new Set(readdirSync(directory).filter(ownReport));
    try {
      takeCoverage();
    } finally {
      // The acknowledged test/teardown interval is complete. Prevent a second,
      // automatic exit write from being cut short by the parent's SIGKILL.
      stopCoverage();
    }
    const created = readdirSync(directory).filter(name => ownReport(name) && !before.has(name));
    if (created.length !== 1) throw new Error('Expected one fresh worker coverage report');
    const report = JSON.parse(readFileSync(join(directory, created[0]), 'utf8'));
    // Vitest's V8 provider can consume/reset earlier script counters. The dump
    // must contain this currently executing preload in the exact worker's file.
    if (!Array.isArray(report.result) || !report.result.some(entry => entry.url === import.meta.url &&
      entry.functions.some(fn => fn.ranges.some(range => range.count > 0)))) {
      throw new Error('Worker coverage report does not contain the active handoff');
    }
  };
  let stopRequested = false;
  let stopped = false;
  process.on('message', message => {
    if (message?.__vitest_worker_request__ !== true) return;
    stopRequested = message.type === 'stop';
    stopped = false;
  });
  process.send = function (message, ...args) {
    const response = message?.__vitest_worker_response__ === true;
    // Report failure at the first completion boundary, before stop can discard
    // the parent's unexpected-exit listener or the worker can naturally exit.
    if (response && (message.type === 'testfileFinished' || (stopRequested && message.type === 'stopped')) &&
      Number(process.exitCode ?? 0) !== 0 && message.error == null) {
      message = {...message, error: {
        name: 'Error',
        message: `Vitest worker requested nonzero exit code ${process.exitCode}`,
      }};
    }
    if (stopRequested && response && message.type === 'stopped') {
      try {
        handoffCoverage();
      } catch (error) {
        if (message.error == null) message = {...message, error: {
          name: 'Error',
          message: `V8 worker coverage handoff failed: ${error.message}`,
        }};
      }
      stopped = message.error == null;
    }
    try {
      return Reflect.apply(send, this, [message, ...args]);
    } catch (error) {
      stopped = false;
      throw error;
    }
  };
  process.on('SIGTERM', () => {
    // Preserve failure; an early signal cannot accept unfinished tests/teardown.
    // Vitest's original 500 ms SIGKILL fallback remains in the parent.
    const code = process.exitCode ?? 0;
    exit(Number(code) !== 0 ? code : stopped ? 0 : 143);
  });
}
