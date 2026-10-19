import { describe, expect, test } from 'bun:test';
import { allowLogin, readLoginEmail, readSmallForm } from '../src/lib/login';

function formRequest(
  body: string,
  contentType = 'application/x-www-form-urlencoded',
) {
  return new Request('https://neteoc.example/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': contentType, 'CF-Connecting-IP': '192.0.2.10' },
    body,
  });
}

describe('login input boundary', () => {
  test('normalizes one email field', async () => {
    expect(
      await readLoginEmail(formRequest('email=%20User%40Example.org%20')),
    ).toBe('user@example.org');
  });

  test('rejects malformed, duplicate, and oversized forms', async () => {
    expect(
      await readLoginEmail(formRequest('{}', 'application/json')),
    ).toBeNull();
    expect(
      await readLoginEmail(formRequest('email=a%40b.org&email=c%40d.org')),
    ).toBeNull();
    expect(await readSmallForm(formRequest('x'.repeat(4097)))).toBeNull();
  });
});

test('login limits use global, IP, then hashed email keys', async () => {
  const seen: string[] = [];
  const makeLimiter = (name: string, success: boolean) => ({
    async limit({ key }: { key: string }) {
      seen.push(`${name}:${key}`);
      return { success };
    },
  });
  const request = formRequest('email=user%40example.org');
  const allowed = await allowLogin(request, 'user@example.org', {
    LOGIN_GLOBAL_LIMIT: makeLimiter('global', true),
    LOGIN_IP_LIMIT: makeLimiter('ip', true),
    LOGIN_EMAIL_LIMIT: makeLimiter('email', false),
  });
  expect(allowed).toBe(false);
  expect(seen[0]).toBe('global:login');
  expect(seen[1]).toBe('ip:192.0.2.10');
  expect(seen[2]).toMatch(/^email:[0-9a-f]{64}$/);
  expect(seen[2]).not.toContain('user@example.org');
});
