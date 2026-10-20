-- Updates a feature inside an open transaction, then holds the row lock for three
-- seconds. The script starts a second session only after this one is sleeping, so
-- the second session must wait on the row lock.
begin;
select set_config('request.jwt.claim.sub', :'user_id', true);
set local role authenticated;
select public.update_feature(:'feature'::uuid, :revision, :'changes'::jsonb) as holder_result;
select pg_sleep(3);
commit;
