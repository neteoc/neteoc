import { describe, expect, test } from 'bun:test';

const { clearSupabaseCookies } = await import('../src/lib/session-cookies');

interface Deleted {
  name: string;
  options: Record<string, unknown>;
}

function recordingCookies() {
  const deleted: Deleted[] = [];
  return {
    deleted,
    cookies: {
      delete(name: string, options: Record<string, unknown>) {
        deleted.push({ name, options });
      },
    },
  };
}

describe('sign-out cookie removal', () => {
  test('removes session and verifier cookies with the session attributes', () => {
    const request = new Request('https://neteoc.example/auth/logout', {
      headers: {
        Cookie:
          'sb-127-auth-token=a; sb-127-auth-token.1=b; sb-127-auth-token-code-verifier=c; other=d',
      },
    });
    const { cookies, deleted } = recordingCookies();
    clearSupabaseCookies(request, cookies as never);
    expect(deleted.map((d) => d.name)).toEqual([
      'sb-127-auth-token',
      'sb-127-auth-token.1',
      'sb-127-auth-token-code-verifier',
    ]);
    for (const { options } of deleted) {
      expect(options).toEqual({
        httpOnly: true,
        secure: true,
        sameSite: 'lax',
        path: '/',
      });
    }
  });

  test('leaves unrelated and look-alike cookies alone', () => {
    const request = new Request('https://neteoc.example/auth/logout', {
      headers: { Cookie: 'theme=dark; sb-127-auth-token-extra=x' },
    });
    const { cookies, deleted } = recordingCookies();
    clearSupabaseCookies(request, cookies as never);
    expect(deleted).toEqual([]);
  });
});
