import { spawnSync } from 'node:child_process';
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  existsSync,
  readFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  return result;
}

function names(args) {
  const result = run('git', args, { encoding: 'buffer' });
  if (result.status !== 0) throw new Error('Unable to enumerate Git files');
  return result.stdout.toString('utf8').split('\0').filter(Boolean);
}

function scan(source, binary) {
  const args = [
    source,
    '--no-verification',
    '--no-update',
    '--json',
    '--fail-on-scan-errors',
  ];
  if (source === 'filesystem') args.push(binary.path);
  else args.push(`file://${process.cwd()}`);
  const result = run(binary.command, args);
  if (result.status !== 0)
    throw new Error(`TruffleHog failed with exit code ${result.status}`);
  const findings = result.stdout
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  for (const finding of findings) {
    const type = finding.DetectorName || 'unknown type';
    const location =
      finding.SourceMetadata?.Data?.Filesystem?.file ||
      finding.SourceMetadata?.Data?.Git?.file ||
      'unknown file';
    console.error(`Possible secret: ${type} in ${location}`);
  }
  if (findings.length)
    throw new Error(`${findings.length} possible secret(s) found`);
  console.log(`Secret scan (${source}): OK`);
}

const mode = process.argv[2];
if (!['staged', 'tree', 'history'].includes(mode))
  throw new Error('Expected staged, tree, or history');
const binary = {
  command: existsSync('.tools/bin/trufflehog')
    ? path.resolve('.tools/bin/trufflehog')
    : 'trufflehog',
};
let temporary;
try {
  if (mode === 'history') scan('git', binary);
  else {
    temporary = mkdtempSync(path.join(os.tmpdir(), 'neteoc-secrets-'));
    const files =
      mode === 'staged'
        ? names(['diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z'])
        : names([
            'ls-files',
            '--cached',
            '--others',
            '--exclude-standard',
            '-z',
          ]);
    for (const file of files) {
      if (path.isAbsolute(file) || file.split(/[\\/]/).includes('..'))
        throw new Error('Unsafe Git path');
      const contents =
        mode === 'staged'
          ? run('git', ['show', `:${file}`], { encoding: 'buffer' })
          : null;
      if (contents && contents.status !== 0)
        throw new Error(`Unable to read staged file ${file}`);
      const destination = path.join(temporary, file);
      mkdirSync(path.dirname(destination), { recursive: true });
      if (contents) writeFileSync(destination, contents.stdout);
      else {
        if (!existsSync(file)) continue;
        writeFileSync(destination, readFileSync(file));
      }
    }
    scan('filesystem', { ...binary, path: temporary });
  }
} finally {
  if (temporary) rmSync(temporary, { recursive: true, force: true });
}
