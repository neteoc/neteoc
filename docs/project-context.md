# Project context and decisions

Recorded 2026-10-19. This document preserves the user's intent across
contributors and agent sessions. Do not re-ask settled questions unless new
evidence changes a material assumption. Ask unresolved questions one at a time,
with a recommendation.

## Purpose

NetEOC supports teams and organizations before, during, and after disasters.
Incident commanders and their staff are central users during incidents;
emergency managers and volunteer organizations also use it between incidents.
Keep the product generic: a shared geographic information system, not a
specialized emergency dispatch, medical, or fleet-management product.

## User requirements

- Astro frontend on Cloudflare; Supabase with PostGIS for the backend, Auth, and
  other services it provides. Prefer Cloudflare for remaining infrastructure
  needs.
- A Postmark account is available if email is needed. Use GitHub Actions for
  CI/CD.
- Bun is the package manager, development runtime, and test runner (the user
  explicitly replaced the initial Node/npm setup). Production follows the
  hosting runtime: Cloudflare Workers and, if needed, Supabase Edge Functions.
- Maps contain multiple reusable layers. Layers contain editable internal GIS
  features or reference external KML, GeoJSON, ArcGIS, and similar sources.
- Maps and layers independently support public, internal, and unlisted
  visibility. Public resources appear in discovery indexes and sitemaps;
  unlisted resources have UUID links. Authenticated internal access is
  organization-scoped.
- Offer web maps and lists plus GIS-consumable links, including GeoJSON and
  network-linked KML. Include configurable third-party basemaps such as OSM.
- Store documentation in `docs/` as Markdown, with optional linked source PDFs
  in `docs/pdfs/`. Follow Conventional Commits 1.0.0 and enforce it
  automatically.
- Pin GitHub Actions to full commit SHAs; look up the latest stable release
  before selecting a pin. Add prudent testing, hooks, linting, analysis, and
  security and secret scanning.
- Current assignment: establish the repository, research, guardrails, high-level
  PRD, and development plan, then **wait for the next instruction**. Do not
  begin building the MVP as part of this assignment.

## Accepted clarification decisions

| Topic                 | User-approved decision                                                                                                                                              |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tenancy               | Multiple organizations; users can belong to several; maps and layers have one owner organization.                                                                   |
| Roles                 | Admin manages members and all content; editor creates/edits content; viewer reads internal content. Anonymous access is read-only.                                  |
| Membership            | Invitation only. Platform administrators create organizations and appoint initial admins; organization admins invite users and assign roles.                        |
| Visibility            | Layer access is independent. An unlisted map link can expose public and unlisted layers, never internal layers without membership or authorized scoped credentials. |
| Offline               | Internet required for MVP; show connection and save status. Offline editing/synchronization is deferred.                                                            |
| Geometry              | Points, lines, and polygons; title, description, optional status, notes, and photos.                                                                                |
| External sources      | Read-only feeds; one-time KML/GeoJSON import makes an editable internal copy. No upstream write-back.                                                               |
| GIS authentication    | Revocable read-only tokens scoped to selected maps/layers for clients such as QGIS. Public and unlisted feeds use URLs.                                             |
| Hosting clarification | Workers with Static Assets, as recommended by current Astro/Cloudflare docs, satisfies the original “Cloudflare Sites” wording.                                     |

## Reference scenarios

1. A call taker marks approximate tree damage at roads or buildings using an
   address or a map click. A commander watches the map/list on a projector.
   Field staff refine locations, attach photos, add notes, and close features
   after clearance. Injury and 911 handling are outside scope.
2. After a winter storm, teams share fuel points, impassable roads, armories,
   and pickup locations for essential workers. Attributes can describe diesel,
   power, opening status, and payment acceptance. The example includes transport
   to dialysis; the MVP does not collect clinical information, model patients,
   or implement medical scheduling or dispatch optimization.

## Proposed implementation defaults

These are engineering recommendations, not additional answers from the user:
internal visibility by default; same-organization map/layer associations; no
cross-organization editing; plain-text notes; `open`, `in_progress`, and
`closed` optional statuses; optimistic concurrency; Supabase private storage;
MapLibre with a drawing-library compatibility spike. See the PRD and
architecture for bounds. Provider contracts, domain, region, budget, and
operational service targets remain deployment decisions, not blockers for this
foundation.
