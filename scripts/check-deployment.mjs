const base = process.argv[2];
if (!base || !/^https:\/\/[^/?#]+\/?$/.test(base)) {
  throw new Error('Pass an HTTPS staging origin with no path');
}

const origin = base.replace(/\/$/, '');

async function request(path, options = {}) {
  const response = await fetch(`${origin}${path}`, {
    ...options,
    redirect: 'manual',
    signal: AbortSignal.timeout(10_000),
  });
  return response;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

let publicPage;
for (let attempt = 0; attempt < 6; attempt++) {
  try {
    publicPage = await request('/');
    if (publicPage.status === 200) break;
  } catch {
    // A new Worker deployment may take a moment to become reachable.
  }
  await new Promise((resolve) => setTimeout(resolve, 2_000));
}
assert(publicPage?.status === 200, 'staging home page must return 200');
assert(
  (await publicPage.text()).includes('NetEOC'),
  'staging home page must contain the expected app',
);

const workspace = await request('/app');
assert(workspace.status === 302, 'anonymous workspace must redirect');
assert(
  workspace.headers.get('location') === '/login',
  'anonymous workspace must redirect to login',
);
assert(
  workspace.headers.get('cache-control') === 'private, no-store',
  'anonymous workspace must not be cached',
);
assert(
  workspace.headers.get('x-robots-tag') === 'noindex',
  'anonymous workspace must not be indexed',
);

const confirmation = await request('/auth/confirm');
assert(confirmation.status === 200, 'confirmation page must render');

for (const path of ['/auth/login', '/auth/confirm']) {
  const response = await request(path, {
    method: 'POST',
    headers: {
      Origin: 'https://attacker.example',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'email=person%40example.org&token=12345678',
  });
  assert(response.status === 403, `${path} must deny cross-origin writes`);
}

console.log('Hosted staging access boundary: OK');
