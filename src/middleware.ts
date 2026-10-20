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

function applyPrivateHeaders(response: Response): Response {
  response.headers.set('Cache-Control', 'private, no-store');
  response.headers.set('Expires', '0');
  response.headers.set('Pragma', 'no-cache');
  response.headers.set('X-Robots-Tag', 'noindex');
  response.headers.set('Referrer-Policy', 'no-referrer');
  return response;
}

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

// Origin must equal this origin exactly, whatever the Content-Type. Astro's own
// check covers form types only, so a JSON or text/plain POST would otherwise
// reach the route. A missing Origin is refused: current browsers send Origin on
// same-origin POSTs, so only a non-browser client omits it. A cross-site
// Sec-Fetch-Site is refused even when Origin matches.
function sameOriginWrite(request: Request, origin: string): boolean {
  const fetchSite = request.headers.get('Sec-Fetch-Site');
  if (fetchSite !== null && fetchSite !== 'same-origin') return false;
  return request.headers.get('Origin') === origin;
}

export const onRequest = defineMiddleware(async (context, next) => {
  if (
    !SAFE_METHODS.has(context.request.method) &&
    !sameOriginWrite(context.request, context.url.origin)
  ) {
    return applyPrivateHeaders(
      new Response('Forbidden', {
        status: 403,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      }),
    );
  }

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
    return applyPrivateHeaders(response);
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

  let response: Response;
  try {
    response = await next();
  } catch {
    // The error may carry request or session detail, so only the category is logged
    // and the body stays generic.
    console.error('route_failed');
    response = new Response('Something went wrong.', {
      status: 500,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
    // The cookies the middleware set before the route failed, such as a rotated
    // session, are not copied here. Astro attaches its cookie jar to the response
    // this function returns, and the adapter writes them. Copying them as well
    // sends each Set-Cookie twice.
  }
  return finish(response);
});
