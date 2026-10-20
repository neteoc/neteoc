-- Plan evidence for the layer viewport read (docs/layer-feature-queries.md).
-- Manual, not run in CI. Synthetic data only.
--
-- Captures the plan of list_layer_features itself, including the statement the
-- function runs and its layer probe, with auto_explain. The function is not
-- re-typed here, so the plan is for the real code.
--
-- Requirements:
--   * A PostgreSQL server that lets a session LOAD auto_explain. The CI image does;
--     the Supabase local stack refuses the library, so run this against a disposable
--     database on a self-hosted server.
--   * The migrations through 20261020183000 applied to an empty database, with the
--     tables and roles of a Supabase project (auth schema, authenticated role).
--
--   psql "$DB" -X -v ON_ERROR_STOP=1 -f tests/perf/layer_viewport_plan.sql
--
-- Fixture: 20 layers of 10,000 features in one organization. The target layer holds
-- 10,000 of 200,000 rows, so the layer predicate is selective, as it is in a real
-- table. A one-layer table would select every row and say nothing about the planner.

begin;

select setseed(0.42);

insert into auth.users (id, email) values
  ('7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', 'plan-admin@neteoc.invalid')
on conflict do nothing;

insert into public.organizations (id, name) values
  ('8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d', 'Plan evidence organization');

insert into public.memberships (organization_id, user_id, role) values
  ('8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d', '7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', 'admin');

-- Layer 1 is the target and has a fixed ID. The others get random IDs.
insert into public.layers (id, organization_id, title)
select
  case when n = 1 then '9c3a2e4d-6f5b-4a7c-8d8e-1f2a3b4c5d6e'::uuid else gen_random_uuid() end,
  '8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d',
  'Synthetic layer ' || n
from generate_series(1, 20) as n;

-- Writes need an authenticated actor for the stamp trigger.
select set_config('request.jwt.claim.sub', '7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', true);

insert into public.features (layer_id, organization_id, geom, title, created_at)
select
  layer.id,
  '8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d',
  case
    when kind < 0.7 then format('SRID=4326;POINT(%s %s)', lon, lat)
    when kind < 0.9 then format('SRID=4326;LINESTRING(%s %s,%s %s)',
      lon, lat, (lon + 0.004), (lat + 0.003))
    else format('SRID=4326;POLYGON((%1$s %2$s,%3$s %2$s,%3$s %4$s,%1$s %4$s,%1$s %2$s))',
      lon, lat, (lon + 0.003), (lat + 0.002))
  end::public.wgs84_geometry,
  'Synthetic feature ' || layer_no || '-' || i,
  timestamptz '2026-10-01 00:00:00+00' + (layer_no * 10000 + i) * interval '1 second'
from (
  select
    i,
    layer_no,
    round((-105.20 + random() * 0.60)::numeric, 6) as lon,
    round((39.50 + random() * 0.50)::numeric, 6) as lat,
    random() as kind
  from generate_series(1, 10000) as i
  cross join generate_series(1, 20) as layer_no
) as synthetic
join public.layers as layer on layer.title = 'Synthetic layer ' || synthetic.layer_no;

commit;

analyze public.features;

-- Plan of the real function. auto_explain logs the function's own statements, the
-- layer probe and the page query, with actual rows and buffers, to this session.
-- Read as the authenticated role with RLS applied, for the medium viewport and the
-- first page. Nothing is written, so the call rolls back.
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_analyze = on;
set auto_explain.log_buffers = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', true);
select jsonb_array_length(public.list_layer_features(
  '9c3a2e4d-6f5b-4a7c-8d8e-1f2a3b4c5d6e', -104.90, 39.70, -104.80, 39.80, 50, null, null, 258048
)->'features') as features_on_first_page;
rollback;
