-- Reports the SQLSTATE a RESTRICT foreign key raises for an Auth user delete,
-- and the same for a NO ACTION foreign key, against the migrated schema.
\set VERBOSITY verbose
begin;
insert into auth.users (id, email) values ('eb83ce3a-102c-4aa6-804d-f8f1f9a21af7', 'probe@neteoc.invalid');
insert into public.organizations (id, name) values ('ef595c35-460f-438b-b504-dc73a6a47a89', 'probe');
insert into public.memberships (organization_id, user_id, role) values ('ef595c35-460f-438b-b504-dc73a6a47a89', 'eb83ce3a-102c-4aa6-804d-f8f1f9a21af7', 'admin');
do $$
begin
  begin
    delete from auth.users where id = 'eb83ce3a-102c-4aa6-804d-f8f1f9a21af7';
    raise notice 'PROBE memberships_user_id_fkey (ON DELETE RESTRICT): no error raised';
  exception when others then
    raise notice 'PROBE memberships_user_id_fkey (ON DELETE RESTRICT): sqlstate=% message=%', sqlstate, sqlerrm;
  end;
end;
$$;
rollback;
