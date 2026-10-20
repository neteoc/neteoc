// Public /api routes, listed explicitly. The middleware refuses every /api path
// that is not listed here unless the request carries a verified session. A public
// read is added here deliberately, with its own tests for every visibility
// state. Nothing is public by default.
export const PUBLIC_API_PREFIXES: readonly string[] = [];

export function isPublicApiPath(pathname: string): boolean {
  return PUBLIC_API_PREFIXES.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  );
}
