# Tenant kernel: first read boundary

The first tenancy migration creates `organizations` and `memberships` in the
development Supabase project. Each membership binds one Auth user to one
organization as an `admin`, `editor`, or `viewer`. Application roles have only
`SELECT` grants. RLS lets an authenticated user read their own membership rows
and organizations for which those rows exist. Anonymous users have no table
grants. No browser or Worker credential can create an organization or appoint a
member through these tables.

The authenticated workspace reads organizations with a user-scoped Supabase
client. The database policy, rather than a filter supplied by the browser,
restricts the list. A signed-in user without a membership sees an invitation
message. This is a read boundary, not the finished organization workflow.

The migration is
[`20261019204906_tenant_read_kernel.sql`](../supabase/migrations/20261019204906_tenant_read_kernel.sql).
It was applied to NetEOC Dev on October 19, 2026. Run
[`tenant_read_kernel.sql`](../tests/sql/tenant_read_kernel.sql) in a transaction
against a disposable local or preview Supabase project with one Auth user. It
inserts two temporary organizations, checks that the member sees only their
organization and membership, checks that another user sees neither, and checks
that anonymous reads and authenticated organization inserts fail. The test rolls
back all fixtures. It passed on NetEOC Dev; both tables remained empty. Supabase
security and performance advisors found no new table findings.

The next tenant changes must add an audited operator bootstrap, organization
admin membership management, single-use invitations, revocation and last-admin
protection, and direct negative tests for each mutation. Until bootstrap is
implemented, the tables intentionally have no application write path. Future
migrations must keep RLS and negative authorization tests alongside new exposed
tables.
