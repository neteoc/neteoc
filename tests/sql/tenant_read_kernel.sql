-- Run against a disposable local or preview Supabase database with at least
-- one Auth user. All fixtures and role changes roll back together.
begin;

do $$
declare
  member_id uuid;
begin
  select id into member_id from auth.users order by created_at limit 1;
  if member_id is null then
    raise exception 'tenant RLS test requires one Auth user';
  end if;

  insert into public.organizations (id, name) values
    ('e1a6a914-46e6-45ca-973f-665cc018c139', 'RLS test organization A'),
    ('ef595c35-460f-438b-b504-dc73a6a47a89', 'RLS test organization B');
  insert into public.memberships (organization_id, user_id, role)
    values ('e1a6a914-46e6-45ca-973f-665cc018c139', member_id, 'viewer');
  perform set_config('request.jwt.claim.sub', member_id::text, true);
end;
$$;

set local role authenticated;
do $$
begin
  if (select count(*) from public.organizations
      where id in ('e1a6a914-46e6-45ca-973f-665cc018c139',
                   'ef595c35-460f-438b-b504-dc73a6a47a89')) <> 1 then
    raise exception 'member must see only their organization';
  end if;
  if (select count(*) from public.memberships
      where organization_id = 'e1a6a914-46e6-45ca-973f-665cc018c139') <> 1 then
    raise exception 'member must see their own membership';
  end if;
  begin
    insert into public.organizations (name) values ('forbidden write');
    raise exception 'authenticated organization insert unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', 'cf92e805-ab3b-4538-8b72-ce3a2bf06bc1', true);
do $$
begin
  if exists (select 1 from public.organizations
             where id = 'e1a6a914-46e6-45ca-973f-665cc018c139')
    or exists (select 1 from public.memberships
               where organization_id = 'e1a6a914-46e6-45ca-973f-665cc018c139') then
    raise exception 'member of another organization read tenant data';
  end if;
end;
$$;

set local role anon;
do $$
begin
  begin
    perform 1 from public.organizations limit 1;
    raise exception 'anonymous organization read unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.memberships limit 1;
    raise exception 'anonymous membership read unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
