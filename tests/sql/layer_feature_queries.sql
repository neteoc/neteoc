-- Execute against a disposable database. Every fixture and role switch rolls back.
-- Each refusal asserts the message it raised, so a value refused for another reason
-- fails the test. A forbidden layer and a nonexistent layer must return the same
-- payload, so the comparison is on the whole document, not on one field.
begin;

insert into auth.users (id, email) values
  ('b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01', 'page-admin-a@neteoc.invalid'),
  ('b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c02', 'page-viewer-a@neteoc.invalid'),
  ('b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c03', 'page-member-b@neteoc.invalid');

insert into public.organizations (id, name) values
  ('c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01', 'Layer query organization A'),
  ('c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d02', 'Layer query organization B');

insert into public.memberships (organization_id, user_id, role) values
  ('c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01', 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01', 'admin'),
  ('c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01', 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c02', 'viewer'),
  ('c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d02', 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c03', 'editor');

insert into public.layers (id, organization_id, title) values
  ('d3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01', 'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01', 'Page layer A'),
  ('d3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e02', 'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01', 'Empty page layer A'),
  ('d3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e03', 'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d02', 'Hidden layer title B');

-- 25 features in layer A. Features 23 to 25 share a created_at, so the id
-- tiebreak is exercised. Each writes as admin A, because the stamp trigger needs
-- an authenticated actor.
select set_config('request.jwt.claim.sub', 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01', true);
insert into public.features (id, layer_id, organization_id, geom, title, created_at)
select
  ('f0000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01',
  'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01',
  format('SRID=4326;POINT(%s 39.7)', -104.9 + i * 0.001)::public.wgs84_geometry,
  'Page feature ' || i,
  case when i between 23 and 25 then timestamptz '2026-10-01 00:01:00+00'
       else timestamptz '2026-10-01 00:00:00+00' + i * interval '1 second' end
from generate_series(1, 25) as i;

-- Three features in layer B, inside the same box as layer A.
select set_config('request.jwt.claim.sub', 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c03', true);
insert into public.features (id, layer_id, organization_id, geom, title, created_at)
select
  ('f1000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e03',
  'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d02',
  format('SRID=4326;POINT(%s 39.7)', -104.9 + i * 0.001)::public.wgs84_geometry,
  'Hidden feature B ' || i,
  timestamptz '2026-10-01 00:00:00+00'
from generate_series(1, 3) as i;

-- Catalog facts are asserted directly, not inferred from an error.
do $$
declare
  fn constant regprocedure :=
    'public.list_layer_features(uuid,double precision,double precision,double precision,double precision,integer,timestamptz,uuid,integer)'::regprocedure;
begin
  if (select prosecdef from pg_proc where oid = fn) then
    raise exception 'list_layer_features is security definer; RLS would be bypassed';
  end if;
  if not exists (
    select 1 from pg_proc
    where oid = fn
      and proconfig @> array['search_path=""']
  ) then
    raise exception 'list_layer_features does not pin search_path to empty';
  end if;
  if has_function_privilege('anon', fn, 'execute') then
    raise exception 'anon can execute list_layer_features';
  end if;
  if not has_function_privilege('authenticated', fn, 'execute') then
    raise exception 'authenticated cannot execute list_layer_features';
  end if;
  if exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
    where p.oid = fn
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'PUBLIC can execute list_layer_features';
  end if;
end;
$$;

-- Allow and deny cases at the function boundary, as the authenticated role. The
-- allow cases read a non-empty page, so a denied case cannot pass by returning
-- nothing for every caller.
do $$
declare
  v_admin constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01';
  v_viewer constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c02';
  v_member_b constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c03';
  v_layer_a constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01';
  v_layer_b constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e03';
  v_missing constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e99';
  v_budget constant integer := 258048;
  v_admin_page jsonb;
  v_viewer_page jsonb;
  v_forbidden jsonb;
  v_missing_page jsonb;
  v_empty constant jsonb := '{"features": [], "has_more": false, "next": null, "oversized_feature_id": null}';
begin
  set local role authenticated;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_admin_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 10, null, null, v_budget);
  if jsonb_array_length(v_admin_page->'features') <> 10 or (v_admin_page->>'has_more')::boolean is not true then
    raise exception 'admin of organization A did not read a full first page of layer A';
  end if;

  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  v_viewer_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 10, null, null, v_budget);
  if v_viewer_page is distinct from v_admin_page then
    raise exception 'viewer and admin of organization A see different pages of layer A';
  end if;

  -- Member of organization B, asking for layer A and for a nonexistent layer.
  perform set_config('request.jwt.claim.sub', v_member_b::text, true);
  v_forbidden := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 10, null, null, v_budget);
  v_missing_page := public.list_layer_features(v_missing, -105, 39, -104, 40, 10, null, null, v_budget);
  if v_forbidden is distinct from v_missing_page then
    raise exception 'a forbidden layer and a nonexistent layer return different payloads';
  end if;
  if v_forbidden is distinct from v_empty then
    raise exception 'forbidden layer payload is not the empty page: %', v_forbidden;
  end if;
  if position('Page layer A' in v_forbidden::text) > 0
    or position('Page feature' in v_forbidden::text) > 0
    or position('d3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01' in v_forbidden::text) > 0 then
    raise exception 'forbidden payload contains a layer title, feature title, or layer id';
  end if;

  -- The same member reads their own layer, so the empty result above is a refusal.
  v_forbidden := public.list_layer_features(v_layer_b, -105, 39, -104, 40, 10, null, null, v_budget);
  if jsonb_array_length(v_forbidden->'features') <> 3 then
    raise exception 'member of organization B cannot read its own layer';
  end if;

  -- The admin of organization A cannot read organization B's layer.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  if public.list_layer_features(v_layer_b, -105, 39, -104, 40, 10, null, null, v_budget) is distinct from v_empty then
    raise exception 'admin of organization A reads layer B';
  end if;

  reset role;
end;
$$;

-- Anonymous callers have no execute privilege. The refusal is the grant check, so
-- the message names the function. A returned row would fail the test.
do $$
begin
  begin
    set local role anon;
    perform public.list_layer_features(
      'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01', -180, -90, 180, 90, 10, null, null, 258048);
    raise exception 'anonymous caller read a layer page';
  exception when insufficient_privilege then
    if sqlerrm <> 'permission denied for function list_layer_features' then
      raise exception 'anonymous refusal came from another cause: %', sqlerrm;
    end if;
  end;
end;
$$;

-- Pagination. Walking layer A at limit 4 must return each of the 25 features once,
-- in (created_at, id) order. The sixth page ends at feature 24, one row before
-- feature 25, and the three features that share a created_at straddle that boundary,
-- so a cursor that ignores id skips feature 25.
do $$
declare
  v_admin constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01';
  v_layer_a constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01';
  v_page jsonb;
  v_ids uuid[] := '{}';
  v_after_at timestamptz;
  v_after_id uuid;
  v_pages integer := 0;
  v_expected uuid[];
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  loop
    v_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 4, v_after_at, v_after_id, 258048);
    v_ids := v_ids || array(select (f->>'id')::uuid from jsonb_array_elements(v_page->'features') as f);
    exit when not (v_page->>'has_more')::boolean;
    v_after_at := (v_page->'next'->>'created_at')::timestamptz;
    v_after_id := (v_page->'next'->>'id')::uuid;
    v_pages := v_pages + 1;
    if v_pages > 10 then
      raise exception 'pagination did not terminate within 10 pages of 4';
    end if;
  end loop;
  reset role;

  select array_agg(id order by created_at, id) into v_expected
  from public.features where layer_id = v_layer_a;
  if cardinality(v_expected) <> 25 then
    raise exception 'fixture has % features in layer A, expected 25', cardinality(v_expected);
  end if;
  if v_ids <> v_expected then
    raise exception 'walk did not return every feature once in (created_at, id) order';
  end if;
end;
$$;

-- Writes between pages. Four changes after the first page:
--   * a row created ahead of the cursor is returned by the walk that continues;
--   * a row created behind the cursor is not returned by that walk, and a fresh
--     walk returns it (the stated contract: a walk is not a snapshot);
--   * a row changed in place ahead of the cursor keeps its position and returns
--     with its current content;
--   * a row deleted ahead of the cursor is absent and does not shift the others.
-- The walk must equal the table as it stands, minus the behind row, in order. That
-- equality rules out a skip and a repeat in one comparison.
do $$
declare
  v_admin constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01';
  v_layer_a constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01';
  v_future constant uuid := 'f2000000-0000-4000-8000-000000000001';
  v_behind constant uuid := 'f2000000-0000-4000-8000-000000000002';
  v_deleted constant uuid := 'f0000000-0000-4000-8000-000000000015';
  v_changed constant uuid := 'f0000000-0000-4000-8000-000000000012';
  v_first jsonb;
  v_page jsonb;
  v_rows jsonb := '[]';
  v_after_at timestamptz;
  v_after_id uuid;
  v_title text;
  v_expected uuid[];
  v_fresh_has_behind boolean;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_first := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 10, null, null, 258048);
  reset role;
  v_rows := v_first->'features';
  v_after_at := (v_first->'next'->>'created_at')::timestamptz;
  v_after_id := (v_first->'next'->>'id')::uuid;

  -- Writes as admin A, after the first page was read.
  insert into public.features (id, layer_id, organization_id, geom, title, created_at) values
    (v_future, v_layer_a, 'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01',
     'SRID=4326;POINT(-104.5 39.5)', 'Future feature', timestamptz '2026-10-02 00:00:00+00'),
    (v_behind, v_layer_a, 'c2a1b0d9-3e5f-4b6c-9d7e-8f9a0b1c2d01',
     'SRID=4326;POINT(-104.5 39.5)', 'Behind feature', timestamptz '2026-10-01 00:00:05+00');
  delete from public.features where id = v_deleted;
  update public.features set title = 'Changed title' where id = v_changed;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  loop
    v_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 10, v_after_at, v_after_id, 258048);
    v_rows := v_rows || (v_page->'features');
    exit when not (v_page->>'has_more')::boolean;
    v_after_at := (v_page->'next'->>'created_at')::timestamptz;
    v_after_id := (v_page->'next'->>'id')::uuid;
  end loop;
  v_fresh_has_behind := exists (
    select 1
    from jsonb_array_elements(public.list_layer_features(v_layer_a, -105, 39, -104, 40, 100, null, null, 258048)->'features') as f
    where (f->>'id')::uuid = v_behind
  );
  reset role;

  select array_agg((f->>'id')::uuid order by ord) into v_expected
  from jsonb_array_elements(v_rows) with ordinality as t(f, ord);
  if v_expected is distinct from (
    select array_agg(id order by created_at, id)
    from public.features
    where layer_id = v_layer_a and id <> v_behind
  ) then
    raise exception 'walk across writes is not the table in (created_at, id) order, minus the behind row';
  end if;

  select f->'properties'->>'title' into v_title
  from jsonb_array_elements(v_rows) as f
  where (f->>'id')::uuid = v_changed;
  if v_title is distinct from 'Changed title' then
    raise exception 'changed row did not return with its current content: %', v_title;
  end if;

  if not v_fresh_has_behind then
    raise exception 'a fresh walk did not return the row created behind the cursor';
  end if;
end;
$$;

-- Validation. Each refusal names the message the function raises.
do $$
declare
  v_layer constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01';
begin
  begin
    perform public.list_layer_features(v_layer, -180, -90, 180, 90, 0, null, null, 258048);
    raise exception 'limit 0 was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'limit must be between 1 and 200' then raise; end if;
  end;

  begin
    perform public.list_layer_features(v_layer, -180, -90, 180, 90, 201, null, null, 258048);
    raise exception 'limit 201 was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'limit must be between 1 and 200' then raise; end if;
  end;

  begin
    perform public.list_layer_features(v_layer, -104, 39, -105, 40, 10, null, null, 258048);
    raise exception 'inverted longitude box was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'bounding box must be WGS84 with min <= max' then raise; end if;
  end;

  begin
    perform public.list_layer_features(v_layer, 'NaN'::double precision, 39, -104, 40, 10, null, null, 258048);
    raise exception 'NaN longitude was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'bounding box must be WGS84 with min <= max' then raise; end if;
  end;

  begin
    perform public.list_layer_features(v_layer, -181, -90, 180, 90, 10, null, null, 258048);
    raise exception 'longitude outside WGS84 was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'bounding box must be WGS84 with min <= max' then raise; end if;
  end;

  begin
    perform public.list_layer_features(v_layer, -180, -90, 180, 90, 10, timestamptz '2026-10-01', null, 258048);
    raise exception 'cursor with created_at and no id was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'cursor needs both created_at and id' then raise; end if;
  end;

  begin
    perform public.list_layer_features(v_layer, -180, -90, 180, 90, 10, null, null, 0);
    raise exception 'zero byte budget was accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'byte budget must be positive' then raise; end if;
  end;
end;
$$;

-- Byte budget. Budgets are set to the measured sizes of the first features, so the
-- page boundary is exact. A budget for two features returns two and stops; the next
-- page starts with the third. A budget one byte short returns one.
do $$
declare
  v_admin constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c01';
  v_member_b constant uuid := 'b1f0a9c3-2d4e-4a5b-8c6d-7e8f9a0b1c03';
  v_layer_a constant uuid := 'd3b2c1e0-4f60-4c7d-8e8f-9a0b1c2d3e01';
  v_sizes integer[];
  v_s1 integer;
  v_s2 integer;
  v_page jsonb;
  v_next jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select array_agg(octet_length(t.f::text) order by t.ord) into v_sizes
  from jsonb_array_elements(
    public.list_layer_features(v_layer_a, -105, 39, -104, 40, 2, null, null, 258048)->'features'
  ) with ordinality as t(f, ord);
  reset role;
  if cardinality(v_sizes) is distinct from 2 then
    raise exception 'budget fixture did not return two features';
  end if;
  v_s1 := v_sizes[1];
  v_s2 := v_sizes[2];

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 3, null, null, v_s1 + v_s2);
  if jsonb_array_length(v_page->'features') <> 2 or (v_page->>'has_more')::boolean is not true then
    raise exception 'budget for two features did not return two features with has_more';
  end if;
  v_next := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 3,
    (v_page->'next'->>'created_at')::timestamptz, (v_page->'next'->>'id')::uuid, 258048);
  if (v_next->'features'->0->>'id')::uuid <> 'f0000000-0000-4000-8000-000000000003' then
    raise exception 'the page after a budget cut did not start with the third feature';
  end if;

  v_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 3, null, null, v_s1 + v_s2 - 1);
  if jsonb_array_length(v_page->'features') <> 1 then
    raise exception 'budget one byte short of two features still returned two';
  end if;

  -- An oversized first feature is reported by id, not skipped and not hidden as an
  -- empty page.
  v_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 3, null, null, 1);
  if jsonb_array_length(v_page->'features') <> 0
    or (v_page->>'oversized_feature_id')::uuid is distinct from 'f0000000-0000-4000-8000-000000000001' then
    raise exception 'oversized first feature was not reported by id: %', v_page;
  end if;
  reset role;

  -- The same budget against a forbidden layer reports nothing, so the oversize
  -- error cannot reveal that the layer has rows.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_member_b::text, true);
  v_page := public.list_layer_features(v_layer_a, -105, 39, -104, 40, 3, null, null, 1);
  if v_page <> '{"features": [], "has_more": false, "next": null, "oversized_feature_id": null}'::jsonb then
    raise exception 'budget error for a forbidden layer differs from an empty page: %', v_page;
  end if;
  reset role;
end;
$$;

rollback;
