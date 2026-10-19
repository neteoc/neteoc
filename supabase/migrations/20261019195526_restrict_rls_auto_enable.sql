-- Supabase's project bootstrap left this event-trigger helper executable by
-- PUBLIC, anon, and authenticated. Application requests do not need it.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- Negative authorization checks for the application-facing database roles.
do $$
begin
  if has_function_privilege('anon', 'public.rls_auto_enable()', 'execute')
    or has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute') then
    raise exception 'application roles must not execute rls_auto_enable';
  end if;
end;
$$;
