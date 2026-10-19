import type { APIRoute } from 'astro';
import { createSupabaseClient } from '../../lib/supabase';

export const GET: APIRoute = async ({ request, cookies, redirect, url }) => {
  const code = url.searchParams.get('code');
  if (!code) return redirect('/login?error=invalid', 303);
  const supabase = createSupabaseClient(request, cookies);
  if (!supabase)
    return new Response('Sign in is not configured', { status: 503 });

  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) return redirect('/login?error=invalid', 303);
  return redirect('/app', 303);
};
