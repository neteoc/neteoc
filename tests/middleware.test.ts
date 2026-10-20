import { beforeEach, describe, expect, mock, test } from 'bun:test';

// The middleware imports Astro and Cloudflare modules that Bun cannot load, so
// the test replaces them with a fake Supabase client. The middleware itself runs
// unchanged. `next()` stands in for a route. A `supabase` set to a function
// receives the cookie jar, so a test can simulate a session refresh the way
// @supabase/ssr writes it.
let supabase: unknown = null;

mock.module('astro:middleware', () => ({
  defineMiddleware: (handler: unknown) => handler,
}));
mock.module('../src/lib/supabase', () => ({
  createSupabaseClient: (_request: unknown, cookies: unknown) =>
    typeof supabase === 'function' ? supabase(cookies) : supabase,
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

const OWN = 'https://neteoc.example';

// Records Set-Cookie values the way Astro's cookie jar exposes them to adapters.
function jar() {
  const out = new Map<string, string>();
  return {
    set(name: string, value: string) {
      out.set(
        name,
        `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=lax; Max-Age=604800`,
      );
    },
    delete(name: string) {
      out.set(
        name,
        `${name}=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT`,
      );
    },
    *headers() {
      yield* out.values();
    },
  };
}

function context(path: string, init: RequestInit = {}, cookies = jar()) {
  return {
    url: new URL(`${OWN}${path}`),
    request: new Request(`${OWN}${path}`, init),
    cookies,
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
  beforeEach(() => {
    supabase = null;
  });

  test('redirects an unauthenticated workspace request to login', async () => {
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

describe('route failure keeps the headers and the rotated session', () => {
  async function throwingRoute() {
    routeCalls++;
    throw new Error('secret stack detail sb-127-auth-token=leaked');
  }

  test('a throwing route gets a generic 500 with the private headers', async () => {
    supabase = verified;
    routeCalls = 0;
    const response = await onRequest(
      context('/api/v1/anything'),
      throwingRoute,
    );
    expect(response.status).toBe(500);
    const body = await response.text();
    expect(body).toBe('Something went wrong.');
    expect(body).not.toContain('secret');
    expect(body).not.toContain('leaked');
    expectPrivate(response);
    expect(response.headers.get('X-Robots-Tag')).toBe('noindex');
    expect(routeCalls).toBe(1);
  });

  test('a session refreshed before the route throws stays in the jar Astro writes from', async () => {
    // Simulates @supabase/ssr refreshing during getClaims: it writes the rotated
    // session through the cookie jar the middleware passed in. Astro attaches that
    // jar to the response the middleware returns, and the adapter writes it. The
    // catch path must leave the jar intact and must not copy it, or the browser
    // would receive each Set-Cookie twice. Delivery is proven on the live Worker.
    supabase = (cookies: { set: (n: string, v: string) => void }) => ({
      auth: {
        getClaims: async () => {
          cookies.set('sb-127-auth-token', 'base64-rotated');
          return { data: { claims: { sub: 'u' } }, error: null };
        },
      },
    });
    const cookies = jar();
    routeCalls = 0;
    const response = await onRequest(
      context('/api/v1/anything', {}, cookies),
      throwingRoute,
    );
    expect(response.status).toBe(500);
    expect(await response.text()).toBe('Something went wrong.');
    expect(response.headers.getSetCookie()).toEqual([]);
    const written = [...cookies.headers()];
    expect(written).toHaveLength(1);
    expect(written[0]).toContain('sb-127-auth-token=base64-rotated');
    expect(written[0]).toContain('HttpOnly');
    expect(written[0]).toContain('Secure');
    expect(written[0]).toContain('SameSite=lax');
    expectPrivate(response);
  });
});

describe('origin checks on state-changing requests', () => {
  beforeEach(() => {
    supabase = null;
  });

  const routes = ['/auth/login', '/auth/confirm', '/auth/logout'];
  const types = [
    'application/x-www-form-urlencoded',
    'application/json',
    'multipart/form-data; boundary=x',
    'text/plain',
  ];
  const refused: [string, string | null, Record<string, string>][] = [
    ['Origin null', 'null', {}],
    ['lookalike host', 'https://neteoc.example.attacker.example', {}],
    ['another host', 'https://attacker.example', {}],
    ['another port', 'https://neteoc.example:8443', {}],
    ['another scheme', 'http://neteoc.example', {}],
    ['missing Origin', null, {}],
    ['cross-site Sec-Fetch-Site', OWN, { 'Sec-Fetch-Site': 'cross-site' }],
  ];

  function post(
    path: string,
    type: string,
    origin: string | null,
    extra: Record<string, string>,
  ) {
    const headers: Record<string, string> = { 'Content-Type': type, ...extra };
    if (origin !== null) headers.Origin = origin;
    return context(path, { method: 'POST', headers, body: '{}' });
  }

  for (const path of routes) {
    for (const type of types) {
      for (const [label, origin, extra] of refused) {
        test(`refuses ${label} on ${path} as ${type}`, async () => {
          let claimsChecks = 0;
          supabase = {
            auth: {
              getClaims: async () => {
                claimsChecks++;
                return { data: null, error: null };
              },
            },
          };
          routeCalls = 0;
          const response = await onRequest(
            post(path, type, origin, extra),
            leakyRoute,
          );
          // Which check refused: the 403 is from the Origin gate, before any
          // route, claim check, or cookie write.
          expect(response.status).toBe(403);
          expect(await response.text()).toBe('Forbidden');
          expect(routeCalls).toBe(0);
          expect(claimsChecks).toBe(0);
          expectPrivate(response);
        });
      }

      test(`accepts the same origin on ${path} as ${type}`, async () => {
        routeCalls = 0;
        const response = await onRequest(
          post(path, type, OWN, { 'Sec-Fetch-Site': 'same-origin' }),
          leakyRoute,
        );
        expect(response.status).toBe(200);
        expect(routeCalls).toBe(1);
      });
    }
  }

  test('a safe method is never refused for its Origin', async () => {
    routeCalls = 0;
    const response = await onRequest(
      context('/auth/login', {
        method: 'GET',
        headers: { Origin: 'https://attacker.example' },
      }),
      leakyRoute,
    );
    expect(response.status).toBe(200);
    expect(routeCalls).toBe(1);
  });
});

describe('public API allowlist', () => {
  test('starts empty, so every /api path is refused without a session', async () => {
    const { PUBLIC_API_PREFIXES, isPublicApiPath } =
      await import('../src/lib/public-api');
    expect(PUBLIC_API_PREFIXES).toEqual([]);
    expect(isPublicApiPath('/api/v1/layers/x/features')).toBe(false);
    expect(isPublicApiPath('/api/public')).toBe(false);
    supabase = null;
    const { response, routeCalls: calls } = await run(
      '/api/v1/layers/00000000-0000-4000-8000-000000000001/features',
    );
    expect(response.status).toBe(401);
    expect(calls).toBe(0);
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
