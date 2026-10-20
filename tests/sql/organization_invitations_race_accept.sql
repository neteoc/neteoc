-- One accepting session. organization_invitations_race.sh runs it with the token,
-- the invitee's user ID, and optionally a pause that holds the row lock open.
select set_config('request.jwt.claim.sub', :'user_id', false);
set role authenticated;
select public.accept_organization_invitation(:'token');
