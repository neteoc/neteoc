import { env } from 'cloudflare:workers';
import { createServerClient, parseCookieHeader } from '@supabase/ssr';
import type { AstroCookies } from 'astro';

export function getSupabaseConfig() {
  const url = env.SUPABASE_URL;
  const key = env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) return null;
  return { url, key };
}

export function createSupabaseClient(
  request: Request,
  cookies: AstroCookies,
  responseHeaders: Headers,
) {
  const config = getSupabaseConfig();
  if (!config) return null;

  return createServerClient(config.url, config.key, {
    cookieOptions: {
      httpOnly: true,
      secure: true,
      sameSite: 'lax',
      path: '/',
      maxAge: 60 * 60 * 24 * 7,
    },
    cookies: {
      getAll() {
        return parseCookieHeader(request.headers.get('Cookie') ?? '');
      },
      setAll(cookiesToSet, headers) {
        for (const { name, value, options } of cookiesToSet) {
          cookies.set(name, value, {
            ...options,
            httpOnly: true,
            secure: true,
            sameSite: 'lax',
            path: '/',
            maxAge:
              options.maxAge !== undefined && options.maxAge <= 0
                ? options.maxAge
                : 60 * 60 * 24 * 7,
          });
        }
        for (const [name, value] of Object.entries(headers ?? {})) {
          responseHeaders.set(name, value);
        }
      },
    },
  });
}

export function clearSupabaseCookies(request: Request, cookies: AstroCookies) {
  const current = parseCookieHeader(request.headers.get('Cookie') ?? '');
  for (const { name } of current) {
    if (/^sb-[A-Za-z0-9_-]+-(auth-token|code-verifier)(?:\.\d+)?$/.test(name)) {
      cookies.delete(name, { path: '/' });
    }
  }
}
