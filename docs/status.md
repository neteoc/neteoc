# Repository status

As of 2026-10-19, the foundation and MVP plan were merged in
[PR #1](https://github.com/neteoc/neteoc/pull/1). The user subsequently asked
for a planning review and for MVP work to begin. The first local slice adds an
Astro/Cloudflare Worker shell, cookie-backed Supabase sign-in routes, and
verified-claim protection for `/app`. The user designated
[`NetEOC Dev`](https://supabase.com/dashboard/project/mssluxsybusndqxdgica) as
the development/preview Supabase project. Its active publishable key and API URL
are present only in an ignored local `.dev.vars` file. No Cloudflare Worker,
Postmark integration, or production deployment has been created. The
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

The project is healthy, with no application tables or migrations. PostGIS is not
yet installed. Its security advisor flags `public.rls_auto_enable()` as a
`SECURITY DEFINER` function executable by anonymous and authenticated roles; the
corresponding event trigger is not installed. Revoke unnecessary execute
privileges in the first tracked schema migration and rerun the advisor. The
Magic Link OTP email template, redirect allow list, full email/code/session
flow, and invitation acceptance remain unverified. Dashboard authentication is
needed to configure the Auth settings.

The foundation's actionlint, TruffleHog tree and history scans, and CI passed at
the previous checkpoint. The initial commit predates the Conventional Commit
policy; future commits and PR titles are validated. Security scanning results
are point-in-time checks, not a substitute for a production authorization
review.
