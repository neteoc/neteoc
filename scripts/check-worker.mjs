import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';

async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitForWorker(url, process) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (process.exitCode !== null)
      throw new Error('Worker preview exited before becoming ready');
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(1_000) });
      if (response.status === 200) return;
    } catch {
      // Wrangler is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Worker preview did not answer within 20 seconds');
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const port = await freePort();
const origin = `http://127.0.0.1:${port}`;
const configDir = await mkdtemp(path.join(tmpdir(), 'neteoc-worker-check-'));
await mkdir(configDir, { recursive: true });
const worker = spawn(
  process.execPath,
  [
    'node_modules/wrangler/bin/wrangler.js',
    'dev',
    '--ip',
    '127.0.0.1',
    '--port',
    String(port),
  ],
  {
    cwd: process.cwd(),
    env: { ...process.env, XDG_CONFIG_HOME: configDir },
    stdio: 'ignore',
  },
);

try {
  await waitForWorker(origin, worker);
  for (const route of ['/app', '/app/example']) {
    const response = await fetch(`${origin}${route}`, { redirect: 'manual' });
    assert(
      response.status === 302,
      `${route} must redirect unauthenticated users`,
    );
    assert(
      response.headers.get('location') === '/login',
      `${route} must redirect to login`,
    );
    assert(
      response.headers.get('cache-control') === 'private, no-store',
      `${route} must not be cached`,
    );
    assert(
      response.headers.get('x-robots-tag') === 'noindex',
      `${route} must not be indexed`,
    );
  }
  // Middleware refuses /api before any route runs, with the route's own 401 shape.
  const api = await fetch(
    `${origin}/api/v1/layers/00000000-0000-4000-8000-000000000001/features`,
  );
  assert(api.status === 401, '/api must refuse without a verified session');
  assert(
    api.headers.get('content-type') === 'application/json; charset=utf-8',
    '/api refusal must be JSON',
  );
  assert(
    api.headers.get('cache-control') === 'private, no-store',
    '/api refusal must not be cached',
  );
  assert(
    (await api.json()).error?.code === 'not_authenticated',
    '/api refusal must name not_authenticated',
  );
  const confirmPage = await fetch(`${origin}/auth/confirm`);
  assert(confirmPage.status === 200, 'confirmation form must render');
  const confirmHtml = await confirmPage.text();
  const loginPage = await fetch(`${origin}/login`);
  assert(loginPage.status === 200, 'password sign-in page must render');
  assert(
    /name="token"[^>]*pattern="\[0-9\]\{8\}"[^>]*maxlength="8"/.test(
      confirmHtml,
    ),
    'confirmation form must accept eight-digit codes',
  );
  for (const route of [
    '/auth/login',
    '/auth/request-code-submit',
    '/auth/confirm',
    '/auth/set-password',
  ]) {
    const response = await fetch(`${origin}${route}`, {
      method: 'POST',
      headers: {
        Origin: 'https://attacker.example',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'email=person%40example.org&token=123456',
      redirect: 'manual',
    });
    assert(
      response.status === 403,
      `${route} must reject cross-origin form POSTs`,
    );
  }
  console.log('Worker access boundary: OK');
} finally {
  worker.kill();
  await rm(configDir, { recursive: true, force: true });
}
