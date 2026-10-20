import { defineMiddleware } from 'astro:middleware';
import { createSupabaseClient } from './lib/supabase';

export const onRequest = defineMiddleware(async (context, next) => {
  const path = context.url.pathname;
  const protectedRoute = path === '/app' || path.startsWith('/app/');
  const authRoute =
    protectedRoute ||
    path === '/login' ||
    path === '/login-sent' ||
    path.startsWith('/auth/') ||
    path.startsWith('/api/');

  if (!authRoute) return next();

  const authHeaders = new Headers();
  context.locals.supabase = createSupabaseClient(
    context.request,
    context.cookies,
    authHeaders,
  );

  function finish(response: Response): Response {
    for (const [name, value] of authHeaders) response.headers.set(name, value);
    response.headers.set('Cache-Control', 'private, no-store');
    response.headers.set('Expires', '0');
    response.headers.set('Pragma', 'no-cache');
    response.headers.set('X-Robots-Tag', 'noindex');
    response.headers.set('Referrer-Policy', 'no-referrer');
    return response;
  }

  if (protectedRoute) {
    const supabase = context.locals.supabase;
    if (!supabase) return finish(context.redirect('/login'));
    const { data, error } = await supabase.auth.getClaims();
    if (error || !data?.claims) return finish(context.redirect('/login'));
  }

  return finish(await next());
});
