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

Allow the exact `/auth/confirm` URL in the project's Auth redirect allow list.
The sign-in route sets `emailRedirectTo` to that URL. The email link carries no
credential; the user enters the code and email address on the confirmation page.
`verifyOtp` runs in a same-origin POST. This works across browsers and devices,
and email link scanners cannot consume the code through a GET. Keep codes out of
request logs and do not add third-party assets or analytics to the confirmation
page.

For local verification, add the exact preview origin used by Wrangler, such as
`http://localhost:8787/auth/confirm`, to the development project's redirect
allow list. Configure a hosted preview URL separately when one exists. The
dashboard's Site URL should also point to an intended application origin, rather
than Supabase's default localhost value, before using email invitations.

The app sets `HttpOnly`, `Secure`, `SameSite=Lax`, and a seven-day maximum age
on Supabase session cookies. Secure cookies require HTTPS outside browser
localhost exceptions. Authentication responses are private and no-store.
Sign-out is local to the current browser, with local cookie removal if Supabase
sign-out fails.

## Rate limits and operations

Cloudflare rate-limit bindings bound sign-in requests and code checks together
to 30 per IP, 5 per normalized email, and 60 globally per minute. They reduce
abuse but are location-local and eventually consistent; they are not exact quota
accounting. Tune the limits against pilot traffic and the selected SMTP
provider. The default Supabase SMTP is not sufficient for real invitations or
incident use; configure the approved Postmark SMTP before a pilot. Operator logs
record rate-limit and provider failure categories/status codes without email
addresses or tokens.

Test the full request, email, confirmation, refresh, and sign-out sequence
against a local or preview Supabase project before considering authentication
complete. Include a different-browser confirmation and a scanner-like GET that
does not consume the code.
