-- One delete as an authenticated editor, in its own transaction.
begin;
select set_config('request.jwt.claim.sub', :'user_id', true);
set local role authenticated;
select public.delete_feature(:'feature'::uuid, :revision) as racer_result;
commit;
