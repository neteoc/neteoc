# Development guidelines

## Local setup

Install [Bun 1.4.3](https://bun.sh/docs/installation) (see `.bun-version`),
Python 3, and Git. Local Worker preview and Worker type generation also require
Node.js 22 or later for the Wrangler CLI. This is a tooling exception: Bun
remains the package manager, script runner, and test runner. The repo leaves
`[run] bun` unset in `bunfig.toml` so `bun run preview` and
`bun run types:worker` invoke Wrangler through real Node.js. Wrangler does not
support running its CLI under Bun. Give Wrangler a writable `XDG_CONFIG_HOME`
where the default config directory is read-only. `bun run check` builds the
Worker and starts a local Wrangler preview to test protected route redirects and
cross-origin POST denial. Keep the Worker compatibility date no newer than the
version supported by the locked `workerd` package. Application code still
targets Cloudflare Workers. On Linux x86_64, run:

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

## Local Supabase stack

`supabase/config.toml` configures the local Supabase CLI stack. Start it from
the repository root with `supabase start`, check it with `supabase status`, and
stop it with `supabase stop`. The local Postgres is `supabase/postgres`
17.11.0.004, which has the same PostgreSQL version (17.11) as NetEOC Dev's
17.11.0.003 build. That makes it the first verification target for
authentication (#7) and the SQL authorization work (#9). The local mail catcher
on `http://127.0.0.1:54324` receives every Auth email, so one-time codes can be
read without a real mailbox. No email leaves the machine.

The CLI's defaults are permissive, and this project overrides them deliberately.
`enable_signup` is `false` under `[auth]` because membership is invitation-only:
an unknown address gets a `422`, which is `otp_disabled` for the
`create_user: false` request the Worker sends (`signup_disabled` without that
flag). The sign-in route answers both with the redirect it uses for a sent code,
and an existing invited user still receives a code. Leave `enable_signup` under
`[auth.email]` set to `true`. That flag enables the email provider rather than
new-user signup, and turning it off fails every sign-in with
`422 email_provider_disabled`, including for existing users, which would disable
the only sign-in method this project has. The Site URL and redirect allow list
match the Worker preview origin, and the email OTP is eight digits with a
600-second expiry. Other defaults are inherited; `auto_expose_new_tables`
matches the hosted default, so migrations must still revoke explicitly.

Treat the running stack as untrusted on a shared network. The CLI publishes
Postgres, Studio, the API, and the mail catcher on every host interface, the
database password is the static `postgres`, and the printed keys, including the
service-role key, are well-known public demo values. They are for this stack
only. Copy the publishable key alone into the ignored `.dev.vars`. Never copy
the secret or service-role key anywhere in the repository or the Worker
configuration, never commit a key, and run `supabase stop` when you are not
using the stack.

The build writes a copy of `.dev.vars` into `dist/server/`. That copy is local
only, and the Worker's static assets come from `dist/client`, so it is not
deployed. `bun run check:bundle` scans all of `dist/` for service-role material
and fails on a secret-key value, so a secret key placed in `.dev.vars` still
fails the check.

## One worktree per issue

Start each issue in its own Git worktree instead of switching branches in the
main checkout:

```sh
git fetch origin
git worktree add ../neteoc-wt/<short-slug> -b <type>/<branch> origin/main
cd ../neteoc-wt/<short-slug>
bun install --frozen-lockfile
```

The install is required so the Husky hooks run there; without it a commit skips
the secret scan, formatting, and policy checks. Remove the worktree with
`git worktree remove ../neteoc-wt/<short-slug>` once its pull request merges.

This is not a style preference. Several agents share this repository, and the
one that reviews and merges works from the main checkout. With a single working
tree, a `git switch` or `git pull` for a review collides with whatever branch is
mid-change, and a review that checks out a pull request moves the tree out from
under in-progress work. Review a branch with `gh pr diff`, or in a worktree of
its own, rather than checking it out in the main checkout.

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
Once a database migration is applied to any shared project, treat that file as
immutable. Make subsequent changes in a new, forward-only migration so source
history matches the SQL that ran. The first `rls_auto_enable` migration is a
recorded exception: its source was guarded after application to NetEOC Dev so
fresh local databases without the bootstrap helper can run it. Its effect on
NetEOC Dev remains the same. Keep scope small. Do not place credentials, live
incident data, addresses of real people, or private photos in fixtures. Use
synthetic data. Never commit `.env`, `.dev.vars`, private keys, or service-role
keys. Treat third-party feed content and linked documents as untrusted input.

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
exceptions for dependencies. For an urgent fix to a specific security advisory,
an exact `name@version` entry in Bun's
[`minimumReleaseAgeExcludes`](https://bun.sh/docs/pm/cli/install#minimum-release-age)
may bypass the age gate after review. Record the advisory, reason, and expiry,
then remove the exception when the release reaches six days. Actions must have
full 40-character SHA references with version comments. Keep permissions at
workflow/job minimum; untrusted PRs get no deployment credentials. Run
`actionlint` and policy checks when editing workflows. Review dependency
advisories and note the reason and expiry for any exception.

Formatting: Prettier for JS, JSON, YAML, and Markdown; markdownlint for prose;
ESLint for JS; add `astro check`, TypeScript, and framework-aware lint when the
application lands. Bun is the developer runtime and package manager. The
Cloudflare deployment runtime is Workers; write Worker-compatible server code.

## Database version

The `tenant-rls` CI job runs the SQL authorization tests against PostgreSQL
17.11 (`postgis/postgis:17-3.6`, pinned by digest in
`.github/workflows/ci.yml`). NetEOC Dev runs PostgreSQL 17.11.0.003. CI tracks
the NetEOC Dev major version: when the project moves to a new major, update the
CI image digest and the server-version check in the same change, and rerun every
SQL test. Do not rely on the runner's preinstalled PostgreSQL, which changes
with the runner image.

The PostGIS image also installs PostGIS into the default database's `public`
schema. CI therefore runs the tests in a database created from `template0`,
which has no extensions, as a new Supabase project does. In a database where
PostGIS already exists elsewhere,
`create extension if not exists postgis with schema extensions` does nothing, so
the feature migration checks the schema and stops. Run migration checks in the
clean database.

Error codes for constraint violations can differ between majors. For
`ON DELETE RESTRICT`, PostgreSQL 16 and 17 raise `foreign_key_violation`
(23503), while PostgreSQL 18 raises `restrict_violation` (23001). Assertions
must match the code the pinned major raises; do not accept several codes to make
a test pass.

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
