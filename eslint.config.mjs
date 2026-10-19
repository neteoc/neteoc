import js from '@eslint/js';
import astro from 'eslint-plugin-astro';
import globals from 'globals';
import tseslint from 'typescript-eslint';
export default [
  {
    ignores: [
      'node_modules/**',
      '.tools/**',
      'dist/**',
      'coverage/**',
      '.husky/**',
      '.astro/**',
      '.wrangler/**',
      'worker-configuration.d.ts',
      'tests/semgrep/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...astro.configs.recommended,
  {
    files: ['**/*.mjs', '**/*.js'],
    languageOptions: { globals: globals.node },
    rules: { eqeqeq: 'error', 'no-var': 'error', 'prefer-const': 'error' },
  },
  {
    files: ['src/**/*.{ts,tsx,astro}'],
    languageOptions: { globals: { ...globals.browser, ...globals.worker } },
    rules: { eqeqeq: 'error', 'no-var': 'error', 'prefer-const': 'error' },
  },
];
