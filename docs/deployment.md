# Staging deployment

NetEOC Dev (`mssluxsybusndqxdgica`) is the staging Supabase project. The
`neteoc` Cloudflare Worker serves the staging application at
`https://neteoc.kerryhatcher.workers.dev`. Local development uses the local
Supabase stack. A later production release needs separate projects.

## Merge release path

GitHub Actions runs the required `Tenant RLS` and `Quality and security` checks
on each pull request. After a merge to `main`, two provider-managed GitHub
integrations deploy from the same commit:

- Supabase's GitHub integration applies unapplied migrations to NetEOC Dev.
- Cloudflare Workers Builds builds and deploys `neteoc`, then runs
  `scripts/check-deployment.mjs` against its hosted URL.

Neither integration needs a deploy token or database password stored in GitHub
Actions. Cloudflare manages its own build token. The Supabase project connection
authorizes Supabase to read the repository and deploy its `supabase/` directory.

The providers run independently. A Worker may deploy before its matching
migration finishes, or a migration may apply while the old Worker still runs.
Every schema change must therefore be compatible with both Worker versions. Use
expand-and-contract migrations and defer removals until all deployed code has
stopped using the old schema. A Worker version can be rolled back, but an
applied database migration cannot be undone by rolling back Worker code. Do not
edit a migration already applied to a shared project; add another migration.

## Supabase GitHub integration

In the NetEOC Dev project, connect `neteoc/neteoc` under **Project Settings →
Integrations → GitHub** with repository root as the working directory. Enable
**Deploy to production** for the repository's `main` branch. Supabase calls the
project's primary branch “production”; this particular project is NetEOC's
staging environment. Automatic branching and preview projects are optional and
are not needed for merge deploys. Add the Supabase migration check to GitHub
branch protection when it appears on a pull request.

Before enabling deployment, compare the project's migration ledger with the
committed migration files. The integration applies pending migrations but cannot
repair missing history entries. Do not push local `supabase/config.toml`
settings to the hosted project unchanged: it contains localhost URLs and local
mail settings. Supabase ignores Auth configuration on the primary branch unless
remote configuration is explicitly enabled.

## Cloudflare Workers Builds

In the **Kerry Personal** account, select the existing Worker named `neteoc`,
connected to `neteoc/neteoc` under **Settings → Build**. Set the production
branch to `main`, root directory to the repository root, and these build
settings:

| Setting        | Value                                                                                                                            |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Build command  | `bun run build`                                                                                                                  |
| Deploy command | `node node_modules/wrangler/bin/wrangler.js deploy && node scripts/check-deployment.mjs https://neteoc.kerryhatcher.workers.dev` |

Keep Bun 1.4.3 selected; Workers Builds detects it from `.bun-version` and
installs dependencies with `bun install --frozen-lockfile` before running the
build command. Keep the Cloudflare-managed API token selected. The Worker name
matches the top-level `name` in `wrangler.jsonc`; this account's `neteoc` Worker
is the staging target. Use a separate Worker and Supabase project for a later
production release.

Set the staging Worker's runtime bindings `SUPABASE_URL` to
`https://mssluxsybusndqxdgica.supabase.co` and `SUPABASE_PUBLISHABLE_KEY` to
NetEOC Dev's active `sb_publishable_` key. These identify the public Supabase
API; they grant only the access allowed by RLS. Store them in Cloudflare's
Worker variables and secrets UI, not in GitHub Actions. The Worker must never
receive a Supabase service-role key or database password.

## Hosted authentication

Set NetEOC Dev's Auth Site URL and exact redirect allow-list entry for the
staging origin and `/auth/confirm`, while retaining the local callback if local
sign-in remains in use. Follow [authentication setup](auth-setup.md) for the OTP
template and SMTP settings. Keep signups invitation-only and use synthetic
staging data.

## Verification and recovery

The hosted smoke check requires `200` from `/`, `302` to `/login` from an
anonymous `/app` request, private no-store and noindex headers, a working code
confirmation page, and `403` for cross-origin authentication POSTs. It does not
send email or consume an OTP; the full sign-in sequence needs a separate staging
acceptance test.

Inspect the Supabase integration's deployment result and Cloudflare's build
result for each merge. A Cloudflare build can pass before the matching Supabase
deployment finishes; check both results before treating a merge as deployed. If
migration application fails, make a new forward migration as needed. Do not
automatically repair history or reset the shared project. If the Worker deploy
or smoke check fails, use Cloudflare's Worker version rollback where safe, then
fix the release. Keep database and uploaded-object backups and a restore
rehearsal before any production pilot.
