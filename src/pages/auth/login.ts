import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { allowLogin, readLoginEmail } from '../../lib/login';

export const POST: APIRoute = async ({ request, locals, redirect, url }) => {
  const supabase = locals.supabase;
  if (!supabase)
    return new Response('Sign in is not configured', { status: 503 });

  const email = await readLoginEmail(request);
  if (!email) return redirect('/login?error=invalid', 303);

  try {
    if (!(await allowLogin(request, email, env))) {
      console.warn('auth_login_rate_limited');
      return redirect('/login?error=rate', 303);
    }
  } catch {
    console.error('auth_login_limiter_unavailable');
    return redirect('/login?error=unavailable', 303);
  }

  try {
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        shouldCreateUser: false,
        emailRedirectTo: `${url.origin}/auth/confirm`,
      },
    });
    if (
      error &&
      (error.status === 0 || error.status === 429 || (error.status ?? 0) >= 500)
    ) {
      console.error('auth_otp_provider_unavailable', {
        status: error.status,
        code: error.code,
      });
      if (error.status !== 429)
        return redirect('/login?error=unavailable', 303);
    }
  } catch {
    console.error('auth_otp_provider_unreachable');
    return redirect('/login?error=unavailable', 303);
  }
  return redirect('/login-sent', 303);
};
