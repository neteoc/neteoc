-- Execute against a disposable database. Every fixture and role switch rolls back.
-- Each refusal asserts the constraint that refused it, not only its SQLSTATE, so a
-- value rejected for the wrong reason fails the test.
begin;

insert into auth.users (id, email) values
  ('c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a01', 'feat-admin-a@neteoc.invalid'),
  ('c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', 'feat-editor-a@neteoc.invalid'),
  ('c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a03', 'feat-viewer-a@neteoc.invalid'),
  ('c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a04', 'feat-editor-b@neteoc.invalid');

insert into public.organizations (id, name) values
  ('d5c2b1e3-8f40-4b21-8c32-6e7f8091ab01', 'Feature test organization A'),
  ('d5c2b1e3-8f40-4b21-8c32-6e7f8091ab02', 'Feature test organization B');

insert into public.memberships (organization_id, user_id, role) values
  ('d5c2b1e3-8f40-4b21-8c32-6e7f8091ab01', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a01', 'admin'),
  ('d5c2b1e3-8f40-4b21-8c32-6e7f8091ab01', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', 'editor'),
  ('d5c2b1e3-8f40-4b21-8c32-6e7f8091ab01', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a03', 'viewer'),
  ('d5c2b1e3-8f40-4b21-8c32-6e7f8091ab02', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a04', 'editor');

insert into public.layers (id, organization_id, title) values
  ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01', 'Feature layer A'),
  ('e6d3c2f4-9051-4c32-9d43-7f8091abc002', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01', 'Feature layer A2'),
  ('e6d3c2f4-9051-4c32-9d43-7f8091abc003', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab02', 'Feature layer B');

-- Seed rows are written as editor A so the actor stamp has a user to record.
select set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', true);
insert into public.features (id, layer_id, organization_id, geom, title, properties) values
  ('f7e4d3c5-a162-4d43-8e54-8091abcd0001', 'e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
   'SRID=4326;POINT(-104.99 39.74)', 'Point A', '{"fuel": "diesel"}'),
  ('f7e4d3c5-a162-4d43-8e54-8091abcd0002', 'e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
   'SRID=4326;LINESTRING(-104.9 39.7,-104.8 39.8)', 'Line A', '{}'),
  ('f7e4d3c5-a162-4d43-8e54-8091abcd0003', 'e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
   'SRID=4326;POLYGON((-105 39.5,-104.5 39.5,-104.5 39.9,-105 39.9,-105 39.5))', 'Polygon A', '{}'),
  ('f7e4d3c5-a162-4d43-8e54-8091abcd0004', 'e6d3c2f4-9051-4c32-9d43-7f8091abc003', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab02',
   'SRID=4326;POINT(2.35 48.85)', 'Point B', '{}'),
  ('f7e4d3c5-a162-4d43-8e54-8091abcd0005', 'e6d3c2f4-9051-4c32-9d43-7f8091abc002', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
   'SRID=4326;POINT(-104.95 39.72)', 'Point on layer A2', '{}');

-- Catalog facts are asserted directly. The CI bootstrap grants everything to
-- anon and authenticated, so an absent revoke shows up here.
do $$
declare
  col text;
  fn text;
begin
  if not exists (
    select 1 from pg_class
    where oid = 'public.features'::regclass and relrowsecurity
  ) then
    raise exception 'RLS is not enabled on public.features';
  end if;

  if (select extnamespace::regnamespace::text from pg_extension where extname = 'postgis') <> 'extensions' then
    raise exception 'PostGIS is not installed in the extensions schema';
  end if;
  if (select atttypid
      from pg_attribute
      where attrelid = 'public.features'::regclass and attname = 'geom') <> 'public.wgs84_geometry'::regtype then
    raise exception 'geom is not the wgs84_geometry domain';
  end if;
  if not exists (
    select 1 from pg_constraint
    where contypid = 'public.wgs84_geometry'::regtype and contype = 'c'
  ) then
    raise exception 'wgs84_geometry has no SRID check';
  end if;

  if has_table_privilege('anon', 'public.features', 'select, insert, update, delete, truncate, references, trigger')
    or has_any_column_privilege('anon', 'public.features', 'select, insert, update, references') then
    raise exception 'anon holds a privilege on features';
  end if;

  if not has_table_privilege('authenticated', 'public.features', 'select')
    or not has_table_privilege('authenticated', 'public.features', 'delete') then
    raise exception 'authenticated lacks select or delete on features';
  end if;
  -- Writes are column-level. Table-level insert or update would expose the
  -- revision, actor, and identity columns.
  if has_table_privilege('authenticated', 'public.features', 'insert, update, truncate, references, trigger') then
    raise exception 'authenticated holds a table-level write privilege on features';
  end if;
  foreach col in array array['layer_id', 'organization_id', 'geom', 'title', 'description', 'status', 'properties'] loop
    if not has_column_privilege('authenticated', 'public.features', col, 'insert') then
      raise exception 'authenticated cannot insert %', col;
    end if;
  end loop;
  foreach col in array array['geom', 'title', 'description', 'status', 'properties'] loop
    if not has_column_privilege('authenticated', 'public.features', col, 'update') then
      raise exception 'authenticated cannot update %', col;
    end if;
  end loop;
  foreach col in array array['id', 'layer_id', 'organization_id', 'revision', 'created_by', 'created_at', 'updated_by', 'updated_at'] loop
    if has_column_privilege('authenticated', 'public.features', col, 'update') then
      raise exception 'authenticated can update %', col;
    end if;
  end loop;
  foreach col in array array['id', 'revision', 'created_by', 'created_at', 'updated_by', 'updated_at'] loop
    if has_column_privilege('authenticated', 'public.features', col, 'insert') then
      raise exception 'authenticated can insert %', col;
    end if;
  end loop;

  if (select count(*) from pg_index i
      join pg_class c on c.oid = i.indexrelid
      where i.indrelid = 'public.features'::regclass
        and pg_get_indexdef(c.oid) like '%USING gist (geom)%') <> 1 then
    raise exception 'features lacks a GiST index on geom';
  end if;

  -- The stamp runs with the caller's rights and a pinned search path. A
  -- client must not reach it directly.
  if has_function_privilege('anon', 'app_private.stamp_feature_write()', 'execute')
    or has_function_privilege('authenticated', 'app_private.stamp_feature_write()', 'execute') then
    raise exception 'an application role can call the feature stamp';
  end if;
  if exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
    where p.oid = 'app_private.stamp_feature_write()'::regprocedure
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'PUBLIC can execute the feature stamp';
  end if;
  fn := 'app_private.stamp_feature_write()';
  if not exists (
    select 1 from pg_proc
    where oid = fn::regprocedure
      and not prosecdef
      and proconfig @> array['search_path=""']
  ) then
    raise exception '% must be security invoker with search_path pinned', fn;
  end if;
end;
$$;

-- Cost order. PostgreSQL evaluates CHECK constraints in name order and stops at
-- the first failure. The vertex limit must refuse before ST_IsValid runs, so its
-- name must sort before features_geom_valid. This bowtie has 4001 vertices and
-- violates both. Both checks would refuse it, so the constraint that names the
-- refusal is the assertion.
do $$
declare
  v_wkt text;
  v_constraint text;
begin
  select 'SRID=4326;POLYGON((' || string_agg(format('%s %s', round(x, 6), round(y, 6)), ',' order by ord) || '))'
    into v_wkt
  from (
    select i as ord, -105 + 0.5 * i / 1000.0 as x, 39.5 + 0.4 * i / 1000.0 as y from generate_series(0, 1000) i
    union all select 1000 + i, -104.5, 39.9 - 0.4 * i / 1000.0 from generate_series(1, 1000) i
    union all select 2000 + i, -104.5 - 0.5 * i / 1000.0, 39.5 + 0.4 * i / 1000.0 from generate_series(1, 1000) i
    union all select 3000 + i, -105, 39.9 - 0.4 * i / 1000.0 from generate_series(1, 1000) i
  ) as seg;

  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              v_wkt::public.wgs84_geometry, 'Bowtie with too many vertices');
    raise exception 'accepted a self-intersecting polygon with 4001 vertices';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_geom_npoints_limit' then
      raise exception 'high-vertex invalid polygon refused by % instead of features_geom_npoints_limit', v_constraint;
    end if;
  end;

  -- Catalog guard for the same ordering. Every check that calls ST_IsValid sorts
  -- after the vertex limit, so a new expensive check cannot run before it.
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.features'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%st_isvalid%'
      and conname collate "C" < 'features_geom_npoints_limit' collate "C"
  ) then
    raise exception 'an ST_IsValid check sorts before features_geom_npoints_limit';
  end if;
end;
$$;

-- Constraints hold for every writer, including the owner, which bypasses RLS.
-- Each row must be refused by the named constraint. A value that is accepted
-- fails through the raise in its block, and a refusal by another constraint fails
-- through the comparison.
do $$
declare
  r record;
  v_constraint text;
  v_layer constant uuid := 'e6d3c2f4-9051-4c32-9d43-7f8091abc001';
  v_org constant uuid := 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01';
begin
  for r in select * from (values
    ('SRID=4326;MULTIPOINT(-104.99 39.74)', 'features_geom_type_supported'),
    ('SRID=4326;MULTILINESTRING((-104.9 39.7,-104.8 39.8))', 'features_geom_type_supported'),
    ('SRID=4326;MULTIPOLYGON(((-105 39.5,-104.5 39.5,-104.5 39.9,-105 39.5)))', 'features_geom_type_supported'),
    ('SRID=4326;GEOMETRYCOLLECTION(POINT(-104.99 39.74))', 'features_geom_type_supported'),
    ('SRID=4326;POINT EMPTY', 'features_geom_not_empty'),
    ('SRID=4326;POLYGON EMPTY', 'features_geom_not_empty'),
    ('SRID=4326;POLYGON((-105 39.5,-104.5 39.9,-104.5 39.5,-105 39.9,-105 39.5))', 'features_geom_valid'),
    ('SRID=4326;LINESTRING(-104.99 39.74,-104.99 39.74)', 'features_geom_valid'),
    ('SRID=4326;POINT(39.74 -104.99)', 'features_geom_lon_lat_range'),
    ('SRID=4326;POINT(-181 39.74)', 'features_geom_lon_lat_range'),
    ('SRID=4326;POINT(-104.99 91)', 'features_geom_lon_lat_range'),
    ('SRID=4326;POINT(NaN 39.74)', 'features_geom_lon_lat_range')
  ) as c(wkt, expected) loop
    begin
      insert into public.features (layer_id, organization_id, geom, title)
        values (v_layer, v_org, r.wkt::public.wgs84_geometry, 'Rejected geometry');
      raise exception 'accepted invalid geometry: %', r.wkt;
    exception when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint is distinct from r.expected then
        raise exception 'geometry % refused by % instead of %', r.wkt, v_constraint, r.expected;
      end if;
    end;
  end loop;

  -- The longest allowed line is 2000 vertices. One more is refused by the vertex limit.
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values (v_layer, v_org, (
        select 'SRID=4326;LINESTRING(' || string_agg(format('%s 39', -104 + i / 10000.0), ',') || ')'
        from generate_series(0, 2000) as i
      )::public.wgs84_geometry, 'Too many vertices');
    raise exception 'accepted a 2001-vertex line';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_geom_npoints_limit' then
      raise exception '2001-vertex line refused by % instead of features_geom_npoints_limit', v_constraint;
    end if;
  end;

  -- Coordinates on the boundary are valid. Longitude 180 and latitude 90 are
  -- allowed, and so is a 2000-vertex line.
  insert into public.features (layer_id, organization_id, geom, title)
    values (v_layer, v_org, 'SRID=4326;POINT(180 90)'::public.wgs84_geometry, 'Boundary point');
  insert into public.features (layer_id, organization_id, geom, title)
    values (v_layer, v_org, 'SRID=4326;POINT(-180 -90)'::public.wgs84_geometry, 'Opposite boundary point');
  insert into public.features (layer_id, organization_id, geom, title)
    values (v_layer, v_org, (
      select 'SRID=4326;LINESTRING(' || string_agg(format('%s 39', -104 + i / 10000.0), ',') || ')'
      from generate_series(0, 1999) as i
    )::public.wgs84_geometry, 'Two thousand vertices');

  -- Attribute and text bounds.
  begin
    insert into public.features (layer_id, organization_id, geom, title, properties)
      values (v_layer, v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Array properties', '[]');
    raise exception 'accepted non-object properties';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_properties_valid' then
      raise exception 'non-object properties refused by % instead of features_properties_valid', v_constraint;
    end if;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title, properties)
      values (v_layer, v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Oversized properties',
              jsonb_build_object('note', repeat('x', 4100)));
    raise exception 'accepted oversized properties';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_properties_valid' then
      raise exception 'oversized properties refused by % instead of features_properties_valid', v_constraint;
    end if;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values (v_layer, v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, '   ');
    raise exception 'accepted a blank title';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_title_valid' then
      raise exception 'blank title refused by % instead of features_title_valid', v_constraint;
    end if;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values (v_layer, v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, repeat('t', 121));
    raise exception 'accepted a 121-character title';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_title_valid' then
      raise exception 'long title refused by % instead of features_title_valid', v_constraint;
    end if;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title, description)
      values (v_layer, v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Long description', repeat('d', 2001));
    raise exception 'accepted a 2001-character description';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_description_valid' then
      raise exception 'long description refused by % instead of features_description_valid', v_constraint;
    end if;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title, status)
      values (v_layer, v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Long status', repeat('s', 41));
    raise exception 'accepted a 41-character status';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_status_valid' then
      raise exception 'long status refused by % instead of features_status_valid', v_constraint;
    end if;
  end;

  -- A feature must sit in its layer's organization, even for the owner.
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc003', v_org, 'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Cross-tenant layer');
    raise exception 'organization A feature attached to organization B layer';
  exception when foreign_key_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_layer_organization_fkey' then
      raise exception 'cross-tenant layer refused by % instead of features_layer_organization_fkey', v_constraint;
    end if;
  end;

  -- Remove the accepted boundary fixtures so the role checks below count only
  -- the seeded rows. Owner deletes bypass RLS.
  delete from public.features
    where title in ('Boundary point', 'Opposite boundary point', 'Two thousand vertices');
end;
$$;

-- A value must declare SRID 4326, and the domain refuses one that does not. An
-- undeclared SRID is refused rather than assigned. Z and M ordinates are refused
-- by the 2D check. Each case names the constraint that refuses it.
select set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', true);
do $$
declare
  r record;
  v_constraint text;
begin
  for r in select * from (values
    ('POINT(-104.99 39.74)', 'wgs84_geometry_check'),
    ('SRID=3857;POINT(-11700000 4900000)', 'wgs84_geometry_check'),
    ('SRID=4326;POINT Z(-104.99 39.74 1600)', 'features_geom_2d'),
    ('SRID=4326;POINTM(-104.99 39.74 5)', 'features_geom_2d'),
    ('SRID=4326;POINT ZM(-104.99 39.74 1600 5)', 'features_geom_2d')
  ) as c(wkt, expected) loop
    begin
      insert into public.features (layer_id, organization_id, geom, title)
        values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
                r.wkt::public.wgs84_geometry, 'Column type check');
      raise exception 'accepted a geometry the column type should refuse: %', r.wkt;
    exception when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint is distinct from r.expected then
        raise exception 'geometry % refused by % instead of %', r.wkt, v_constraint, r.expected;
      end if;
    end;
  end loop;
end;
$$;

-- Stamping. Actor, revision, and timestamps come from the trigger, not from the
-- caller. An update advances the revision whatever value the writer names.
do $$
declare
  v_row public.features;
begin
  select * into v_row from public.features where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  if v_row.created_by <> 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02' or v_row.updated_by <> 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02' then
    raise exception 'seed insert did not record the editor as actor';
  end if;
  if v_row.revision <> 1 then raise exception 'new feature revision is %, expected 1', v_row.revision; end if;

  update public.features set title = 'Point A revised', revision = 99
    where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  select * into v_row from public.features where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  if v_row.revision <> 2 then
    raise exception 'owner update set revision %, expected 2 from the trigger', v_row.revision;
  end if;

  -- Identity and placement cannot change, even for the owner.
  begin
    update public.features set layer_id = 'e6d3c2f4-9051-4c32-9d43-7f8091abc002'
      where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
    raise exception 'owner moved a feature to another layer';
  exception when raise_exception then
    if sqlerrm not like 'feature identity%' then raise; end if;
  end;

  -- A write without an authenticated actor is refused, including by the owner.
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'No actor');
    raise exception 'accepted a feature write with no actor';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', true);
end;
$$;

-- Editor in organization A reads its features and writes within its
-- organization. Cross-tenant reads and writes are denied, and column grants
-- keep identity, revision, and actor fields out of reach.
select set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', true);
set local role authenticated;
do $$
declare
  affected integer;
  v_id uuid;
  v_constraint text;
begin
  if (select count(*) from public.features) <> 4
    or (select count(*) from public.features where organization_id = 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab02') <> 0 then
    raise exception 'editor A reads outside or misses organization A';
  end if;

  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc003', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab02',
              'SRID=4326;POINT(2.35 48.85)'::public.wgs84_geometry, 'Cross-tenant insert');
    raise exception 'editor A inserted a feature into organization B';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc003', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              'SRID=4326;POINT(2.35 48.85)'::public.wgs84_geometry, 'Organization A row, B layer');
    raise exception 'editor A attached an organization B layer';
  exception when foreign_key_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_layer_organization_fkey' then
      raise exception 'foreign layer refused by % instead of features_layer_organization_fkey', v_constraint;
    end if;
  end;

  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              'SRID=4326;POINT Z(-104.99 39.74 1600)'::public.wgs84_geometry, '3D from API');
    raise exception 'editor A stored a 3D point';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_geom_2d' then
      raise exception '3D point refused by % instead of features_geom_2d', v_constraint;
    end if;
  end;

  insert into public.features (layer_id, organization_id, geom, title, properties)
    values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
            'SRID=4326;POINT(-104.97 39.73)'::public.wgs84_geometry, 'Editor point', '{"status_note": "ok"}')
    returning id into v_id;
  if (select created_by from public.features where id = v_id) <> 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02' then
    raise exception 'editor insert did not record the editor as actor';
  end if;

  update public.features set title = 'Point A edited by editor', description = 'Synthetic note'
    where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not edit a same-organization feature'; end if;

  update public.features set geom = 'SRID=4326;POLYGON((-105 39.5,-104.5 39.5,-104.5 39.95,-105 39.9,-105 39.5))'::public.wgs84_geometry
    where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0003';
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not reshape a same-organization polygon'; end if;
  begin
    update public.features set geom = 'SRID=4326;POLYGON((-105 39.5,-104.5 39.9,-104.5 39.5,-105 39.9,-105 39.5))'::public.wgs84_geometry
      where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0003';
    raise exception 'editor reshaped a polygon into a self-intersecting one';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'features_geom_valid' then
      raise exception 'self-intersecting reshape refused by % instead of features_geom_valid', v_constraint;
    end if;
  end;

  update public.features set title = 'cross-tenant rename' where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0004';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'editor A updated organization B feature'; end if;
  delete from public.features where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0004';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'editor A deleted organization B feature'; end if;

  begin
    update public.features set revision = 50 where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
    raise exception 'editor set a revision by hand';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.features set organization_id = 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab02'
      where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
    raise exception 'editor moved a feature to another organization';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.features set created_by = 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a01'
      where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
    raise exception 'editor rewrote the creating actor';
  exception when insufficient_privilege then null;
  end;

  delete from public.features where id = v_id;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not delete a same-organization feature'; end if;
end;
$$;

-- Viewer in organization A reads its features and writes nothing.
select set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a03', true);
set local role authenticated;
do $$
declare
  affected integer;
begin
  if (select count(*) from public.features where organization_id = 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01') <> 4 then
    raise exception 'viewer could not read organization A features';
  end if;

  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Viewer feature');
    raise exception 'viewer inserted a feature';
  exception when insufficient_privilege then null;
  end;

  update public.features set title = 'viewer rename' where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer updated a feature'; end if;
  delete from public.features where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer deleted a feature'; end if;
end;
$$;

-- Editor in organization B sees only organization B and cannot touch A.
select set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a04', true);
set local role authenticated;
do $$
declare
  affected integer;
begin
  if (select count(*) from public.features) <> 1
    or (select count(*) from public.features where organization_id = 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01') <> 0 then
    raise exception 'organization B editor reads organization A features';
  end if;

  update public.features set title = 'cross-tenant edit' where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'organization B editor updated organization A feature'; end if;
  delete from public.features where id = 'f7e4d3c5-a162-4d43-8e54-8091abcd0001';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'organization B editor deleted organization A feature'; end if;

  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Cross-tenant insert');
    raise exception 'organization B editor inserted into organization A';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- Anonymous visitors hold no privilege on features. The privilege checks above
-- prove that directly, and the statements below confirm the behavior.
set local role anon;
do $$
begin
  begin
    perform 1 from public.features limit 1;
    raise exception 'anonymous feature read succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.features (layer_id, organization_id, geom, title)
      values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
              'SRID=4326;POINT(-104.99 39.74)'::public.wgs84_geometry, 'Anonymous feature');
    raise exception 'anonymous feature insert succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- Bounded viewport query: with sequential scans disabled, the planner must use
-- the GiST index on geom. This shows the index is usable. It does not show the
-- planner chooses it for real data: this fixture has four rows, and #13 measures
-- a real layer.
reset role;
select set_config('request.jwt.claim.sub', 'c4b1a0d2-7e3f-4a10-9b21-5d6e7f809a02', true);
set local enable_seqscan = off;
do $$
declare
  r record;
  v_plan text := '';
begin
  for r in execute $q$
    explain (costs off)
    select id from public.features
    where layer_id = 'e6d3c2f4-9051-4c32-9d43-7f8091abc001'
      and geom operator(extensions.&&) extensions.st_makeenvelope(-105, 39.4, -104.4, 40, 4326)
    limit 100
  $q$ loop
    v_plan := v_plan || r."QUERY PLAN" || E'\n';
  end loop;
  if position('features_geom_gist_idx' in v_plan) = 0 then
    raise exception 'bounded viewport query cannot use the GiST index: %', v_plan;
  end if;
end;
$$;

-- A feature is part of its layer. Deleting the layer removes it, and the
-- other layer's features remain.
reset role;
do $$
declare
  v_count integer;
begin
  delete from public.layers where id = 'e6d3c2f4-9051-4c32-9d43-7f8091abc002';
  select count(*) into v_count from public.features
    where layer_id = 'e6d3c2f4-9051-4c32-9d43-7f8091abc002';
  if v_count <> 0 then raise exception 'deleting a layer left its features behind'; end if;
  if (select count(*) from public.features where layer_id = 'e6d3c2f4-9051-4c32-9d43-7f8091abc001') <> 3 then
    raise exception 'deleting one layer changed another layer''s features';
  end if;
end;
$$;

-- The table CHECKs are backstops for a later migration that drops the domain.
-- Drop it inside this transaction, then show the CHECKs alone refuse an undeclared
-- SRID, a non-4326 SRID, Z, and M. The rollback restores the column.
alter table public.features alter column geom type extensions.geometry;
do $$
declare
  r record;
  v_constraint text;
begin
  for r in select * from (values
    ('POINT(-104.99 39.74)', 'features_geom_srid'),
    -- In-range coordinates, so the SRID check is what refuses it. Web Mercator
    -- metres would fail features_geom_lon_lat_range first.
    ('SRID=3857;POINT(-104.99 39.74)', 'features_geom_srid'),
    ('SRID=4326;POINT Z(-104.99 39.74 1600)', 'features_geom_2d'),
    ('SRID=4326;POINTM(-104.99 39.74 5)', 'features_geom_2d')
  ) as c(wkt, expected) loop
    begin
      insert into public.features (layer_id, organization_id, geom, title)
        values ('e6d3c2f4-9051-4c32-9d43-7f8091abc001', 'd5c2b1e3-8f40-4b21-8c32-6e7f8091ab01',
                r.wkt::extensions.geometry, 'Backstop check');
      raise exception 'accepted without the column typmod: %', r.wkt;
    exception when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint is distinct from r.expected then
        raise exception 'backstop geometry % refused by % instead of %', r.wkt, v_constraint, r.expected;
      end if;
    end;
  end loop;
end;
$$;

rollback;
