import { beforeEach, describe, expect, mock, test } from 'bun:test';

// The middleware imports Astro and Cloudflare modules that Bun cannot load, so
// the test replaces them with a fake Supabase client. The middleware itself runs
// unchanged, and `next()` stands in for a route that returns data. The point is
// that the middleware refuses before any route can answer.
let supabase: unknown = null;

mock.module('astro:middleware', () => ({
  defineMiddleware: (handler: unknown) => handler,
}));
mock.module('../src/lib/supabase', () => ({
  createSupabaseClient: () => supabase,
}));

const { onRequest } = (await import('../src/middleware')) as {
  onRequest: (
    context: unknown,
    next: () => Promise<Response>,
  ) => Promise<Response>;
};

const verified = {
  auth: {
    getClaims: async () => ({ data: { claims: { sub: 'u' } }, error: null }),
  },
};

function context(path: string) {
  return {
    url: new URL(`https://neteoc.example${path}`),
    request: new Request(`https://neteoc.example${path}`),
    cookies: { set() {}, delete() {} },
    locals: {},
    redirect(location: string, status = 302) {
      return new Response(null, { status, headers: { Location: location } });
    },
  };
}

let routeCalls = 0;
async function leakyRoute() {
  routeCalls++;
  return new Response('{"features":[{"id":"secret"}]}', {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function run(path: string) {
  routeCalls = 0;
  const response = await onRequest(context(path), leakyRoute);
  return { response, body: await response.text(), routeCalls };
}

function expectPrivate(response: Response) {
  expect(response.headers.get('Cache-Control')).toBe('private, no-store');
  expect(response.headers.get('X-Robots-Tag')).toBe('noindex');
  expect(response.headers.get('Referrer-Policy')).toBe('no-referrer');
}

describe('middleware /api gate', () => {
  beforeEach(() => {
    supabase = null;
  });

  test('refuses an unauthenticated API read before the route runs', async () => {
    supabase = {
      auth: { getClaims: async () => ({ data: null, error: null }) },
    };
    const {
      response,
      body,
      routeCalls: calls,
    } = await run(
      '/api/v1/layers/00000000-0000-4000-8000-000000000001/features',
    );
    expect(response.status).toBe(401);
    expect(calls).toBe(0);
    expect(body).not.toContain('secret');
    expect(response.headers.get('Content-Type')).toBe(
      'application/json; charset=utf-8',
    );
    expect(JSON.parse(body)).toEqual({
      error: { code: 'not_authenticated', message: 'Sign in to continue.' },
    });
    expectPrivate(response);
    expect(response.headers.get('Expires')).toBe('0');
    expect(response.headers.get('Pragma')).toBe('no-cache');
  });

  test('refuses when claim verification reports an error', async () => {
    supabase = {
      auth: {
        getClaims: async () => ({ data: null, error: { status: 401 } }),
      },
    };
    const { response, routeCalls: calls } = await run('/api/v1/anything');
    expect(response.status).toBe(401);
    expect(calls).toBe(0);
  });

  test('fails closed when claim verification throws', async () => {
    supabase = {
      auth: {
        getClaims: async () => {
          throw new Error('network');
        },
      },
    };
    const { response, routeCalls: calls } = await run('/api/v1/anything');
    expect(response.status).toBe(401);
    expect(calls).toBe(0);
  });

  test('fails closed when Supabase is not configured', async () => {
    supabase = null;
    const { response, routeCalls: calls } = await run('/api/v1/anything');
    expect(response.status).toBe(401);
    expect(calls).toBe(0);
  });

  test('passes a verified session through with private headers', async () => {
    supabase = verified;
    const { response, body, routeCalls: calls } = await run('/api/v1/anything');
    expect(response.status).toBe(200);
    expect(calls).toBe(1);
    expect(body).toContain('secret');
    expectPrivate(response);
  });
});

describe('middleware protected pages', () => {
  test('redirects an unauthenticated workspace request to login', async () => {
    supabase = null;
    const { response, routeCalls: calls } = await run('/app');
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe('/login');
    expect(calls).toBe(0);
    expectPrivate(response);
  });

  test('passes a verified workspace request through', async () => {
    supabase = verified;
    const { response, routeCalls: calls } = await run('/app/example');
    expect(response.status).toBe(200);
    expect(calls).toBe(1);
  });
});

describe('middleware scope', () => {
  test('leaves public pages alone', async () => {
    supabase = null;
    const { response, routeCalls: calls } = await run('/');
    expect(calls).toBe(1);
    expect(response.headers.get('Cache-Control')).toBeNull();
  });
});
