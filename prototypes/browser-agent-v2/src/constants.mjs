import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROTOTYPE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const REPOSITORY_ROOT = path.resolve(PROTOTYPE_ROOT, '..', '..');
export const ARTIFACT_ROOT = path.join(
  REPOSITORY_ROOT,
  '.artifacts',
  'aegis-agent-v2-prototypes',
);

export const EVENT_TYPES = new Set([
  'run.started',
  'scenario.reset',
  'navigation.requested',
  'navigation.completed',
  'observation.captured',
  'action.requested',
  'action.completed',
  'assertion.recorded',
  'security.violation',
  'adapter.output',
  'run.finished',
]);

export const FORCED_ADAPTER_ENVIRONMENT = Object.freeze({
  ANONYMIZED_TELEMETRY: 'false',
  BROWSER_USE_CLOUD_SYNC: 'false',
  BROWSER_USE_DISABLE_EXTENSIONS: '1',
  SKYVERN_TELEMETRY: 'false',
  ENABLE_CODE_BLOCK: 'false',
  DISABLE_CODE_BLOCK_EXECUTION: 'true',
  OTEL_SDK_DISABLED: 'true',
  STAGEHAND_ENV: 'LOCAL',
});

export const MODEL_PROVIDER_DEFINITIONS = Object.freeze({
  openai: Object.freeze({ environmentVariable: 'OPENAI_API_KEY' }),
  anthropic: Object.freeze({ environmentVariable: 'ANTHROPIC_API_KEY' }),
  gemini: Object.freeze({ environmentVariable: 'GOOGLE_API_KEY' }),
});

export const DEVELOPMENT_MODEL_KEY_NAMES = new Set(
  Object.values(MODEL_PROVIDER_DEFINITIONS).map(({ environmentVariable }) => environmentVariable),
);
