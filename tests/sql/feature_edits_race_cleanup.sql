-- Removes the committed race fixtures. The audit trail refuses deletion by design,
-- so the immutability trigger is disabled for this one transaction and restored
-- before it commits. A failure rolls the whole transaction back.
begin;
select set_config('request.jwt.claim.sub', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c01', true);
-- Deleting the features appends their own events, so it comes first.
delete from public.features where organization_id = 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10';
alter table app_private.feature_audit_events disable trigger feature_audit_events_immutable;
delete from app_private.feature_audit_events
  where organization_id = 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10';
alter table app_private.feature_audit_events enable trigger feature_audit_events_immutable;
delete from public.layers where organization_id = 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10';
delete from public.memberships where organization_id = 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10';
delete from public.organizations where id = 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10';
delete from auth.users where id in (
  'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c01', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c02');
commit;
