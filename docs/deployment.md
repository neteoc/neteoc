# Staging deployment

NetEOC Dev (`mssluxsybusndqxdgica`) is the staging Supabase project. A
`neteoc-staging` Cloudflare Worker serves the staging application. Local
development uses the local Supabase stack. Production will have separate
projects and an approval-gated release workflow; this staging job does not
deploy production.

## Merge release path

The `deploy-staging` job in `.github/workflows/ci.yml` runs only for a push to
`main`, after the SQL authorization and quality/security jobs pass. GitHub's
`neteoc-staging` concurrency group prevents overlapping release jobs. The job
links to NetEOC Dev, previews pending migrations, applies them, builds the Astro
Worker with Bun 1.4.3, deploys with the locked Wrangler version, and checks the
hosted access boundary. A failed migration or build stops the Worker deployment.
The job never runs with deployment credentials for a pull request. The build and
deploy both set `CLOUDFLARE_ENV=staging`; Astro selects Wrangler's environment
during its build, so `--env` at deploy time alone would use the top-level
bindings.

New schema changes must be forward-compatible with the previously deployed
Worker. A Worker version can be rolled back, but an applied database migration
cannot be undone by rolling back Worker code. Do not edit a migration already
applied to a shared project; add another migration.

## One-time GitHub configuration

Create a GitHub Actions environment named `staging`, restricted to `main`. Set
these environment variables:

| Variable                | Value                                                    |
| ----------------------- | -------------------------------------------------------- |
| `CLOUDFLARE_ACCOUNT_ID` | Account that owns the staging Worker.                    |
| `STAGING_BASE_URL`      | HTTPS origin of `neteoc-staging`, with no path or query. |

Set these **environment secrets**:

| Secret                     | Purpose                                                                |
| -------------------------- | ---------------------------------------------------------------------- |
| `CLOUDFLARE_API_TOKEN`     | Account-scoped token with the permissions needed to deploy Workers.    |
| `SUPABASE_ACCESS_TOKEN`    | Scoped token permitted to link and deploy to NetEOC Dev.               |
| `SUPABASE_DB_PASSWORD`     | Database password for NetEOC Dev; only the migration step receives it. |
| `SUPABASE_PUBLISHABLE_KEY` | Active `sb_publishable_` key for NetEOC Dev.                           |

The Worker receives only the Supabase URL and publishable key. The deployment
step puts them in a temporary file with mode `0600`, passes that file to
Wrangler's `--secrets-file`, and removes it when the step exits. The database
password and access token are never Worker bindings. Do not place any of these
values in the repository or in pull-request workflows.

## One-time hosted configuration

Confirm the remote migration ledger matches every migration already applied to
NetEOC Dev before enabling the job. The next merge will apply any remaining
committed migrations; the workflow must not repair or reset migration history.
Set NetEOC Dev's Auth Site URL and exact redirect allow-list entry for the
hosted staging origin and `/auth/confirm`, while retaining the local callback if
local sign-in remains in use. Follow [authentication setup](auth-setup.md) for
the OTP template and SMTP settings. Do not push the local `supabase/config.toml`
to NetEOC Dev unchanged: it contains localhost URLs and local mail settings. Use
synthetic staging data only.

## Verification and recovery

The hosted smoke check requires `200` from `/`, `302` to `/login` from an
anonymous `/app` request, private no-store and noindex headers, a working code
confirmation page, and `403` for cross-origin authentication POSTs. It does not
send email or consume an OTP; the full sign-in sequence needs a separate staging
acceptance test.

If migration application fails, inspect the failed migration and make a new
forward migration as needed. Do not automatically repair history or reset the
shared project. If the Worker deployment or smoke check fails after a successful
migration, use Cloudflare's Worker version rollback where safe, then fix the
release and rerun CI. Keep database and uploaded-object backups and a restore
rehearsal before any production pilot.
