import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

// Fails if the built output carries a Supabase service-role credential. The
// check decodes JWT payloads and matches the secret-key shape, so no key value
// is written into this file. Browser assets under dist/client must contain no
// service-role term at all. The Worker code under dist/server may name the term
// in the vendored Supabase client's documentation, but never in a key.

const dist = path.resolve('dist');
const SECRET_KEY = /sb_secret_[A-Za-z0-9_-]{16,}/;
const JWT = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g;
const failures = [];

async function* files(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* files(full);
    else yield full;
  }
}

function serviceRoleJwt(token) {
  const payload = token.split('.')[1];
  try {
    const claims = JSON.parse(
      Buffer.from(payload, 'base64url').toString('utf8'),
    );
    return claims.role === 'service_role';
  } catch {
    return false;
  }
}

let scanned = 0;
let serviceWordHits = 0;
for await (const file of files(dist)) {
  scanned++;
  const relative = path.relative(dist, file);
  const text = (await readFile(file)).toString('latin1');
  if (SECRET_KEY.test(text)) failures.push(`${relative}: secret-key value`);
  for (const token of text.match(JWT) ?? []) {
    if (serviceRoleJwt(token)) {
      failures.push(`${relative}: service-role JWT`);
      break;
    }
  }
  if (relative.startsWith(`client${path.sep}`)) {
    if (/service_role/.test(text))
      failures.push(`${relative}: service_role in browser asset`);
    if (
      path.basename(relative).startsWith('.env') ||
      path.basename(relative) === '.dev.vars'
    )
      failures.push(`${relative}: environment file in browser assets`);
  } else if (/service_role/.test(text)) {
    serviceWordHits++;
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(failure);
  throw new Error(`service-role material found in ${failures.length} place(s)`);
}
console.log(
  `Bundle check: OK (${scanned} files; service_role documentation words in server code: ${serviceWordHits} files)`,
);
