import fs from 'node:fs';
import path from 'node:path';
import { EVENT_TYPES } from './constants.mjs';
import { redact } from './security.mjs';

export class EventJournal {
  #sequence = 0;

  constructor({ runId, scenarioId, runRoot }) {
    this.runId = runId;
    this.scenarioId = scenarioId;
    this.runRoot = runRoot;
    this.eventsPath = path.join(runRoot, 'events.jsonl');
    this.assertionsPath = path.join(runRoot, 'assertions.json');
    this.assertions = [];
  }

  append(type, payload = {}) {
    if (!EVENT_TYPES.has(type)) throw new Error(`未知事件类型：${type}`);
    const event = {
      schemaVersion: 1,
      sequence: ++this.#sequence,
      timestamp: new Date().toISOString(),
      runId: this.runId,
      scenarioId: this.scenarioId,
      type,
      payload: redact(payload),
    };
    fs.appendFileSync(this.eventsPath, `${JSON.stringify(event)}\n`, { encoding: 'utf8', mode: 0o600 });
    return event;
  }

  assertion(name, passed, details = {}) {
    const assertion = redact({ name, passed: Boolean(passed), details });
    this.assertions.push(assertion);
    fs.writeFileSync(this.assertionsPath, `${JSON.stringify(this.assertions, null, 2)}\n`, {
      encoding: 'utf8',
      mode: 0o600,
    });
    this.append('assertion.recorded', assertion);
    return assertion;
  }
}
