# Authentication setup for the runtime slice

The current shell signs in existing Supabase Auth users only. Organization
invitations and membership checks are a later MVP slice. Do not enable public
self-signup for a connected project.

## Worker bindings

`wrangler.jsonc` declares `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` as
required secrets. Set them for each environment before deploying. The
publishable key is not privileged, but declaring it as a secret avoids
environment-specific placeholder values in committed configuration. Never bind a
service-role or secret API key to this Worker.

For local development, copy `.dev.vars.example` to ignored `.dev.vars` and
replace both values. `bun run types:worker` regenerates the binding types when
`wrangler.jsonc` changes. No live deployment is part of this setup.

The development/preview project is
[`NetEOC Dev`](https://supabase.com/dashboard/project/mssluxsybusndqxdgica)
(`mssluxsybusndqxdgica`). Its API URL is
`https://mssluxsybusndqxdgica.supabase.co`. Use an active `sb_publishable_` key
from Project Settings → API Keys; never commit the key or substitute a
service-role key. The local `.dev.vars` file is ignored by Git.

## Sign-in email template

Configure the Supabase **Magic Link** email template for each connected project.
Use the one-time code variable instead of Supabase's default verification link:

```html
<p>Your NetEOC sign-in code is <strong>{{ .Token }}</strong>.</p>
<p>Enter it at <a href="{{ .RedirectTo }}">NetEOC sign in</a>.</p>
```

The local stack sends this same body from `supabase/templates/magic_link.html`,
which `supabase/config.toml` names under `[auth.email.template.magic_link]`.
`tests/auth-config.test.ts` fails if the tracked file and this block drift
apart. The CLI default is a "Your sign-in link" message with a token-bearing
link and no code, so it must not be used.

Allow the exact `/auth/confirm` URL in the project's Auth redirect allow list.
The sign-in route sets `emailRedirectTo` to that URL. The email link carries no
credential; the user enters the code and email address on the confirmation page.
`verifyOtp` runs in a same-origin POST. This works across browsers and devices,
and email link scanners cannot consume the code through a GET. Keep codes out of
request logs and do not add third-party assets or analytics to the confirmation
page.

The development project's Site URL is `http://localhost:8787`, and its redirect
allow list includes exactly `http://localhost:8787/auth/confirm`. Configure a
hosted preview URL separately when one exists. Its Magic Link or OTP template
uses the code-only body above with subject `Your NetEOC sign-in code`. Custom
SMTP is enabled through the dedicated `NetEOC Dev` Postmark server (ID
`21138589`, transactional stream `outbound`) at `smtp.postmarkapp.com:587`. The
temporary verified sender is `kerry@kerryhatcher.com`; replace it with a
verified NetEOC sender before a pilot. The server token is stored in Supabase
SMTP settings and must not be committed or copied into Worker bindings. On
October 19, 2026, a local sign-in request for an existing Auth user produced a
Postmark `Delivered` event. Code confirmation, session refresh, and sign-out
still need end-to-end testing.

Set **Authentication → Sign In / Providers → Email → Email OTP expiration** to
`600` seconds (10 minutes) for every connected project. The development project
uses this value, reduced from its initial 3,600-second setting on October
19, 2026. Keep the email OTP length at eight digits.

The app sets `HttpOnly`, `Secure`, `SameSite=Lax`, and a seven-day maximum age
on Supabase session cookies. Secure cookies require HTTPS outside browser
localhost exceptions. Authentication responses are private and no-store.
Sign-out is local to the current browser, with local cookie removal if Supabase
sign-out fails. It does not revoke the refresh token on the server, so a copy of
the cookies stays usable until the session timebox ends. Server-side global
sign-out would end sessions on every device and is a product decision.

`[auth.sessions] timebox` is set to `168h`, a Go duration (seven days; Go has no
day unit). GoTrue refuses a refresh once a session's `not_after` has passed. On
the local stack, the timebox reaches the GoTrue process, but new sessions are
created with `not_after` NULL, so the timebox is not applied yet. Until that is
resolved, the seven-day session bound is not enforced locally, and the hosted
dashboard setting must be verified separately rather than assumed.

The end-to-end suite asserts the `Set-Cookie` attributes on real responses. It
does not depend on browser storage behavior. Current Chrome and Firefox accept
`Secure` cookies over `http://localhost`; a manual walkthrough in the browser
under test should confirm that the session persists there.

## API access

Every `/api` path requires a verified session unless it is listed in
`src/lib/public-api.ts`. The list is empty. A route that forgets its own check
still returns no data, because the middleware refuses first with the same
`not_authenticated` JSON shape. A public read is added to that list
deliberately, with tests for each visibility state; nothing is public by
default.

## Sign-in response timing

The sign-in request answers with the same redirect whether or not the address
has an account and whether or not the provider accepted the send. The provider
call runs after the response (`waitUntil`), so a slow provider cannot make a
known address answer more slowly than an unknown one. The rate limits still run
before the response, because they depend only on the caller and the address.

The cost is that a failed send is invisible to the user. The sign-in page says
"check your email" even when no email was sent. Failures are logged as a
category and status (`auth_otp_provider_unavailable`), never as an address, and
an operator watches those logs during a pilot. This is the accepted cost of not
leaking account existence through timing.

## Rate limits and operations

Cloudflare rate-limit bindings bound sign-in requests to 30 per IP, 5 per
normalized email, and 60 globally per minute. IP and email checks run before the
global check so one throttled client cannot exhaust shared capacity. Code
verification has separate limits of 30 per IP and 60 globally per minute; a
sign-in request cannot exhaust the verification buckets. These limits are
location-local and eventually consistent, not exact quota accounting. The
verification path deliberately has no per-email bucket, so guesses against a
single address remain bounded by its ten-minute OTP lifetime and the IP and
shared verification limits. Two clients at the per-IP cap can exhaust the shared
60-per-minute verification bucket in one Cloudflare location and delay
legitimate confirmations there. Monitor throttling during the pilot and revisit
the shared limit or add stronger abuse controls if this occurs. Sign-in's
per-email bucket also permits targeted delays to that address; monitor that
trade-off alongside provider delivery. Tune limits against pilot traffic and the
SMTP provider. The default Supabase SMTP is not sufficient for real invitations
or incident use; use a dedicated NetEOC Postmark server before a pilot. Operator
logs record rate-limit and provider failure categories/status codes without
email addresses or tokens.

Test the full request, email, confirmation, refresh, and sign-out sequence
against a local or preview Supabase project before considering authentication
complete. Include a different-browser confirmation and a scanner-like GET that
does not consume the code.

## Hosted settings checklist

Merging a change to `supabase/config.toml` or the template does not change
hosted Auth. The hosted project reads its Auth settings from the dashboard
unless remote configuration is enabled, and it is not. Apply these settings to
each connected project, then check them:

1. Authentication → Sign In / Providers → Email: the Email provider is on.
2. Allow new users to sign up: off. This is `[auth] enable_signup = false`. The
   Email provider itself stays on.
3. Email OTP length: `8`.
4. Email OTP expiration: `600` seconds.
5. Authentication → Email Templates → Magic Link: subject
   `Your NetEOC sign-in code`, body equal to the code-only block above.
6. Authentication → Sessions: timebox `168` hours. Leave the inactivity timeout
   unset.
7. URL configuration: the Site URL and the redirect allow list contain the exact
   `/auth/confirm` URL for each origin.

The settings endpoint confirms the first two without a session:

```sh
curl -s -H "apikey: $SUPABASE_PUBLISHABLE_KEY" "$SUPABASE_URL/auth/v1/settings"
```

Expect `"disable_signup":true` and `"email":true`. The endpoint does not report
OTP length, expiry, timebox, or the template. Check those in the dashboard, then
send one code to a synthetic address and confirm it arrives with eight digits.

## Local verification

```sh
supabase start
# Put the publishable key from `supabase status` into the ignored .dev.vars.
bun run test:auth-local
```

`bun run test:auth-local` builds the Worker, starts `wrangler dev` on port 8787,
and runs `tests/auth-local.test.ts`. The suite reads codes from Mailpit
(`http://127.0.0.1:54324`). It reads and backdates GoTrue rows through
`docker exec supabase_db_neteoc`, so Docker must be running. It is skipped
unless `NETEOC_AUTH_E2E=1`, and CI does not run it. A run takes several minutes
because GoTrue and the Worker both limit repeated sends to one address.
