-- Transactional feature writes with revision conflicts (issue #14, PRD MVP-04).
--
-- Three functions create, update, and delete a feature. Each one is granted to
-- authenticated, so each one is a public API in its own right: every bound, every
-- authorization check, and every revision check lives here. The routes in front of
-- them are a convenience for well-behaved callers and are never a control.
--
-- Direct writes to public.features are removed from application roles in this
-- migration. Without that, a client could skip the expected-revision check by
-- writing the table over PostgREST. Reads keep their grant and policy.
--
-- Compatibility with a Worker deployed before or after this migration: no
-- deployed Worker writes features, and the only read it makes is select and
-- list_layer_features, which are unchanged. Nothing here drops an object, so
-- either Worker version runs against either schema.
--
-- The functions are security definer, which is a deviation from the invoker
-- default. A caller with no table grant cannot write through an invoker function,
-- and a table grant is exactly what removes the revision check. Each function
-- therefore carries its own authorization, in the statement that writes. The
-- search path is pinned to the empty string and every reference is qualified.

-- ---------------------------------------------------------------------------
-- Audit trail. It records who deleted what and when, and carries no feature
-- content: no title, description, attribute, or coordinate. It has no foreign key
-- to features or layers, so it outlives the rows it describes. The invitation
-- audit table is the pattern: append-only, no update or delete path, no grant to
-- an application role.
-- ---------------------------------------------------------------------------
create table app_private.feature_audit_events (
  id uuid primary key default gen_random_uuid(),
  feature_id uuid not null,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  layer_id uuid not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  -- Only deletion is recorded today. A feature has no visibility tier or
  -- placement that can change (#19 adds the tier), so a deletion is the only
  -- access-relevant change that exists. #19 widens this list in its own migration.
  action text not null,
  resource_revision integer not null,
  summary text not null,
  created_at timestamptz not null default now(),
  constraint feature_audit_events_action_valid check (action in ('deleted')),
  constraint feature_audit_events_revision_positive check (resource_revision >= 1),
  constraint feature_audit_events_summary_bounded check (char_length(summary) between 1 and 200)
);

create index feature_audit_events_feature_id_idx on app_private.feature_audit_events (feature_id);
create index feature_audit_events_organization_time_idx
  on app_private.feature_audit_events (organization_id, created_at desc);
create index feature_audit_events_actor_user_id_idx on app_private.feature_audit_events (actor_user_id);

alter table app_private.feature_audit_events enable row level security;
revoke all on table app_private.feature_audit_events from public, anon, authenticated;

create function app_private.reject_feature_audit_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'feature audit events are immutable';
end;
$$;

create trigger feature_audit_events_immutable
  before update or delete on app_private.feature_audit_events
  for each row execute function app_private.reject_feature_audit_change();

create trigger feature_audit_events_no_truncate
  before truncate on app_private.feature_audit_events
  for each statement execute function app_private.reject_feature_audit_change();

-- Appends the deletion event inside the deleting statement's transaction, so a
-- delete and its record commit or fail together. It is a trigger on the table,
-- not code in the RPC, so a layer delete that cascades to features and a delete by
-- any other writer are recorded too. It is security definer because the deleting
-- caller holds no grant on the audit table. A trigger function cannot be called
-- directly, so a client has no entry point to forge an event. A deletion with no
-- authenticated actor cannot be attributed, and is refused rather than recorded
-- anonymously.
create function app_private.record_feature_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise insufficient_privilege using message = 'feature deletion requires an authenticated actor';
  end if;
  insert into app_private.feature_audit_events (
    feature_id, organization_id, layer_id, actor_user_id, action, resource_revision, summary
  ) values (
    old.id, old.organization_id, old.layer_id, v_actor, 'deleted', old.revision,
    format('deleted %s feature at revision %s', extensions.geometrytype(old.geom), old.revision)
  );
  return null;
end;
$$;

create trigger features_audit_deletion
  after delete on public.features
  for each row execute function app_private.record_feature_deletion();

-- TRUNCATE fires no row-level DELETE trigger, so the deletion audit above would
-- not see it. A truncate of features, or a truncate of layers with CASCADE that
-- reaches features, would remove rows with no audit record. This statement-level
-- trigger refuses both, for every role, the table owner included. The refusal
-- names the way to remove a feature: one at a time, so each deletion is recorded.
create function app_private.refuse_feature_truncate()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'feature rows cannot be truncated; delete each feature so the deletion is audited'
    using errcode = 'feature_not_supported';
end;
$$;

create trigger features_refuse_truncate
  before truncate on public.features
  for each statement execute function app_private.refuse_feature_truncate();

revoke all on function app_private.reject_feature_audit_change(),
  app_private.record_feature_deletion(),
  app_private.refuse_feature_truncate()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Remove the direct write path. The insert, update, and delete policies stay in
-- place. They are inert while no role holds the grant, and they keep the editor
-- rule in force if a later migration or a default privilege ever restores one.
-- tests/sql/feature_edits.sql asserts the grants are absent, so that case fails
-- the build rather than relying on the policies.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on table public.features from authenticated;

-- ---------------------------------------------------------------------------
-- Validation helpers. They run with the rights of whoever calls them, and the
-- callers are the definer functions below. No application role can reach them.
-- Every refusal is a fixed message with SQLSTATE 22023, so a rejected request
-- never reaches a table constraint. A constraint violation carries the failing
-- row in its DETAIL, which would put feature content into a database log. The
-- table constraints remain as a backstop.
-- ---------------------------------------------------------------------------
-- The characters Unicode classes as White_Space. btrim with the default set removes
-- only spaces, so a title of a tab, a newline, or a non-breaking space passed. A
-- value that is blank once these are removed is refused, and so is one with any of
-- them at either end. Interior whitespace is kept.
create function app_private.feature_whitespace()
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) || chr(133)
    || chr(160) || chr(5760)
    || (select string_agg(chr(n), '' order by n) from generate_series(8192, 8202) as n)
    || chr(8232) || chr(8233) || chr(8239) || chr(8287) || chr(12288)
$$;

create function app_private.check_feature_title(p_title text)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  if p_title is null
    or char_length(p_title) not between 1 and 120
    or p_title <> btrim(p_title, app_private.feature_whitespace()) then
    raise exception 'title must be 1 to 120 characters with no leading or trailing space'
      using errcode = 'invalid_parameter_value';
  end if;
end;
$$;

create function app_private.check_feature_description(p_description text)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  if p_description is not null and char_length(p_description) > 2000 then
    raise exception 'description must be at most 2000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
end;
$$;

create function app_private.check_feature_status(p_status text)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  if p_status is not null
    and (char_length(p_status) not between 1 and 40
      or p_status <> btrim(p_status, app_private.feature_whitespace())) then
    raise exception 'status must be 1 to 40 characters with no leading or trailing space'
      using errcode = 'invalid_parameter_value';
  end if;
end;
$$;

-- True when every number in the document returns unchanged from a JSON.parse and
-- JSON.stringify round trip, which is what supabase-js does on the read path. A
-- number does so exactly when the shortest decimal text of its nearest double
-- equals it. That rejects 1e500 (read back as null), 12345678901234567890 (read
-- back as 12345678901234567000), and 0.1000000000000000055511151231257827 (read
-- back as 0.1), and accepts 0.1, 9007199254740992, and 1e22. A double that
-- JavaScript can print exactly is accepted even above 2^53, because the text it
-- prints equals the stored number. The shortest-text form is a PostgreSQL 12
-- behavior that depends on extra_float_digits, so the setting is pinned here.
create function app_private.attribute_numbers_faithful(p_attributes jsonb)
returns boolean
language plpgsql
stable
security invoker
set search_path = ''
set extra_float_digits = 1
as $$
declare
  v_number numeric;
begin
  for v_number in
    select (n #>> '{}')::numeric
    from jsonb_path_query(p_attributes, 'strict $.** ? (@.type() == "number")') as n
  loop
    begin
      if ((v_number::double precision)::text)::numeric is distinct from v_number then
        return false;
      end if;
    exception when numeric_value_out_of_range then
      -- Beyond the double range in either direction, including underflow.
      return false;
    end;
  end loop;
  return true;
end;
$$;

create function app_private.validate_feature_attributes(p_attributes jsonb)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  -- The size limit matches the features_properties_valid constraint.
  if p_attributes is null
    or jsonb_typeof(p_attributes) <> 'object'
    or octet_length(p_attributes::text) > 4096 then
    raise exception 'attributes must be a JSON object of at most 4096 bytes'
      using errcode = 'invalid_parameter_value';
  end if;
  if not app_private.attribute_numbers_faithful(p_attributes) then
    raise exception 'attribute numbers must be exactly representable as double-precision values'
      using errcode = 'invalid_parameter_value';
  end if;
end;
$$;

-- Reads a GeoJSON Point, LineString, or Polygon into the stored geometry type.
-- The checks run in a fixed order, cheapest first: the byte ceiling, the shape of
-- the JSON, the range of every coordinate, the parse, the vertex limit, and only
-- then the validity test, which is the expensive one. PostGIS parses leniently (a
-- string coordinate reads as a number, a crs member changes the SRID), so the
-- JSON shape is checked here rather than trusted to the parser.
create function app_private.parse_feature_geometry(p_geometry jsonb)
returns public.wgs84_geometry
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_type text;
  v_coordinates jsonb;
  v_geom extensions.geometry;
  v_shape_message constant text := 'geometry must be a GeoJSON Point, LineString, or Polygon object';
  v_position_message constant text := 'geometry coordinates must be 2D numeric positions';
  v_range_message constant text := 'geometry must lie within longitude -180..180 and latitude -90..90';
  v_valid_message constant text := 'geometry must be a valid, non-empty shape';
  v_prefix text;
begin
  if p_geometry is null or jsonb_typeof(p_geometry) = 'null' then
    raise exception 'geometry is required' using errcode = 'invalid_parameter_value';
  end if;
  -- The ceiling is the parse cost bound. 2000 vertices of full precision fit well
  -- inside it, and so does a polygon with several rings.
  if octet_length(p_geometry::text) > 131072 then
    raise exception 'geometry must be at most 131072 bytes' using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_typeof(p_geometry) <> 'object'
    or (select array_agg(k order by k) from jsonb_object_keys(p_geometry) as k)
      is distinct from array['coordinates', 'type']
    or jsonb_typeof(p_geometry->'type') <> 'string'
    or (p_geometry->>'type') not in ('Point', 'LineString', 'Polygon') then
    raise exception '%', v_shape_message using errcode = 'invalid_parameter_value';
  end if;
  v_type := p_geometry->>'type';
  v_coordinates := p_geometry->'coordinates';

  -- Every level is checked before the next one is addressed, so a strict path
  -- never meets a value of the wrong kind.
  if v_type = 'Point' then
    v_prefix := '$';
    if jsonb_typeof(v_coordinates) <> 'array'
      or jsonb_array_length(v_coordinates) <> 2
      or jsonb_path_exists(v_coordinates, 'strict $[*] ? (@.type() != "number")') then
      raise exception '%', v_position_message using errcode = 'invalid_parameter_value';
    end if;
  elsif v_type = 'LineString' then
    v_prefix := '$[*]';
    if jsonb_typeof(v_coordinates) <> 'array'
      or jsonb_array_length(v_coordinates) = 0
      or jsonb_path_exists(v_coordinates, 'strict $[*] ? (@.type() != "array")')
      or jsonb_path_exists(v_coordinates, 'strict $[*] ? (@.size() != 2)')
      or jsonb_path_exists(v_coordinates, 'strict $[*][*] ? (@.type() != "number")') then
      raise exception '%', v_position_message using errcode = 'invalid_parameter_value';
    end if;
  else
    v_prefix := '$[*][*]';
    if jsonb_typeof(v_coordinates) <> 'array'
      or jsonb_array_length(v_coordinates) = 0
      or jsonb_path_exists(v_coordinates, 'strict $[*] ? (@.type() != "array")')
      or jsonb_path_exists(v_coordinates, 'strict $[*] ? (@.size() == 0)')
      or jsonb_path_exists(v_coordinates, 'strict $[*][*] ? (@.type() != "array")')
      or jsonb_path_exists(v_coordinates, 'strict $[*][*] ? (@.size() != 2)')
      or jsonb_path_exists(v_coordinates, 'strict $[*][*][*] ? (@.type() != "number")') then
      raise exception '%', v_position_message using errcode = 'invalid_parameter_value';
    end if;
  end if;

  -- Longitude is the first number of a position, latitude the second. The check
  -- reads the JSON numbers, so a value no double can hold is refused here and never
  -- reaches the parser.
  if jsonb_path_exists(v_coordinates, (format('strict %s[0] ? (@ < -180 || @ > 180)', v_prefix))::jsonpath)
    or jsonb_path_exists(v_coordinates, (format('strict %s[1] ? (@ < -90 || @ > 90)', v_prefix))::jsonpath) then
    raise exception '%', v_range_message using errcode = 'invalid_parameter_value';
  end if;

  begin
    v_geom := extensions.st_geomfromgeojson(p_geometry::text);
  exception when others then
    -- A shape the parser cannot build, such as a one-point line or a ring that
    -- does not close. The parser's own text is not passed on.
    raise exception '%', v_valid_message using errcode = 'invalid_parameter_value';
  end;

  -- The vertex limit sorts before the validity test, as in the table constraints.
  if extensions.st_npoints(v_geom) > 2000 then
    raise exception 'geometry must contain at most 2000 vertices' using errcode = 'invalid_parameter_value';
  end if;
  if extensions.st_srid(v_geom) <> 4326 or extensions.st_isempty(v_geom) then
    raise exception '%', v_valid_message using errcode = 'invalid_parameter_value';
  end if;
  if extensions.st_xmin(v_geom) < -180 or extensions.st_xmax(v_geom) > 180
    or extensions.st_ymin(v_geom) < -90 or extensions.st_ymax(v_geom) > 90 then
    raise exception '%', v_range_message using errcode = 'invalid_parameter_value';
  end if;
  -- The flags form. The one-argument form raises a NOTICE that names the reason and
  -- the location of a self-intersection, with the submitted coordinates. A notice
  -- reaches client and database logs, and feature content must never reach either.
  -- Flags 0 is the default validity test, with no notice.
  if not extensions.st_isvalid(v_geom, 0) then
    raise exception '%', v_valid_message using errcode = 'invalid_parameter_value';
  end if;
  return v_geom::public.wgs84_geometry;
end;
$$;

-- The feature as GeoJSON, in the shape list_layer_features returns, so a client
-- reads a write result and a read result with one parser. The list function is
-- not changed here: it ships in an earlier migration. tests/sql/feature_edits.sql
-- asserts the two documents are equal for the same row.
create function app_private.feature_json(p_feature public.features)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'type', 'Feature',
    'id', p_feature.id,
    'geometry', extensions.st_asgeojson(p_feature.geom, 9)::jsonb,
    'properties', jsonb_build_object(
      'title', p_feature.title,
      'description', p_feature.description,
      'status', p_feature.status,
      'attributes', p_feature.properties,
      'revision', p_feature.revision,
      'created_at', p_feature.created_at,
      'updated_at', p_feature.updated_at
    )
  )
$$;

-- Raised when a caller may not edit the feature, or it does not exist. A caller
-- who is an editor or admin of the organization that held the feature may learn
-- that it was deleted, because the audit trail records the deletion for them and
-- they are entitled to that organization's records. Every other caller gets one
-- answer whether the feature never existed, belongs to another organization, or
-- is visible to a viewer. The statement shape is the same on every path.
create function app_private.raise_feature_unavailable(p_feature_id uuid, p_user_id uuid)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if exists (
    select 1
    from app_private.feature_audit_events as a
    where a.feature_id = p_feature_id
      and a.action = 'deleted'
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = a.organization_id
          and m.user_id = p_user_id
          and m.role in ('admin', 'editor')
      )
  ) then
    raise exception 'feature was deleted' using errcode = 'PT410';
  end if;
  raise insufficient_privilege using message = 'feature not found or not editable';
end;
$$;

-- ---------------------------------------------------------------------------
-- create_feature
-- ---------------------------------------------------------------------------
-- The caller must be an admin or editor of the layer's organization. The
-- organization is taken from the layer, never from the caller. A caller who is not
-- gets one answer for a layer that is hidden, foreign, or missing, and the answer
-- is given before the payload is read, so an invalid payload cannot reveal which
-- layers exist. The authorization and the insert are one statement, which sees one
-- snapshot, the same guarantee a row policy gives.
create function public.create_feature(
  p_layer_id uuid,
  p_geometry jsonb,
  p_title text,
  p_description text default null,
  p_status text default null,
  p_attributes jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_geom public.wgs84_geometry;
  v_row public.features;
begin
  if p_layer_id is null then
    raise exception 'layer is required' using errcode = 'invalid_parameter_value';
  end if;
  if v_user_id is null then
    raise insufficient_privilege using message = 'sign in to edit features';
  end if;
  if not exists (
    select 1
    from public.layers as l
    where l.id = p_layer_id
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = l.organization_id
          and m.user_id = v_user_id
          and m.role in ('admin', 'editor')
      )
  ) then
    raise insufficient_privilege using message = 'layer not found or not editable';
  end if;

  v_geom := app_private.parse_feature_geometry(p_geometry);
  perform app_private.check_feature_title(p_title);
  perform app_private.check_feature_description(p_description);
  perform app_private.check_feature_status(p_status);
  perform app_private.validate_feature_attributes(p_attributes);

  begin
    insert into public.features (layer_id, organization_id, geom, title, description, status, properties)
    select l.id, l.organization_id, v_geom, p_title, p_description, p_status, p_attributes
    from public.layers as l
    where l.id = p_layer_id
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = l.organization_id
          and m.user_id = v_user_id
          and m.role in ('admin', 'editor')
      )
    returning * into v_row;
  exception when foreign_key_violation then
    -- The layer was deleted between the check and the insert.
    raise insufficient_privilege using message = 'layer not found or not editable';
  end;
  if v_row.id is null then
    -- Authorization was withdrawn between the check and the insert.
    raise insufficient_privilege using message = 'layer not found or not editable';
  end if;
  return app_private.feature_json(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- update_feature
-- ---------------------------------------------------------------------------
-- p_changes is a patch. A key that is present sets that field, and a key that is
-- absent leaves it alone, so a reshape sends only "geometry". A null clears
-- description or status and is refused for the other fields. Unknown keys are
-- refused, so the revision, the actor, and the placement cannot be named.
--
-- The revision check is the write itself. One UPDATE carries the feature ID, the
-- expected revision, and the editor check in its WHERE clause. Concurrent writers
-- queue on the row lock, and the loser re-reads the committed row, finds the
-- revision moved on, and updates nothing. There is no read followed by a write, so
-- there is no window for a lost update. The classification below runs only after
-- the UPDATE matched nothing, and it only chooses which error to raise.
create function public.update_feature(
  p_feature_id uuid,
  p_expected_revision integer,
  p_changes jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_row public.features;
  v_current integer;
  v_set_geom boolean;
  v_set_title boolean;
  v_set_description boolean;
  v_set_status boolean;
  v_set_attributes boolean;
  v_geom public.wgs84_geometry;
  v_title text;
  v_description text;
  v_status text;
  v_attributes jsonb;
begin
  if p_feature_id is null then
    raise exception 'feature is required' using errcode = 'invalid_parameter_value';
  end if;
  if p_expected_revision is null or p_expected_revision < 1 then
    raise exception 'expected revision must be a positive whole number' using errcode = 'invalid_parameter_value';
  end if;
  -- Argument shape and size do not depend on any row, so they are checked before
  -- the caller is looked up. The ceiling is the geometry ceiling plus room for the
  -- other fields at their own limits.
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' then
    raise exception 'changes must be a JSON object' using errcode = 'invalid_parameter_value';
  end if;
  if octet_length(p_changes::text) > 147456 then
    raise exception 'changes must be at most 147456 bytes' using errcode = 'invalid_parameter_value';
  end if;
  if v_user_id is null then
    raise insufficient_privilege using message = 'sign in to edit features';
  end if;

  -- Turn the caller away before the payload is read, for the reason create does.
  if not exists (
    select 1
    from public.features as f
    where f.id = p_feature_id
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = f.organization_id
          and m.user_id = v_user_id
          and m.role in ('admin', 'editor')
      )
  ) then
    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);
  end if;

  if p_changes = '{}'::jsonb then
    raise exception 'changes must name at least one field' using errcode = 'invalid_parameter_value';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_changes) as k
    where k not in ('geometry', 'title', 'description', 'status', 'attributes')
  ) then
    raise exception 'changes contain a field that cannot be changed' using errcode = 'invalid_parameter_value';
  end if;

  v_set_geom := p_changes ? 'geometry';
  v_set_title := p_changes ? 'title';
  v_set_description := p_changes ? 'description';
  v_set_status := p_changes ? 'status';
  v_set_attributes := p_changes ? 'attributes';

  if v_set_geom then
    v_geom := app_private.parse_feature_geometry(p_changes->'geometry');
  end if;
  if v_set_title then
    if jsonb_typeof(p_changes->'title') <> 'string' then
      raise exception 'title must be 1 to 120 characters with no leading or trailing space'
        using errcode = 'invalid_parameter_value';
    end if;
    v_title := p_changes->>'title';
    perform app_private.check_feature_title(v_title);
  end if;
  if v_set_description then
    if jsonb_typeof(p_changes->'description') not in ('string', 'null') then
      raise exception 'description must be at most 2000 characters' using errcode = 'invalid_parameter_value';
    end if;
    v_description := p_changes->>'description';
    perform app_private.check_feature_description(v_description);
  end if;
  if v_set_status then
    if jsonb_typeof(p_changes->'status') not in ('string', 'null') then
      raise exception 'status must be 1 to 40 characters with no leading or trailing space'
        using errcode = 'invalid_parameter_value';
    end if;
    v_status := p_changes->>'status';
    perform app_private.check_feature_status(v_status);
  end if;
  if v_set_attributes then
    v_attributes := p_changes->'attributes';
    perform app_private.validate_feature_attributes(v_attributes);
  end if;

  -- The compare-and-set. Geometry, title, description, status, attributes, and,
  -- through the stamp trigger, the revision, the actor, and the timestamp, change
  -- in this one statement or not at all.
  update public.features as f
  set geom = case when v_set_geom then v_geom else f.geom end,
      title = case when v_set_title then v_title else f.title end,
      description = case when v_set_description then v_description else f.description end,
      status = case when v_set_status then v_status else f.status end,
      properties = case when v_set_attributes then v_attributes else f.properties end
  where f.id = p_feature_id
    and f.revision = p_expected_revision
    and exists (
      select 1 from public.memberships as m
      where m.organization_id = f.organization_id
        and m.user_id = v_user_id
        and m.role in ('admin', 'editor')
    )
  returning f.* into v_row;

  if v_row.id is null then
    -- Nothing matched. Say why, to a caller who is allowed to know.
    select f.revision into v_current
    from public.features as f
    where f.id = p_feature_id
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = f.organization_id
          and m.user_id = v_user_id
          and m.role in ('admin', 'editor')
      );
    if found then
      raise exception 'feature revision conflict'
        using errcode = 'PT409', detail = format('current revision %s', v_current);
    end if;
    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);
  end if;
  return app_private.feature_json(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- delete_feature
-- ---------------------------------------------------------------------------
-- The same compare-and-set as update. The deleting statement fires the audit
-- trigger, so the row and its record go together, and a failure in either leaves
-- both as they were.
create function public.delete_feature(
  p_feature_id uuid,
  p_expected_revision integer
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_row public.features;
  v_current integer;
begin
  if p_feature_id is null then
    raise exception 'feature is required' using errcode = 'invalid_parameter_value';
  end if;
  if p_expected_revision is null or p_expected_revision < 1 then
    raise exception 'expected revision must be a positive whole number' using errcode = 'invalid_parameter_value';
  end if;
  if v_user_id is null then
    raise insufficient_privilege using message = 'sign in to edit features';
  end if;

  delete from public.features as f
  where f.id = p_feature_id
    and f.revision = p_expected_revision
    and exists (
      select 1 from public.memberships as m
      where m.organization_id = f.organization_id
        and m.user_id = v_user_id
        and m.role in ('admin', 'editor')
    )
  returning f.* into v_row;

  if v_row.id is null then
    select f.revision into v_current
    from public.features as f
    where f.id = p_feature_id
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = f.organization_id
          and m.user_id = v_user_id
          and m.role in ('admin', 'editor')
      );
    if found then
      raise exception 'feature revision conflict'
        using errcode = 'PT409', detail = format('current revision %s', v_current);
    end if;
    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);
  end if;
  return jsonb_build_object('id', v_row.id, 'deleted', true, 'revision', v_row.revision);
end;
$$;

-- Grants. The helpers are reachable only through the functions above. The three
-- RPCs are executable by authenticated and by nobody else.
revoke all on function app_private.feature_whitespace(),
  app_private.check_feature_title(text),
  app_private.check_feature_description(text),
  app_private.check_feature_status(text),
  app_private.attribute_numbers_faithful(jsonb),
  app_private.validate_feature_attributes(jsonb),
  app_private.parse_feature_geometry(jsonb),
  app_private.feature_json(public.features),
  app_private.raise_feature_unavailable(uuid, uuid)
  from public, anon, authenticated;

revoke all on function public.create_feature(uuid, jsonb, text, text, text, jsonb),
  public.update_feature(uuid, integer, jsonb),
  public.delete_feature(uuid, integer)
  from public, anon;
grant execute on function public.create_feature(uuid, jsonb, text, text, text, jsonb),
  public.update_feature(uuid, integer, jsonb),
  public.delete_feature(uuid, integer)
  to authenticated;
