import type { APIRoute } from 'astro';
import { createSupabaseClient } from '../../lib/supabase';

export const POST: APIRoute = async ({ request, cookies, redirect, url }) => {
  if (request.headers.get('Origin') !== url.origin)
    return new Response(null, { status: 403 });
  const supabase = createSupabaseClient(request, cookies);
  if (!supabase)
    return new Response('Sign in is not configured', { status: 503 });

  const form = await request.formData();
  const email = form.get('email');
  if (
    typeof email !== 'string' ||
    email.length > 320 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
  ) {
    return redirect('/login?error=invalid', 303);
  }

  await supabase.auth.signInWithOtp({
    email,
    options: {
      shouldCreateUser: false,
      emailRedirectTo: `${url.origin}/auth/callback`,
    },
  });
  return redirect('/login-sent', 303);
};
