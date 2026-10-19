# Tenant kernel: first read boundary

The first tenancy migration creates `organizations` and `memberships` in the
development Supabase project. Each membership binds one Auth user to one
organization as an `admin`, `editor`, or `viewer`. Application roles have only
`SELECT` grants. RLS lets an authenticated user read their own membership rows
and organizations for which those rows exist. Anonymous users have no table
grants. No browser or Worker credential can create an organization or appoint a
member through these tables. A follow-up migration makes the role a Postgres
enum and blocks deletion of an Auth user who still has a membership. An explicit
offboarding path must remove memberships after checking last-admin protection.

The authenticated workspace reads organizations with a user-scoped Supabase
client. The database policy, rather than a filter supplied by the browser,
restricts the list. A signed-in user without a membership sees an invitation
message. This is a read boundary, not the finished organization workflow.

The first migration is
[`20261019204906_tenant_read_kernel.sql`](../supabase/migrations/20261019204906_tenant_read_kernel.sql).
[`20261019212322_harden_tenant_memberships.sql`](../supabase/migrations/20261019212322_harden_tenant_memberships.sql)
follows it without changing the applied file. Both were applied to NetEOC Dev on
October 19, 2026. The SQL test inserts three temporary Auth users and two
organizations with the same name. It verifies each tenant member sees only their
own organization and membership, cannot see a co-member, and cannot write either
table. It also checks anonymous denial and that an Auth user with a membership
cannot be deleted. The transaction rolls back all fixtures; it passed on NetEOC
Dev, leaving both tables empty.

CI runs [`tenant_read_kernel.sql`](../tests/sql/tenant_read_kernel.sql) against
PostgreSQL 16 with a minimal Auth schema from
[`ci-bootstrap.sql`](../tests/sql/ci-bootstrap.sql). This keeps the RLS and
grant checks in the PR gate without production credentials. The same SQL test
was run against NetEOC Dev to cover its actual Auth schema. Supabase security
and performance advisors found no new table findings.

The next tenant changes must add an audited operator bootstrap, organization
admin membership management, single-use invitations, revocation and last-admin
protection, and direct negative tests for each mutation. Until bootstrap is
implemented, the tables intentionally have no application write path. Future
migrations must keep RLS and negative authorization tests alongside new exposed
tables.
