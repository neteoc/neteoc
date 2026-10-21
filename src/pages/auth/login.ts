import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { allowLogin, readPasswordLogin } from '../../lib/login';

export const POST: APIRoute = async ({ request, locals, redirect }) => {
  const supabase = locals.supabase;
  if (!supabase)
    return new Response('Sign in is not configured', { status: 503 });

  const credentials = await readPasswordLogin(request);
  if (!credentials) return redirect('/login?error=invalid', 303);

  try {
    if (!(await allowLogin(request, credentials.email, env)))
      return redirect('/login?error=rate', 303);
  } catch {
    console.error('auth_login_limiter_unavailable');
    return redirect('/login?error=unavailable', 303);
  }

  try {
    const { error } = await supabase.auth.signInWithPassword(credentials);
    if (!error) return redirect('/app', 303);
    if (
      error.status === 0 ||
      error.status === 429 ||
      (error.status ?? 0) >= 500
    ) {
      console.error('auth_password_provider_unavailable', {
        status: error.status,
        code: error.code,
      });
      return redirect('/login?error=unavailable', 303);
    }
  } catch {
    console.error('auth_password_provider_unreachable');
    return redirect('/login?error=unavailable', 303);
  }

  // One response for an unknown account and an incorrect password.
  return redirect('/login?error=credentials', 303);
};
