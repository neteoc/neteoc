# NetEOC

NetEOC is a Network Enhanced Operations Center for sharing geographic
information before, during, and after disasters. Teams will create maps, reuse
internal and external GIS layers, and share selected information with members,
the public, and GIS clients.

This repository contains the project foundation, MVP plan, and the first local
Astro/Cloudflare runtime slice. It is not ready for operational use. Start with
the [documentation index](docs/README.md), then read the
[project context](docs/project-context.md), [PRD](docs/prd.md), and
[development plan](docs/development-plan.md). Development uses Bun; the intended
application stack is Astro on Cloudflare Workers with Static Assets and Supabase
with PostGIS.

To validate the current code, install Bun 1.4.3 and run:

```sh
bun install --frozen-lockfile
bun run check
```

Run `bun run dev` for local Astro development or `bun run build` followed by
`bun run preview` to exercise the Worker runtime. Copy `.dev.vars.example` to
`.dev.vars` and provide a local Supabase URL and publishable key when testing
authentication. Configure the sign-in email template as described in the
[authentication setup](docs/auth-setup.md). The application intentionally has no
service-role key binding.

See the [development guide](docs/development.md) for security tool setup, commit
rules, and future implementation conventions.
