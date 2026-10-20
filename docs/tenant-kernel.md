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

The next tenant changes must add organization admin membership management,
last-admin protection, and direct negative tests for each mutation. Invitations
are described below. Until bootstrap is implemented, the tables intentionally
have no application write path. Future migrations must keep RLS and negative
authorization tests alongside new exposed tables.

## Single-use invitations

[`20261020162500_organization_invitations.sql`](../supabase/migrations/20261020162500_organization_invitations.sql)
adds `organization_invitations`. Each row binds one normalized email to one
organization and one role, with an expiry of at most 14 days. Issuance returns
the plaintext token once. The table stores only its SHA-256 digest, and no
application role can select that column. Application roles get no direct writes.
Three security definer functions carry the logic, each with an explicit check
and a pinned search path:

- `issue_organization_invitation` requires a current admin of the organization.
- `revoke_organization_invitation` requires an admin of the invitation's
  organization. A non-admin gets the same answer for an unknown ID.
- `accept_organization_invitation` requires a signed-in user with a confirmed
  email equal to the invitation's email. It locks the invitation row, refuses a
  used, revoked, or expired invitation, and writes the membership.

Each issuance, revocation, and consumption appends an event to
`app_private.invitation_audit_events`. The event holds the IDs and the action
only. It has no email address and no token. Triggers keep the audit log
append-only, and they prevent a row that has been consumed or revoked from
changing again.

The token has 244 random bits, from two `gen_random_uuid()` values, and is
stored only as a SHA-256 digest. A salt or keyed hash would add little against a
244-bit random value, and a server-side key would have to live in the database
for acceptance to work. A stolen row therefore holds no usable credential, and
accepting still requires the plaintext and a signed-in account for that exact
address. Supabase request logs can record function arguments, so the application
must not log the RPC body for `accept_organization_invitation`.

`tests/sql/organization_invitations.sql` covers the grants and pins, constraint
violations, each role's issuance and revocation, wrong-tenant and wrong-email
denials, replay, expiry, revocation, an unconfirmed account, and audit
immutability. `tests/sql/organization_invitations_race.sh` runs two committed
sessions against one invitation and checks that exactly one succeeds.
