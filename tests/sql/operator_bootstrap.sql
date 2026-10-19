-- Transactional operator/bootstrap allow and application-role deny cases.
begin;

insert into auth.users (id, email) values
  ('7644a5f6-0390-4f51-94df-b51e642e1945', 'operator@neteoc.invalid'),
  ('398a968a-82d5-42e9-a225-47ff213c85b5', 'initial-admin@neteoc.invalid');

do $$
declare
  created_id uuid;
begin
  begin
    perform app_private.bootstrap_organization(
      'Bootstrap fixture',
      '398a968a-82d5-42e9-a225-47ff213c85b5',
      '7644a5f6-0390-4f51-94df-b51e642e1945',
      'test-change-001'
    );
    raise exception 'organization created before platform admin appointment';
  exception when raise_exception then
    if sqlerrm <> 'platform administrator is not appointed' then raise; end if;
  end;

  perform app_private.bootstrap_platform_admin(
    '7644a5f6-0390-4f51-94df-b51e642e1945', 'test-change-001'
  );
  begin
    perform app_private.bootstrap_platform_admin(
      '398a968a-82d5-42e9-a225-47ff213c85b5', 'test-change-002'
    );
    raise exception 'second platform admin bootstrap succeeded';
  exception when raise_exception then
    if sqlerrm <> 'platform administrator already bootstrapped' then raise; end if;
  end;

  created_id := app_private.bootstrap_organization(
    'Bootstrap fixture',
    '398a968a-82d5-42e9-a225-47ff213c85b5',
    '7644a5f6-0390-4f51-94df-b51e642e1945',
    'test-change-003'
  );
  if not exists (
    select 1 from public.memberships
    where organization_id = created_id
      and user_id = '398a968a-82d5-42e9-a225-47ff213c85b5'
      and role = 'admin'
  ) then
    raise exception 'initial admin membership absent';
  end if;
  if (select count(*) from app_private.audit_events
      where operator_ref like 'test-change-%') <> 2 then
    raise exception 'bootstrap audit trail missing or duplicated';
  end if;

  begin
    perform app_private.bootstrap_organization(
      'Must roll back',
      '398a968a-82d5-42e9-a225-47ff213c85b5',
      '7644a5f6-0390-4f51-94df-b51e642e1945',
      'x'
    );
    raise exception 'short operator reference accepted';
  exception when check_violation then null;
  end;
  if exists (select 1 from public.organizations where name = 'Must roll back') then
    raise exception 'failed bootstrap left an organization behind';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', '398a968a-82d5-42e9-a225-47ff213c85b5', true);
set local role authenticated;
do $$
begin
  if has_schema_privilege('authenticated', 'app_private', 'USAGE') then
    raise exception 'authenticated role can use private schema';
  end if;
  begin
    perform app_private.bootstrap_organization(
      'Forbidden',
      '398a968a-82d5-42e9-a225-47ff213c85b5',
      '7644a5f6-0390-4f51-94df-b51e642e1945',
      'test-change-004'
    );
    raise exception 'authenticated organization bootstrap succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from app_private.audit_events;
    raise exception 'authenticated audit read succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

set local role anon;
do $$
begin
  if has_schema_privilege('anon', 'app_private', 'USAGE') then
    raise exception 'anonymous role can use private schema';
  end if;
  begin
    perform app_private.bootstrap_platform_admin(
      '398a968a-82d5-42e9-a225-47ff213c85b5', 'test-change-005'
    );
    raise exception 'anonymous platform admin bootstrap succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
