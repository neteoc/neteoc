import { parseCookieHeader } from '@supabase/ssr';
import type { AstroCookies } from 'astro';

export function clearSupabaseCookies(request: Request, cookies: AstroCookies) {
  const current = parseCookieHeader(request.headers.get('Cookie') ?? '');
  for (const { name } of current) {
    if (/^sb-[A-Za-z0-9_-]+-(auth-token|code-verifier)(?:\.\d+)?$/.test(name)) {
      cookies.delete(name, {
        httpOnly: true,
        secure: true,
        sameSite: 'lax',
        path: '/',
      });
    }
  }
}
