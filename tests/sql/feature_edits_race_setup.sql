-- Committed fixtures for feature_edits_race.sh. Concurrent sessions must see the
-- same rows, so these cannot roll back. The script removes them on exit.
insert into auth.users (id, email) values
  ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c01', 'feat-race-editor-1@neteoc.invalid'),
  ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c02', 'feat-race-editor-2@neteoc.invalid');

insert into public.organizations (id, name) values
  ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10', 'Feature race organization');

insert into public.memberships (organization_id, user_id, role) values
  ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c01', 'editor'),
  ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c02', 'editor');

insert into public.layers (id, organization_id, title) values
  ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c20', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10', 'Feature race layer');

-- One feature per scenario, so the scenarios cannot interfere with each other.
select set_config('request.jwt.claim.sub', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c01', false);
insert into public.features (id, layer_id, organization_id, geom, title)
select ('b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c3' || n)::uuid,
       'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c20', 'b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10',
       'SRID=4326;POINT(-104.9 39.7)', 'Race seed ' || n
from generate_series(1, 4) as n;
