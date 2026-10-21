import { describe, expect, mock, test } from 'bun:test';

mock.module('cloudflare:workers', () => ({
  env: {
    LOGIN_IP_LIMIT: { limit: async () => ({ success: true }) },
    LOGIN_EMAIL_LIMIT: { limit: async () => ({ success: true }) },
    LOGIN_GLOBAL_LIMIT: { limit: async () => ({ success: true }) },
  },
}));

const { POST } = await import('../src/pages/auth/login');

function context(
  password: string,
  signInWithPassword: (credentials: unknown) => Promise<unknown>,
) {
  return {
    request: new Request('http://localhost:8787/auth/login', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'CF-Connecting-IP': '192.0.2.5',
      },
      body: new URLSearchParams({ email: 'member@example.test', password }),
    }),
    locals: { supabase: { auth: { signInWithPassword } } },
    redirect(location: string, status = 302) {
      return new Response(null, { status, headers: { Location: location } });
    },
  };
}

describe('password sign-in', () => {
  test('uses Supabase password authentication and enters the workspace', async () => {
    let input: unknown;
    const response = await POST(
      context('example password', async (credentials) => {
        input = credentials;
        return { error: null };
      }) as never,
    );
    expect(input).toEqual({
      email: 'member@example.test',
      password: 'example password',
    });
    expect(response.status).toBe(303);
    expect(response.headers.get('location')).toBe('/app');
  });

  test('wrong password and unknown account get the same response', async () => {
    const responses = [];
    for (const code of ['invalid_credentials', 'user_not_found']) {
      const response = await POST(
        context('incorrect', async () => ({
          error: { status: 400, code },
        })) as never,
      );
      responses.push([
        response.status,
        response.headers.get('location'),
        await response.text(),
      ]);
    }
    expect(responses[0]).toEqual(responses[1]);
    expect(responses[0][1]).toBe('/login?error=credentials');
  });
});
