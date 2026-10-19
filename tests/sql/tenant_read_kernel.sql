-- Execute against a disposable database. Every fixture and role switch rolls back.
begin;

insert into auth.users (id, email) values
  ('cb4c4b80-c9c9-4192-90e8-49b8c56c4937', 'rls-a@neteoc.invalid'),
  ('eb83ce3a-102c-4aa6-804d-f8f1f9a21af7', 'rls-b@neteoc.invalid'),
  ('39bc44d3-0eea-4e18-949b-64113a2bf7e3', 'rls-c@neteoc.invalid');

insert into public.organizations (id, name) values
  ('e1a6a914-46e6-45ca-973f-665cc018c139', 'RLS test duplicate name'),
  ('ef595c35-460f-438b-b504-dc73a6a47a89', 'RLS test duplicate name');

insert into public.memberships (organization_id, user_id, role) values
  ('e1a6a914-46e6-45ca-973f-665cc018c139', 'cb4c4b80-c9c9-4192-90e8-49b8c56c4937', 'viewer'),
  ('ef595c35-460f-438b-b504-dc73a6a47a89', 'eb83ce3a-102c-4aa6-804d-f8f1f9a21af7', 'admin'),
  ('e1a6a914-46e6-45ca-973f-665cc018c139', '39bc44d3-0eea-4e18-949b-64113a2bf7e3', 'editor');

-- Auth deletion cannot silently remove a membership, even for an admin.
do $$
begin
  begin
    delete from auth.users where id = 'eb83ce3a-102c-4aa6-804d-f8f1f9a21af7';
    raise exception 'Auth deletion removed a member';
  exception when foreign_key_violation then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', 'cb4c4b80-c9c9-4192-90e8-49b8c56c4937', true);
set local role authenticated;
do $$
declare
  affected integer;
begin
  if (select count(*) from public.organizations
      where id in ('e1a6a914-46e6-45ca-973f-665cc018c139',
                   'ef595c35-460f-438b-b504-dc73a6a47a89')) <> 1
    or not exists (select 1 from public.organizations
                   where id = 'e1a6a914-46e6-45ca-973f-665cc018c139') then
    raise exception 'tenant A member did not see exactly tenant A';
  end if;
  if (select count(*) from public.memberships
      where organization_id = 'e1a6a914-46e6-45ca-973f-665cc018c139') <> 1 then
    raise exception 'tenant A member read a co-member or lost their own row';
  end if;

  begin
    insert into public.organizations (name) values ('forbidden write');
    raise exception 'authenticated organization insert succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.organizations set name = 'forbidden write'
      where id = 'e1a6a914-46e6-45ca-973f-665cc018c139';
    get diagnostics affected = row_count;
    if affected <> 0 then raise exception 'authenticated organization update succeeded'; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.organizations
      where id = 'e1a6a914-46e6-45ca-973f-665cc018c139';
    get diagnostics affected = row_count;
    if affected <> 0 then raise exception 'authenticated organization delete succeeded'; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.memberships (organization_id, user_id, role)
      values ('ef595c35-460f-438b-b504-dc73a6a47a89',
              'cb4c4b80-c9c9-4192-90e8-49b8c56c4937', 'admin');
    raise exception 'authenticated membership insert succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.memberships set role = 'admin'
      where organization_id = 'e1a6a914-46e6-45ca-973f-665cc018c139'
        and user_id = 'cb4c4b80-c9c9-4192-90e8-49b8c56c4937';
    get diagnostics affected = row_count;
    if affected <> 0 then raise exception 'authenticated role escalation succeeded'; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.memberships
      where organization_id = 'e1a6a914-46e6-45ca-973f-665cc018c139'
        and user_id = 'cb4c4b80-c9c9-4192-90e8-49b8c56c4937';
    get diagnostics affected = row_count;
    if affected <> 0 then raise exception 'authenticated membership delete succeeded'; end if;
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', 'eb83ce3a-102c-4aa6-804d-f8f1f9a21af7', true);
do $$
begin
  if (select count(*) from public.organizations
      where id in ('e1a6a914-46e6-45ca-973f-665cc018c139',
                   'ef595c35-460f-438b-b504-dc73a6a47a89')) <> 1
    or not exists (select 1 from public.organizations
                   where id = 'ef595c35-460f-438b-b504-dc73a6a47a89')
    or (select count(*) from public.memberships
        where organization_id in ('e1a6a914-46e6-45ca-973f-665cc018c139',
                                  'ef595c35-460f-438b-b504-dc73a6a47a89')) <> 1 then
    raise exception 'tenant B crossed tenant boundary';
  end if;
end;
$$;

set local role anon;
do $$
begin
  begin
    perform 1 from public.organizations limit 1;
    raise exception 'anonymous organization read succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.memberships limit 1;
    raise exception 'anonymous membership read succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
