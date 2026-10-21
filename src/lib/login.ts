type Limiter = { limit(input: { key: string }): Promise<{ success: boolean }> };

export interface LoginLimiters {
  LOGIN_GLOBAL_LIMIT: Limiter;
  LOGIN_IP_LIMIT: Limiter;
  LOGIN_EMAIL_LIMIT: Limiter;
}

export interface VerifyLimiters {
  VERIFY_GLOBAL_LIMIT: Limiter;
  VERIFY_IP_LIMIT: Limiter;
}

const MAX_FORM_BYTES = 4096;
export const EMAIL_OTP_LENGTH = 8;
export const EMAIL_OTP_PATTERN = `[0-9]{${EMAIL_OTP_LENGTH}}`;

export function isValidEmailOtp(value: string): boolean {
  return new RegExp(`^${EMAIL_OTP_PATTERN}$`).test(value);
}

export async function readSmallForm(
  request: Request,
): Promise<URLSearchParams | null> {
  const contentType = request.headers.get('content-type')?.split(';', 1)[0];
  if (contentType !== 'application/x-www-form-urlencoded' || !request.body)
    return null;

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_FORM_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new URLSearchParams(new TextDecoder().decode(body));
}

export async function readLoginEmail(request: Request): Promise<string | null> {
  const form = await readSmallForm(request);
  if (!form) return null;
  return normalizeLoginEmail(form);
}

export async function readPasswordLogin(
  request: Request,
): Promise<{ email: string; password: string } | null> {
  const form = await readSmallForm(request);
  if (!form) return null;
  const email = normalizeLoginEmail(form);
  const passwords = form.getAll('password');
  if (!email || passwords.length !== 1) return null;
  const password = passwords[0];
  if (!password || new TextEncoder().encode(password).byteLength > 1024)
    return null;
  return { email, password };
}

export function normalizeLoginEmail(form: URLSearchParams): string | null {
  const values = form.getAll('email');
  if (values.length !== 1) return null;
  const email = values[0].trim().toLowerCase();
  if (email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
    return null;
  return email;
}

export async function allowLogin(
  request: Request,
  email: string,
  limiters: LoginLimiters,
): Promise<boolean> {
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const perIp = await limiters.LOGIN_IP_LIMIT.limit({ key: ip });
  if (!perIp.success) return false;

  const emailBytes = new TextEncoder().encode(email);
  const digest = await crypto.subtle.digest('SHA-256', emailBytes);
  const emailHash = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');

  const perEmail = await limiters.LOGIN_EMAIL_LIMIT.limit({ key: emailHash });
  if (!perEmail.success) return false;
  const global = await limiters.LOGIN_GLOBAL_LIMIT.limit({ key: 'login' });
  return global.success;
}

export async function allowVerify(
  request: Request,
  limiters: VerifyLimiters,
): Promise<boolean> {
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const perIp = await limiters.VERIFY_IP_LIMIT.limit({ key: ip });
  if (!perIp.success) return false;
  const global = await limiters.VERIFY_GLOBAL_LIMIT.limit({ key: 'verify' });
  return global.success;
}
