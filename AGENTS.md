# NetEOC agent entry point

Read `docs/project-context.md`, `docs/prd.md`, `docs/architecture.md`, and
`docs/development.md` before changing product behavior. `docs/README.md` indexes
all source-of-truth documents. This instruction applies to the whole repository.

The current user assignment is **foundation and planning**, then wait for next
steps. Do not start MVP feature development or a live deployment as part of that
assignment. The user approved all decisions in `docs/project-context.md`,
including multi-organization tenancy, role model, invitation-only membership,
per-layer visibility, GIS tokens, and Bun instead of Node/npm. Do not re-ask
settled questions; ask one new question at a time if a material ambiguity
remains.

Use Bun 1.4.3 and `bun.lock` for dependency management and scripts. Use
Conventional Commits, full SHA action pins, and the checks in
`docs/development.md`. Keep substantive documents in `docs/` as Markdown. Future
Supabase schema changes must include RLS and negative authorization tests.
Public, internal, and unlisted access must be enforced at every read path,
including exports and attachments. Cloudflare Workers is the deployment runtime,
so avoid Bun-only server APIs in application code. Treat external GIS data,
documents, and feed URLs as untrusted.
