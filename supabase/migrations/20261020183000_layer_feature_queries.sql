-- One page of a layer's features, for viewport and list views. The page is
-- ordered by (created_at, id). Both columns are immutable after insert, so a
-- cursor keeps its position while other rows are written. See
-- docs/layer-feature-queries.md for the cursor, limits, and error contract.
--
-- Security invoker: features_read_member applies to the caller, so a layer the
-- caller cannot read returns the same empty page as a layer that does not exist.
-- The function never reports a count, extent, title, or budget error for rows
-- the caller cannot see.
create function public.list_layer_features(
  p_layer_id uuid,
  p_min_lon double precision,
  p_min_lat double precision,
  p_max_lon double precision,
  p_max_lat double precision,
  p_limit integer,
  p_after_created_at timestamptz default null,
  p_after_id uuid default null,
  p_byte_budget integer default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  -- The API validates these before calling. The database repeats the checks so
  -- a direct caller cannot reach the query with values the API would refuse.
  if p_layer_id is null then
    raise exception 'layer is required' using errcode = 'invalid_parameter_value';
  end if;
  if p_min_lon is null or p_min_lat is null or p_max_lon is null or p_max_lat is null
    or p_min_lon > p_max_lon or p_min_lat > p_max_lat
    or p_min_lon < -180 or p_max_lon > 180 or p_min_lat < -90 or p_max_lat > 90 then
    raise exception 'bounding box must be WGS84 with min <= max' using errcode = 'invalid_parameter_value';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'limit must be between 1 and 200' using errcode = 'invalid_parameter_value';
  end if;
  if p_byte_budget is null or p_byte_budget < 1 then
    raise exception 'byte budget must be positive' using errcode = 'invalid_parameter_value';
  end if;
  if (p_after_created_at is null) <> (p_after_id is null) then
    raise exception 'cursor needs both created_at and id' using errcode = 'invalid_parameter_value';
  end if;

  -- Probe the layer before reading its features. Under layers_read_member, a layer
  -- the caller cannot read is invisible here, exactly as a missing layer is, so both
  -- take the same path: one primary-key lookup and the empty page. Without the probe,
  -- a forbidden layer's rows are scanned and filtered one by one under RLS, and the
  -- extra latency reveals that the layer exists. The payload here must stay equal to
  -- the page returned for a visible, empty layer.
  if not exists (select 1 from public.layers as l where l.id = p_layer_id) then
    return jsonb_build_object(
      'features', '[]'::jsonb,
      'has_more', false,
      'next', null,
      'oversized_feature_id', null
    );
  end if;

  -- The probe row (limit + 1) shows whether a further page exists without a count.
  -- Running bytes are measured on the jsonb text, so a page never exceeds the
  -- budget the API reserves for its envelope.
  return (
    with page as (
      select
        f.id,
        f.created_at,
        jsonb_build_object(
          'type', 'Feature',
          'id', f.id,
          'geometry', extensions.st_asgeojson(f.geom, 9)::jsonb,
          'properties', jsonb_build_object(
            'title', f.title,
            'description', f.description,
            'status', f.status,
            'attributes', f.properties,
            'revision', f.revision,
            'created_at', f.created_at,
            'updated_at', f.updated_at
          )
        ) as feature
      from public.features as f
      where f.layer_id = p_layer_id
        and f.geom operator(extensions.&&) extensions.st_makeenvelope(p_min_lon, p_min_lat, p_max_lon, p_max_lat, 4326)
        and (p_after_id is null or (f.created_at, f.id) > (p_after_created_at, p_after_id))
      order by f.created_at, f.id
      limit p_limit + 1
    ),
    sized as (
      select
        page.id,
        page.created_at,
        page.feature,
        row_number() over (order by page.created_at, page.id) as position,
        sum(octet_length(page.feature::text)) over (
          order by page.created_at, page.id
          rows between unbounded preceding and current row
        ) as running_bytes
      from page
    ),
    kept as (
      select sized.*
      from sized
      where sized.position <= p_limit
        and sized.running_bytes <= p_byte_budget
    )
    select jsonb_build_object(
      'features', coalesce(
        (select jsonb_agg(kept.feature order by kept.position) from kept),
        '[]'::jsonb
      ),
      'has_more', (select count(*) from sized) > (select count(*) from kept),
      'next', (
        select jsonb_build_object('created_at', kept.created_at, 'id', kept.id)
        from kept
        order by kept.position desc
        limit 1
      ),
      -- Set only when the first row of the page is larger than the budget. The
      -- page cannot advance past it, so the API reports it rather than skipping it.
      'oversized_feature_id', case
        when not exists (select 1 from kept) then (select sized.id from sized where sized.position = 1)
        else null
      end
    )
  );
end;
$$;

revoke all on function public.list_layer_features(
  uuid, double precision, double precision, double precision, double precision,
  integer, timestamptz, uuid, integer
) from public, anon;
grant execute on function public.list_layer_features(
  uuid, double precision, double precision, double precision, double precision,
  integer, timestamptz, uuid, integer
) to authenticated;
