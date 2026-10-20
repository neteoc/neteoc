-- One update as an authenticated editor, in its own transaction.
begin;
select set_config('request.jwt.claim.sub', :'user_id', true);
set local role authenticated;
select public.update_feature(:'feature'::uuid, :revision, :'changes'::jsonb) as racer_result;
commit;
