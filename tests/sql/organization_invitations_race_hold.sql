-- Accepts the invitation inside an open transaction, then holds it for three
-- seconds. The script starts a second session only after this one is sleeping,
-- so the second session must wait on the row lock.
begin;
select set_config('request.jwt.claim.sub', :'user_id', true);
set local role authenticated;
select public.accept_organization_invitation(:'token');
select pg_sleep(3);
commit;
