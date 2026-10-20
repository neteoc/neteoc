import { defineMiddleware } from 'astro:middleware';
import { isPublicApiPath } from './lib/public-api';
import { createSupabaseClient } from './lib/supabase';

// Verified claims, not a cookie's presence, decide identity. Any failure,
// including a missing Supabase configuration, fails closed.
async function hasVerifiedClaims(
  supabase: App.Locals['supabase'],
): Promise<boolean> {
  if (!supabase) return false;
  try {
    const { data, error } = await supabase.auth.getClaims();
    return !error && Boolean(data?.claims);
  } catch {
    return false;
  }
}

// Same shape as the features route's own 401, so a client sees one contract
// whether the middleware or the route refuses the request.
function unauthorizedApi(): Response {
  return new Response(
    JSON.stringify({
      error: { code: 'not_authenticated', message: 'Sign in to continue.' },
    }),
    {
      status: 401,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    },
  );
}

export const onRequest = defineMiddleware(async (context, next) => {
  const path = context.url.pathname;
  const protectedRoute = path === '/app' || path.startsWith('/app/');
  const apiRoute = path.startsWith('/api/');
  const authRoute =
    protectedRoute ||
    path === '/login' ||
    path === '/login-sent' ||
    path.startsWith('/auth/') ||
    apiRoute;

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

  // Every /api route requires a verified session unless it is on the explicit
  // public allowlist, so a route that forgets its own check still returns no data.
  if (apiRoute && !isPublicApiPath(path)) {
    if (!(await hasVerifiedClaims(context.locals.supabase)))
      return finish(unauthorizedApi());
  }

  if (protectedRoute) {
    if (!(await hasVerifiedClaims(context.locals.supabase)))
      return finish(context.redirect('/login'));
  }

  return finish(await next());
});
