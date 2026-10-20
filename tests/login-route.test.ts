import { afterEach, describe, expect, mock, spyOn, test } from 'bun:test';

// The route imports Cloudflare's env binding, which Bun cannot load. Every rate
// limiter allows the request, so the limits are exercised separately below.
const allowAll = {
  LOGIN_IP_LIMIT: { limit: async () => ({ success: true }) },
  LOGIN_EMAIL_LIMIT: { limit: async () => ({ success: true }) },
  LOGIN_GLOBAL_LIMIT: { limit: async () => ({ success: true }) },
};
let limitersAllow = true;
mock.module('cloudflare:workers', () => ({
  env: {
    LOGIN_IP_LIMIT: {
      limit: async () => ({ success: limitersAllow }),
    },
    LOGIN_EMAIL_LIMIT: allowAll.LOGIN_EMAIL_LIMIT,
    LOGIN_GLOBAL_LIMIT: allowAll.LOGIN_GLOBAL_LIMIT,
  },
}));

const { POST } = await import('../src/pages/auth/login');

const EMAIL = 'member@example.test';

type ProviderResult = { error: { status: number; code: string } | null };

// Records calls. `provider` decides what signInWithOtp resolves to, so a test can
// hold it open and observe the response before the provider settles.
function fakeSupabase(provider: () => Promise<ProviderResult>) {
  const calls: unknown[] = [];
  return {
    calls,
    auth: {
      signInWithOtp(input: unknown) {
        calls.push(input);
        return provider();
      },
    },
  };
}

function context(
  email: string,
  supabase: unknown,
  background: Promise<unknown>[],
) {
  const request = new Request('http://localhost:8787/auth/login', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'CF-Connecting-IP': '198.51.100.20',
      Origin: 'http://localhost:8787',
    },
    body: new URLSearchParams({ email }).toString(),
  });
  return {
    request,
    url: new URL('http://localhost:8787/auth/login'),
    locals: {
      supabase,
      cfContext: {
        waitUntil(promise: Promise<unknown>) {
          background.push(promise);
        },
      },
    },
    redirect(location: string, status = 302) {
      return new Response(null, { status, headers: { Location: location } });
    },
  };
}

// Everything a browser can observe about a response, in a comparable form.
async function observable(response: Response) {
  return {
    status: response.status,
    headers: [...response.headers.entries()].sort(),
    cookies: response.headers.getSetCookie(),
    body: await response.text(),
  };
}

afterEach(() => {
  limitersAllow = true;
});

describe('sign-in route answers before the provider settles', () => {
  test('returns the generic redirect while the provider call is still pending', async () => {
    let release!: (result: ProviderResult) => void;
    const pending = new Promise<ProviderResult>((resolve) => {
      release = resolve;
    });
    const supabase = fakeSupabase(() => pending);
    const background: Promise<unknown>[] = [];

    // If the route awaited the provider, this call would never return and the
    // test would fail by timeout. That is the regression this test guards.
    const response = await POST(context(EMAIL, supabase, background) as never);

    expect(response.status).toBe(303);
    expect(response.headers.get('location')).toBe('/login-sent');
    expect(supabase.calls).toEqual([
      {
        email: EMAIL,
        options: {
          shouldCreateUser: false,
          emailRedirectTo: 'http://localhost:8787/auth/confirm',
        },
      },
    ]);
    expect(background).toHaveLength(1);

    release({ error: { status: 422, code: 'otp_disabled' } });
    await Promise.all(background);
  }, 5_000);
});

describe('known, unknown, and failed sends look the same to the caller', () => {
  test('success, unknown address, provider failure, and a thrown error are byte-identical', async () => {
    const outcomes: (() => Promise<ProviderResult>)[] = [
      async () => ({ error: null }),
      async () => ({ error: { status: 422, code: 'otp_disabled' } }),
      async () => ({ error: { status: 500, code: 'unexpected_failure' } }),
      async () => {
        throw new Error('network down');
      },
    ];
    const seen = [];
    for (const provider of outcomes) {
      const background: Promise<unknown>[] = [];
      const response = await POST(
        context(EMAIL, fakeSupabase(provider), background) as never,
      );
      await Promise.all(background);
      seen.push(await observable(response));
    }
    for (const other of seen.slice(1)) expect(other).toEqual(seen[0]);
    expect(seen[0]).toEqual({
      status: 303,
      headers: [['location', '/login-sent']],
      cookies: [],
      body: '',
    });
  });
});

describe('provider failures are logged without the address', () => {
  test('a failed send logs its category and status, never the email', async () => {
    const errors = spyOn(console, 'error').mockImplementation(() => {});
    try {
      const background: Promise<unknown>[] = [];
      await POST(
        context(
          EMAIL,
          fakeSupabase(async () => ({
            error: { status: 500, code: 'unexpected_failure' },
          })),
          background,
        ) as never,
      );
      await Promise.all(background);
      expect(errors).toHaveBeenCalledWith('auth_otp_provider_unavailable', {
        status: 500,
        code: 'unexpected_failure',
      });
      const logged = JSON.stringify(errors.mock.calls);
      expect(logged).not.toContain(EMAIL);
    } finally {
      errors.mockRestore();
    }
  });

  test('an unknown address is an expected rejection, not a logged failure', async () => {
    const errors = spyOn(console, 'error').mockImplementation(() => {});
    try {
      const background: Promise<unknown>[] = [];
      await POST(
        context(
          EMAIL,
          fakeSupabase(async () => ({
            error: { status: 422, code: 'otp_disabled' },
          })),
          background,
        ) as never,
      );
      await Promise.all(background);
      expect(errors).not.toHaveBeenCalled();
    } finally {
      errors.mockRestore();
    }
  });
});

describe('rate limits stay synchronous', () => {
  test('a limited request never reaches the provider', async () => {
    limitersAllow = false;
    const supabase = fakeSupabase(async () => ({ error: null }));
    const background: Promise<unknown>[] = [];
    const response = await POST(context(EMAIL, supabase, background) as never);
    expect(response.headers.get('location')).toBe('/login?error=rate');
    expect(supabase.calls).toHaveLength(0);
    expect(background).toHaveLength(0);
  });
});
