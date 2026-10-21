# Staging deployment

NetEOC Dev (`mssluxsybusndqxdgica`) is the staging Supabase project. The
`neteoc` Cloudflare Worker serves the staging application at
`https://neteoc.kerryhatcher.workers.dev`. Local development uses the local
Supabase stack. A later production release needs separate projects.

## Merge release path

GitHub Actions runs the required `Tenant RLS` and `Quality and security` checks
on pull requests and pushes to `main`. After those checks pass on `main`, the
`Deploy staging` job applies pending Supabase migrations, builds and deploys the
existing `neteoc` Worker, then runs the hosted smoke check. The job uses the
`staging` GitHub environment and serializes releases. A failed migration stops
the Worker deploy; a failed smoke check fails the release job.

Disable automatic `main` deployments in the Supabase GitHub integration and
Cloudflare Workers Builds before enabling this job. Otherwise the providers can
deploy the same commit independently. Preview builds may remain enabled. A later
production release needs separate projects and credentials.

## GitHub Actions staging credentials

Set these secrets in the `staging` GitHub environment:

| Secret                  | Purpose                                                       |
| ----------------------- | ------------------------------------------------------------- |
| `SUPABASE_ACCESS_TOKEN` | Scoped token for NetEOC Dev with read access needed by `link` |
| `SUPABASE_DB_PASSWORD`  | NetEOC Dev database password                                  |
| `CLOUDFLARE_API_TOKEN`  | Token scoped to Kerry Personal with Workers edit permission   |

Set `CLOUDFLARE_ACCOUNT_ID` as a GitHub Actions variable; it is already present
at repository level. Before the first release, compare NetEOC Dev's migration
ledger with committed files. `db push` applies pending files and stops on a
history mismatch. The workflow does not repair history, include seed data, or
push the local `supabase/config.toml` settings, which contain localhost URLs and
local mail settings. Every migration must remain compatible with the running
Worker until the new Worker deploys. Do not edit an applied migration.

## Cloudflare Worker

The `SESSION` KV binding in `wrangler.jsonc` uses the existing `neteoc-session`
namespace. Its explicit ID avoids an auto-provisioning conflict after a failed
first deploy has already created the namespace.

The workflow selects Bun 1.4.3 from `.bun-version`, installs from `bun.lock`,
and uses the pinned Wrangler dependency. The Worker name matches the top-level
`name` in `wrangler.jsonc`.

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

Check the `Deploy staging` job before treating a merge as deployed. If migration
application fails, make a new forward migration as needed. Do not automatically
repair history or reset the shared project. If the Worker deploy or smoke check
fails, use Cloudflare's Worker version rollback where safe, then fix the
release. Keep database and uploaded-object backups and a restore rehearsal
before any production pilot.
