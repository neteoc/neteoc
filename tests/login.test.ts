import { describe, expect, test } from 'bun:test';
import {
  allowLogin,
  allowVerify,
  EMAIL_OTP_LENGTH,
  EMAIL_OTP_PATTERN,
  isValidEmailOtp,
  readLoginEmail,
  readSmallForm,
} from '../src/lib/login';

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

test('email OTP input and server validation share the configured length', () => {
  expect(EMAIL_OTP_LENGTH).toBe(8);
  expect(EMAIL_OTP_PATTERN).toBe('[0-9]{8}');
  expect(isValidEmailOtp('12345678')).toBe(true);
  expect(isValidEmailOtp('123456')).toBe(false);
  expect(isValidEmailOtp('123456789')).toBe(false);
  expect(isValidEmailOtp('1234abcd')).toBe(false);
});

test('login limits reject one IP before consuming shared buckets', async () => {
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
    LOGIN_IP_LIMIT: makeLimiter('ip', false),
    LOGIN_EMAIL_LIMIT: makeLimiter('email', true),
  });
  expect(allowed).toBe(false);
  expect(seen).toEqual(['ip:192.0.2.10']);
});

test('login limits hash email and consume global capacity last', async () => {
  const seen: string[] = [];
  const makeLimiter = (name: string) => ({
    async limit({ key }: { key: string }) {
      seen.push(`${name}:${key}`);
      return { success: true };
    },
  });
  const allowed = await allowLogin(
    formRequest('email=user%40example.org'),
    'user@example.org',
    {
      LOGIN_GLOBAL_LIMIT: makeLimiter('global'),
      LOGIN_IP_LIMIT: makeLimiter('ip'),
      LOGIN_EMAIL_LIMIT: makeLimiter('email'),
    },
  );
  expect(allowed).toBe(true);
  expect(seen[0]).toBe('ip:192.0.2.10');
  expect(seen[1]).toMatch(/^email:[0-9a-f]{64}$/);
  expect(seen[1]).not.toContain('user@example.org');
  expect(seen[2]).toBe('global:login');
});

test('email throttling leaves global capacity for other responders', async () => {
  const seen: string[] = [];
  const allowed = await allowLogin(
    formRequest('email=user%40example.org'),
    'user@example.org',
    {
      LOGIN_IP_LIMIT: {
        async limit() {
          seen.push('ip');
          return { success: true };
        },
      },
      LOGIN_EMAIL_LIMIT: {
        async limit() {
          seen.push('email');
          return { success: false };
        },
      },
      LOGIN_GLOBAL_LIMIT: {
        async limit() {
          seen.push('global');
          return { success: true };
        },
      },
    },
  );
  expect(allowed).toBe(false);
  expect(seen).toEqual(['ip', 'email']);
});

test('code verification uses independent IP and global buckets', async () => {
  const seen: string[] = [];
  const allowed = await allowVerify(formRequest('email=user%40example.org'), {
    VERIFY_IP_LIMIT: {
      async limit({ key }) {
        seen.push(`ip:${key}`);
        return { success: true };
      },
    },
    VERIFY_GLOBAL_LIMIT: {
      async limit({ key }) {
        seen.push(`global:${key}`);
        return { success: true };
      },
    },
  });
  expect(allowed).toBe(true);
  expect(seen).toEqual(['ip:192.0.2.10', 'global:verify']);
});
