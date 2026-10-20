-- Committed fixtures for organization_invitations_race.sh. Two sessions need to
-- see the same invitation, so these rows cannot roll back. The script deletes
-- them on exit. Each token is returned to the script's variables, not printed.
insert into auth.users (id, email, email_confirmed_at) values
  ('f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a01', 'race-admin@neteoc.invalid', now()),
  ('f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a02', 'race-invitee-1@neteoc.invalid', now()),
  ('f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a03', 'race-invitee-2@neteoc.invalid', now());

insert into public.organizations (id, name) values
  ('f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10', 'Invitation race organization');

insert into public.memberships (organization_id, user_id, role) values
  ('f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10', 'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a01', 'admin');

select set_config('request.jwt.claim.sub', 'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a01', false);
set role authenticated;
select 'token_one:' || public.issue_organization_invitation(
  'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10', 'race-invitee-1@neteoc.invalid', 'viewer');
select 'token_two:' || public.issue_organization_invitation(
  'f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10', 'race-invitee-2@neteoc.invalid', 'viewer');
