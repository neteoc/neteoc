-- Preserve memberships when an Auth user is deleted so an organization cannot
-- silently lose its only admin. Offboarding must remove memberships explicitly.
alter table public.memberships
  drop constraint memberships_user_id_fkey,
  add constraint memberships_user_id_fkey
    foreign key (user_id) references auth.users(id) on delete restrict;

-- Keep role values constrained in both Postgres and generated application types.
create type public.organization_role as enum ('admin', 'editor', 'viewer');
alter table public.memberships
  drop constraint memberships_role_check,
  alter column role type public.organization_role
    using role::public.organization_role;

revoke all on type public.organization_role from public, anon;
grant usage on type public.organization_role to authenticated;
