# Operator bootstrap

This is the first write path for MVP-01. It is intentionally available only to a
privileged database operator through the Supabase SQL editor. The Worker has no
service credential, and `anon` and `authenticated` cannot use the private schema
or its functions. No platform admin or organization was created when the
migration was applied to NetEOC Dev.

## Procedure

1. Confirm the intended platform admin and initial organization admin already
   exist in `auth.users`. Record their UUIDs from the Auth dashboard. Confirm
   each intended person and the organization name through the normal project
   approval process. Do not infer an administrator from the oldest Auth user.
2. Choose a durable operator reference, such as a change ticket ID and operator
   handle. It is recorded in `app_private.audit_events` and must be 3–120
   trimmed characters. Do not put credentials or private incident data in it.
3. In the privileged SQL editor, bootstrap the first platform admin once:

   ```sql
   select app_private.bootstrap_platform_admin(
     '<platform-admin-user-uuid>'::uuid,
     '<operator-reference>'
   );
   ```

4. Create an organization and its first admin atomically:

   ```sql
   select app_private.bootstrap_organization(
     '<organization-name>',
     '<initial-admin-user-uuid>'::uuid,
     '<platform-admin-user-uuid>'::uuid,
     '<operator-reference>'
   );
   ```

5. Check the returned organization UUID, initial `admin` membership, and two
   audit rows before treating the operation as complete. If the second call
   fails, it leaves no partial organization.

The first platform admin cannot be bootstrapped twice. The organization function
requires a currently appointed platform admin UUID. At this stage, only an
operator can invoke either function; an application-facing platform-admin path
has not been built. Future offboarding must account for audit references before
deleting Auth users. An operator should not delete or alter audit rows.

`tests/sql/operator_bootstrap.sql` covers successful creation, the second-admin
and unappointed-admin denials, atomic rollback on invalid input, and denial of
private schema access to `authenticated` and `anon`. It runs in CI and was also
run on NetEOC Dev with a transaction rollback.
