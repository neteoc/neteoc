import js from '@eslint/js';
import globals from 'globals';
export default [
  {
    ignores: [
      'node_modules/**',
      '.tools/**',
      'dist/**',
      'coverage/**',
      '.husky/**',
      'tests/semgrep/**',
    ],
  },
  js.configs.recommended,
  {
    files: ['**/*.mjs', '**/*.js'],
    languageOptions: { globals: globals.node },
    rules: { eqeqeq: 'error', 'no-var': 'error', 'prefer-const': 'error' },
  },
];
