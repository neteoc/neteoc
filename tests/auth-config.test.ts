import { describe, expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

// Checks the tracked local Auth configuration against the access model in
// docs/auth-setup.md. The live GoTrue settings are checked by the end-to-end
// suite; this runs in the default gate, so a regression fails before deploy.

const root = path.resolve(import.meta.dir, '..');

interface AuthConfig {
  auth: {
    enable_signup: boolean;
    email: {
      enable_signup: boolean;
      otp_length: number;
      otp_expiry: number;
      template: { magic_link: { subject: string; content_path: string } };
    };
    sessions: { timebox: string };
  };
}

const config = Bun.TOML.parse(
  await readFile(path.join(root, 'supabase/config.toml'), 'utf8'),
) as unknown as AuthConfig;

// Go duration strings: "168h" is accepted, and "7d" is not.
function goDurationSeconds(value: string): number | null {
  const unit: Record<string, number> = { h: 3600, m: 60, s: 1 };
  const match = value.match(/^(\d+)([hms])$/);
  return match ? Number(match[1]) * unit[match[2]] : null;
}

describe('local Auth configuration', () => {
  test('signup is closed under [auth] while the email provider stays enabled', () => {
    // [auth] enable_signup = false rejects unknown addresses. Setting
    // [auth.email] enable_signup = false disables the provider for everyone.
    expect(config.auth.enable_signup).toBe(false);
    expect(config.auth.email.enable_signup).toBe(true);
  });

  test('email codes are eight digits and expire after 600 seconds', () => {
    expect(config.auth.email.otp_length).toBe(8);
    expect(config.auth.email.otp_expiry).toBe(600);
  });

  test('sessions end seven days after sign-in and the value parses as a Go duration', () => {
    expect(goDurationSeconds(config.auth.sessions.timebox)).toBe(604800);
  });

  test('the sign-in email is the tracked code-only template', () => {
    const magic = config.auth.email.template.magic_link;
    expect(magic.subject).toBe('Your NetEOC sign-in code');
    expect(magic.content_path).toBe('./supabase/templates/magic_link.html');
  });
});

describe('sign-in email template', () => {
  test('matches the body documented in docs/auth-setup.md', async () => {
    const docs = await readFile(path.join(root, 'docs/auth-setup.md'), 'utf8');
    const block = docs.match(/```html\n([\s\S]*?)```/);
    expect(block).not.toBeNull();
    const template = await readFile(
      path.join(root, 'supabase/templates/magic_link.html'),
      'utf8',
    );
    expect(template.trim()).toBe(block?.[1].trim());
  });

  test('carries the one-time code and no token-bearing link', async () => {
    const template = await readFile(
      path.join(root, 'supabase/templates/magic_link.html'),
      'utf8',
    );
    expect(template).toContain('{{ .Token }}');
    expect(template).not.toContain('{{ .ConfirmationURL }}');
    expect(template).not.toContain('/auth/v1/verify');
  });
});
