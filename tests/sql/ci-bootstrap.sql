-- Minimal Supabase Auth surface for PostgreSQL RLS tests in CI. Production
-- migrations still run against the real Supabase development project.
create role anon nologin;
create role authenticated nologin;

create schema auth;
create table auth.users (
  id uuid primary key,
  email text,
  created_at timestamptz not null default now()
);

create function auth.uid() returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;

-- Supabase grants new public tables and functions to anon and authenticated by
-- default. Mirror that here so every revoke in a migration is exercised, not
-- just assumed. Without these defaults a missing revoke passes CI and fails on
-- a real project.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
