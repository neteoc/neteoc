-- Maps reference reusable layers through an association that owns order and
-- per-map default visibility. A layer exists once and is shared by every map
-- that attaches it, so an edit to the layer appears on each of those maps.
create table public.maps (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  title text not null,
  description text,
  created_at timestamptz not null default now(),
  constraint maps_title_valid check (
    title = btrim(title) and char_length(title) between 1 and 120
  ),
  constraint maps_description_valid check (
    description is null or char_length(description) <= 2000
  ),
  -- Target of the composite foreign keys below, which keep associations within
  -- one organization even for a privileged writer that bypasses RLS.
  constraint maps_id_organization_key unique (id, organization_id)
);

create index maps_organization_id_idx on public.maps (organization_id);

create table public.layers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  title text not null,
  created_at timestamptz not null default now(),
  constraint layers_title_valid check (
    title = btrim(title) and char_length(title) between 1 and 120
  ),
  constraint layers_id_organization_key unique (id, organization_id)
);

create index layers_organization_id_idx on public.layers (organization_id);

create table public.map_layers (
  map_id uuid not null,
  layer_id uuid not null,
  organization_id uuid not null,
  position integer not null check (position >= 0),
  default_visible boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (map_id, layer_id),
  constraint map_layers_map_position_key unique (map_id, position),
  constraint map_layers_map_organization_fkey
    foreign key (map_id, organization_id)
    references public.maps (id, organization_id) on delete cascade,
  constraint map_layers_layer_organization_fkey
    foreign key (layer_id, organization_id)
    references public.layers (id, organization_id) on delete cascade
);

create index map_layers_layer_id_idx on public.map_layers (layer_id);

alter table public.maps enable row level security;
alter table public.layers enable row level security;
alter table public.map_layers enable row level security;

revoke all on table public.maps, public.layers, public.map_layers
  from public, anon, authenticated;

-- Column grants keep organization ownership and association keys immutable to
-- application roles. Writes are further limited to admins and editors below.
grant select, delete on table public.maps, public.layers, public.map_layers to authenticated;
grant insert (organization_id, title, description) on public.maps to authenticated;
grant update (title, description) on public.maps to authenticated;
grant insert (organization_id, title) on public.layers to authenticated;
grant update (title) on public.layers to authenticated;
grant insert (map_id, layer_id, organization_id, position, default_visible)
  on public.map_layers to authenticated;
grant update (position, default_visible) on public.map_layers to authenticated;

create policy maps_read_member on public.maps
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = maps.organization_id
        and m.user_id = (select auth.uid())
    )
  );

create policy maps_insert_editor on public.maps
  for insert to authenticated
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = maps.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy maps_update_editor on public.maps
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = maps.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  )
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = maps.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy maps_delete_editor on public.maps
  for delete to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = maps.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy layers_read_member on public.layers
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = layers.organization_id
        and m.user_id = (select auth.uid())
    )
  );

create policy layers_insert_editor on public.layers
  for insert to authenticated
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy layers_update_editor on public.layers
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  )
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy layers_delete_editor on public.layers
  for delete to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy map_layers_read_member on public.map_layers
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = map_layers.organization_id
        and m.user_id = (select auth.uid())
    )
  );

create policy map_layers_insert_editor on public.map_layers
  for insert to authenticated
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = map_layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy map_layers_update_editor on public.map_layers
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = map_layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  )
  with check (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = map_layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

create policy map_layers_delete_editor on public.map_layers
  for delete to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = map_layers.organization_id
        and m.user_id = (select auth.uid())
        and m.role in ('admin', 'editor')
    )
  );

