import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

const nodeGlobals = {
  Buffer: 'readonly',
  URL: 'readonly',
  console: 'readonly',
  process: 'readonly',
  structuredClone: 'readonly',
};

export default tseslint.config(
  {
    ignores: ['**/node_modules/**', '**/dist/**', '**/coverage/**', '.artifacts/**'],
  },
  {
    files: ['scripts/ci/**/*.mjs'],
    ...eslint.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: nodeGlobals,
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
