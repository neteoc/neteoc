import { execFileSync } from 'node:child_process';
import { lint } from 'markdownlint/promise';
import process from 'node:process';

const files = execFileSync(
  'git',
  ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
  {
    encoding: 'utf8',
  },
)
  .split('\0')
  .filter((file) => file.endsWith('.md'));
const result = await lint({
  files,
  config: { default: true, MD013: false, MD024: { siblings_only: true } },
});
const problems = Object.entries(result).flatMap(([file, errors]) =>
  errors.map(
    (error) =>
      `${file}:${error.lineNumber} ${error.ruleNames.join('/')} ${error.ruleDescription}`,
  ),
);
if (problems.length) {
  for (const problem of problems) console.error(problem);
  process.exitCode = 1;
} else console.log(`Markdown lint: OK (${files.length} files)`);
