import type { APIRoute } from 'astro';
import { createSupabaseClient } from '../../lib/supabase';

export const POST: APIRoute = async ({ request, cookies, redirect, url }) => {
  if (request.headers.get('Origin') !== url.origin)
    return new Response(null, { status: 403 });
  const supabase = createSupabaseClient(request, cookies);
  if (supabase) await supabase.auth.signOut();
  return redirect('/login', 303);
};
