-- Single-use, expiring invitations scoped to one organization. Only the sha256
-- digest of the plaintext token is stored. Application roles get no direct
-- writes: issuance, revocation, and acceptance go through the functions below.
-- RLS cannot bind a secret token to a row, and an invitee is not yet a member,
-- so those functions are security definer with explicit checks.
create table public.organization_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  email text not null,
  role public.organization_role not null,
  -- Never selected by an application role. A stolen row holds no usable token.
  token_digest bytea not null unique,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_by uuid references auth.users(id) on delete restrict,
  revoked_at timestamptz,
  consumed_by uuid references auth.users(id) on delete restrict,
  consumed_at timestamptz,
  -- Stored in normalized form, so equality is exact for every writer.
  constraint organization_invitations_email_normalized check (
    email = lower(btrim(email, E' \t\r\n'))
    and char_length(email) between 3 and 254
    and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  ),
  constraint organization_invitations_lifetime_valid check (
    expires_at > created_at and expires_at <= created_at + interval '14 days'
  ),
  constraint organization_invitations_revocation_pair check (
    (revoked_at is null) = (revoked_by is null)
  ),
  constraint organization_invitations_consumption_pair check (
    (consumed_at is null) = (consumed_by is null)
  ),
  constraint organization_invitations_single_outcome check (
    revoked_at is null or consumed_at is null
  ),
  -- Target of the composite foreign key on the audit table.
  constraint organization_invitations_id_organization_key unique (id, organization_id)
);

create index organization_invitations_organization_id_idx
  on public.organization_invitations (organization_id);

-- Append-only record of issuance, revocation, and consumption. It holds IDs and
-- the action only: no email address and no token or digest.
create table app_private.invitation_audit_events (
  id uuid primary key default gen_random_uuid(),
  invitation_id uuid not null,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('issued', 'revoked', 'consumed')),
  created_at timestamptz not null default now(),
  constraint invitation_audit_events_invitation_organization_fkey
    foreign key (invitation_id, organization_id)
    references public.organization_invitations (id, organization_id) on delete restrict
);

create index invitation_audit_events_invitation_id_idx
  on app_private.invitation_audit_events (invitation_id);
create index invitation_audit_events_organization_time_idx
  on app_private.invitation_audit_events (organization_id, created_at desc);
create index invitation_audit_events_actor_user_id_idx
  on app_private.invitation_audit_events (actor_user_id);

alter table public.organization_invitations enable row level security;
alter table app_private.invitation_audit_events enable row level security;

revoke all on table public.organization_invitations from public, anon, authenticated;
revoke all on table app_private.invitation_audit_events from public, anon, authenticated;

-- Admins may read invitations for their organization, except the digest column.
grant select (
  id, organization_id, email, role, created_by, created_at, expires_at,
  revoked_by, revoked_at, consumed_by, consumed_at
) on table public.organization_invitations to authenticated;

create policy organization_invitations_read_admin on public.organization_invitations
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships as m
      where m.organization_id = organization_invitations.organization_id
        and m.user_id = (select auth.uid())
        and m.role = 'admin'
    )
  );

-- Runs before any update. Terms are fixed at issuance, and a finished
-- invitation accepts no further change, whichever path attempts it.
create function app_private.guard_organization_invitation_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.consumed_at is not null or old.revoked_at is not null then
    raise exception 'invitation is no longer pending';
  end if;
  if new.id is distinct from old.id
    or new.organization_id is distinct from old.organization_id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.token_digest is distinct from old.token_digest
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or new.expires_at is distinct from old.expires_at then
    raise exception 'invitation terms are immutable';
  end if;
  return new;
end;
$$;

create trigger organization_invitations_guard
  before update on public.organization_invitations
  for each row execute function app_private.guard_organization_invitation_update();

-- Security definer so that a caller with no write grant can still append an
-- audit row. Trigger functions cannot be invoked directly, so there is no
-- entry point for a client to forge an event.
create function app_private.record_invitation_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into app_private.invitation_audit_events (
      invitation_id, organization_id, actor_user_id, action
    ) values (new.id, new.organization_id, new.created_by, 'issued');
  elsif new.revoked_at is not null and old.revoked_at is null then
    insert into app_private.invitation_audit_events (
      invitation_id, organization_id, actor_user_id, action
    ) values (new.id, new.organization_id, new.revoked_by, 'revoked');
  elsif new.consumed_at is not null and old.consumed_at is null then
    insert into app_private.invitation_audit_events (
      invitation_id, organization_id, actor_user_id, action
    ) values (new.id, new.organization_id, new.consumed_by, 'consumed');
  end if;
  return null;
end;
$$;

create trigger organization_invitations_audit
  after insert or update on public.organization_invitations
  for each row execute function app_private.record_invitation_event();

create function app_private.reject_invitation_audit_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'invitation audit events are immutable';
end;
$$;

create trigger invitation_audit_events_immutable
  before update or delete on app_private.invitation_audit_events
  for each row execute function app_private.reject_invitation_audit_change();

-- Issues an invitation and returns the plaintext token once. The caller must
-- be a current admin of p_organization_id. The token is 64 lowercase hex digits
-- drawn from two gen_random_uuid() values (about 244 random bits).
create function public.issue_organization_invitation(
  p_organization_id uuid,
  p_email text,
  p_role public.organization_role,
  p_lifetime interval default interval '7 days'
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(btrim(p_email, E' \t\r\n'));
  v_token text;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'sign in to issue an invitation';
  end if;
  if not exists (
    select 1 from public.memberships as m
    where m.organization_id = p_organization_id
      and m.user_id = v_user_id
      and m.role = 'admin'
  ) then
    raise insufficient_privilege using message = 'only organization admins can issue invitations';
  end if;
  if v_email is null
    or char_length(v_email) not between 3 and 254
    or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid invitation email';
  end if;
  if p_role is null then
    raise exception 'invitation role is required';
  end if;
  if p_lifetime is null
    or p_lifetime < interval '1 hour'
    or p_lifetime > interval '14 days' then
    raise exception 'invitation lifetime must be between 1 hour and 14 days';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '')
    || replace(gen_random_uuid()::text, '-', '');
  insert into public.organization_invitations (
    organization_id, email, role, token_digest, created_by, expires_at
  ) values (
    p_organization_id, v_email, p_role,
    sha256(convert_to(v_token, 'UTF8')), v_user_id, now() + p_lifetime
  );
  return v_token;
end;
$$;

-- Revokes a pending invitation. A caller who is not an admin of the invitation's
-- organization gets the same answer as for an unknown ID, so IDs do not leak.
create function public.revoke_organization_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.organization_invitations;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'sign in to revoke an invitation';
  end if;
  select * into v_invitation from public.organization_invitations as i
    where i.id = p_invitation_id
      and exists (
        select 1 from public.memberships as m
        where m.organization_id = i.organization_id
          and m.user_id = v_user_id
          and m.role = 'admin'
      )
    for update;
  if not found then
    raise insufficient_privilege using message = 'only organization admins can revoke this invitation';
  end if;
  if v_invitation.consumed_at is not null or v_invitation.revoked_at is not null then
    raise exception 'invitation is no longer pending';
  end if;

  update public.organization_invitations
    set revoked_at = now(), revoked_by = v_user_id
    where id = p_invitation_id;
end;
$$;

-- Accepts an invitation for the signed-in user. The invitee is not yet a member,
-- so this function must read the invitation and insert membership on the
-- caller's behalf. It returns the organization ID.
create function public.accept_organization_invitation(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_invitation public.organization_invitations;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'sign in to accept an invitation';
  end if;
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'malformed invitation token';
  end if;
  -- Only a confirmed address proves control of the mailbox. An unconfirmed
  -- sign-up could otherwise claim an invitation addressed to someone else.
  select lower(btrim(u.email, E' \t\r\n')) into v_email
    from auth.users as u
    where u.id = v_user_id and u.email_confirmed_at is not null;
  if v_email is null then
    raise insufficient_privilege using message = 'a confirmed email is required to accept an invitation';
  end if;

  -- Lock before checking state. A concurrent attempt waits here, then re-reads
  -- the committed row and finds it consumed.
  select * into v_invitation from public.organization_invitations as i
    where i.token_digest = sha256(convert_to(p_token, 'UTF8'))
    for update;
  if not found then
    raise exception 'invitation not found';
  end if;
  if v_invitation.email <> v_email then
    raise insufficient_privilege using message = 'invitation is for a different email address';
  end if;
  if v_invitation.consumed_at is not null then
    raise exception 'invitation already used';
  end if;
  if v_invitation.revoked_at is not null then
    raise exception 'invitation revoked';
  end if;
  if v_invitation.expires_at <= now() then
    raise exception 'invitation expired';
  end if;
  if exists (
    select 1 from public.memberships as m
    where m.organization_id = v_invitation.organization_id
      and m.user_id = v_user_id
  ) then
    raise exception 'already a member of this organization';
  end if;

  insert into public.memberships (organization_id, user_id, role)
    values (v_invitation.organization_id, v_user_id, v_invitation.role);
  update public.organization_invitations
    set consumed_at = now(), consumed_by = v_user_id
    where id = v_invitation.id;
  return v_invitation.organization_id;
end;
$$;

-- Grants: the trigger functions are reachable only through their tables, so
-- no application role can call them directly. Each callable function has an
-- explicit execute grant to authenticated only.
revoke all on function app_private.guard_organization_invitation_update(),
  app_private.record_invitation_event(),
  app_private.reject_invitation_audit_change()
  from public, anon, authenticated;

revoke all on function public.issue_organization_invitation(uuid, text, public.organization_role, interval),
  public.revoke_organization_invitation(uuid),
  public.accept_organization_invitation(text)
  from public, anon;
grant execute on function public.issue_organization_invitation(uuid, text, public.organization_role, interval),
  public.revoke_organization_invitation(uuid),
  public.accept_organization_invitation(text)
  to authenticated;
