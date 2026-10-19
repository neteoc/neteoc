import type { APIRoute } from 'astro';
import { clearSupabaseCookies } from '../../lib/supabase';

export const POST: APIRoute = async ({
  request,
  cookies,
  locals,
  redirect,
}) => {
  const supabase = locals.supabase;
  if (supabase) {
    try {
      const { error } = await supabase.auth.signOut({ scope: 'local' });
      if (error) {
        console.error('auth_signout_failed', {
          status: error.status,
          code: error.code,
        });
      }
    } catch {
      console.error('auth_signout_unreachable');
    }
  }
  clearSupabaseCookies(request, cookies);
  return redirect('/login', 303);
};
