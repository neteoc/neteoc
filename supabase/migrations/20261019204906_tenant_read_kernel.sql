-- The first tenant boundary is read-only for application roles. Operator-only
-- bootstrap and membership mutations will be added with audited paths later.
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now(),
  constraint organizations_name_valid check (
    name = btrim(name) and char_length(name) between 1 and 120
  )
);

create table public.memberships (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'editor', 'viewer')),
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create index memberships_user_id_idx on public.memberships (user_id, organization_id);

alter table public.organizations enable row level security;
alter table public.memberships enable row level security;

revoke all on table public.organizations, public.memberships from public, anon, authenticated;
grant select on table public.organizations, public.memberships to authenticated;

create policy organizations_read_member on public.organizations
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = organizations.id
        and m.user_id = (select auth.uid())
    )
  );

create policy memberships_read_self on public.memberships
  for select to authenticated
  using (user_id = (select auth.uid()));
