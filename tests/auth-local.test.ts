import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

// Sign-in against the local Supabase CLI stack, end to end. It runs only when
// NETEOC_AUTH_E2E=1, because it needs the running stack, Docker, and a built
// Worker. `bun run test:auth-local` does all three. CI does not run it.
//
// The Worker listens on the Site URL port that supabase/config.toml and
// docs/auth-setup.md name, so the redirect allow list matches exactly. Codes are
// read from Mailpit. The database is used only to read, or backdate, rows that
// GoTrue owns. Expiry and timebox are therefore proven without waiting.

const enabled = process.env.NETEOC_AUTH_E2E === '1';
const ORIGIN = 'http://localhost:8787';
const MAILPIT = 'http://127.0.0.1:54324';
const DB_CONTAINER = 'supabase_db_neteoc';
const SUPABASE = 'http://127.0.0.1:54321';
const KNOWN = 'member@example.test';
const SESSION_COOKIE = /^sb-[A-Za-z0-9]+-auth-token(\.\d+)?$/;
const CLIENT = '198.51.100.77';

let worker: ChildProcess | undefined;
let configDir: string | undefined;

// Read-only or backdating SQL against the local database only. Throws on error.
function sql(query: string): string {
  return execFileSync(
    'docker',
    [
      'exec',
      DB_CONTAINER,
      'psql',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-v',
      'ON_ERROR_STOP=1',
      '-tAc',
      query,
    ],
    { encoding: 'utf8' },
  ).trim();
}

function userId(email: string): string {
  const id = sql(`select id from auth.users where email = '${email}'`);
  if (!id) throw new Error(`no synthetic user ${email} in the local stack`);
  return id;
}

// The cookies one browser would keep. A new Jar is a different browser.
class Jar {
  cookies = new Map<string, string>();

  header(): string {
    return [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; ');
  }

  absorb(response: Response) {
    for (const raw of response.headers.getSetCookie()) {
      const pair = raw.split(';', 1)[0];
      const index = pair.indexOf('=');
      const name = pair.slice(0, index);
      if (/Expires=Thu, 01 Jan 1970/.test(raw)) this.cookies.delete(name);
      else this.cookies.set(name, pair.slice(index + 1));
    }
  }

  session(): { name: string; value: string } | undefined {
    const found = [...this.cookies].find(([name]) => SESSION_COOKIE.test(name));
    return found ? { name: found[0], value: found[1] } : undefined;
  }
}

interface CallOptions {
  method?: string;
  jar?: Jar;
  form?: Record<string, string>;
  origin?: string;
  client?: string;
}

async function call(pathname: string, options: CallOptions = {}) {
  const headers: Record<string, string> = {
    Origin: options.origin ?? ORIGIN,
    'CF-Connecting-IP': options.client ?? CLIENT,
  };
  if (options.jar && options.jar.header())
    headers.Cookie = options.jar.header();
  let body: string | undefined;
  if (options.form) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    body = new URLSearchParams(options.form).toString();
  }
  const response = await fetch(`${ORIGIN}${pathname}`, {
    method: options.method ?? (body === undefined ? 'GET' : 'POST'),
    headers,
    body,
    redirect: 'manual',
    signal: AbortSignal.timeout(15_000),
  });
  options.jar?.absorb(response);
  return response;
}

const location = (response: Response) => response.headers.get('location') ?? '';
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Asserts the attributes a real session Set-Cookie must carry.
function expectSessionAttributes(raw: string) {
  expect(raw).toMatch(/;\s*HttpOnly(;|$)/);
  expect(raw).toMatch(/;\s*Secure(;|$)/);
  expect(raw).toMatch(/;\s*SameSite=Lax(;|$)/);
  expect(raw).toMatch(/;\s*Path=\/(;|$)/);
  expect(raw).toMatch(/;\s*Max-Age=604800(;|$)/);
}

function sessionSetCookies(response: Response): string[] {
  return response.headers
    .getSetCookie()
    .filter((raw) => SESSION_COOKIE.test(raw.split('=', 1)[0]));
}

// @supabase/ssr stores the session as "base64-" plus base64url JSON.
function decodeSession(value: string): Record<string, unknown> {
  if (!value.startsWith('base64-'))
    throw new Error('unexpected session cookie encoding');
  return JSON.parse(Buffer.from(value.slice(7), 'base64url').toString('utf8'));
}

function encodeSession(session: Record<string, unknown>): string {
  return `base64-${Buffer.from(JSON.stringify(session), 'utf8').toString('base64url')}`;
}

// Makes the stored session look expired, so the next request must refresh it
// with the real refresh token. Nothing is forged: GoTrue still judges the token.
function expireSessionLocally(jar: Jar) {
  const session = jar.session();
  if (!session) throw new Error('no session cookie to expire');
  if (session.name !== 'sb-127-auth-token')
    throw new Error('session is chunked; this helper expects one cookie');
  const decoded = decodeSession(session.value);
  decoded.expires_at = 1;
  jar.cookies.set(session.name, encodeSession(decoded));
}

interface MailpitMessage {
  ID: string;
  To: { Address: string }[];
}

async function mailpitIds(): Promise<Set<string>> {
  const response = await fetch(`${MAILPIT}/api/v1/messages?limit=200`);
  const body = (await response.json()) as { messages?: MailpitMessage[] };
  return new Set((body.messages ?? []).map((m) => m.ID));
}

async function newestMessageTo(
  email: string,
  seen: Set<string>,
): Promise<string | undefined> {
  const response = await fetch(`${MAILPIT}/api/v1/messages?limit=200`);
  const body = (await response.json()) as { messages?: MailpitMessage[] };
  return (body.messages ?? []).find(
    (m) => !seen.has(m.ID) && m.To.some((t) => t.Address === email),
  )?.ID;
}

async function codeFromMessage(id: string): Promise<string> {
  const response = await fetch(`${MAILPIT}/api/v1/message/${id}`);
  const message = (await response.json()) as { HTML: string; Subject: string };
  const match = message.HTML.match(/<strong>([^<]*)<\/strong>/);
  return match?.[1] ?? '';
}

// Requests a code and returns the one Mailpit delivers. Every send replaces the
// previous code for the address. GoTrue's one-second spacing and the Worker's
// per-address limit both surface as a redirect, so a send is retried until mail
// arrives.
async function sendCode(email: string, jar: Jar): Promise<string> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const seen = await mailpitIds();
    const response = await call('/auth/login', { jar, form: { email } });
    const target = location(response);
    if (target.includes('error=rate')) {
      await sleep(13_000);
      continue;
    }
    if (target.includes('error='))
      throw new Error(`sign-in refused: ${target}`);
    for (let poll = 0; poll < 25; poll++) {
      const id = await newestMessageTo(email, seen);
      if (id) return codeFromMessage(id);
      await sleep(200);
    }
    await sleep(1_500);
  }
  throw new Error(`no sign-in email arrived for ${email}`);
}

async function confirm(
  email: string,
  token: string,
  jar: Jar,
  origin?: string,
): Promise<Response> {
  return call('/auth/confirm', { jar, form: { email, token }, origin });
}

// One complete sign-in in its own browser: request, read, confirm.
async function signIn(): Promise<Jar> {
  const jar = new Jar();
  const code = await sendCode(KNOWN, jar);
  const response = await confirm(KNOWN, code, jar);
  expect(location(response)).toBe('/app');
  expect(jar.session()).toBeDefined();
  return jar;
}

async function protectedStatus(jar: Jar) {
  return call('/app', { jar });
}

describe.skipIf(!enabled)('email code sign-in against local Supabase', () => {
  beforeAll(async () => {
    configDir = await mkdtemp(path.join(tmpdir(), 'neteoc-auth-e2e-'));
    worker = spawn(
      'node',
      [
        'node_modules/wrangler/bin/wrangler.js',
        'dev',
        '--ip',
        '127.0.0.1',
        '--port',
        '8787',
      ],
      {
        cwd: process.cwd(),
        env: { ...process.env, XDG_CONFIG_HOME: configDir },
        stdio: 'ignore',
      },
    );
    for (let i = 0; i < 300; i++) {
      try {
        if ((await fetch(`${ORIGIN}/`)).status === 200) return;
      } catch {
        // Wrangler is still starting.
      }
      await sleep(200);
    }
    throw new Error('Worker did not answer on the Site URL port');
  }, 90_000);

  afterAll(async () => {
    worker?.kill();
    if (configDir) await rm(configDir, { recursive: true, force: true });
  });

  test('live Auth settings match the access model', async () => {
    const env = await readFile(path.join(process.cwd(), '.dev.vars'), 'utf8');
    const key = env.match(/^SUPABASE_PUBLISHABLE_KEY=(.+)$/m)?.[1]?.trim();
    expect(key).toBeDefined();
    const settings = (await (
      await fetch(`${SUPABASE}/auth/v1/settings`, {
        headers: { apikey: key ?? '' },
      })
    ).json()) as { disable_signup: boolean; external: { email: boolean } };
    // [auth] enable_signup = false, and [auth.email] enable_signup = true.
    expect(settings.disable_signup).toBe(true);
    expect(settings.external.email).toBe(true);
  }, 30_000);

  test('the sign-in email carries an eight-digit code and no sign-in link', async () => {
    const jar = new Jar();
    const seen = await mailpitIds();
    const response = await call('/auth/login', {
      jar,
      form: { email: KNOWN },
    });
    expect(location(response)).toBe('/login-sent');
    let id: string | undefined;
    for (let poll = 0; poll < 25 && !id; poll++) {
      id = await newestMessageTo(KNOWN, seen);
      if (!id) await sleep(200);
    }
    expect(id).toBeDefined();
    const message = (await (
      await fetch(`${MAILPIT}/api/v1/message/${id}`)
    ).json()) as { HTML: string; Subject: string };
    expect(message.Subject).toBe('Your NetEOC sign-in code');
    expect(message.HTML).toMatch(/<strong>\d{8}<\/strong>/);
    expect(message.HTML).toContain(`${ORIGIN}/auth/confirm`);
    // A token-bearing link would let a scanner consume the sign-in.
    expect(message.HTML).not.toContain('/auth/v1/verify');
    expect(message.HTML).not.toMatch(/token=/);
  }, 60_000);

  test('a scanner GET of the confirmation page does not consume the code', async () => {
    const browser = new Jar();
    const scanner = new Jar();
    const code = await sendCode(KNOWN, browser);
    const preview = await call(
      `/auth/confirm?email=${encodeURIComponent(KNOWN)}&token=${code}`,
      { jar: scanner },
    );
    expect(preview.status).toBe(200);
    expect(preview.headers.getSetCookie()).toEqual([]);
    expect(await preview.text()).not.toContain(code);
    const response = await confirm(KNOWN, code, browser);
    expect(location(response)).toBe('/app');
    const session = sessionSetCookies(response);
    expect(session.length).toBeGreaterThan(0);
    for (const raw of session) expectSessionAttributes(raw);
  }, 120_000);

  test('a code requested in one browser confirms in another', async () => {
    const requester = new Jar();
    const confirmer = new Jar();
    const code = await sendCode(KNOWN, requester);
    expect(requester.header()).toContain('code-verifier');
    expect(confirmer.header()).toBe('');
    const response = await confirm(KNOWN, code, confirmer);
    expect(location(response)).toBe('/app');
    expect(confirmer.session()).toBeDefined();
  }, 120_000);

  test('a wrong code fails and sets no session', async () => {
    const jar = new Jar();
    const code = await sendCode(KNOWN, jar);
    const wrong = code.slice(0, 7) + ((Number(code[7]) + 1) % 10).toString();
    const response = await confirm(KNOWN, wrong, jar);
    expect(location(response)).toBe('/auth/confirm?error=invalid');
    expect(sessionSetCookies(response)).toEqual([]);
    expect(jar.session()).toBeUndefined();
  }, 120_000);

  test('an expired code fails safely; expiry is 600 seconds from issue', async () => {
    const jar = new Jar();
    const code = await sendCode(KNOWN, jar);
    const id = userId(KNOWN);
    const lifetime = Number(
      sql(
        `select extract(epoch from (expires_at - (created_at at time zone 'UTC')))::int from auth.one_time_tokens where user_id = '${id}' order by created_at desc limit 1`,
      ),
    );
    expect(lifetime).toBe(600);
    sql(
      `update auth.one_time_tokens set expires_at = now() - interval '1 second' where user_id = '${id}'`,
    );
    const response = await confirm(KNOWN, code, jar);
    expect(location(response)).toBe('/auth/confirm?error=invalid');
    expect(sessionSetCookies(response)).toEqual([]);
  }, 120_000);

  test('cross-origin confirmation is refused and leaves the code usable', async () => {
    const jar = new Jar();
    const code = await sendCode(KNOWN, jar);
    const refused = await confirm(KNOWN, code, jar, 'https://attacker.example');
    expect(refused.status).toBe(403);
    expect(sessionSetCookies(refused)).toEqual([]);
    const response = await confirm(KNOWN, code, jar);
    expect(location(response)).toBe('/app');
  }, 120_000);

  test('known and unknown addresses get the same status, redirect, headers and cookies', async () => {
    const normalize = (response: Response) => ({
      status: response.status,
      location: location(response),
      headers: [
        'cache-control',
        'expires',
        'pragma',
        'x-robots-tag',
        'referrer-policy',
      ].map((name) => `${name}: ${response.headers.get(name)}`),
      cookies: response.headers
        .getSetCookie()
        .map((raw) =>
          raw
            .replace(/flow-[0-9a-f]+-/g, 'flow-ID-')
            .replace(/^([^=]+)=[^;]*/, '$1=<value>'),
        )
        .sort(),
    });
    const known = await call('/auth/login', {
      jar: new Jar(),
      form: { email: KNOWN },
    });
    const unknown = await call('/auth/login', {
      jar: new Jar(),
      form: { email: `nobody-${crypto.randomUUID()}@example.test` },
    });
    expect(normalize(unknown)).toEqual(normalize(known));
    expect(await unknown.text()).toBe(await known.text());
  }, 120_000);

  test('malformed and boundary email inputs never produce a server error', async () => {
    const cases: [string, string][] = [
      ['', '/login?error=invalid'],
      ['   ', '/login?error=invalid'],
      ['a'.repeat(309) + '@example.test', '/login?error=invalid'],
      ['probe@example', '/login?error=invalid'],
      ['pro be@example.test', '/login?error=invalid'],
      ['probe\u0000@example.test', '/login-sent'],
      ['ünïcode-probe@exämple.test', '/login-sent'],
      ['probe+tag@example.test', '/login-sent'],
    ];
    for (const [email, expected] of cases) {
      const response = await call('/auth/login', {
        form: { email },
        client: `198.51.100.${Math.floor(Math.random() * 200)}`,
      });
      expect(response.status).toBe(303);
      expect({ email, location: location(response) }).toEqual({
        email,
        location: expected,
      });
    }
  }, 120_000);

  test('malformed codes are refused before confirmation and set no session', async () => {
    const jar = new Jar();
    for (const token of ['1234567', '123456789', '1234abcd', '1234 5678']) {
      const response = await confirm(KNOWN, token, jar);
      expect(location(response)).toBe('/auth/confirm?error=invalid');
    }
    expect(jar.session()).toBeUndefined();
  }, 60_000);

  test('/api routes refuse without a session and serve with one', async () => {
    const featureRoute =
      '/api/v1/layers/00000000-0000-4000-8000-000000000001/features';
    const anonymous = await call(featureRoute);
    expect(anonymous.status).toBe(401);
    expect(anonymous.headers.get('cache-control')).toBe('private, no-store');
    expect(await anonymous.json()).toEqual({
      error: { code: 'not_authenticated', message: 'Sign in to continue.' },
    });

    const jar = await signIn();
    const signedIn = await call(featureRoute, { jar });
    expect(signedIn.status).not.toBe(401);
    expect(signedIn.headers.get('cache-control')).toBe('private, no-store');
  }, 180_000);

  test('GET requests never change session state', async () => {
    const jar = await signIn();
    const before = jar.header();
    const logoutGet = await call('/auth/logout', { jar });
    expect(logoutGet.status).toBe(404);
    expect(logoutGet.headers.getSetCookie()).toEqual([]);
    expect(jar.header()).toBe(before);
    expect((await protectedStatus(jar)).status).toBe(200);
  }, 180_000);

  test('an expired access token refreshes with the stored refresh token', async () => {
    const jar = await signIn();
    const oldSession = jar.session();
    expect(oldSession).toBeDefined();
    const oldAccess = decodeSession(oldSession?.value ?? '').access_token;
    expireSessionLocally(jar);
    const response = await protectedStatus(jar);
    expect(response.status).toBe(200);
    const refreshed = sessionSetCookies(response);
    expect(refreshed.length).toBeGreaterThan(0);
    for (const raw of refreshed) expectSessionAttributes(raw);
    jar.absorb(response);
    const newAccess = decodeSession(jar.session()?.value ?? '').access_token;
    expect(newAccess).toBeDefined();
    expect(newAccess).not.toBe(oldAccess);
  }, 180_000);

  test('the session timebox is 168 hours from sign-in, as configured', async () => {
    await signIn();
    const id = userId(KNOWN);
    const lifetime = Number(
      sql(
        `select extract(epoch from (not_after - created_at))::int from auth.sessions where user_id = '${id}' order by created_at desc limit 1`,
      ),
    );
    expect(lifetime).toBe(604800);
  }, 180_000);

  test('a session past its timebox does not refresh', async () => {
    const jar = await signIn();
    const id = userId(KNOWN);
    sql(
      `update auth.sessions set not_after = now() - interval '1 second' where id = (select id from auth.sessions where user_id = '${id}' order by created_at desc limit 1)`,
    );
    expireSessionLocally(jar);
    const response = await protectedStatus(jar);
    expect(response.status).toBe(302);
    expect(location(response)).toBe('/login');
    expect(sessionSetCookies(response)).toEqual([]);
  }, 180_000);

  test('sign-out removes the session cookies with their attributes', async () => {
    const jar = await signIn();
    const response = await call('/auth/logout', {
      jar,
      method: 'POST',
      form: {},
    });
    expect(location(response)).toBe('/login');
    const cleared = response.headers
      .getSetCookie()
      .filter((raw) => SESSION_COOKIE.test(raw.split('=', 1)[0]));
    expect(cleared.length).toBeGreaterThan(0);
    for (const raw of cleared) {
      expect(raw).toMatch(/Expires=Thu, 01 Jan 1970/);
      expect(raw).toMatch(/;\s*HttpOnly(;|$)/);
      expect(raw).toMatch(/;\s*Secure(;|$)/);
      expect(raw).toMatch(/;\s*SameSite=Lax(;|$)/);
    }
    expect(jar.session()).toBeUndefined();
    expect((await protectedStatus(jar)).headers.get('location')).toBe('/login');
  }, 180_000);
});
