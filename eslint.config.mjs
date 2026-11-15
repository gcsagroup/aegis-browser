import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import security from 'eslint-plugin-security';

const ciNodeGlobals = {
  Buffer: 'readonly',
  URL: 'readonly',
  console: 'readonly',
  process: 'readonly',
  structuredClone: 'readonly',
};

const nodeGlobals = {
  ...ciNodeGlobals,
  AbortController: 'readonly',
  AbortSignal: 'readonly',
  Blob: 'readonly',
  FormData: 'readonly',
  Headers: 'readonly',
  Request: 'readonly',
  Response: 'readonly',
  TextDecoder: 'readonly',
  TextEncoder: 'readonly',
  URLSearchParams: 'readonly',
  WebSocket: 'readonly',
  atob: 'readonly',
  btoa: 'readonly',
  clearInterval: 'readonly',
  clearTimeout: 'readonly',
  crypto: 'readonly',
  fetch: 'readonly',
  navigator: 'readonly',
  performance: 'readonly',
  setImmediate: 'readonly',
  setInterval: 'readonly',
  setTimeout: 'readonly',
};

const browserExtensionGlobals = {
  browser: 'readonly',
  crypto: 'readonly',
  document: 'readonly',
  location: 'readonly',
  URL: 'readonly',
  window: 'readonly',
};

const localNodeScriptFiles = [
  'scripts/dev/**/*.mjs',
  'scripts/check-repo-contracts.mjs',
  'apps/browser/scripts/**/*.mjs',
  'apps/ios/scripts/**/*.mjs',
  'apps/ios/Tests/**/*.mjs',
  'packages/core/scripts/**/*.mjs',
  'packages/core/src/script-risk/evaluation/*.mjs',
];

export default tseslint.config(
  {
    files: [
      "apps/browser/scripts/ios-access-phase1-evidence.mjs",
      "apps/browser/scripts/ios-access-phase1-evidence_test.mjs",
      "apps/browser/scripts/macos-access-phase1-evidence.mjs",
      "apps/ios/scripts/simulator-input-manifest.mjs",
      "apps/ios/scripts/test-simulator-input-evidence.mjs",
      "packages/core/src/script-risk/evaluation/blind-protocol.test.ts"
],
    plugins: {security},
    // Codacy enables this plugin independently. Register it so scoped,
    // reasoned Codacy suppressions can also be parsed by the local ESLint gate.
    linterOptions: {reportUnusedDisableDirectives: false},
  },
  {
    ignores: ['**/node_modules/**', '**/dist/**', '**/coverage/**', '.artifacts/**'],
  },
  {
    files: ['scripts/ci/**/*.mjs'],
    ...eslint.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: ciNodeGlobals,
    },
  },
  {
    files: localNodeScriptFiles,
    ...eslint.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: nodeGlobals,
    },
    rules: {
      ...eslint.configs.recommended.rules,
      'no-unused-vars': ['error', {
        argsIgnorePattern: '^_',
        caughtErrorsIgnorePattern: '^_',
        varsIgnorePattern: '^_',
      }],
    },
  },
  {
    files: ['apps/ios/SharedWebExtension/*.js'],
    ...eslint.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'script',
      globals: browserExtensionGlobals,
    },
  },
  {
    files: ['packages/core/src/**/*.ts'],
    extends: [eslint.configs.recommended, ...tseslint.configs.recommended],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: nodeGlobals,
    },
    rules: {
      'no-undef': 'off',
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
    },
  },
  {
    files: ['packages/core/src/**/*.test.ts'],
    rules: {
      'no-loss-of-precision': 'off',
      'no-useless-escape': 'off',
      '@typescript-eslint/ban-ts-comment': 'off',
    },
  },
  {
    files: ['packages/core/src/privacy/pii.ts'],
    rules: {'no-useless-escape': 'off'},
  },
  {
    files: ['packages/core/src/script-risk/structure-signature.ts'],
    rules: {'@typescript-eslint/no-empty-object-type': 'off'},
  },
);
