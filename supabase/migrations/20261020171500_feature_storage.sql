-- PostGIS stores 2D WGS84 feature geometry. Supabase exposes extensions from the
-- extensions schema, so PostGIS functions stay out of public. If PostGIS already
-- sits elsewhere, the statement below is a silent no-op, so the check after it
-- stops the migration instead of storing features in the wrong schema.
create extension if not exists postgis with schema extensions;

do $$
begin
  if not exists (
    select 1 from pg_extension
    where extname = 'postgis'
      and extnamespace = 'extensions'::regnamespace
  ) then
    raise exception 'postgis must be installed in the extensions schema';
  end if;
end;
$$;

-- Features are planar geometry, not geography. Validity, bounding boxes, and
-- the GiST operators used by viewport queries are defined for geometry. Metre
-- distances are not an MVP requirement; a query that needs them can cast.
--
-- The domain rejects a value that does not declare SRID 4326. A geometry column
-- typed geometry(Geometry, 4326) would silently assign 4326 to an undeclared
-- SRID, so the caller's coordinates would be stored unchecked. A domain has no
-- typmod, so the check sees the value as supplied.
create domain public.wgs84_geometry as extensions.geometry
  check (extensions.st_srid(value) = 4326);

create table public.features (
  id uuid primary key default gen_random_uuid(),
  layer_id uuid not null,
  organization_id uuid not null,
  geom public.wgs84_geometry not null,
  title text not null,
  description text,
  status text,
  properties jsonb not null default '{}'::jsonb,
  revision integer not null default 1,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now(),
  -- Composite key keeps a feature in its layer's organization, even for a
  -- privileged writer. Removing a layer removes its features.
  constraint features_layer_organization_fkey
    foreign key (layer_id, organization_id)
    references public.layers (id, organization_id) on delete cascade,
  constraint features_title_valid check (
    title = btrim(title) and char_length(title) between 1 and 120
  ),
  constraint features_description_valid check (
    description is null or char_length(description) <= 2000
  ),
  constraint features_status_valid check (
    status is null or (status = btrim(status) and char_length(status) between 1 and 40)
  ),
  -- Attributes are a bounded JSON object. Jsonb text is compared by length.
  constraint features_properties_valid check (
    jsonb_typeof(properties) = 'object' and octet_length(properties::text) <= 4096
  ),
  -- Point, line, and polygon only. Multi-part and collection types are rejected
  -- so an import can report them as unsupported rather than store them.
  constraint features_geom_type_supported check (
    extensions.geometrytype(geom) in ('POINT', 'LINESTRING', 'POLYGON')
  ),
  -- The domain already rejects a non-4326 value. This check holds the stored
  -- value to the same rule if a later migration drops the domain.
  constraint features_geom_srid check (extensions.st_srid(geom) = 4326),
  -- Z and M ordinates are rejected. ST_NDims counts them.
  constraint features_geom_2d check (extensions.st_ndims(geom) = 2),
  -- An empty geometry has NULL bounds, and a NULL bound passes a CHECK. Reject it
  -- explicitly.
  constraint features_geom_not_empty check (not extensions.st_isempty(geom)),
  constraint features_geom_valid check (extensions.st_isvalid(geom)),
  -- Every vertex lies within the bounds, because the bounding box covers them
  -- all. NaN compares above 180 and 90, so it fails the upper bounds. A swapped
  -- pair fails when its longitude is outside -90..90, as for most of the
  -- Americas. A swap of a point with longitude inside -90..90 is still a valid
  -- coordinate, such as Paris written as latitude then longitude. Only the
  -- API's GeoJSON order can prevent that.
  constraint features_geom_lon_lat_range check (
    extensions.st_xmin(geom) >= -180 and extensions.st_xmax(geom) <= 180
    and extensions.st_ymin(geom) >= -90 and extensions.st_ymax(geom) <= 90
  ),
  -- A 2D vertex is 16 bytes of EWKB, so 2000 vertices stay near 32 KB. This
  -- bound also limits the geometry payload.
  constraint features_geom_vertex_limit check (extensions.st_npoints(geom) <= 2000)
);

create index features_organization_id_idx on public.features (organization_id);
create index features_layer_id_idx on public.features (layer_id);
-- A GiST index serves bounding-box queries (geom && envelope). Viewport reads
-- filter by layer and bounding box, so the planner can combine this index with
-- the layer_id index.
create index features_geom_gist_idx on public.features using gist (geom);

alter table public.features enable row level security;

revoke all on table public.features from public, anon, authenticated;

-- Column grants keep identity, placement, and actor fields immutable to
-- application roles. Revision and actor are stamped by trigger below.
grant select on table public.features to authenticated;
grant insert (layer_id, organization_id, geom, title, description, status, properties)
  on public.features to authenticated;
grant update (geom, title, description, status, properties)
  on public.features to authenticated;
grant delete on table public.features to authenticated;

create policy features_read_member on public.features
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = features.organization_id
        and m.user_id = (select auth.uid())
    )
  );

create policy features_insert_editor on public.features
  for insert to authenticated
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = features.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy features_update_editor on public.features
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = features.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  )
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = features.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy features_delete_editor on public.features
  for delete to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = features.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

-- Stamps the actor, revision, and timestamps on every write, so a client cannot
-- supply them. A write without an authenticated actor is refused. An update
-- that changes identity, placement, or creation fields is refused, and a
-- revision cannot be set by hand.
create function app_private.stamp_feature_write()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise insufficient_privilege using message = 'feature writes require an authenticated actor';
  end if;

  if tg_op = 'INSERT' then
    new.revision := 1;
    new.created_by := v_actor;
  else
    if new.id is distinct from old.id
      or new.organization_id is distinct from old.organization_id
      or new.layer_id is distinct from old.layer_id
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at then
      raise exception 'feature identity, placement, and creation fields are immutable';
    end if;
    new.revision := old.revision + 1;
  end if;

  new.updated_by := v_actor;
  new.updated_at := now();
  return new;
end;
$$;

create trigger features_stamp
  before insert or update on public.features
  for each row execute function app_private.stamp_feature_write();

revoke all on function app_private.stamp_feature_write() from public, anon, authenticated;
