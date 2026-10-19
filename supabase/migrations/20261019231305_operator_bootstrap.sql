-- Operator-only bootstrap. These functions are deliberately outside the Data
-- API's exposed schemas and are never granted to application roles.
create schema app_private;
revoke all on schema app_private from public, anon, authenticated;

create table app_private.platform_admins (
  user_id uuid primary key references auth.users(id) on delete restrict,
  appointed_at timestamptz not null default now()
);

create table app_private.audit_events (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('platform_admin_bootstrapped', 'organization_bootstrapped')),
  actor_user_id uuid references auth.users(id) on delete restrict,
  organization_id uuid references public.organizations(id) on delete restrict,
  operator_ref text not null check (
    operator_ref = btrim(operator_ref) and char_length(operator_ref) between 3 and 120
  ),
  created_at timestamptz not null default now()
);

create index audit_events_organization_time_idx
  on app_private.audit_events (organization_id, created_at desc);

alter table app_private.platform_admins enable row level security;
alter table app_private.audit_events enable row level security;
revoke all on table app_private.platform_admins, app_private.audit_events
  from public, anon, authenticated;

-- Run once through the SQL editor as a privileged database operator. The
-- operator_ref identifies the change ticket/operator in the durable audit log.
create function app_private.bootstrap_platform_admin(
  p_user_id uuid,
  p_operator_ref text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_user_id is null or p_operator_ref is null then
    raise exception 'user and operator reference are required';
  end if;

  -- Serialize two simultaneous first-admin attempts.
  lock table app_private.platform_admins in exclusive mode;
  if exists (select 1 from app_private.platform_admins) then
    raise exception 'platform administrator already bootstrapped';
  end if;

  insert into app_private.platform_admins (user_id) values (p_user_id);
  insert into app_private.audit_events (action, actor_user_id, operator_ref)
    values ('platform_admin_bootstrapped', p_user_id, p_operator_ref);
end;
$$;

-- This operator path creates an organization and its initial admin atomically.
-- Later app-facing organization creation must check a current platform-admin
-- membership and keep the same audit/authorization boundary.
create function app_private.bootstrap_organization(
  p_name text,
  p_initial_admin_id uuid,
  p_platform_admin_id uuid,
  p_operator_ref text
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  if p_name is null or p_initial_admin_id is null or p_platform_admin_id is null
    or p_operator_ref is null then
    raise exception 'name, initial admin, platform admin, and operator reference are required';
  end if;
  if not exists (
    select 1 from app_private.platform_admins
    where user_id = p_platform_admin_id
  ) then
    raise exception 'platform administrator is not appointed';
  end if;

  insert into public.organizations (name)
    values (p_name)
    returning id into v_organization_id;
  insert into public.memberships (organization_id, user_id, role)
    values (v_organization_id, p_initial_admin_id, 'admin');
  insert into app_private.audit_events (
    action, actor_user_id, organization_id, operator_ref
  ) values (
    'organization_bootstrapped', p_platform_admin_id, v_organization_id, p_operator_ref
  );

  return v_organization_id;
end;
$$;

revoke all on function app_private.bootstrap_platform_admin(uuid, text),
  app_private.bootstrap_organization(text, uuid, uuid, text)
  from public, anon, authenticated;
