# Development guidelines

## Local setup

Install [Bun 1.4.3](https://bun.sh/docs/installation) (see `.bun-version`),
Python 3, and Git. Local Worker preview and Worker type generation also require
Node.js 22 or later for the Wrangler CLI. This is a tooling exception: Bun
remains the package manager, script runner, and test runner. Run local preview
with `node node_modules/wrangler/bin/wrangler.js dev` and a writable
`XDG_CONFIG_HOME`; Wrangler does not support running its CLI under Bun. Keep the
Worker compatibility date no newer than the version supported by the locked
`workerd` package. Application code still targets Cloudflare Workers. On Linux
x86_64, run:

```sh
bun install --frozen-lockfile
bun run security:install
bun run check
bun run security:semgrep
bun run security:trivy
bun run secrets:tree
```

The first install activates Husky hooks. Security binaries are downloaded into
ignored `.tools/bin/` only after SHA-256 verification against
`scripts/tool-versions.json`. Semgrep is separately pinned in
`requirements-security.txt`; install in a Python virtual environment and ensure
`semgrep` is on `PATH`. CI does this automatically. On other systems, install
the same verified tool versions through a trusted package manager or add checked
archive hashes for that platform.

## Commit and pull request discipline

Follow
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):
`type(scope): imperative description` such as `docs: record MVP access model`.
Breaking changes use `!` or a `BREAKING CHANGE:` footer. Commitlint rejects bad
commit messages in the local `commit-msg` hook and CI checks every PR commit.
The PR title is also checked so squash merges remain conventional. The
`pre-commit` hook scans staged blobs for secrets, checks changed file formatting
and lint, and validates repository policy; `pre-push` runs the full local check.
Hooks can be skipped locally, so protected branch CI is the merge gate.

PRs should explain behavior, migration or access implications, and validation.
Keep scope small. Do not place credentials, live incident data, addresses of
real people, or private photos in fixtures. Use synthetic data. Never commit
`.env`, `.dev.vars`, private keys, or service-role keys. Treat third-party feed
content and linked documents as untrusted input.

## Source and test rules

Use strict TypeScript in future Astro application code; prefer explicit input
validation and generated database types. Keep runtime secrets in platform
bindings; only publishable Supabase keys may reach browsers. Avoid privileged
server clients for ordinary user operations. Test behavior and denial cases at
the access boundary. For edits, test cross-tenant access, visibility
transitions, revocation, direct storage URLs, and GIS export parity. Fail on
validation errors, show unsaved state, and instrument operations without logging
sensitive payloads.

Before adding a package or Action, check its current supported release and
license, use an exact package version, update `bun.lock`, and scan dependencies.
`bunfig.toml` requires newly resolved package versions to be at least six days
old (518,400 seconds). `bun.lock` was regenerated under this rule; frozen
installs continue to use its exact versions. Do not add blanket age-gate
exceptions for dependencies. Actions must have full 40-character SHA references
with version comments. Keep permissions at workflow/job minimum; untrusted PRs
get no deployment credentials. Run `actionlint` and policy checks when editing
workflows. Review dependency advisories and note the reason and expiry for any
exception.

Formatting: Prettier for JS, JSON, YAML, and Markdown; markdownlint for prose;
ESLint for JS; add `astro check`, TypeScript, and framework-aware lint when the
application lands. Bun is the developer runtime and package manager. The
Cloudflare deployment runtime is Workers; write Worker-compatible server code.

## Secrets and scans

`bun run secrets:staged` scans the exact staged blobs, including files that
differ from the working tree. `bun run secrets:tree` scans tracked files;
history scan covers existing Git commits. TruffleHog runs without remote
verification so suspected credentials are not sent to third-party verifiers. It
reports only paths and finding types through the wrapper, never credential
values. Trivy fails on high/critical vulnerabilities or misconfigurations.
Semgrep scans application code as it is added; custom rules guard known
dangerous patterns. A finding needs review or a narrow, documented exception,
not a broad ignore.
