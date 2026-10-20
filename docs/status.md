# Repository status

PR #4 merged on October 19, 2026. The first tenant read boundary is complete:
NetEOC Dev now has organizations and memberships with RLS, member-only
organization reads, self-only membership reads, and no application writes.
Direct SQL allow/deny tests passed and rolled back their fixtures; CI now runs
them against PostgreSQL. The workspace lists only organizations returned by the
user-scoped client, with IDs to distinguish duplicate names. The next slice adds
an operator-only, audited bootstrap path for the first platform admin and
organization admin. Its transactional SQL test passed on NetEOC Dev and rolled
back every fixture; no real admins or organizations were created. Invitations,
membership mutation, and full sign-in session testing remain next steps. See
[Tenant kernel](tenant-kernel.md) and
[Operator bootstrap](operator-bootstrap.md).

As of 2026-10-19, the foundation and MVP plan were merged in
[PR #1](https://github.com/neteoc/neteoc/pull/1). The user subsequently asked
for a planning review and for MVP work to begin. The first local slice adds an
Astro/Cloudflare Worker shell, cookie-backed Supabase sign-in routes, and
verified-claim protection for `/app`. The user designated
[`NetEOC Dev`](https://supabase.com/dashboard/project/mssluxsybusndqxdgica) as
the development/preview Supabase project. Its active publishable key and API URL
are present only in an ignored local `.dev.vars` file. No Cloudflare Worker or
production deployment has been created. The development project sends Auth email
through a dedicated `NetEOC Dev` Postmark server. The
[implementation contract](mvp-implementation-contract.md) records remaining
architecture gates.

The foundation includes the root agent guide, documentation set, Bun lockfile,
Conventional Commit hooks, SHA-pinned GitHub Actions CI, a policy checker,
tests, Semgrep rules, and pinned security tooling. GitHub native secret
scanning, push protection, and Dependabot security updates are enabled. The
`main` branch requires pull requests, the `Quality and security` check, current
branch status, and linear history; force pushes and deletions are disabled. The
foundation PR CI run passed all jobs and scans.

The current local Worker runtime returned `200` for `/`, `302` from `/app` to
`/login` without credentials, and `403` for a cross-origin sign-in POST. After
connecting the development project, the Worker returned the generic sign-in
response for a synthetic nonexistent address. The Auth user count stayed at one,
confirming that this request did not create an account. `bun run check` passed
with Bun 1.4.3, including Astro diagnostics and the Worker build. Bun audit,
Semgrep, and Trivy reported no high or critical findings in this slice.

PostGIS is tracked in the migration that adds feature storage. That migration
installs it into the `extensions` schema and refuses to continue if it lands
anywhere else. The `features` table stores 2D WGS84 point, line, and polygon
geometry with bounded attributes, a stable ID, a trigger-stamped revision and
actor, and RLS for anonymous, viewer, editor, and cross-tenant access. CI runs
the authorization tests in a clean database on PostgreSQL 17 with PostGIS 3.6,
and the same tests pass on the local Supabase stack with PostGIS 3.3. NetEOC Dev
has not received this migration; applying it waits for the Dev application step.
The first tracked migration removed `PUBLIC`, `anon`, and `authenticated`
execute privileges from the pre-existing `public.rls_auto_enable()`
event-trigger helper; negative privilege checks pass and the security advisor no
longer flags the function. The corresponding event trigger is not installed, so
each future table migration must enable RLS explicitly. The development Auth
Site URL is `http://localhost:8787`, and the exact `/auth/confirm` redirect is
allowed. Custom SMTP and the code-only Magic Link OTP template are configured. A
local sign-in request produced a Postmark `Delivered` event. Code confirmation,
session refresh, sign-out, and invitation acceptance remain unverified. A
verified NetEOC sender is needed before a pilot; the development project
currently uses a temporary sender.

Layer feature reads (#13) add `GET /api/v1/layers/{layerId}/features`, backed by
`list_layer_features`. The read returns a bounded page ordered by a stable
`(created_at, id)` cursor. Over-limit bounding boxes, page sizes, sorts, and
cursors fail with explicit errors, never a silent truncation. A forbidden layer
and a nonexistent layer return byte-identical empty pages, which the database
test and the live PostgREST run both confirmed. On a synthetic 10,000-feature
layer the planner uses the layer index rather than the geometry index. A btree
on `(layer_id, created_at, id)` speeds populated viewports and slows empty ones,
so no index is added while that trade-off awaits a decision. See
[Layer feature reads](layer-feature-queries.md). NetEOC Dev has not received
these migrations.

The foundation's actionlint, TruffleHog tree and history scans, and CI passed at
the previous checkpoint. The initial commit predates the Conventional Commit
policy; future commits and PR titles are validated. Security scanning results
are point-in-time checks, not a substitute for a production authorization
review.
