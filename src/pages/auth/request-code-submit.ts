import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { allowLogin, readLoginEmail } from '../../lib/login';

type Supabase = NonNullable<App.Locals['supabase']>;

// The provider call runs after the response. A known and an unknown address then
// take the same time to answer, which closes the timing channel that a slow
// provider send would open. The cost is that a failed send is not shown to the
// user; it is logged here as a category and status only, never the address.
async function sendSignInCode(
  supabase: Supabase,
  email: string,
  origin: string,
) {
  try {
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        shouldCreateUser: false,
        emailRedirectTo: `${origin}/auth/confirm`,
      },
    });
    // An unknown address is an expected 422 and is not logged as a failure.
    if (
      error &&
      (error.status === 0 || error.status === 429 || (error.status ?? 0) >= 500)
    ) {
      console.error('auth_otp_provider_unavailable', {
        status: error.status,
        code: error.code,
      });
    }
  } catch {
    console.error('auth_otp_provider_unreachable');
  }
}

export const POST: APIRoute = async ({ request, locals, redirect, url }) => {
  const supabase = locals.supabase;
  const cfContext = locals.cfContext;
  if (!supabase || !cfContext)
    return new Response('Sign in is not configured', { status: 503 });

  const email = await readLoginEmail(request);
  if (!email) return redirect('/auth/request-code?error=invalid', 303);

  // Rate limits stay synchronous: they depend on the address and the caller,
  // never on whether an account exists, so they cannot leak membership.
  try {
    if (!(await allowLogin(request, email, env))) {
      console.warn('auth_login_rate_limited');
      return redirect('/auth/request-code?error=rate', 303);
    }
  } catch {
    console.error('auth_login_limiter_unavailable');
    return redirect('/auth/request-code?error=unavailable', 303);
  }

  cfContext.waitUntil(sendSignInCode(supabase, email, url.origin));
  return redirect('/login-sent', 303);
};
