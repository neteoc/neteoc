-- Execute against a disposable database. Every fixture and role switch rolls back.
-- Concurrent acceptance needs committed rows, so it lives in
-- organization_invitations_race.sh.
begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', 'inv-admin-a@neteoc.invalid', now()),
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e502', 'inv-viewer-a@neteoc.invalid', now()),
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e503', 'inv-editor-a@neteoc.invalid', now()),
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e504', 'inv-admin-b@neteoc.invalid', now()),
  -- Auth can store mixed case. Acceptance must still match the invitation.
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e505', 'Invitee@Neteoc.Invalid', now()),
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e506', 'other-person@neteoc.invalid', now()),
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e507', 'unconfirmed@neteoc.invalid', null),
  ('a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e508', 'revoke-target@neteoc.invalid', now());

insert into public.organizations (id, name) values
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'Invitation test organization A'),
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f602', 'Invitation test organization B');

-- The invitee already belongs to organization B, so acceptance into A must leave B intact.
insert into public.memberships (organization_id, user_id, role) values
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', 'admin'),
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e502', 'viewer'),
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e503', 'editor'),
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f602', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e504', 'admin'),
  ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f602', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e505', 'viewer');

-- An already-expired invitation cannot be issued through the function. Insert
-- it directly as the fixture owner. Its plaintext token is 64 ones.
insert into public.organization_invitations (
  id, organization_id, email, role, token_digest, created_by, created_at, expires_at
) values (
  'c3d2e4f6-3d4e-4f70-8b12-c3d4e5f6a701',
  'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601',
  'invitee@neteoc.invalid',
  'viewer',
  sha256(convert_to(repeat('1', 64), 'UTF8')),
  'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501',
  now() - interval '2 days',
  now() - interval '1 day'
);

-- Privilege and configuration assertions. Each check reads the catalog, so a
-- missing revoke or a dropped pin fails even when behavior would still deny.
do $$
declare
  fn text;
begin
  if (select count(*) from pg_class
      where relrowsecurity
        and oid in ('public.organization_invitations'::regclass,
                    'app_private.invitation_audit_events'::regclass)) <> 2 then
    raise exception 'RLS is not enabled on every invitation table';
  end if;

  if has_table_privilege('anon', 'public.organization_invitations', 'select, insert, update, delete, truncate, references, trigger')
    or has_any_column_privilege('anon', 'public.organization_invitations', 'select, insert, update, references') then
    raise exception 'anon holds a privilege on organization_invitations';
  end if;
  if has_table_privilege('authenticated', 'public.organization_invitations', 'insert, update, delete, truncate, references, trigger')
    or has_any_column_privilege('authenticated', 'public.organization_invitations', 'insert, update, references') then
    raise exception 'authenticated can write organization_invitations directly';
  end if;
  -- Column-level read only. Table-level SELECT would expose token_digest.
  if has_table_privilege('authenticated', 'public.organization_invitations', 'select') then
    raise exception 'authenticated has table-level select on organization_invitations';
  end if;
  if not has_column_privilege('authenticated', 'public.organization_invitations', 'email', 'select') then
    raise exception 'authenticated cannot read invitation email';
  end if;
  if has_column_privilege('authenticated', 'public.organization_invitations', 'token_digest', 'select') then
    raise exception 'authenticated can read token_digest';
  end if;

  if has_table_privilege('anon', 'app_private.invitation_audit_events', 'select, insert, update, delete, truncate')
    or has_table_privilege('authenticated', 'app_private.invitation_audit_events', 'select, insert, update, delete, truncate') then
    raise exception 'an application role can touch the invitation audit log';
  end if;

  if has_function_privilege('anon', 'public.issue_organization_invitation(uuid, text, public.organization_role, interval)', 'execute')
    or has_function_privilege('anon', 'public.revoke_organization_invitation(uuid)', 'execute')
    or has_function_privilege('anon', 'public.accept_organization_invitation(text)', 'execute') then
    raise exception 'anon can execute an invitation function';
  end if;
  if not has_function_privilege('authenticated', 'public.issue_organization_invitation(uuid, text, public.organization_role, interval)', 'execute')
    or not has_function_privilege('authenticated', 'public.revoke_organization_invitation(uuid)', 'execute')
    or not has_function_privilege('authenticated', 'public.accept_organization_invitation(text)', 'execute') then
    raise exception 'authenticated cannot execute an invitation function';
  end if;

  -- PUBLIC has an implicit execute grant unless it is revoked. A null proacl
  -- means the default ACL applies, so expand that instead of skipping it.
  if exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
    where p.oid in (
        'public.issue_organization_invitation(uuid, text, public.organization_role, interval)'::regprocedure,
        'public.revoke_organization_invitation(uuid)'::regprocedure,
        'public.accept_organization_invitation(text)'::regprocedure,
        'app_private.record_invitation_event()'::regprocedure,
        'app_private.guard_organization_invitation_update()'::regprocedure,
        'app_private.reject_invitation_audit_change()'::regprocedure
      )
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'PUBLIC can execute an invitation function';
  end if;
  if has_function_privilege('authenticated', 'app_private.record_invitation_event()', 'execute')
    or has_function_privilege('authenticated', 'app_private.guard_organization_invitation_update()', 'execute') then
    raise exception 'authenticated can call a trigger function directly';
  end if;

  -- The three callable functions are security definer with a pinned search
  -- path. Losing either property changes what name resolution and RLS apply.
  foreach fn in array array[
    'public.issue_organization_invitation(uuid, text, public.organization_role, interval)',
    'public.revoke_organization_invitation(uuid)',
    'public.accept_organization_invitation(text)',
    'app_private.record_invitation_event()'
  ] loop
    if not exists (
      select 1 from pg_proc
      where oid = fn::regprocedure
        and prosecdef
        and proconfig @> array['search_path=""']
    ) then
      raise exception '% must be security definer with search_path pinned', fn;
    end if;
  end loop;
  -- The guard and immutability triggers run as the caller and need no privilege.
  foreach fn in array array[
    'app_private.guard_organization_invitation_update()',
    'app_private.reject_invitation_audit_change()'
  ] loop
    if not exists (
      select 1 from pg_proc
      where oid = fn::regprocedure
        and not prosecdef
        and proconfig @> array['search_path=""']
    ) then
      raise exception '% must be security invoker with search_path pinned', fn;
    end if;
  end loop;
end;
$$;

-- Schema-level checks run as the fixture owner: constraints hold for every writer.
do $$
begin
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'Mixed@Neteoc.Invalid', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '1 day');
    raise exception 'uppercase email stored';
  exception when check_violation then null;
  end;
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', '  padded@neteoc.invalid ', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '1 day');
    raise exception 'padded email stored';
  exception when check_violation then null;
  end;
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'no-domain-dot@neteoc', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '1 day');
    raise exception 'malformed email stored';
  exception when check_violation then null;
  end;
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'a b@neteoc.invalid', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '1 day');
    raise exception 'address with embedded space stored';
  exception when check_violation then null;
  end;
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'long@neteoc.invalid', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '15 days');
    raise exception 'lifetime beyond 14 days stored';
  exception when check_violation then null;
  end;
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at, consumed_by, consumed_at, revoked_by, revoked_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'both@neteoc.invalid', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '1 day',
              'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now(), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now());
    raise exception 'invitation both consumed and revoked';
  exception when check_violation then null;
  end;
  begin
    insert into public.organization_invitations (organization_id, email, role, token_digest, created_by, expires_at, consumed_at)
      values ('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'orphan@neteoc.invalid', 'viewer', sha256('x'::bytea), 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', now() + interval '1 day', now());
    raise exception 'consumption without a consumer stored';
  exception when check_violation then null;
  end;
end;
$$;

-- Admin in organization A issues invitations. The token is returned once, so it
-- is kept in a transaction-local setting for the acceptance checks below.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', true);
set local role authenticated;
do $$
declare
  v_token text;
begin
  -- Input is normalized before storage, so padding and case must not create a second address.
  v_token := public.issue_organization_invitation(
    'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', '  Invitee@NETEOC.Invalid ', 'viewer');
  perform set_config('test.invitee_token', v_token, true);

  v_token := public.issue_organization_invitation(
    'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'other-person@neteoc.invalid', 'editor');
  perform set_config('test.other_token', v_token, true);

  v_token := public.issue_organization_invitation(
    'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'revoke-target@neteoc.invalid', 'viewer');
  perform set_config('test.revoke_token', v_token, true);
  perform set_config('test.revoke_id', (
    select id::text from public.organization_invitations
    where email = 'revoke-target@neteoc.invalid'
  ), true);

  v_token := public.issue_organization_invitation(
    'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'inv-viewer-a@neteoc.invalid', 'viewer');
  perform set_config('test.member_token', v_token, true);

  v_token := public.issue_organization_invitation(
    'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'unconfirmed@neteoc.invalid', 'viewer');
  perform set_config('test.unconfirmed_token', v_token, true);

  -- Admin sees the organization's invitations: the five new ones plus the fixture.
  if (select count(*) from public.organization_invitations) <> 6 then
    raise exception 'admin cannot read the organization invitations it issued';
  end if;
  -- The plaintext token is returned, so a stored secret would be a fault.
  if v_token !~ '^[0-9a-f]{64}$' then
    raise exception 'issued token is not 64 lowercase hex digits';
  end if;
end;
$$;

-- Malformed issuance by the admin. Each message is checked exactly, so a
-- rejection for an unrelated reason cannot pass.
do $$
begin
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'not-an-email', 'viewer');
    raise exception 'malformed email issued';
  exception when others then
    if sqlerrm <> 'invalid invitation email' then raise; end if;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'two words@neteoc.invalid', 'viewer');
    raise exception 'email with an inner space issued';
  exception when others then
    if sqlerrm <> 'invalid invitation email' then raise; end if;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', null, 'viewer');
    raise exception 'null email issued';
  exception when others then
    if sqlerrm <> 'invalid invitation email' then raise; end if;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'role-check@neteoc.invalid', null);
    raise exception 'invitation without a role issued';
  exception when others then
    if sqlerrm <> 'invitation role is required' then raise; end if;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'role-check@neteoc.invalid', 'owner'::text::public.organization_role);
    raise exception 'unknown role issued';
  exception when invalid_text_representation then null;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'life@neteoc.invalid', 'viewer', interval '0 seconds');
    raise exception 'zero-length invitation issued';
  exception when others then
    if sqlerrm <> 'invitation lifetime must be between 1 hour and 14 days' then raise; end if;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'life@neteoc.invalid', 'viewer', interval '15 days');
    raise exception 'invitation beyond 14 days issued';
  exception when others then
    if sqlerrm <> 'invitation lifetime must be between 1 hour and 14 days' then raise; end if;
  end;
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'life@neteoc.invalid', 'viewer', null);
    raise exception 'null lifetime issued';
  exception when others then
    if sqlerrm <> 'invitation lifetime must be between 1 hour and 14 days' then raise; end if;
  end;
end;
$$;

-- Viewer and editor in organization A cannot issue. An admin of organization B
-- cannot issue into A (wrong tenant). The function's own check gives each
-- denial, so each message is asserted exactly.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e502', true);
set local role authenticated;
do $$
begin
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'viewer-escalation@neteoc.invalid', 'admin');
    raise exception 'viewer issued an invitation';
  exception when insufficient_privilege then
    if sqlerrm <> 'only organization admins can issue invitations' then raise; end if;
  end;
end;
$$;
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e503', true);
do $$
begin
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'editor-escalation@neteoc.invalid', 'viewer');
    raise exception 'editor issued an invitation';
  exception when insufficient_privilege then
    if sqlerrm <> 'only organization admins can issue invitations' then raise; end if;
  end;
end;
$$;
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e504', true);
do $$
begin
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'cross-tenant@neteoc.invalid', 'viewer');
    raise exception 'admin of organization B issued into organization A';
  exception when insufficient_privilege then
    if sqlerrm <> 'only organization admins can issue invitations' then raise; end if;
  end;
  -- Organization B's admin cannot read organization A's invitations.
  if (select count(*) from public.organization_invitations
      where organization_id = 'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601') <> 0 then
    raise exception 'organization B admin read organization A invitations';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e502', true);
do $$
begin
  -- A viewer cannot read the invitation list either.
  if (select count(*) from public.organization_invitations) <> 0 then
    raise exception 'viewer read organization invitations';
  end if;
end;
$$;

-- Revocation. Only an admin of the invitation's organization may revoke it. For
-- a non-admin, an unknown ID and an existing one give the same answer.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e502', true);
do $$
begin
  begin
    perform public.revoke_organization_invitation(current_setting('test.revoke_id')::uuid);
    raise exception 'viewer revoked an invitation';
  exception when insufficient_privilege then
    if sqlerrm <> 'only organization admins can revoke this invitation' then raise; end if;
  end;
end;
$$;
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e504', true);
do $$
begin
  begin
    perform public.revoke_organization_invitation(current_setting('test.revoke_id')::uuid);
    raise exception 'organization B admin revoked organization A invitation';
  exception when insufficient_privilege then
    if sqlerrm <> 'only organization admins can revoke this invitation' then raise; end if;
  end;
  begin
    perform public.revoke_organization_invitation('d4e3f5a7-4e5f-4a81-9c23-d4e5f6a7b801');
    raise exception 'revoke of an unknown invitation succeeded';
  exception when insufficient_privilege then
    if sqlerrm <> 'only organization admins can revoke this invitation' then raise; end if;
  end;
end;
$$;
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501', true);
do $$
begin
  perform public.revoke_organization_invitation(current_setting('test.revoke_id')::uuid);
  -- A second revocation is refused rather than rewriting who revoked it.
  begin
    perform public.revoke_organization_invitation(current_setting('test.revoke_id')::uuid);
    raise exception 'invitation revoked twice';
  exception when others then
    if sqlerrm <> 'invitation is no longer pending' then raise; end if;
  end;
end;
$$;

-- Acceptance by the signed-in invitee. Each denial is checked against its exact message.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e505', true);
set local role authenticated;
do $$
begin
  -- Malformed tokens never reach the lookup.
  begin
    perform public.accept_organization_invitation('not-a-token');
    raise exception 'malformed token accepted';
  exception when others then
    if sqlerrm <> 'malformed invitation token' then raise; end if;
  end;
  begin
    perform public.accept_organization_invitation(left(current_setting('test.invitee_token'), 63));
    raise exception 'token one character short accepted';
  exception when others then
    if sqlerrm <> 'malformed invitation token' then raise; end if;
  end;
  begin
    perform public.accept_organization_invitation(upper(current_setting('test.invitee_token')));
    raise exception 'uppercase token accepted';
  exception when others then
    if sqlerrm <> 'malformed invitation token' then raise; end if;
  end;
  begin
    perform public.accept_organization_invitation(null);
    raise exception 'null token accepted';
  exception when others then
    if sqlerrm <> 'malformed invitation token' then raise; end if;
  end;
  -- Well formed but unknown.
  begin
    perform public.accept_organization_invitation(repeat('2', 64));
    raise exception 'unknown token accepted';
  exception when others then
    if sqlerrm <> 'invitation not found' then raise; end if;
  end;
  -- A correct token for an invitation addressed to someone else is refused, and that refusal does not consume it.
  begin
    perform public.accept_organization_invitation(current_setting('test.other_token'));
    raise exception 'invitee accepted an invitation for another address';
  exception when insufficient_privilege then
    if sqlerrm <> 'invitation is for a different email address' then raise; end if;
  end;
  -- Expired, from the fixture.
  begin
    perform public.accept_organization_invitation(repeat('1', 64));
    raise exception 'expired invitation accepted';
  exception when others then
    if sqlerrm <> 'invitation expired' then raise; end if;
  end;
end;
$$;

-- Unconfirmed sign-up with a matching address is refused: the mailbox is not proven.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e507', true);
do $$
begin
  begin
    perform public.accept_organization_invitation(current_setting('test.unconfirmed_token'));
    raise exception 'unconfirmed account accepted an invitation';
  exception when insufficient_privilege then
    if sqlerrm <> 'a confirmed email is required to accept an invitation' then raise; end if;
  end;
end;
$$;

-- A signed-out request has no user to bind the invitation to.
select set_config('request.jwt.claim.sub', '', true);
do $$
begin
  begin
    perform public.accept_organization_invitation(current_setting('test.invitee_token'));
    raise exception 'signed-out request accepted an invitation';
  exception when insufficient_privilege then
    if sqlerrm <> 'sign in to accept an invitation' then raise; end if;
  end;
end;
$$;

-- Revoked invitation, accepted by its own address after revocation.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e508', true);
do $$
begin
  begin
    perform public.accept_organization_invitation(current_setting('test.revoke_token'));
    raise exception 'revoked invitation accepted';
  exception when others then
    if sqlerrm <> 'invitation revoked' then raise; end if;
  end;
end;
$$;

-- An existing member is refused, and the invitation stays pending.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e502', true);
do $$
begin
  begin
    perform public.accept_organization_invitation(current_setting('test.member_token'));
    raise exception 'existing member accepted an invitation';
  exception when others then
    if sqlerrm <> 'already a member of this organization' then raise; end if;
  end;
end;
$$;

-- Allow case: the invitee accepts. The returned ID must be organization A.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e505', true);
do $$
declare
  v_org uuid;
begin
  v_org := public.accept_organization_invitation(current_setting('test.invitee_token'));
  if v_org <> 'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601' then
    raise exception 'acceptance returned the wrong organization';
  end if;

  -- Replay of the consumed token fails with the used message, not the membership message.
  begin
    perform public.accept_organization_invitation(current_setting('test.invitee_token'));
    raise exception 'consumed invitation accepted again';
  exception when others then
    if sqlerrm <> 'invitation already used' then raise; end if;
  end;
end;
$$;

-- The second address accepts its own invitation after the wrong-email attempt.
select set_config('request.jwt.claim.sub', 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e506', true);
do $$
begin
  if public.accept_organization_invitation(current_setting('test.other_token'))
     <> 'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601' then
    raise exception 'other address could not accept after a refused attempt';
  end if;
end;
$$;

-- Superuser checks: the state transitions, membership results, and audit trail.
reset role;
do $$
declare
  v_invitee_id uuid := 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e505';
  v_invitation uuid;
  v_count integer;
begin
  -- Single-use: the invitee holds one membership in A, at the invited role, and is still in B.
  if (select role::text from public.memberships
      where organization_id = 'b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601' and user_id = v_invitee_id) <> 'viewer' then
    raise exception 'invitee membership in A is missing or has the wrong role';
  end if;
  if (select count(*) from public.memberships where user_id = v_invitee_id) <> 2 then
    raise exception 'acceptance into A changed the invitee membership in B';
  end if;

  -- Stored digest matches the token. The plaintext is not in the table.
  if not exists (
    select 1 from public.organization_invitations
    where token_digest = sha256(convert_to(current_setting('test.invitee_token'), 'UTF8'))
  ) then
    raise exception 'stored digest does not match the issued token';
  end if;
  if exists (
    select 1 from public.organization_invitations
    where token_digest = convert_to(current_setting('test.invitee_token'), 'UTF8')
  ) then
    raise exception 'plaintext token stored';
  end if;

  -- Wrong-email refusal and existing-member refusal change no state.
  select id into v_invitation from public.organization_invitations
    where token_digest = sha256(convert_to(current_setting('test.member_token'), 'UTF8'));
  if (select consumed_at from public.organization_invitations where id = v_invitation) is not null then
    raise exception 'a refused acceptance consumed an invitation';
  end if;
  select count(*) into v_count from app_private.invitation_audit_events
    where invitation_id = v_invitation;
  if v_count <> 1 then
    raise exception 'refused acceptance wrote an audit event';
  end if;

  -- Audit trail for the accepted invitation: issued by the admin, consumed by the invitee.
  select id into v_invitation from public.organization_invitations
    where consumed_by = v_invitee_id;
  if (select count(*) from app_private.invitation_audit_events
      where invitation_id = v_invitation and action = 'issued'
        and actor_user_id = 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501') <> 1
    or (select count(*) from app_private.invitation_audit_events
      where invitation_id = v_invitation and action = 'consumed'
        and actor_user_id = v_invitee_id) <> 1 then
    raise exception 'audit trail for consumption is incomplete';
  end if;

  -- Revocation is audited with the revoking admin as actor.
  if (select count(*) from app_private.invitation_audit_events a
      join public.organization_invitations i on i.id = a.invitation_id
      where i.email = 'revoke-target@neteoc.invalid'
        and a.action = 'revoked'
        and a.actor_user_id = 'a1f0c2d4-1b2c-4d5e-8f90-a1b2c3d4e501') <> 1 then
    raise exception 'revocation was not audited with its admin actor';
  end if;

  -- The audit table holds IDs and an action only: no address and no token.
  if (select string_agg(column_name, ',' order by ordinal_position)
      from information_schema.columns
      where table_schema = 'app_private' and table_name = 'invitation_audit_events')
     <> 'id,invitation_id,organization_id,actor_user_id,action,created_at' then
    raise exception 'invitation audit table has an unexpected column';
  end if;

  -- Guard: a pending invitation's terms cannot change, and a finished one takes no change.
  begin
    update public.organization_invitations
      set expires_at = now() + interval '1 day'
      where email = 'inv-viewer-a@neteoc.invalid';
    raise exception 'invitation expiry changed after issuance';
  exception when others then
    if sqlerrm <> 'invitation terms are immutable' then raise; end if;
  end;
  begin
    update public.organization_invitations
      set revoked_at = now(), revoked_by = v_invitee_id
      where id = v_invitation;
    raise exception 'consumed invitation revoked';
  exception when others then
    if sqlerrm <> 'invitation is no longer pending' then raise; end if;
  end;

  -- Audit rows are append-only, including for the owner.
  begin
    update app_private.invitation_audit_events set action = 'issued';
    raise exception 'audit event updated';
  exception when others then
    if sqlerrm <> 'invitation audit events are immutable' then raise; end if;
  end;
  begin
    delete from app_private.invitation_audit_events;
    raise exception 'audit event deleted';
  exception when others then
    if sqlerrm <> 'invitation audit events are immutable' then raise; end if;
  end;
end;
$$;

-- Anonymous visitors have no grant. The message names the missing grant, not
-- the function's own check, so this proves the revoke rather than the body.
set local role anon;
do $$
begin
  begin
    perform public.issue_organization_invitation('b2e1d3f5-2c3d-4e6f-9a01-b2c3d4e5f601', 'anon@neteoc.invalid', 'viewer');
    raise exception 'anonymous issuance succeeded';
  exception when insufficient_privilege then
    if sqlerrm <> 'permission denied for function issue_organization_invitation' then raise; end if;
  end;
  begin
    perform public.accept_organization_invitation(repeat('1', 64));
    raise exception 'anonymous acceptance succeeded';
  exception when insufficient_privilege then
    if sqlerrm <> 'permission denied for function accept_organization_invitation' then raise; end if;
  end;
  begin
    perform 1 from public.organization_invitations limit 1;
    raise exception 'anonymous invitation read succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
rollback;
