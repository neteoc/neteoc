-- Removes the committed fixtures. The session replication role skips the audit
-- immutability trigger, which is the only path that deletes audit rows.
set session_replication_role = replica;
delete from app_private.invitation_audit_events
  where organization_id = 'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10';
delete from public.memberships
  where organization_id = 'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10';
delete from public.organization_invitations
  where organization_id = 'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10';
delete from public.organizations
  where id = 'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10';
delete from auth.users
  where id in (
    'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a01',
    'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a02',
    'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a03'
  );
