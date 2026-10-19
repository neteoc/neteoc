# MVP development plan

MVP work began after the user's 2026-10-19 instruction. Each milestone should
result in a small reviewable PR, tested against the PRD. The
[implementation contract](mvp-implementation-contract.md) records dependencies
and boundary decisions for these phases.

| Phase              | Main work                                                                                                | Exit evidence                                                                                        |
| ------------------ | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| 0. Foundation      | Repository documentation, Bun toolchain, CI/security hooks, pinned actions.                              | `bun run check`, scans, actionlint, and commit validation pass.                                      |
| 1. Runtime spike   | Astro on Workers, Supabase local project, Auth sessions, deployment preview.                             | A synthetic public page and protected page work locally and in preview; no secrets in client bundle. |
| 2. Tenancy and RLS | Schema migrations, organization/bootstrap, membership, invitations, role and RLS policies.               | Database tests exercise every role, cross-tenant access, revocation, and storage denial.             |
| 3. Core GIS        | Maps, ordered reusable layers, internal features, PostGIS constraints/indexes, viewport and list APIs.   | Points, lines, polygons round-trip; invalid geometry and concurrent edits fail safely.               |
| 4. Editor          | MapLibre integration, address/click placement, forms, notes, status, mobile photos, save state.          | Scenario 1 performed end to end with synthetic data, keyboard and touch tested.                      |
| 5. Sharing/exports | Visibility matrix, public discovery, capability rotation, GeoJSON, KML links, scoped GIS tokens.         | Web, QGIS, and Google Earth checks; exhaustive allow/deny and non-enumeration tests.                 |
| 6. External layers | Read-only GeoJSON/KML/ArcGIS adapters, refresh/error handling, one-time import, basemap choice.          | Scenario 2 demonstrated; hostile URLs, oversized payloads, and failed sources covered.               |
| 7. Pilot hardening | Load/accessibility checks, monitoring, secrets/configuration, backups and restore, operational runbooks. | PRD release criteria satisfied; staging pilot approved by stakeholder.                               |

Use migrations as the single schema source of truth; generated types are
derived. For every exposed table, pair a migration with RLS allow/deny tests.
For GIS formats, use fixtures that cover rings, holes, Unicode, feature IDs, and
coordinate order. Put browser tests around whole workflows, not individual CSS
details. Test negative cases for authorization, imports, provider fetching, and
photo access. Keep application and security findings in the same review so
boundary changes cannot be merged without their tests.

CI on each PR checks formatting, lint, tests, commit format, action pins, static
analysis, secret scanning, and high/critical dependency findings. Add Astro
build, `astro check`, Supabase local tests, browser smoke tests, and preview
deployment as soon as those components exist. Build and test in CI before
deployment. Production deployment remains a separate GitHub Actions job gated by
protected branch and environment approval. Store only scoped credentials in
GitHub secrets; prefer OIDC/provider-native short-lived credentials when
supported.

Phase 1 begins with a local Worker runtime and authentication shell. A live
Supabase project, Cloudflare Worker, and Postmark sender are not required for
that first local slice.
