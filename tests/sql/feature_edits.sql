-- Execute against a disposable database. Every fixture and role switch rolls back.
--
-- Every call below goes to the RPC directly, as the caller's database role, with
-- no route in between. The three functions are granted to authenticated, so each
-- one is a public API in its own right: a bound, an authorization check, or a
-- revision check that lived only in a route would not be a control. Each refusal
-- asserts the SQLSTATE and the exact message, so a request refused for the wrong
-- reason fails the test. Validation failures must come from the function (22023),
-- never from a table constraint (23514): a constraint error carries the failing
-- row, which would put feature content into a database log.
begin;

create function pg_temp.id(n text) returns uuid
language sql immutable
as $$
  select (case n
    when 'admin_a' then 'a1b2c3d4-e5f6-4a7b-8c9d-000000000001'
    when 'editor_a' then 'a1b2c3d4-e5f6-4a7b-8c9d-000000000002'
    when 'viewer_a' then 'a1b2c3d4-e5f6-4a7b-8c9d-000000000003'
    when 'editor_b' then 'a1b2c3d4-e5f6-4a7b-8c9d-000000000004'
    when 'outsider' then 'a1b2c3d4-e5f6-4a7b-8c9d-000000000005'
    when 'org_a' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000a1'
    when 'org_b' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000a2'
    when 'layer_a1' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000c1'
    when 'layer_a2' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000c2'
    when 'layer_b1' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000c3'
    when 'feat_point' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000f1'
    when 'feat_line' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000f2'
    when 'feat_poly' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000f3'
    when 'feat_b' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000f4'
    when 'feat_absent' then 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000ff'
  end)::uuid
$$;

create function pg_temp.act_as(n text) returns void
language sql
as $$ select set_config('request.jwt.claim.sub', pg_temp.id(n)::text, true) $$;

-- Runs one statement and reports how it ended: ok, or SQLSTATE|message|detail.
create function pg_temp.outcome(q text) returns text
language plpgsql
as $$
declare
  v_detail text;
begin
  execute q;
  return 'ok';
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return sqlstate || '|' || sqlerrm || '|' || coalesce(v_detail, '');
end;
$$;

-- The statement must fail with exactly this SQLSTATE and message. A different
-- error, or success, fails the test and names the label.
create function pg_temp.expect(label text, q text, code text, msg text, detail text default '')
returns void
language plpgsql
as $$
declare
  v_got text := pg_temp.outcome(q);
  v_want text := code || '|' || msg || '|' || detail;
begin
  if v_got is distinct from v_want then
    raise exception '%: expected [%] but got [%]', label, v_want, v_got;
  end if;
end;
$$;

create function pg_temp.point(lon double precision, lat double precision) returns jsonb
language sql immutable
as $$ select jsonb_build_object('type', 'Point', 'coordinates', jsonb_build_array(lon, lat)) $$;

-- A ten-vertex line whose JSON text is exactly total bytes. The padding is
-- trailing zeros in the coordinates, which jsonb keeps because it preserves the
-- scale of a numeric. A numeric holds at most 16383 fractional digits, so a single
-- coordinate cannot carry the padding of a 128 KiB geometry; twenty can.
create function pg_temp.padded_line(total integer) returns jsonb
language plpgsql immutable
as $$
declare
  v_base integer;
  v_extra integer;
  v_each integer;
  v_rest integer;
begin
  select octet_length(jsonb_build_object('type', 'LineString', 'coordinates', (
    select jsonb_agg(jsonb_build_array((-104.9 + i * 0.01)::numeric(10, 2), (39.7 + i * 0.01)::numeric(10, 2)) order by i)
    from generate_series(0, 9) as i))::text) into v_base;
  v_extra := total - v_base;
  v_each := v_extra / 20;
  v_rest := v_extra % 20;
  return jsonb_build_object('type', 'LineString', 'coordinates', (
    select jsonb_agg(jsonb_build_array(
      ((-104.9 + i * 0.01)::numeric(10, 2)::text || repeat('0', v_each + case when i = 0 then v_rest else 0 end))::numeric,
      ((39.7 + i * 0.01)::numeric(10, 2)::text || repeat('0', v_each))::numeric) order by i)
    from generate_series(0, 9) as i));
end;
$$;

create function pg_temp.line(n integer) returns jsonb
language sql immutable
as $$
  select jsonb_build_object('type', 'LineString', 'coordinates', (
    select jsonb_agg(jsonb_build_array(-104 + i / 10000.0, 39 + (i % 2) / 100.0) order by i)
    from generate_series(0, n - 1) as i
  ))
$$;

insert into auth.users (id, email) values
  (pg_temp.id('admin_a'), 'edit-admin-a@neteoc.invalid'),
  (pg_temp.id('editor_a'), 'edit-editor-a@neteoc.invalid'),
  (pg_temp.id('viewer_a'), 'edit-viewer-a@neteoc.invalid'),
  (pg_temp.id('editor_b'), 'edit-editor-b@neteoc.invalid'),
  (pg_temp.id('outsider'), 'edit-outsider@neteoc.invalid');

insert into public.organizations (id, name) values
  (pg_temp.id('org_a'), 'Edit test organization A'),
  (pg_temp.id('org_b'), 'Edit test organization B');

insert into public.memberships (organization_id, user_id, role) values
  (pg_temp.id('org_a'), pg_temp.id('admin_a'), 'admin'),
  (pg_temp.id('org_a'), pg_temp.id('editor_a'), 'editor'),
  (pg_temp.id('org_a'), pg_temp.id('viewer_a'), 'viewer'),
  (pg_temp.id('org_b'), pg_temp.id('editor_b'), 'editor');

insert into public.layers (id, organization_id, title) values
  (pg_temp.id('layer_a1'), pg_temp.id('org_a'), 'Edit layer A1'),
  (pg_temp.id('layer_a2'), pg_temp.id('org_a'), 'Edit layer A2'),
  (pg_temp.id('layer_b1'), pg_temp.id('org_b'), 'Edit layer B1');

select pg_temp.act_as('editor_a');
insert into public.features (id, layer_id, organization_id, geom, title, description, properties) values
  (pg_temp.id('feat_point'), pg_temp.id('layer_a1'), pg_temp.id('org_a'),
   'SRID=4326;POINT(-104.99 39.74)', 'Seed point', 'Seed description', '{"fuel": "diesel"}'),
  (pg_temp.id('feat_line'), pg_temp.id('layer_a1'), pg_temp.id('org_a'),
   'SRID=4326;LINESTRING(-104.9 39.7,-104.8 39.8)', 'Seed line', null, '{}'),
  (pg_temp.id('feat_poly'), pg_temp.id('layer_a1'), pg_temp.id('org_a'),
   'SRID=4326;POLYGON((-105 39.5,-104.5 39.5,-104.5 39.9,-105 39.9,-105 39.5))', 'Seed polygon', null, '{}');
select pg_temp.act_as('editor_b');
insert into public.features (id, layer_id, organization_id, geom, title) values
  (pg_temp.id('feat_b'), pg_temp.id('layer_b1'), pg_temp.id('org_b'),
   'SRID=4326;POINT(2.35 48.85)', 'Seed point B');

-- ---------------------------------------------------------------------------
-- Catalog: grants, pins, and the removal of direct writes. Privileges are asserted
-- with the has_*_privilege functions, not inferred from behavior. The CI bootstrap
-- grants everything to anon and authenticated by default, so a missing revoke
-- shows up here.
-- ---------------------------------------------------------------------------
do $$
declare
  fn text;
  col text;
begin
  -- Revision discipline holds only if no other write path exists. A table grant
  -- to authenticated would let a client skip the expected-revision check.
  if has_table_privilege('authenticated', 'public.features', 'insert, update, delete, truncate, references, trigger') then
    raise exception 'authenticated holds a table-level write privilege on features';
  end if;
  if has_any_column_privilege('authenticated', 'public.features', 'insert, update, references') then
    raise exception 'authenticated holds a column-level write privilege on features';
  end if;
  if not has_table_privilege('authenticated', 'public.features', 'select') then
    raise exception 'authenticated lost select on features';
  end if;
  if has_table_privilege('anon', 'public.features', 'select, insert, update, delete')
    or has_any_column_privilege('anon', 'public.features', 'select, insert, update') then
    raise exception 'anon holds a privilege on features';
  end if;

  foreach fn in array array[
    'public.create_feature(uuid, jsonb, text, text, text, jsonb)',
    'public.update_feature(uuid, integer, jsonb)',
    'public.delete_feature(uuid, integer)'
  ] loop
    if not has_function_privilege('authenticated', fn, 'execute') then
      raise exception 'authenticated cannot execute %', fn;
    end if;
    if has_function_privilege('anon', fn, 'execute') then
      raise exception 'anon can execute %', fn;
    end if;
    if exists (
      select 1
      from pg_proc as p
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
      where p.oid = fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'PUBLIC can execute %', fn;
    end if;
    -- Definer, because the caller holds no table privilege. The search path is
    -- pinned and every reference is schema-qualified.
    if not exists (
      select 1 from pg_proc
      where oid = fn::regprocedure
        and prosecdef
        and proconfig @> array['search_path=""']
    ) then
      raise exception '% must be security definer with search_path pinned', fn;
    end if;
  end loop;

  -- The number check depends on the shortest-round-trip float format, which a
  -- session can change. The function pins it.
  if not exists (
    select 1 from pg_proc
    where oid = 'app_private.attribute_numbers_faithful(jsonb)'::regprocedure
      and proconfig @> array['extra_float_digits=1']
  ) then
    raise exception 'the number check must pin extra_float_digits';
  end if;

  -- Helpers and trigger functions are reachable only through the RPCs and the
  -- table. They run with the caller's rights and a pinned path, except the audit
  -- trigger, which must append for a caller with no grant on the audit table.
  foreach fn in array array[
    'app_private.feature_json(public.features)',
    'app_private.parse_feature_geometry(jsonb)',
    'app_private.attribute_numbers_faithful(jsonb)',
    'app_private.validate_feature_attributes(jsonb)',
    'app_private.check_feature_title(text)',
    'app_private.check_feature_description(text)',
    'app_private.check_feature_status(text)',
    'app_private.raise_feature_unavailable(uuid, uuid)',
    'app_private.record_feature_deletion()',
    'app_private.reject_feature_audit_change()'
  ] loop
    if has_function_privilege('anon', fn, 'execute')
      or has_function_privilege('authenticated', fn, 'execute') then
      raise exception 'an application role can execute %', fn;
    end if;
    if not exists (
      select 1 from pg_proc
      where oid = fn::regprocedure and proconfig @> array['search_path=""']
    ) then
      raise exception '% must pin search_path', fn;
    end if;
  end loop;
  if not (select prosecdef from pg_proc where oid = 'app_private.record_feature_deletion()'::regprocedure) then
    raise exception 'the deletion audit trigger must be security definer';
  end if;
  if (select prosecdef from pg_proc where oid = 'app_private.parse_feature_geometry(jsonb)'::regprocedure) then
    raise exception 'the geometry parser must be security invoker';
  end if;

  -- The audit table: RLS on, no grant to any application role, append-only.
  if not exists (
    select 1 from pg_class
    where oid = 'app_private.feature_audit_events'::regclass and relrowsecurity
  ) then
    raise exception 'RLS is not enabled on feature_audit_events';
  end if;
  if has_table_privilege('anon', 'app_private.feature_audit_events', 'select, insert, update, delete, truncate')
    or has_table_privilege('authenticated', 'app_private.feature_audit_events', 'select, insert, update, delete, truncate')
    or has_any_column_privilege('authenticated', 'app_private.feature_audit_events', 'select, insert, update') then
    raise exception 'an application role holds a privilege on feature_audit_events';
  end if;
  -- No foreign key from the audit table to features or layers: the record must
  -- outlive the row it describes.
  if exists (
    select 1 from pg_constraint
    where conrelid = 'app_private.feature_audit_events'::regclass
      and contype = 'f'
      and confrelid in ('public.features'::regclass, 'public.layers'::regclass)
  ) then
    raise exception 'feature_audit_events references a table whose rows it must outlive';
  end if;
  -- The audit table has no column that could hold feature content.
  foreach col in array array['title', 'description', 'status', 'properties', 'attributes', 'geom'] loop
    if exists (
      select 1 from pg_attribute
      where attrelid = 'app_private.feature_audit_events'::regclass
        and attname = col and not attisdropped
    ) then
      raise exception 'feature_audit_events has a % column', col;
    end if;
  end loop;
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'app_private.feature_audit_events'::regclass
      and tgname = 'feature_audit_events_immutable'
      and tgenabled = 'O'
  ) or not exists (
    select 1 from pg_trigger
    where tgrelid = 'app_private.feature_audit_events'::regclass
      and tgname = 'feature_audit_events_no_truncate'
      and tgenabled = 'O'
  ) then
    raise exception 'the audit table lacks its append-only triggers';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.features'::regclass
      and tgname = 'features_audit_deletion'
      and tgenabled = 'O'
  ) then
    raise exception 'features lacks the deletion audit trigger';
  end if;
  -- Statement-level BEFORE TRUNCATE, so the refusal happens once per statement.
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.features'::regclass
      and tgname = 'features_refuse_truncate'
      and tgenabled = 'O'
      and (tgtype & 2) = 2    -- BEFORE
      and (tgtype & 32) = 32  -- TRUNCATE
      and (tgtype & 1) = 0    -- statement level
  ) then
    raise exception 'features lacks the BEFORE TRUNCATE statement trigger';
  end if;
end;
$$;

-- Structural proxy for the compare-and-set. The behavioural race tests prove the
-- predicate works; this fails if someone moves the revision test out of the write
-- statement, for example into a separate SELECT before it. It is brittle on purpose:
-- a failure means the write's shape changed and the race evidence needs a rerun.
do $$
declare
  v_src text;
  v_fn text;
  v_write text;
  v_end text;
begin
  foreach v_fn in array array['public.update_feature', 'public.delete_feature'] loop
    select pg_get_functiondef((v_fn || case when v_fn like '%update%' then '(uuid, integer, jsonb)' else '(uuid, integer)' end)::regprocedure)
      into v_src;
    v_write := case when v_fn like '%update%' then 'update public.features as f' else 'delete from public.features as f' end;
    v_end := 'returning f.* into v_row;';
    if position(v_write in v_src) = 0 or position(v_end in v_src) = 0
      or position('and f.revision = p_expected_revision' in v_src) = 0
      or position('and f.revision = p_expected_revision' in v_src)
        not between position(v_write in v_src) and position(v_end in v_src) then
      raise exception '% does not check the revision inside its write statement', v_fn;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Create: allowed roles, then the refusals that must look alike.
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_feature jsonb;
  v_listed jsonb;
  v_row public.features;
  v_ids uuid[] := '{}';
  v_id uuid;
begin
  -- Editor creates a point, a line, and a polygon in layer A1.
  perform pg_temp.act_as('editor_a');
  v_feature := public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-104.97, 39.73), 'Editor point',
    'A synthetic note', 'open', '{"count": 3, "tags": ["a", "b"]}');
  if v_feature->>'type' <> 'Feature'
    or v_feature->'geometry' <> '{"type": "Point", "coordinates": [-104.97, 39.73]}'::jsonb
    or v_feature->'properties'->>'title' <> 'Editor point'
    or v_feature->'properties'->>'description' <> 'A synthetic note'
    or v_feature->'properties'->>'status' <> 'open'
    or v_feature->'properties'->'attributes' <> '{"count": 3, "tags": ["a", "b"]}'::jsonb
    or (v_feature->'properties'->>'revision')::integer <> 1 then
    raise exception 'create_feature returned an unexpected feature: %', v_feature;
  end if;
  v_ids := v_ids || (v_feature->>'id')::uuid;

  -- The result is the same document list_layer_features serves, so a client
  -- renders a write result and a read result with one parser.
  v_listed := (
    select f
    from jsonb_array_elements(
      public.list_layer_features(pg_temp.id('layer_a1'), null, null, null, null, 200, null, null, 258048)->'features'
    ) as f
    where f->>'id' = v_feature->>'id'
  );
  if v_listed is distinct from v_feature then
    raise exception 'create result differs from the list read: % vs %', v_feature, v_listed;
  end if;

  v_feature := public.create_feature(pg_temp.id('layer_a1'), pg_temp.line(3), 'Editor line');
  v_ids := v_ids || (v_feature->>'id')::uuid;
  v_feature := public.create_feature(pg_temp.id('layer_a1'),
    '{"type":"Polygon","coordinates":[[[-105,39.5],[-104.5,39.5],[-104.5,39.9],[-105,39.5]]]}', 'Editor polygon');
  v_ids := v_ids || (v_feature->>'id')::uuid;
  if (select count(*) from public.features where id = any (v_ids)) <> 3 then
    raise exception 'editor creates did not persist';
  end if;

  -- The organization and the actor come from the database, never the caller.
  for v_row in select * from public.features where id = any (v_ids) loop
    if v_row.organization_id <> pg_temp.id('org_a')
      or v_row.created_by <> pg_temp.id('editor_a')
      or v_row.updated_by <> pg_temp.id('editor_a')
      or v_row.revision <> 1 then
      raise exception 'created row has wrong organization, actor, or revision';
    end if;
  end loop;

  -- An admin may create too.
  perform pg_temp.act_as('admin_a');
  perform public.create_feature(pg_temp.id('layer_a2'), pg_temp.point(-104.9, 39.7), 'Admin point');

  -- A viewer, a user with no membership, another organization's editor, and a
  -- nonexistent layer all get the same answer, byte for byte.
  perform pg_temp.act_as('viewer_a');
  perform pg_temp.expect('viewer create', format(
    'select public.create_feature(%L, %L::jsonb, %L)', pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Viewer point'),
    '42501', 'layer not found or not editable');
  perform pg_temp.act_as('outsider');
  perform pg_temp.expect('outsider create', format(
    'select public.create_feature(%L, %L::jsonb, %L)', pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Outsider point'),
    '42501', 'layer not found or not editable');
  perform pg_temp.act_as('editor_b');
  perform pg_temp.expect('cross-tenant create', format(
    'select public.create_feature(%L, %L::jsonb, %L)', pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Cross-tenant point'),
    '42501', 'layer not found or not editable');
  perform pg_temp.expect('nonexistent layer create', format(
    'select public.create_feature(%L, %L::jsonb, %L)', 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000fe', pg_temp.point(-104.9, 39.7), 'Ghost point'),
    '42501', 'layer not found or not editable');
  -- The refusal is decided before the payload is looked at, so an invalid
  -- payload from an unauthorized caller does not reveal which layers exist.
  perform pg_temp.expect('cross-tenant create with invalid payload', format(
    'select public.create_feature(%L, %L::jsonb, %L)', pg_temp.id('layer_a1'), '{"type":"MultiPoint","coordinates":[]}', ''),
    '42501', 'layer not found or not editable');
  perform pg_temp.expect('nonexistent layer create with invalid payload', format(
    'select public.create_feature(%L, %L::jsonb, %L)', 'a1b2c3d4-e5f6-4a7b-8c9d-0000000000fe', '{"type":"MultiPoint","coordinates":[]}', ''),
    '42501', 'layer not found or not editable');

  -- A caller with no identity at all.
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.expect('unsigned create', format(
    'select public.create_feature(%L, %L::jsonb, %L)', pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Unsigned point'),
    '42501', 'sign in to edit features');

  -- None of the refused calls wrote anything.
  reset role;
  if exists (select 1 from public.features where title in
    ('Viewer point', 'Outsider point', 'Cross-tenant point', 'Ghost point', 'Unsigned point')) then
    raise exception 'a refused create left a row behind';
  end if;
  set local role authenticated;
end;
$$;

-- Anonymous callers have no execute privilege at all.
set local role anon;
do $$
begin
  perform pg_temp.expect('anon create', format(
    'select public.create_feature(%L, %L::jsonb, %L)', pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Anon point'),
    '42501', 'permission denied for function create_feature');
  perform pg_temp.expect('anon update', format(
    'select public.update_feature(%L, 1, %L::jsonb)', pg_temp.id('feat_point'), '{"title": "Anon"}'),
    '42501', 'permission denied for function update_feature');
  perform pg_temp.expect('anon delete', format(
    'select public.delete_feature(%L, 1)', pg_temp.id('feat_point')),
    '42501', 'permission denied for function delete_feature');
end;
$$;

-- ---------------------------------------------------------------------------
-- Create validation. Every row is refused by the function with its own message.
-- A constraint refusal (23514) would carry the failing row into the log, so the
-- SQLSTATE is part of the assertion: remove a function check and the row below
-- reaches the table constraint and fails here.
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  r record;
begin
  perform pg_temp.act_as('editor_a');

  for r in select * from (values
    ('geometry null', 'null::jsonb', 'geometry is required'),
    ('geometry not an object', '''[1, 2]''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('geometry a string', '''"POINT(1 2)"''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('feature wrapper', '''{"type":"Feature","geometry":{"type":"Point","coordinates":[-104.9,39.7]}}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('multipoint', '''{"type":"MultiPoint","coordinates":[[-104.9,39.7]]}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('multilinestring', '''{"type":"MultiLineString","coordinates":[[[-104.9,39.7],[-104.8,39.8]]]}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('multipolygon', '''{"type":"MultiPolygon","coordinates":[[[[-105,39.5],[-104.5,39.5],[-104.5,39.9],[-105,39.5]]]]}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('collection', '''{"type":"GeometryCollection","geometries":[]}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('missing type', '''{"coordinates":[-104.9,39.7]}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('missing coordinates', '''{"type":"Point"}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('crs member', '''{"type":"Point","coordinates":[-104.9,39.7],"crs":{"type":"name","properties":{"name":"EPSG:3857"}}}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('bbox member', '''{"type":"Point","coordinates":[-104.9,39.7],"bbox":[0,0,1,1]}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('point with altitude', '''{"type":"Point","coordinates":[-104.9,39.7,1600]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('point with one number', '''{"type":"Point","coordinates":[-104.9]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('point empty coordinates', '''{"type":"Point","coordinates":[]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('point string coordinate', '''{"type":"Point","coordinates":["-104.9",39.7]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('point null coordinate', '''{"type":"Point","coordinates":[null,39.7]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('point nested position', '''{"type":"Point","coordinates":[[-104.9,39.7]]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('line with altitude', '''{"type":"LineString","coordinates":[[-104.9,39.7,1],[-104.8,39.8,2]]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('line empty', '''{"type":"LineString","coordinates":[]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('line of numbers', '''{"type":"LineString","coordinates":[-104.9,39.7]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('line short position', '''{"type":"LineString","coordinates":[[-104.9],[-104.8,39.8]]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('line string coordinate', '''{"type":"LineString","coordinates":[[-104.9,"39.7"],[-104.8,39.8]]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('polygon ring of numbers', '''{"type":"Polygon","coordinates":[-105,39.5]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('polygon one-deep', '''{"type":"Polygon","coordinates":[[-105,39.5],[-104.5,39.5],[-104.5,39.9],[-105,39.5]]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('polygon without rings', '''{"type":"Polygon","coordinates":[]}''::jsonb', 'geometry coordinates must be 2D numeric positions'),
    ('line 2001 vertices', 'pg_temp.line(2001)', 'geometry must contain at most 2000 vertices'),
    ('swapped lon lat', 'pg_temp.point(39.74, -104.99)', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('longitude 181', 'pg_temp.point(181, 39.7)', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('longitude -181', 'pg_temp.point(-181, 39.7)', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('latitude 91', 'pg_temp.point(-104.9, 91)', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('latitude -91', 'pg_temp.point(-104.9, -91)', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('coordinate beyond double range', '''{"type":"Point","coordinates":[1e500,39.7]}''::jsonb', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('one-vertex line', '''{"type":"LineString","coordinates":[[-104.9,39.7]]}''::jsonb', 'geometry must be a valid, non-empty shape'),
    ('repeated-point line', '''{"type":"LineString","coordinates":[[-104.9,39.7],[-104.9,39.7]]}''::jsonb', 'geometry must be a valid, non-empty shape'),
    ('bowtie polygon', '''{"type":"Polygon","coordinates":[[[-105,39.5],[-104.5,39.9],[-104.5,39.5],[-105,39.9],[-105,39.5]]]}''::jsonb', 'geometry must be a valid, non-empty shape'),
    ('unclosed ring', '''{"type":"Polygon","coordinates":[[[-105,39.5],[-104.5,39.5],[-104.5,39.9],[-105,39.9]]]}''::jsonb', 'geometry must be a valid, non-empty shape'),
    ('three-vertex ring', '''{"type":"Polygon","coordinates":[[[-105,39.5],[-104.5,39.5],[-105,39.5]]]}''::jsonb', 'geometry must be a valid, non-empty shape'),
    ('geometry over the byte ceiling', 'pg_temp.padded_line(131073)', 'geometry must be at most 131072 bytes')
  ) as c(label, geometry_sql, message) loop
    perform pg_temp.expect('geometry: ' || r.label,
      format('select public.create_feature(%L, %s, %L)', pg_temp.id('layer_a1'), r.geometry_sql, 'Rejected'),
      '22023', r.message);
  end loop;

  -- The byte ceiling is exact: one byte under is read, and the ceiling itself is
  -- accepted by the size check and stored.
  if octet_length(pg_temp.padded_line(131072)::text) <> 131072 then
    raise exception 'the padding helper is off by %', octet_length(pg_temp.padded_line(131072)::text) - 131072;
  end if;
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.padded_line(131072), 'At the byte ceiling');

  -- Vertex boundary: 2000 is stored, 2001 is refused (above).
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.line(2000), 'Two thousand vertices');
  -- Coordinate boundaries are valid.
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(180, 90), 'Boundary point');
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-180, -90), 'Opposite boundary point');
end;
$$;

do $$
declare
  r record;
begin
  perform pg_temp.act_as('editor_a');
  -- Text and attribute bounds, each with a boundary pair where one exists.
  for r in select * from (values
    ('title null', 'null', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title empty', '''''', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title blank', '''   ''', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title padded', '''padded ''', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title tab', 'chr(9)', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title newline', 'chr(10)', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title non-breaking space', 'chr(160)', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title ideographic space', 'chr(12288)', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title trailing tab', '''x'' || chr(9)', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title leading non-breaking space', 'chr(160) || ''x''', 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title 121', quote_literal(repeat('t', 121)), 'null', 'null', '''{}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('description 2001', '''ok''', quote_literal(repeat('d', 2001)), 'null', '''{}''::jsonb', 'description must be at most 2000 characters'),
    ('status empty', '''ok''', 'null', '''''', '''{}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('status padded', '''ok''', 'null', '''open ''', '''{}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('status tab', '''ok''', 'null', 'chr(9)', '''{}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('status newline', '''ok''', 'null', 'chr(10)', '''{}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('status non-breaking space', '''ok''', 'null', 'chr(160)', '''{}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('status 41', '''ok''', 'null', quote_literal(repeat('s', 41)), '''{}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('attributes null', '''ok''', 'null', 'null', 'null::jsonb', 'attributes must be a JSON object of at most 4096 bytes'),
    ('attributes array', '''ok''', 'null', 'null', '''[]''::jsonb', 'attributes must be a JSON object of at most 4096 bytes'),
    ('attributes string', '''ok''', 'null', 'null', '''"x"''::jsonb', 'attributes must be a JSON object of at most 4096 bytes'),
    ('attributes 4097 bytes', '''ok''', 'null', 'null', format('jsonb_build_object(''k'', %L)', repeat('x', 4097 - 9)), 'attributes must be a JSON object of at most 4096 bytes'),
    -- Numbers the read path cannot return faithfully are refused at write time.
    ('attribute beyond double range', '''ok''', 'null', 'null', '''{"n": 1e500}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute below double range', '''ok''', 'null', 'null', '''{"n": -1e500}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute integer beyond 2^53', '''ok''', 'null', 'null', '''{"n": 12345678901234567890}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute 2^53 + 1', '''ok''', 'null', 'null', '''{"n": 9007199254740993}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute over-precise decimal', '''ok''', 'null', 'null', '''{"n": 0.1000000000000000055511151231257827}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute nested in array', '''ok''', 'null', 'null', '''{"a": [1, {"b": [12345678901234567890]}]}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute underflow', '''ok''', 'null', 'null', '''{"n": 1e-500}''::jsonb', 'attribute numbers must be exactly representable as double-precision values')
  ) as c(label, title_sql, description_sql, status_sql, attributes_sql, message) loop
    perform pg_temp.expect(r.label,
      format('select public.create_feature(%L, %L::jsonb, %s, %s, %s, %s)',
        pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), r.title_sql, r.description_sql, r.status_sql, r.attributes_sql),
      '22023', r.message);
  end loop;

  -- Whitespace inside a title is kept, so only the ends are refused.
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Interior' || chr(160) || 'space');
  -- The boundary values on the accepted side.
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), repeat('t', 120),
    repeat('d', 2000), repeat('s', 40), jsonb_build_object('k', repeat('x', 4096 - 9)));
  -- Numbers that survive JSON.parse and JSON.stringify unchanged are accepted: a
  -- plain decimal, the largest exact integer, an integer a double holds exactly,
  -- the shortest decimal for a double, a small and a large exponent.
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Exact numbers', null, null,
    '{"a": 0.1, "b": 9007199254740991, "c": 9007199254740992, "d": 0.30000000000000004, "e": 1e22, "f": -1.5e300, "g": 5e-324, "h": [0, -0, 1.0, 2.50], "i": {"j": 3}}');
end;
$$;

-- A session's float output setting must not change which numbers are accepted.
set local extra_float_digits = 0;
do $$
begin
  perform pg_temp.act_as('editor_a');
  perform public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Float setting 0', null, null,
    '{"d": 0.30000000000000004}');
  perform pg_temp.expect('float setting 0, inexact number', format(
    'select public.create_feature(%L, %L::jsonb, %L, null, null, %L::jsonb)',
    pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Float setting 0', '{"n": 12345678901234567890}'),
    '22023', 'attribute numbers must be exactly representable as double-precision values');
end;
$$;
reset extra_float_digits;

-- ---------------------------------------------------------------------------
-- Update: allowed patch shapes, the revision check, and the refusals.
-- ---------------------------------------------------------------------------
do $$
declare
  v_before public.features;
  v_after public.features;
  v_result jsonb;
  v_detail text;
begin
  perform pg_temp.act_as('editor_a');
  select * into v_before from public.features where id = pg_temp.id('feat_point');
  if v_before.revision <> 1 then raise exception 'seed revision is not 1'; end if;

  -- Reshape: geometry only. Everything else keeps its value, and the revision,
  -- actor, and timestamp move with the geometry.
  perform pg_temp.act_as('admin_a');
  v_result := public.update_feature(pg_temp.id('feat_point'), 1,
    jsonb_build_object('geometry', pg_temp.point(-104.5, 39.5)));
  select * into v_after from public.features where id = pg_temp.id('feat_point');
  if v_result->'geometry' <> '{"type": "Point", "coordinates": [-104.5, 39.5]}'::jsonb
    or (v_result->'properties'->>'revision')::integer <> 2
    or extensions.st_astext(v_after.geom) <> 'POINT(-104.5 39.5)'
    or v_after.revision <> 2
    or v_after.title is distinct from v_before.title
    or v_after.description is distinct from v_before.description
    or v_after.status is distinct from v_before.status
    or v_after.properties is distinct from v_before.properties
    or v_after.updated_by <> pg_temp.id('admin_a')
    or v_after.created_by <> v_before.created_by
    or v_after.created_at <> v_before.created_at
    or v_after.id <> v_before.id
    or v_after.layer_id <> v_before.layer_id
    or v_after.organization_id <> v_before.organization_id then
    raise exception 'reshape did not move geometry, revision, and actor together: %', v_result;
  end if;

  -- Update several fields at once, and clear nullable ones with an explicit null.
  perform pg_temp.act_as('editor_a');
  v_result := public.update_feature(pg_temp.id('feat_point'), 2, jsonb_build_object(
    'title', 'Renamed point', 'description', null, 'status', 'closed', 'attributes', jsonb_build_object('fuel', 'unleaded')));
  select * into v_after from public.features where id = pg_temp.id('feat_point');
  if v_after.revision <> 3
    or v_after.title <> 'Renamed point'
    or v_after.description is not null
    or v_after.status <> 'closed'
    or v_after.properties <> '{"fuel": "unleaded"}'::jsonb
    or extensions.st_astext(v_after.geom) <> 'POINT(-104.5 39.5)'
    or v_after.updated_by <> pg_temp.id('editor_a') then
    raise exception 'multi-field update stored the wrong values: %', v_result;
  end if;

  -- Replaying the request that already succeeded is a conflict, not a second write.
  begin
    perform public.update_feature(pg_temp.id('feat_point'), 2, jsonb_build_object('title', 'Replay'));
    raise exception 'a replayed update was accepted';
  exception when sqlstate 'PT409' then
    get stacked diagnostics v_detail = pg_exception_detail;
    if sqlerrm <> 'feature revision conflict' or v_detail <> 'current revision 3' then
      raise exception 'replay conflict reported [%] [%]', sqlerrm, v_detail;
    end if;
  end;
  if (select title from public.features where id = pg_temp.id('feat_point')) <> 'Renamed point'
    or (select revision from public.features where id = pg_temp.id('feat_point')) <> 3 then
    raise exception 'a conflicting update changed the row';
  end if;

  -- A revision from the future conflicts as well. Only an exact match writes.
  perform pg_temp.expect('future revision', format(
    'select public.update_feature(%L, 4, %L::jsonb)', pg_temp.id('feat_point'), '{"title": "Future"}'),
    'PT409', 'feature revision conflict', 'current revision 3');

  -- Reshape a line and a polygon.
  perform public.update_feature(pg_temp.id('feat_line'), 1, jsonb_build_object('geometry', pg_temp.line(5)));
  perform public.update_feature(pg_temp.id('feat_poly'), 1, jsonb_build_object('geometry', jsonb_build_object(
    'type', 'Polygon',
    'coordinates', '[[[-105,39.5],[-104.5,39.5],[-104.5,39.95],[-105,39.9],[-105,39.5]]]'::jsonb)));
  if (select revision from public.features where id = pg_temp.id('feat_line')) <> 2
    or (select extensions.st_npoints(geom) from public.features where id = pg_temp.id('feat_line')) <> 5 then
    raise exception 'line reshape did not store';
  end if;
  -- A reshape to a different geometry type is a reshape. The type is not pinned.
  perform public.update_feature(pg_temp.id('feat_line'), 2, jsonb_build_object('geometry', pg_temp.point(-104.6, 39.6)));
  if (select extensions.geometrytype(geom) from public.features where id = pg_temp.id('feat_line')) <> 'POINT' then
    raise exception 'type-changing reshape did not store';
  end if;
end;
$$;

-- Update validation. Each patch is refused by the function and leaves the row alone.
do $$
declare
  r record;
  v_before public.features;
  v_after public.features;
begin
  perform pg_temp.act_as('editor_a');
  select * into v_before from public.features where id = pg_temp.id('feat_poly');

  for r in select * from (values
    ('patch null', 'null::jsonb', 'changes must be a JSON object'),
    ('patch array', '''[]''::jsonb', 'changes must be a JSON object'),
    ('patch string', '''"title"''::jsonb', 'changes must be a JSON object'),
    ('patch empty', '''{}''::jsonb', 'changes must name at least one field'),
    ('unknown field', '''{"title": "ok", "organization_id": "a1b2c3d4-e5f6-4a7b-8c9d-0000000000a2"}''::jsonb', 'changes contain a field that cannot be changed'),
    ('layer move', '''{"layer_id": "a1b2c3d4-e5f6-4a7b-8c9d-0000000000c2"}''::jsonb', 'changes contain a field that cannot be changed'),
    ('revision by hand', '''{"revision": 99}''::jsonb', 'changes contain a field that cannot be changed'),
    ('actor by hand', '''{"updated_by": "a1b2c3d4-e5f6-4a7b-8c9d-000000000001"}''::jsonb', 'changes contain a field that cannot be changed'),
    ('geometry null', '''{"geometry": null}''::jsonb', 'geometry is required'),
    ('title null', '''{"title": null}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title number', '''{"title": 5}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title padded', '''{"title": " padded"}''::jsonb', 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title tab', format('jsonb_build_object(''title'', %L)', chr(9)), 'title must be 1 to 120 characters with no leading or trailing space'),
    ('title non-breaking space', format('jsonb_build_object(''title'', %L)', chr(160)), 'title must be 1 to 120 characters with no leading or trailing space'),
    ('status newline', format('jsonb_build_object(''status'', %L)', chr(10)), 'status must be 1 to 40 characters with no leading or trailing space'),
    ('title 121', format('jsonb_build_object(''title'', %L)', repeat('t', 121)), 'title must be 1 to 120 characters with no leading or trailing space'),
    ('description 2001', format('jsonb_build_object(''description'', %L)', repeat('d', 2001)), 'description must be at most 2000 characters'),
    ('description number', '''{"description": 5}''::jsonb', 'description must be at most 2000 characters'),
    ('status 41', format('jsonb_build_object(''status'', %L)', repeat('s', 41)), 'status must be 1 to 40 characters with no leading or trailing space'),
    ('status empty', '''{"status": ""}''::jsonb', 'status must be 1 to 40 characters with no leading or trailing space'),
    ('attributes null', '''{"attributes": null}''::jsonb', 'attributes must be a JSON object of at most 4096 bytes'),
    ('attributes array', '''{"attributes": []}''::jsonb', 'attributes must be a JSON object of at most 4096 bytes'),
    ('attributes 4097', format('jsonb_build_object(''attributes'', jsonb_build_object(''k'', %L))', repeat('x', 4097 - 9)), 'attributes must be a JSON object of at most 4096 bytes'),
    ('attribute number', '''{"attributes": {"n": 12345678901234567890}}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('attribute infinity', '''{"attributes": {"n": 1e500}}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    ('geometry bowtie', '''{"geometry": {"type":"Polygon","coordinates":[[[-105,39.5],[-104.5,39.9],[-104.5,39.5],[-105,39.9],[-105,39.5]]]}}''::jsonb', 'geometry must be a valid, non-empty shape'),
    ('geometry multipoint', '''{"geometry": {"type":"MultiPoint","coordinates":[[-104.9,39.7]]}}''::jsonb', 'geometry must be a GeoJSON Point, LineString, or Polygon object'),
    ('geometry 2001', '{"geometry": ' || 'pg_temp.line(2001)' || '}', 'geometry must contain at most 2000 vertices'),
    ('geometry out of range', '''{"geometry": {"type":"Point","coordinates":[39.74,-104.99]}}''::jsonb', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    -- A valid field beside an invalid one: the whole patch is refused.
    ('valid title, invalid geometry', '''{"title": "Half applied", "geometry": {"type":"Point","coordinates":[181,0]}}''::jsonb', 'geometry must lie within longitude -180..180 and latitude -90..90'),
    ('valid geometry, invalid attributes', '''{"geometry": {"type":"Point","coordinates":[-104.9,39.7]}, "attributes": {"n": 1e500}}''::jsonb', 'attribute numbers must be exactly representable as double-precision values'),
    -- The size check runs before the field check, so an oversized patch of an
    -- unknown field proves the ceiling. One byte under it is read and refused as
    -- an unknown field, which proves the boundary is exact.
    ('patch one byte over the ceiling', format('jsonb_build_object(''zzz'', %L)', repeat('x', 147457 - 11)), 'changes must be at most 147456 bytes'),
    ('patch at the ceiling', format('jsonb_build_object(''zzz'', %L)', repeat('x', 147456 - 11)), 'changes contain a field that cannot be changed'),
    ('geometry one byte over the ceiling', 'jsonb_build_object(''geometry'', pg_temp.padded_line(131073))', 'geometry must be at most 131072 bytes')
  ) as c(label, patch_sql, message) loop
    -- The geometry 2001 row builds its patch from a function call, so evaluate it.
    perform pg_temp.expect('update: ' || r.label,
      format('select public.update_feature(%L, 1, %s)', pg_temp.id('feat_poly'),
        case r.label when 'geometry 2001' then 'jsonb_build_object(''geometry'', pg_temp.line(2001))' else r.patch_sql end),
      '22023', r.message);
  end loop;

  perform pg_temp.expect('expected revision null', format(
    'select public.update_feature(%L, null, %L::jsonb)', pg_temp.id('feat_poly'), '{"title": "x"}'),
    '22023', 'expected revision must be a positive whole number');
  perform pg_temp.expect('expected revision 0', format(
    'select public.update_feature(%L, 0, %L::jsonb)', pg_temp.id('feat_poly'), '{"title": "x"}'),
    '22023', 'expected revision must be a positive whole number');
  perform pg_temp.expect('expected revision negative', format(
    'select public.update_feature(%L, -1, %L::jsonb)', pg_temp.id('feat_poly'), '{"title": "x"}'),
    '22023', 'expected revision must be a positive whole number');
  perform pg_temp.expect('feature null', format(
    'select public.update_feature(null, 1, %L::jsonb)', '{"title": "x"}'),
    '22023', 'feature is required');

  -- Nothing above wrote anything: the row is byte-for-byte what it was.
  select * into v_after from public.features where id = pg_temp.id('feat_poly');
  if v_after is distinct from v_before then
    raise exception 'a refused update changed the row: % vs %', v_before, v_after;
  end if;
end;
$$;

-- The geometry boundary on the accepted side: a geometry at its byte ceiling is stored.
do $$
declare
  v_patch jsonb;
begin
  perform pg_temp.act_as('editor_a');
    v_patch := jsonb_build_object('geometry', pg_temp.padded_line(131072));
  perform public.update_feature(pg_temp.id('feat_poly'), 2, v_patch);
  if (select revision from public.features where id = pg_temp.id('feat_poly')) <> 3 then
    raise exception 'a patch inside the ceiling was refused';
  end if;
end;
$$;

-- TRUNCATE removes rows without firing the row-level deletion audit, so the guard
-- refuses it for the table owner too. Both routes are asserted: a direct truncate,
-- and a truncate of the parent that cascades to features. Each must fail with the
-- guard's own SQLSTATE and message. The owner is the strongest caller, so this is
-- the case that matters.
reset role;
do $$
declare
  v_before bigint := (select count(*) from public.features);
begin
  perform pg_temp.expect('owner truncates features', 'truncate public.features',
    '0A000', 'feature rows cannot be truncated; delete each feature so the deletion is audited');
  perform pg_temp.expect('owner truncates layers cascade', 'truncate public.layers cascade',
    '0A000', 'feature rows cannot be truncated; delete each feature so the deletion is audited');
  if (select count(*) from public.features) <> v_before or v_before = 0 then
    raise exception 'a refused truncate changed the feature count';
  end if;
end;
$$;
set local role authenticated;
do $$
begin
  perform pg_temp.act_as('admin_a');
  perform pg_temp.expect('authenticated truncates features', 'truncate public.features',
    '42501', 'permission denied for table features');
end;
$$;

-- A write that fails after validation changes nothing. The failure is injected with
-- a check no valid row of this title can pass, so the function's own validation
-- accepts the request and the UPDATE statement itself fails. Geometry, title,
-- attributes, revision, actor, and timestamp are all as they were.
do $$
declare
  v_before public.features;
  v_after public.features;
  v_outcome text;
begin
  perform pg_temp.act_as('editor_a');
  reset role;
  select * into v_before from public.features where id = pg_temp.id('feat_line');
  alter table public.features
    add constraint injected_failure check (title <> 'Injected failure') not valid;
  set local role authenticated;
  perform pg_temp.act_as('admin_a');
  v_outcome := pg_temp.outcome(format('select public.update_feature(%L, %s, %L::jsonb)',
    pg_temp.id('feat_line'), v_before.revision,
    jsonb_build_object('geometry', pg_temp.line(4), 'title', 'Injected failure', 'attributes', '{"k": 1}'::jsonb)));
  reset role;
  alter table public.features drop constraint injected_failure;
  select * into v_after from public.features where id = pg_temp.id('feat_line');
  if v_outcome not like '23514|%injected_failure%' then
    raise exception 'the injected failure did not surface: %', v_outcome;
  end if;
  if v_after is distinct from v_before then
    raise exception 'a failed update left a partial change: % vs %', v_before, v_after;
  end if;
  set local role authenticated;
end;
$$;

-- A create that fails after validation leaves no row.
do $$
declare
  v_outcome text;
  v_count bigint;
begin
  reset role;
  select count(*) into v_count from public.features;
  alter table public.features
    add constraint injected_failure check (title <> 'Injected failure') not valid;
  set local role authenticated;
  perform pg_temp.act_as('editor_a');
  v_outcome := pg_temp.outcome(format('select public.create_feature(%L, %L::jsonb, %L)',
    pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Injected failure'));
  reset role;
  alter table public.features drop constraint injected_failure;
  if v_outcome not like '23514|%injected_failure%' then
    raise exception 'the injected failure did not surface: %', v_outcome;
  end if;
  if (select count(*) from public.features) <> v_count then
    raise exception 'a failed create left a row';
  end if;
  set local role authenticated;
end;
$$;

-- Refusals that must look alike, and the revision information a refusal may carry.
do $$
declare
  v_expected text;
  v_who text;
  v_target text;
  v_seen text;
  v_before public.features;
  v_before_audit bigint;
begin
  reset role;
  select * into v_before from public.features where id = pg_temp.id('feat_b');
  set local role authenticated;

  -- A viewer of the feature's organization, an outsider, another organization's
  -- editor, and a caller naming a feature that never existed receive the same
  -- SQLSTATE, message, and detail, whatever the revision they send. In particular
  -- the wrong organization learns neither that the feature exists nor its
  -- revision.
  v_expected := '42501|feature not found or not editable|';
  foreach v_who in array array['viewer_a', 'outsider', 'editor_b'] loop
    perform pg_temp.act_as(v_who);
    foreach v_target in array array['feat_point', 'feat_absent'] loop
      -- editor_b on feat_point is the cross-tenant case; editor_b on feat_absent
      -- is a plain miss. viewer_a and outsider cover both too.
      for v_seen in
        select pg_temp.outcome(format('select public.update_feature(%L, %s, %L::jsonb)',
          pg_temp.id(v_target), rev, '{"title": "Intrusion"}'))
        from unnest(array[1, 3, 4, 999]) as rev
      loop
        if v_seen <> v_expected then
          raise exception 'update by % on % answered [%] instead of [%]', v_who, v_target, v_seen, v_expected;
        end if;
      end loop;
      for v_seen in
        select pg_temp.outcome(format('select public.delete_feature(%L, %s)', pg_temp.id(v_target), rev))
        from unnest(array[1, 3, 4, 999]) as rev
      loop
        if v_seen <> v_expected then
          raise exception 'delete by % on % answered [%] instead of [%]', v_who, v_target, v_seen, v_expected;
        end if;
      end loop;
    end loop;
  end loop;

  -- The same holds when the payload is invalid: the caller is turned away before
  -- the payload is read.
  perform pg_temp.act_as('editor_b');
  perform pg_temp.expect('cross-tenant update, invalid payload', format(
    'select public.update_feature(%L, 1, %L::jsonb)', pg_temp.id('feat_point'), '{"geometry": {"type": "MultiPoint"}}'),
    '42501', 'feature not found or not editable');
  perform pg_temp.expect('absent update, invalid payload', format(
    'select public.update_feature(%L, 1, %L::jsonb)', pg_temp.id('feat_absent'), '{"geometry": {"type": "MultiPoint"}}'),
    '42501', 'feature not found or not editable');

  -- Nothing the refused callers did changed a row.
  reset role;
  if (select title from public.features where id = pg_temp.id('feat_point')) <> 'Renamed point'
    or (select revision from public.features where id = pg_temp.id('feat_point')) <> 3 then
    raise exception 'a refused update or delete changed organization A data';
  end if;
  if (select f from public.features as f where id = pg_temp.id('feat_b')) is distinct from v_before then
    raise exception 'organization B data changed';
  end if;
  set local role authenticated;
end;
$$;

-- ---------------------------------------------------------------------------
-- Delete: revision discipline, audit, and the record outliving the row.
-- ---------------------------------------------------------------------------
do $$
declare
  v_result jsonb;
  v_audit record;
  v_count bigint;
  v_summary text;
begin
  perform pg_temp.act_as('editor_a');

  -- Stale: refused, row kept, nothing audited.
  perform pg_temp.expect('delete with a stale revision', format(
    'select public.delete_feature(%L, 2)', pg_temp.id('feat_point')),
    'PT409', 'feature revision conflict', 'current revision 3');
  perform pg_temp.expect('delete with a future revision', format(
    'select public.delete_feature(%L, 4)', pg_temp.id('feat_point')),
    'PT409', 'feature revision conflict', 'current revision 3');
  perform pg_temp.expect('delete revision 0', format(
    'select public.delete_feature(%L, 0)', pg_temp.id('feat_point')),
    '22023', 'expected revision must be a positive whole number');
  perform pg_temp.expect('delete revision null', format(
    'select public.delete_feature(%L, null)', pg_temp.id('feat_point')),
    '22023', 'expected revision must be a positive whole number');
  perform pg_temp.expect('delete feature null', 'select public.delete_feature(null, 1)',
    '22023', 'feature is required');
  reset role;
  if not exists (select 1 from public.features where id = pg_temp.id('feat_point') and revision = 3) then
    raise exception 'a refused delete removed or changed the row';
  end if;
  if exists (select 1 from app_private.feature_audit_events where feature_id = pg_temp.id('feat_point')) then
    raise exception 'a refused delete was audited';
  end if;
  set local role authenticated;
  perform pg_temp.act_as('editor_a');

  -- Success with the current revision.
  v_result := public.delete_feature(pg_temp.id('feat_point'), 3);
  if v_result <> jsonb_build_object('id', pg_temp.id('feat_point'), 'deleted', true, 'revision', 3) then
    raise exception 'delete_feature returned %', v_result;
  end if;

  reset role;
  if exists (select 1 from public.features where id = pg_temp.id('feat_point')) then
    raise exception 'delete_feature left the row';
  end if;
  select * into v_audit from app_private.feature_audit_events where feature_id = pg_temp.id('feat_point');
  if v_audit.organization_id <> pg_temp.id('org_a')
    or v_audit.layer_id <> pg_temp.id('layer_a1')
    or v_audit.actor_user_id <> pg_temp.id('editor_a')
    or v_audit.action <> 'deleted'
    or v_audit.resource_revision <> 3
    or v_audit.created_at is null then
    raise exception 'delete audit record is wrong: %', v_audit;
  end if;
  -- The summary is bounded and holds no feature content: not the title, the
  -- description, an attribute value, or a coordinate.
  v_summary := v_audit.summary;
  if char_length(v_summary) > 200
    or v_summary ilike '%Renamed point%'
    or v_summary ilike '%unleaded%'
    or v_summary like '%-104.5%'
    or v_summary like '%39.5%' then
    raise exception 'audit summary leaks content or exceeds its bound: %', v_summary;
  end if;
  if v_summary <> 'deleted POINT feature at revision 3' then
    raise exception 'unexpected audit summary: %', v_summary;
  end if;
  -- The audit row, and nothing else about the feature, outlives it.
  select count(*) into v_count from app_private.feature_audit_events;
  if v_count <> 1 then raise exception 'expected one audit event, found %', v_count; end if;
  set local role authenticated;

  -- A second delete of the same feature. The organization's editor learns the
  -- feature was deleted. Others still get the uniform answer.
  perform pg_temp.act_as('editor_a');
  perform pg_temp.expect('editor deletes again', format(
    'select public.delete_feature(%L, 3)', pg_temp.id('feat_point')),
    'PT410', 'feature was deleted');
  perform pg_temp.expect('editor updates a deleted feature', format(
    'select public.update_feature(%L, 3, %L::jsonb)', pg_temp.id('feat_point'), '{"title": "Zombie"}'),
    'PT410', 'feature was deleted');
  perform pg_temp.act_as('admin_a');
  perform pg_temp.expect('admin updates a deleted feature', format(
    'select public.update_feature(%L, 3, %L::jsonb)', pg_temp.id('feat_point'), '{"title": "Zombie"}'),
    'PT410', 'feature was deleted');
  perform pg_temp.act_as('viewer_a');
  perform pg_temp.expect('viewer updates a deleted feature', format(
    'select public.update_feature(%L, 3, %L::jsonb)', pg_temp.id('feat_point'), '{"title": "Zombie"}'),
    '42501', 'feature not found or not editable');
  perform pg_temp.act_as('editor_b');
  perform pg_temp.expect('other organization updates a deleted feature', format(
    'select public.update_feature(%L, 3, %L::jsonb)', pg_temp.id('feat_point'), '{"title": "Zombie"}'),
    '42501', 'feature not found or not editable');
  perform pg_temp.expect('other organization deletes a deleted feature', format(
    'select public.delete_feature(%L, 3)', pg_temp.id('feat_point')),
    '42501', 'feature not found or not editable');
  perform pg_temp.act_as('outsider');
  perform pg_temp.expect('outsider deletes a deleted feature', format(
    'select public.delete_feature(%L, 3)', pg_temp.id('feat_point')),
    '42501', 'feature not found or not editable');

  -- The viewer's and the other organization's attempts wrote no audit event.
  reset role;
  select count(*) into v_count from app_private.feature_audit_events;
  if v_count <> 1 then raise exception 'refused deletes were audited: % events', v_count; end if;
  set local role authenticated;

  -- Admin deletes with the current revision. The viewer cannot.
  perform pg_temp.act_as('viewer_a');
  perform pg_temp.expect('viewer deletes', format(
    'select public.delete_feature(%L, 3)', pg_temp.id('feat_poly')),
    '42501', 'feature not found or not editable');
  perform pg_temp.act_as('admin_a');
  perform public.delete_feature(pg_temp.id('feat_poly'), 3);
  reset role;
  if (select actor_user_id from app_private.feature_audit_events where feature_id = pg_temp.id('feat_poly'))
    <> pg_temp.id('admin_a') then
    raise exception 'the admin delete did not record the admin';
  end if;
  set local role authenticated;
end;
$$;

-- Application roles cannot read, forge, or alter the audit trail.
do $$
begin
  perform pg_temp.act_as('admin_a');
  perform pg_temp.expect('admin reads audit', 'select count(*) from app_private.feature_audit_events',
    '42501', 'permission denied for schema app_private');
  perform pg_temp.expect('admin writes audit', format(
    'insert into app_private.feature_audit_events (feature_id, organization_id, layer_id, actor_user_id, action, resource_revision, summary) values (%L, %L, %L, %L, %L, 1, %L)',
    pg_temp.id('feat_line'), pg_temp.id('org_a'), pg_temp.id('layer_a1'), pg_temp.id('admin_a'), 'deleted', 'forged'),
    '42501', 'permission denied for schema app_private');
end;
$$;

-- The audit trail is append-only, even for the owner. The owner is the strongest
-- writer there is, so refusing it is the proof that no path rewrites history.
reset role;
do $$
begin
  perform pg_temp.expect('owner updates audit', $q$update app_private.feature_audit_events set summary = 'edited'$q$,
    'P0001', 'feature audit events are immutable');
  perform pg_temp.expect('owner deletes audit', 'delete from app_private.feature_audit_events',
    'P0001', 'feature audit events are immutable');
  perform pg_temp.expect('owner truncates audit', 'truncate app_private.feature_audit_events',
    'P0001', 'feature audit events are immutable');
end;
$$;

-- Audit shape: the constraints that bound it, asserted by name.
do $$
declare
  v_constraint text;
begin
  perform pg_temp.act_as('admin_a');
  begin
    insert into app_private.feature_audit_events (feature_id, organization_id, layer_id, actor_user_id, action, resource_revision, summary)
      values (pg_temp.id('feat_line'), pg_temp.id('org_a'), pg_temp.id('layer_a1'), pg_temp.id('admin_a'), 'renamed', 1, 'x');
    raise exception 'accepted an unknown audit action';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'feature_audit_events_action_valid' then
      raise exception 'unknown action refused by % instead of feature_audit_events_action_valid', v_constraint;
    end if;
  end;
  begin
    insert into app_private.feature_audit_events (feature_id, organization_id, layer_id, actor_user_id, action, resource_revision, summary)
      values (pg_temp.id('feat_line'), pg_temp.id('org_a'), pg_temp.id('layer_a1'), pg_temp.id('admin_a'), 'deleted', 1, repeat('s', 201));
    raise exception 'accepted an oversized audit summary';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'feature_audit_events_summary_bounded' then
      raise exception 'long summary refused by % instead of feature_audit_events_summary_bounded', v_constraint;
    end if;
  end;
  begin
    insert into app_private.feature_audit_events (feature_id, organization_id, layer_id, actor_user_id, action, resource_revision, summary)
      values (pg_temp.id('feat_line'), pg_temp.id('org_a'), pg_temp.id('layer_a1'), pg_temp.id('admin_a'), 'deleted', 0, 'x');
    raise exception 'accepted revision 0';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint is distinct from 'feature_audit_events_revision_positive' then
      raise exception 'revision 0 refused by % instead of feature_audit_events_revision_positive', v_constraint;
    end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Atomic deletion and audit: a delete whose audit append fails leaves the row.
-- The failure is injected with a check that no audit row can satisfy.
-- ---------------------------------------------------------------------------
do $$
declare
  v_outcome text;
begin
  perform pg_temp.act_as('editor_a');
  alter table app_private.feature_audit_events
    add constraint injected_failure check (summary = 'never') not valid;
  set local role authenticated;
  v_outcome := pg_temp.outcome(format('select public.delete_feature(%L, 3)', pg_temp.id('feat_line')));
  reset role;
  alter table app_private.feature_audit_events drop constraint injected_failure;
  if v_outcome not like '23514|%injected_failure%' then
    raise exception 'the injected audit failure did not surface: %', v_outcome;
  end if;
  if not exists (select 1 from public.features where id = pg_temp.id('feat_line') and revision = 3) then
    raise exception 'a delete whose audit append failed removed the row';
  end if;
  if exists (select 1 from app_private.feature_audit_events where feature_id = pg_temp.id('feat_line')) then
    raise exception 'a failed delete left an audit event';
  end if;
end;
$$;

-- A delete by the owner with no actor cannot be recorded, so it is refused. A
-- deletion nobody is accountable for is not allowed to happen quietly.
do $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.expect('owner delete without an actor', format(
    'delete from public.features where id = %L', pg_temp.id('feat_line')),
    '42501', 'feature deletion requires an authenticated actor');
  if not exists (select 1 from public.features where id = pg_temp.id('feat_line')) then
    raise exception 'an unaudited delete removed the row';
  end if;
end;
$$;

-- Deleting a layer deletes its features by cascade. The trail records each one
-- and the actor who deleted the layer.
do $$
declare
  v_count bigint;
begin
  perform pg_temp.act_as('editor_a');
  perform public.create_feature(pg_temp.id('layer_a2'), pg_temp.point(-104.9, 39.7), 'Cascade one');
  perform public.create_feature(pg_temp.id('layer_a2'), pg_temp.point(-104.8, 39.7), 'Cascade two');
  select count(*) into v_count from public.features where layer_id = pg_temp.id('layer_a2');
  if v_count < 3 then raise exception 'cascade fixture missing: %', v_count; end if;
  delete from public.layers where id = pg_temp.id('layer_a2');
  if exists (select 1 from public.features where layer_id = pg_temp.id('layer_a2')) then
    raise exception 'the layer delete left features';
  end if;
  if (select count(*) from app_private.feature_audit_events
      where layer_id = pg_temp.id('layer_a2') and actor_user_id = pg_temp.id('editor_a')
        and action = 'deleted') <> v_count then
    raise exception 'the cascade was not audited feature by feature';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Direct table writes are no longer an API. A client that skips the RPCs cannot
-- overwrite a feature without a revision.
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_id uuid;
begin
  perform pg_temp.act_as('editor_a');
  perform pg_temp.expect('direct insert', format(
    'insert into public.features (layer_id, organization_id, geom, title) values (%L, %L, %L::public.wgs84_geometry, %L)',
    pg_temp.id('layer_a1'), pg_temp.id('org_a'), 'SRID=4326;POINT(-104.9 39.7)', 'Direct'),
    '42501', 'permission denied for table features');
  v_id := (public.create_feature(pg_temp.id('layer_a1'), pg_temp.point(-104.9, 39.7), 'Direct target')->>'id')::uuid;
  perform pg_temp.expect('direct update', format(
    'update public.features set title = %L where id = %L', 'Direct overwrite', v_id),
    '42501', 'permission denied for table features');
  perform pg_temp.expect('direct delete', format(
    'delete from public.features where id = %L', v_id),
    '42501', 'permission denied for table features');
  -- Reads still work.
  if (select title from public.features where id = v_id) <> 'Direct target' then
    raise exception 'editor cannot read what it created';
  end if;
end;
$$;

-- Reads follow the same boundary as before: a member reads, a stranger does not.
do $$
begin
  perform pg_temp.act_as('viewer_a');
  if (select count(*) from public.features where organization_id = pg_temp.id('org_a')) = 0 then
    raise exception 'viewer cannot read organization A features';
  end if;
  perform pg_temp.act_as('editor_b');
  if exists (select 1 from public.features where organization_id = pg_temp.id('org_a')) then
    raise exception 'editor B reads organization A features';
  end if;
end;
$$;

rollback;
