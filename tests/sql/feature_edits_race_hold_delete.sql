-- Deletes a feature inside an open transaction, then holds the row lock.
begin;
select set_config('request.jwt.claim.sub', :'user_id', true);
set local role authenticated;
select public.delete_feature(:'feature'::uuid, :revision) as holder_result;
select pg_sleep(3);
commit;
