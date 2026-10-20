-- Query evidence for the layer viewport read (docs/layer-feature-queries.md).
-- Manual, not run in CI. Synthetic data only.
--
-- Run once, in an empty database that already has the migrations through
-- 20261020183000 applied:
--   psql "$DB" -X -v ON_ERROR_STOP=1 -f tests/perf/layer_viewport_plan.sql
--
-- The fixture is committed and holds 20 layers of 10,000 features each, so the
-- target layer is 5% of the table. A one-layer table would select every row by
-- layer, which says nothing about the planner. Plans are read as the authenticated
-- role, with RLS applied, and without enable_seqscan = off.

-- Synthetic fixture (committed).
begin;
-- Synthetic layers for viewport plan evidence: five layers of 10,000 features in
-- one organization. The first is the target; the other four make the table
-- representative, since a layer predicate on a one-layer table selects every row.
-- Deterministic (setseed). The caller rolls back. No real places or people.
select setseed(0.42);

insert into auth.users (id, email) values
  ('7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', 'plan-admin@neteoc.invalid')
on conflict do nothing;
insert into public.organizations (id, name) values
  ('8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d', 'Plan evidence organization');
insert into public.memberships (organization_id, user_id, role) values
  ('8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d', '7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', 'admin');
insert into public.layers (id, organization_id, title)
select
  case when n = 1 then '9c3a2e4d-6f5b-4a7c-8d8e-1f2a3b4c5d6e'::uuid else gen_random_uuid() end,
  '8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d',
  'Synthetic layer ' || n
from generate_series(1, 20) as n;

-- Pinned to the admin so the stamp trigger has an actor.
select set_config('request.jwt.claim.sub', '7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', true);

insert into public.features (layer_id, organization_id, geom, title, created_at)
select
  layer.id,
  '8b2f1d3c-5e4a-4f6b-9c7d-0e1f2a3b4c5d',
  case
    when kind < 0.7 then
      format('SRID=4326;POINT(%s %s)', lon, lat)
    when kind < 0.9 then
      format('SRID=4326;LINESTRING(%s %s,%s %s)',
        lon, lat, (lon + 0.004), (lat + 0.003))
    else
      format('SRID=4326;POLYGON((%1$s %2$s,%3$s %2$s,%3$s %4$s,%1$s %4$s,%1$s %2$s))',
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
join lateral (
  select id from public.layers
  where title = 'Synthetic layer ' || synthetic.layer_no
) as layer on true;

analyze public.features;
commit;

analyze public.features;

-- The statement list_layer_features runs for one page, against the target layer.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '7a1e0c2b-4d3f-4e5a-8b6c-9d0e1f2a3b4c', true);
explain (analyze, buffers, costs on, timing on)
select f.id, f.created_at
from public.features as f
where f.layer_id = '9c3a2e4d-6f5b-4a7c-8d8e-1f2a3b4c5d6e'
  and f.geom operator(extensions.&&) extensions.st_makeenvelope(-104.90, 39.70, -104.80, 39.80, 4326)
  and exists (
    select 1 from public.memberships as m
    where m.organization_id = f.organization_id and m.user_id = auth.uid()
  )
order by f.created_at, f.id
limit 51;
rollback;

-- The same page through the public entry point, timed.
\timing on
select jsonb_array_length(public.list_layer_features(
  '9c3a2e4d-6f5b-4a7c-8d8e-1f2a3b4c5d6e', -104.90, 39.70, -104.80, 39.80, 50, null, null, 258048
)->'features') as features_on_first_page;
