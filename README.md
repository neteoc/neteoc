# NetEOC

NetEOC is a planned Network Enhanced Operations Center for sharing geographic
information before, during, and after disasters. Teams will create maps, reuse
internal and external GIS layers, and share selected information with members,
the public, and GIS clients.

This repository currently contains the **project foundation and MVP plan**.
Start with the [documentation index](docs/README.md), then read the
[project context](docs/project-context.md), [PRD](docs/prd.md), and
[development plan](docs/development-plan.md). Development uses Bun; the intended
application stack is Astro on Cloudflare Workers with Static Assets and Supabase
with PostGIS.

To validate the foundation, install Bun 1.4.3 and run:

```sh
bun install --frozen-lockfile
bun run check
```

See the [development guide](docs/development.md) for security tool setup, commit
rules, and future implementation conventions.
