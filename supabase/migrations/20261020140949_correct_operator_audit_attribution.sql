-- The SQL editor operator is the actor, identified by operator_ref. The user
-- appointed to a role is the subject, not the person who performed the change.
alter table app_private.audit_events
  rename column actor_user_id to subject_user_id;
alter table app_private.audit_events
  rename constraint audit_events_actor_user_id_fkey
    to audit_events_subject_user_id_fkey;
alter index app_private.audit_events_actor_user_id_idx
  rename to audit_events_subject_user_id_idx;

create or replace function app_private.bootstrap_platform_admin(
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

  lock table app_private.platform_admins in exclusive mode;
  if exists (select 1 from app_private.platform_admins) then
    raise exception 'platform administrator already bootstrapped';
  end if;

  insert into app_private.platform_admins (user_id) values (p_user_id);
  insert into app_private.audit_events (action, subject_user_id, operator_ref)
    values ('platform_admin_bootstrapped', p_user_id, p_operator_ref);
end;
$$;

create or replace function app_private.bootstrap_organization(
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
    action, subject_user_id, organization_id, operator_ref
  ) values (
    'organization_bootstrapped', p_initial_admin_id, v_organization_id, p_operator_ref
  );

  return v_organization_id;
end;
$$;

revoke all on function app_private.bootstrap_platform_admin(uuid, text),
  app_private.bootstrap_organization(text, uuid, uuid, text)
  from public, anon, authenticated;
