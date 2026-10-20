-- Execute against a disposable database. Every fixture and role switch rolls back.
begin;

insert into auth.users (id, email) values
  ('a6b5e009-da39-4eaf-b814-aee4369278ec', 'maps-admin-a@neteoc.invalid'),
  ('189bddc1-f820-4028-aeda-ff677f18b242', 'maps-editor-a@neteoc.invalid'),
  ('2aaa848c-7ef5-4963-98d8-70f09f6ccefd', 'maps-viewer-a@neteoc.invalid'),
  ('3075774e-1e6f-41ba-a4e2-aa57573f3999', 'maps-editor-b@neteoc.invalid');

insert into public.organizations (id, name) values
  ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'Maps test organization A'),
  ('e053c15e-069a-4a54-8dd7-201ea4a68a33', 'Maps test organization B');

insert into public.memberships (organization_id, user_id, role) values
  ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'a6b5e009-da39-4eaf-b814-aee4369278ec', 'admin'),
  ('e048500e-d098-49c7-a0a0-8b66298ba22e', '189bddc1-f820-4028-aeda-ff677f18b242', 'editor'),
  ('e048500e-d098-49c7-a0a0-8b66298ba22e', '2aaa848c-7ef5-4963-98d8-70f09f6ccefd', 'viewer'),
  ('e053c15e-069a-4a54-8dd7-201ea4a68a33', '3075774e-1e6f-41ba-a4e2-aa57573f3999', 'editor');

insert into public.maps (id, organization_id, title) values
  ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 'Map A1'),
  ('eb52639a-e4ca-48d2-8c62-5d04fc58f3b5', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 'Map A2'),
  ('b7234d8d-d678-40ad-a7fa-2faaba2aa57f', 'e053c15e-069a-4a54-8dd7-201ea4a68a33', 'Map B');

insert into public.layers (id, organization_id, title) values
  ('5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 'Layer A'),
  ('9dae20a0-732b-4420-911e-99074608a1fa', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 'Layer C'),
  ('6bdc937a-b378-4794-9bce-b43217ea069c', 'e053c15e-069a-4a54-8dd7-201ea4a68a33', 'Layer B');

insert into public.map_layers (map_id, layer_id, organization_id, position, default_visible) values
  ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 0, true),
  ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '9dae20a0-732b-4420-911e-99074608a1fa', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 1, true),
  ('eb52639a-e4ca-48d2-8c62-5d04fc58f3b5', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 0, false),
  ('b7234d8d-d678-40ad-a7fa-2faaba2aa57f', '6bdc937a-b378-4794-9bce-b43217ea069c', 'e053c15e-069a-4a54-8dd7-201ea4a68a33', 0, true);

-- Constraints hold even for a privileged writer, which bypasses RLS. A map or
-- layer from another organization cannot be attached, and positions are unique.
do $$
begin
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '6bdc937a-b378-4794-9bce-b43217ea069c', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 2);
    raise exception 'organization B layer attached to organization A map';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('b7234d8d-d678-40ad-a7fa-2faaba2aa57f', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e053c15e-069a-4a54-8dd7-201ea4a68a33', 1);
    raise exception 'organization A layer attached to organization B map';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('b7234d8d-d678-40ad-a7fa-2faaba2aa57f', '9dae20a0-732b-4420-911e-99074608a1fa', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 1);
    raise exception 'association claimed a different organization than its map';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('eb52639a-e4ca-48d2-8c62-5d04fc58f3b5', '9dae20a0-732b-4420-911e-99074608a1fa', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 0);
    raise exception 'two layers share one position on a map';
  exception when unique_violation then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('eb52639a-e4ca-48d2-8c62-5d04fc58f3b5', '9dae20a0-732b-4420-911e-99074608a1fa', 'e048500e-d098-49c7-a0a0-8b66298ba22e', -1);
    raise exception 'negative layer position accepted';
  exception when check_violation then null;
  end;
  if (select count(*) from pg_class
      where relnamespace = 'public'::regnamespace
        and relname in ('maps', 'layers', 'map_layers')
        and relrowsecurity) <> 3 then
    raise exception 'RLS is not enabled on every maps table';
  end if;
end;
$$;

-- Assert grants and function configuration directly. An anonymous denial must
-- come from the missing grant, not from the function's own role check, which
-- raises the same SQLSTATE. CI grants anon and authenticated everything by
-- default (see ci-bootstrap.sql), so these checks fail if a revoke is missing.
do $$
declare
  t text;
begin
  if has_function_privilege('anon', 'public.reorder_map_layers(uuid, uuid[])', 'execute') then
    raise exception 'anon can execute reorder_map_layers';
  end if;
  if not has_function_privilege('authenticated', 'public.reorder_map_layers(uuid, uuid[])', 'execute') then
    raise exception 'authenticated cannot execute reorder_map_layers';
  end if;
  foreach t in array array['public.maps', 'public.layers', 'public.map_layers'] loop
    if has_table_privilege('anon', t, 'select, insert, update, delete, truncate, references, trigger') then
      raise exception 'anon holds a privilege on %', t;
    end if;
    if not has_table_privilege('authenticated', t, 'select') then
      raise exception 'authenticated cannot read %', t;
    end if;
  end loop;
  -- Reorder runs with the caller's rights and a pinned search path. Losing
  -- either property would change what RLS and name resolution apply.
  if not exists (
    select 1 from pg_proc
    where oid = 'public.reorder_map_layers(uuid, uuid[])'::regprocedure
      and not prosecdef
      and proconfig @> array['search_path=""']
  ) then
    raise exception 'reorder_map_layers must be security invoker with search_path pinned';
  end if;
end;
$$;

-- Editor in organization A: reads stay in A, cross-tenant writes are denied,
-- and same-organization writes, reorder, and detach behave as specified.
select set_config('request.jwt.claim.sub', '189bddc1-f820-4028-aeda-ff677f18b242', true);
set local role authenticated;
do $$
declare
  affected integer;
  v_map uuid;
  v_layer uuid;
begin
  if (select count(*) from public.maps) <> 2
    or (select count(*) from public.layers) <> 2
    or (select count(*) from public.map_layers) <> 3 then
    raise exception 'editor A read outside or missing organization A';
  end if;

  begin
    insert into public.maps (organization_id, title) values ('e053c15e-069a-4a54-8dd7-201ea4a68a33', 'cross-tenant map');
    raise exception 'editor A inserted a map into organization B';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.layers (organization_id, title) values ('e053c15e-069a-4a54-8dd7-201ea4a68a33', 'cross-tenant layer');
    raise exception 'editor A inserted a layer into organization B';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('b7234d8d-d678-40ad-a7fa-2faaba2aa57f', '6bdc937a-b378-4794-9bce-b43217ea069c', 'e053c15e-069a-4a54-8dd7-201ea4a68a33', 1);
    raise exception 'editor A associated organization B records';
  exception when insufficient_privilege then null;
  end;
  update public.maps set title = 'cross-tenant rename' where id = 'b7234d8d-d678-40ad-a7fa-2faaba2aa57f';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'editor A renamed organization B map'; end if;
  delete from public.layers where id = '6bdc937a-b378-4794-9bce-b43217ea069c';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'editor A deleted organization B layer'; end if;
  delete from public.maps where id = 'b7234d8d-d678-40ad-a7fa-2faaba2aa57f';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'editor A deleted organization B map'; end if;
  delete from public.map_layers where map_id = 'b7234d8d-d678-40ad-a7fa-2faaba2aa57f';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'editor A deleted organization B associations'; end if;

  -- One layer appears on a map at most once. The primary key rejects a second attach.
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 9);
    raise exception 'same layer attached to a map twice';
  exception when unique_violation then null;
  end;

  -- The row passes RLS because it names organization A, but its layer belongs to B.
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '6bdc937a-b378-4794-9bce-b43217ea069c', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 2);
    raise exception 'organization B layer attached through an organization A row';
  exception when foreign_key_violation then null;
  end;

  begin
    update public.maps set organization_id = 'e053c15e-069a-4a54-8dd7-201ea4a68a33'
      where id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2';
    raise exception 'application role changed a map organization';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.map_layers set layer_id = '9dae20a0-732b-4420-911e-99074608a1fa'
      where map_id = 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5'
        and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
    raise exception 'application role re-pointed an association';
  exception when insufficient_privilege then null;
  end;

  -- Same-organization writes are allowed for editors.
  insert into public.maps (organization_id, title) values
    ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'Editor map')
    returning id into v_map;
  insert into public.layers (organization_id, title) values
    ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'Editor layer')
    returning id into v_layer;
  insert into public.map_layers (map_id, layer_id, organization_id, position)
    values (v_map, v_layer, 'e048500e-d098-49c7-a0a0-8b66298ba22e', 0);
  insert into public.map_layers (map_id, layer_id, organization_id, position, default_visible)
    values (v_map, '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 1, false);
  update public.maps set title = 'Editor map renamed' where id = v_map;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not rename a same-organization map'; end if;
  update public.map_layers set default_visible = true
    where map_id = v_map and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not toggle default visibility'; end if;
  if (select count(*) from public.map_layers where map_id = v_map) <> 2 then
    raise exception 'editor-created map does not hold two attached layers';
  end if;

  -- One layer edit appears on every map that attaches it.
  update public.layers set title = 'Layer A renamed' where id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not edit a same-organization layer'; end if;
  if (select count(*) from public.map_layers ml
      join public.layers l on l.id = ml.layer_id
      where ml.map_id in ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5')
        and l.title = 'Layer A renamed') <> 2 then
    raise exception 'layer edit is not reflected on both maps';
  end if;

  -- Detaching removes only the association.
  delete from public.map_layers
    where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
      and layer_id = '9dae20a0-732b-4420-911e-99074608a1fa';
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'editor could not detach a layer'; end if;
  if not exists (select 1 from public.layers where id = '9dae20a0-732b-4420-911e-99074608a1fa') then
    raise exception 'detaching a layer deleted it';
  end if;
  if (select count(*) from public.map_layers where map_id = 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5') <> 1 then
    raise exception 'detaching from one map changed another map';
  end if;

  insert into public.map_layers (map_id, layer_id, organization_id, position, default_visible)
    values ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '9dae20a0-732b-4420-911e-99074608a1fa', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 1, true);

  -- Reorder changes only the named map. Rejected orders leave positions intact.
  perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
    array['9dae20a0-732b-4420-911e-99074608a1fa', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990']::uuid[]);
  if (select position from public.map_layers
      where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
        and layer_id = '9dae20a0-732b-4420-911e-99074608a1fa') <> 0
    or (select position from public.map_layers
        where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
          and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990') <> 1 then
    raise exception 'reorder did not apply to the named map';
  end if;
  if (select position from public.map_layers
      where map_id = 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5'
        and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990') <> 0 then
    raise exception 'reorder on one map moved the layer on another map';
  end if;

  begin
    perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
      array['9dae20a0-732b-4420-911e-99074608a1fa']::uuid[]);
    raise exception 'partial reorder accepted';
  exception when raise_exception then
    if sqlerrm <> 'layer order must list every attached layer exactly once' then raise; end if;
  end;
  begin
    perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
      array['9dae20a0-732b-4420-911e-99074608a1fa', '9dae20a0-732b-4420-911e-99074608a1fa']::uuid[]);
    raise exception 'duplicate layer in reorder accepted';
  exception when raise_exception then
    if sqlerrm <> 'layer order must list every attached layer exactly once' then raise; end if;
  end;
  begin
    perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
      array['9dae20a0-732b-4420-911e-99074608a1fa', '6bdc937a-b378-4794-9bce-b43217ea069c']::uuid[]);
    raise exception 'reorder accepted a layer that is not attached';
  exception when raise_exception then
    if sqlerrm <> 'layer order references a layer that is not attached' then raise; end if;
  end;
  if (select position from public.map_layers
      where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
        and layer_id = '9dae20a0-732b-4420-911e-99074608a1fa') <> 0
    or (select position from public.map_layers
        where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
          and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990') <> 1 then
    raise exception 'rejected reorder left positions changed';
  end if;

  begin
    perform public.reorder_map_layers('b7234d8d-d678-40ad-a7fa-2faaba2aa57f',
      array['6bdc937a-b378-4794-9bce-b43217ea069c']::uuid[]);
    raise exception 'editor A reordered organization B map';
  exception when insufficient_privilege then null;
  end;

  -- Per-map default visibility is independent for the same layer.
  update public.map_layers set default_visible = true
    where map_id = 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5'
      and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  if (select default_visible from public.map_layers
      where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
        and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990') is not true then
    raise exception 'toggling map A2 changed map A1 visibility';
  end if;
  update public.map_layers set default_visible = false
    where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
      and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  if (select default_visible from public.map_layers
      where map_id = 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5'
        and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990') is not true then
    raise exception 'toggling map A1 changed map A2 visibility';
  end if;
end;
$$;

-- Organization admin: writes allowed, and deleting a map keeps its layers.
select set_config('request.jwt.claim.sub', 'a6b5e009-da39-4eaf-b814-aee4369278ec', true);
set local role authenticated;
do $$
declare
  affected integer;
  v_layer uuid;
  v_map uuid;
begin
  insert into public.layers (organization_id, title) values
    ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'Admin layer')
    returning id into v_layer;
  insert into public.map_layers (map_id, layer_id, organization_id, position)
    values ('eb52639a-e4ca-48d2-8c62-5d04fc58f3b5', v_layer, 'e048500e-d098-49c7-a0a0-8b66298ba22e', 1);
  perform public.reorder_map_layers('eb52639a-e4ca-48d2-8c62-5d04fc58f3b5',
    array[v_layer, '5b8e8e0e-c19b-456f-8b6c-4270e03d5990']::uuid[]);
  if (select position from public.map_layers
      where map_id = 'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5' and layer_id = v_layer) <> 0 then
    raise exception 'admin reorder did not apply';
  end if;

  select id into v_map from public.maps where title = 'Editor map renamed';
  delete from public.maps where id = v_map;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'admin could not delete a same-organization map'; end if;
  if exists (select 1 from public.map_layers where map_id = v_map) then
    raise exception 'deleted map left associations behind';
  end if;
  if (select count(*) from public.layers where title = 'Editor layer') <> 1 then
    raise exception 'deleting a map deleted its layer';
  end if;
end;
$$;

-- Viewer in organization A: reads its organization, writes nothing.
select set_config('request.jwt.claim.sub', '2aaa848c-7ef5-4963-98d8-70f09f6ccefd', true);
set local role authenticated;
do $$
declare
  affected integer;
begin
  if (select count(*) from public.maps where id in ('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
                                                    'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5')) <> 2 then
    raise exception 'viewer could not read organization A maps';
  end if;

  begin
    insert into public.maps (organization_id, title) values ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'viewer map');
    raise exception 'viewer inserted a map';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.layers (organization_id, title) values ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'viewer layer');
    raise exception 'viewer inserted a layer';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('31dd3909-8050-4085-8c0a-1625a5b4b9d2', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e048500e-d098-49c7-a0a0-8b66298ba22e', 5);
    raise exception 'viewer attached a layer';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
      array['5b8e8e0e-c19b-456f-8b6c-4270e03d5990', '9dae20a0-732b-4420-911e-99074608a1fa']::uuid[]);
    raise exception 'viewer reordered a map';
  exception when insufficient_privilege then null;
  end;

  update public.maps set title = 'viewer rename' where id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer renamed a map'; end if;
  update public.layers set title = 'viewer rename' where id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer edited a layer'; end if;
  update public.map_layers set default_visible = true
    where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2' and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer toggled default visibility'; end if;
  delete from public.map_layers where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer detached layers'; end if;
  delete from public.maps where id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer deleted a map'; end if;
  delete from public.layers where id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'viewer deleted a layer'; end if;

  -- The denied update targeted map A1. Its value is false here, so a denied
  -- write must leave it false.
  if (select default_visible from public.map_layers
      where map_id = '31dd3909-8050-4085-8c0a-1625a5b4b9d2'
        and layer_id = '5b8e8e0e-c19b-456f-8b6c-4270e03d5990') is not false then
    raise exception 'viewer write changed default visibility state';
  end if;
end;
$$;

-- Editor in organization B: sees and changes only organization B.
select set_config('request.jwt.claim.sub', '3075774e-1e6f-41ba-a4e2-aa57573f3999', true);
set local role authenticated;
do $$
declare
  affected integer;
begin
  if (select count(*) from public.maps where id in ('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
                                                    'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5')) <> 0
    or (select count(*) from public.map_layers where map_id in ('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
                                                                'eb52639a-e4ca-48d2-8c62-5d04fc58f3b5')) <> 0
    or (select count(*) from public.layers where id in ('5b8e8e0e-c19b-456f-8b6c-4270e03d5990',
                                                        '9dae20a0-732b-4420-911e-99074608a1fa')) <> 0 then
    raise exception 'organization B editor read organization A records';
  end if;
  if (select count(*) from public.maps) <> 1 then
    raise exception 'organization B editor cannot read its own map exactly';
  end if;

  begin
    perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
      array['5b8e8e0e-c19b-456f-8b6c-4270e03d5990', '9dae20a0-732b-4420-911e-99074608a1fa']::uuid[]);
    raise exception 'organization B editor reordered organization A map';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.map_layers (map_id, layer_id, organization_id, position)
      values ('b7234d8d-d678-40ad-a7fa-2faaba2aa57f', '5b8e8e0e-c19b-456f-8b6c-4270e03d5990', 'e053c15e-069a-4a54-8dd7-201ea4a68a33', 1);
    raise exception 'organization B editor attached organization A layer';
  exception when foreign_key_violation then null;
  end;

  update public.maps set title = 'Map B renamed' where id = 'b7234d8d-d678-40ad-a7fa-2faaba2aa57f';
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'organization B editor could not rename own map'; end if;
end;
$$;

-- Anonymous visitors have no table privileges and cannot execute reorder.
set local role anon;
do $$
begin
  begin
    perform 1 from public.maps limit 1;
    raise exception 'anonymous map read succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.map_layers limit 1;
    raise exception 'anonymous association read succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.layers limit 1;
    raise exception 'anonymous layer read succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.maps (organization_id, title) values ('e048500e-d098-49c7-a0a0-8b66298ba22e', 'anonymous map');
    raise exception 'anonymous map insert succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.reorder_map_layers('31dd3909-8050-4085-8c0a-1625a5b4b9d2',
      array['5b8e8e0e-c19b-456f-8b6c-4270e03d5990', '9dae20a0-732b-4420-911e-99074608a1fa']::uuid[]);
    raise exception 'anonymous reorder succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
