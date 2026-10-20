-- Measures the latency of refused feature writes, to test the claim in
-- docs/feature-writes.md that unauthorized callers get the same answer whether or not
-- the feature exists. The answers (SQLSTATE and message) are asserted in
-- tests/sql/feature_edits.sql; this file measures how long each answer takes.
--
-- Run by hand against a disposable database, never in CI. Everything is rolled back.
-- Cases are interleaved in one loop, so drift in the host affects every case alike.
-- Each call is timed with clock_timestamp() around the statement, including its
-- exception handling, which is the same for every case.
--
--   psql -X -v ON_ERROR_STOP=1 -f tests/perf/feature_write_timing.sql
begin;

insert into auth.users (id, email) values
  ('c0ffee00-0000-4000-8000-000000000001', 'timing-editor-b@neteoc.invalid'),
  ('c0ffee00-0000-4000-8000-000000000002', 'timing-viewer-a@neteoc.invalid');
insert into public.organizations (id, name) values
  ('c0ffee00-0000-4000-8000-0000000000a1', 'Timing organization A'),
  ('c0ffee00-0000-4000-8000-0000000000a2', 'Timing organization B');
insert into public.memberships (organization_id, user_id, role) values
  ('c0ffee00-0000-4000-8000-0000000000a1', 'c0ffee00-0000-4000-8000-000000000002', 'viewer'),
  ('c0ffee00-0000-4000-8000-0000000000a2', 'c0ffee00-0000-4000-8000-000000000001', 'editor');
insert into public.layers (id, organization_id, title) values
  ('c0ffee00-0000-4000-8000-0000000000c1', 'c0ffee00-0000-4000-8000-0000000000a1', 'Timing layer A');

select set_config('request.jwt.claim.sub', 'c0ffee00-0000-4000-8000-000000000002', false);
insert into public.features (id, layer_id, organization_id, geom, title) values
  ('c0ffee00-0000-4000-8000-0000000000f1', 'c0ffee00-0000-4000-8000-0000000000c1',
   'c0ffee00-0000-4000-8000-0000000000a1', 'SRID=4326;POINT(-104.99 39.74)', 'Timing feature');

create temporary table timing (case_name text not null, elapsed_us double precision not null, outcome text not null)
  on commit drop;
grant insert on timing to authenticated;

set local role authenticated;
do $$
declare
  v_editor_b uuid := 'c0ffee00-0000-4000-8000-000000000001';
  v_viewer_a uuid := 'c0ffee00-0000-4000-8000-000000000002';
  v_live uuid := 'c0ffee00-0000-4000-8000-0000000000f1';
  v_layer uuid := 'c0ffee00-0000-4000-8000-0000000000c1';
  v_absent uuid := 'c0ffee00-0000-4000-8000-0000000000ff';
  v_t0 timestamptz;
  v_outcome text;
  v_round integer;
  v_case record;
begin
  for v_round in 1..2000 loop
    for v_case in select * from (values
      ('update, absent feature, other organization', 'update', v_absent, v_editor_b),
      ('update, live feature, other organization', 'update', v_live, v_editor_b),
      ('update, live feature, same organization viewer', 'update', v_live, v_viewer_a),
      ('delete, absent feature, other organization', 'delete', v_absent, v_editor_b),
      ('delete, live feature, other organization', 'delete', v_live, v_editor_b),
      ('delete, live feature, same organization viewer', 'delete', v_live, v_viewer_a),
      ('create, absent layer, other organization', 'create', v_absent, v_editor_b),
      ('create, live layer, other organization', 'create', v_layer, v_editor_b),
      ('create, live layer, same organization viewer', 'create', v_layer, v_viewer_a)
    ) as c(label, op, target, caller)
    loop
      perform set_config('request.jwt.claim.sub', v_case.caller::text, true);
      v_t0 := clock_timestamp();
      begin
        if v_case.op = 'update' then
          perform public.update_feature(v_case.target, 1, '{"title": "Timing"}'::jsonb);
        elsif v_case.op = 'delete' then
          perform public.delete_feature(v_case.target, 1);
        else
          perform public.create_feature(v_case.target, '{"type":"Point","coordinates":[-104.9,39.7]}'::jsonb, 'Timing');
        end if;
        v_outcome := 'ok';
      exception when others then
        v_outcome := sqlstate || ' ' || sqlerrm;
      end;
      insert into timing values (v_case.label, extract(epoch from clock_timestamp() - v_t0) * 1000000, v_outcome);
    end loop;
  end loop;
end;
$$;
reset role;

-- The outcome per case must be one answer, or the timing compares different things.
select case_name, outcome, count(*) as calls
from timing
group by case_name, outcome
order by case_name, outcome;

select case_name,
  round(percentile_cont(0.5) within group (order by elapsed_us)::numeric, 1) as median_us,
  round(avg(elapsed_us)::numeric, 1) as mean_us,
  count(*) as calls
from timing
group by case_name
order by case_name;

rollback;
