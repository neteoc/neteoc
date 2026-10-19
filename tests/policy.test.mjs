import { describe, expect, test } from 'bun:test';
import { inspectPackage, inspectWorkflow } from '../scripts/check-policy.mjs';

describe('repository policy', () => {
  const base =
    'name: CI\npermissions:\n  contents: read\njobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n';
  test('accepts immutable action references and least-privilege permissions', () => {
    expect(inspectWorkflow(base, 'ci.yml')).toEqual([]);
  });
  test('rejects floating action tags and missing permissions', () => {
    expect(
      inspectWorkflow(
        base
          .replace(/@[0-9a-f]{40}/, '@v7')
          .replace('permissions:\n  contents: read\n', ''),
        'ci.yml',
      ).length,
    ).toBe(2);
  });
  test('rejects unpinned dependencies and a missing Bun manager', () => {
    expect(inspectPackage({ dependencies: { astro: '^7.0.0' } }).length).toBe(
      3,
    );
  });
});
