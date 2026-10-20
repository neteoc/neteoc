-- Replaces a map's full layer order in one transaction. Each position moves
-- above the current maximum first, so the unique (map_id, position) index never
-- sees two rows sharing a position mid-update. Runs as the caller, so RLS still
-- applies.
create function public.reorder_map_layers(
  p_map_id uuid,
  p_layer_ids uuid[]
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_expected integer := cardinality(p_layer_ids);
  v_offset integer;
  v_updated integer;
begin
  if p_map_id is null or p_layer_ids is null then
    raise exception 'map and layer order are required';
  end if;
  -- Lock the map before reading its layers, so an attach that commits
  -- concurrently cannot slip in between the checks and the update. Under RLS
  -- this row is visible for update only to admins and editors, so a reader who
  -- cannot edit gets no row and is refused here.
  perform 1 from public.maps as mp where mp.id = p_map_id for update;
  if not found then
    raise insufficient_privilege using message = 'map editing requires an admin or editor role';
  end if;
  if (select count(*) from public.map_layers where map_id = p_map_id) <> v_expected
    or (select count(distinct l) from unnest(p_layer_ids) as l) <> v_expected then
    raise exception 'layer order must list every attached layer exactly once';
  end if;

  select coalesce(max(position), 0) + v_expected + 1 into v_offset
    from public.map_layers where map_id = p_map_id;
  update public.map_layers set position = position + v_offset
    where map_id = p_map_id;

  update public.map_layers as ml
    set position = (o.ord - 1)::integer
    from unnest(p_layer_ids) with ordinality as o(layer_id, ord)
    where ml.map_id = p_map_id
      and ml.layer_id = o.layer_id;
  get diagnostics v_updated = row_count;
  if v_updated <> v_expected then
    raise exception 'layer order references a layer that is not attached';
  end if;
end;
$$;

revoke all on function public.reorder_map_layers(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_map_layers(uuid, uuid[]) to authenticated;
