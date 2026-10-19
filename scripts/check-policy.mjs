import { readFileSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import YAML from 'yaml';

export function inspectWorkflow(source, filename) {
  const errors = [];
  let workflow;
  try {
    workflow = YAML.parse(source, { uniqueKeys: true });
  } catch (error) {
    return [`${filename}: invalid YAML: ${error.message}`];
  }
  if (!workflow || typeof workflow !== 'object') {
    return [`${filename}: expected a workflow object`];
  }
  if (!workflow.permissions || typeof workflow.permissions !== 'object') {
    errors.push(`${filename}: declare least-privilege workflow permissions`);
  }
  if (!workflow.jobs || typeof workflow.jobs !== 'object') {
    errors.push(`${filename}: no jobs declared`);
    return errors;
  }
  for (const [jobName, job] of Object.entries(workflow.jobs)) {
    for (const [index, step] of (job.steps || []).entries()) {
      if (!step.uses) continue;
      const id = `${filename}: jobs.${jobName}.steps[${index}]`;
      if (
        typeof step.uses !== 'string' ||
        !/^[\w.-]+\/[\w.-]+(?:\/[\w.-]+)*@[0-9a-f]{40}$/.test(step.uses)
      ) {
        errors.push(
          `${id}: use an action pinned to a full 40-character commit SHA`,
        );
      }
    }
  }
  return errors;
}

export function inspectPackage(pkg) {
  const errors = [];
  if (!pkg.packageManager?.startsWith('bun@'))
    errors.push('package.json: packageManager must pin Bun');
  if (!pkg.engines?.bun) errors.push('package.json: engines.bun is required');
  for (const [kind, deps] of Object.entries({
    dependencies: pkg.dependencies || {},
    devDependencies: pkg.devDependencies || {},
  })) {
    for (const [name, version] of Object.entries(deps)) {
      if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(version))
        errors.push(`package.json: ${kind}.${name} must use an exact version`);
    }
  }
  return errors;
}

function main() {
  const failures = inspectPackage(
    JSON.parse(readFileSync('package.json', 'utf8')),
  );
  if (!existsSync('bun.lock')) failures.push('bun.lock: required');
  for (const file of [
    'AGENTS.md',
    'docs/project-context.md',
    'docs/prd.md',
    'docs/development-plan.md',
    'docs/research.md',
    'docs/security.md',
  ]) {
    if (!existsSync(file)) failures.push(`${file}: required`);
  }
  const dir = '.github/workflows';
  if (!existsSync(dir)) failures.push(`${dir}: required`);
  else
    for (const file of readdirSync(dir).filter((name) =>
      /\.ya?ml$/.test(name),
    )) {
      const filename = path.join(dir, file);
      failures.push(
        ...inspectWorkflow(readFileSync(filename, 'utf8'), filename),
      );
    }
  if (failures.length) {
    for (const failure of failures) console.error(failure);
    process.exitCode = 1;
  } else console.log('Repository policy: OK');
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(import.meta.filename)
)
  main();
