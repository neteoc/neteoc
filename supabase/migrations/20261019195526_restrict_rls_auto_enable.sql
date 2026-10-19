-- Some Supabase projects include this event-trigger helper with PUBLIC execute
-- access. Application requests do not need it. A fresh local database may not
-- include the helper, so only revoke and test privileges when it exists.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';

    -- Negative authorization checks for the application-facing database roles.
    if has_function_privilege('anon', 'public.rls_auto_enable()', 'execute')
      or has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute') then
      raise exception 'application roles must not execute rls_auto_enable';
    end if;
  end if;
end;
$$;
