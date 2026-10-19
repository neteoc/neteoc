# MVP implementation contract

Status: implementation guide, 2026-10-19. The [PRD](prd.md) defines scope and
the [architecture](architecture.md) defines the access model. This document
turns open design choices into build and review gates. Proposed defaults remain
changeable when a spike produces contrary evidence.

## Delivery sequence and dependencies

1. **Runtime and authentication:** Astro routes build and run under the Worker
   runtime. An existing invited user can sign in, refresh a session, and sign
   out. Protected server routes verify claims and set private no-store headers.
   Browser cookies alone never prove authorization. Preview uses synthetic data
   and separate credentials. No live deployment is part of the runtime spike.
2. **Tenant kernel:** migrations create organizations, memberships, invitations,
   audit events, and a private bootstrap path for the first platform admin.
   Bootstrap credentials stay out of the Worker. Invitations create or link the
   exact normalized email and are single-use, expiring, and revocable. Current
   membership rows, not stale JWT role claims, decide access. Last-admin removal
   is rejected. Tests cover each role, cross-tenant denial, invitation replay,
   revocation, and malformed inputs.
3. **GIS kernel:** same-organization map/layer associations, internal features,
   bounded viewport queries, optimistic revision checks, and transactional
   writes. A map's layer order and default visibility live on the association; a
   layer edit propagates to every map. Database geometry checks and RLS ship in
   the same migration as each table, with negative tests.
4. **Editing and collaboration:** map and list share one selection/filter model;
   editing shows pending, saved, stale, and failed states. Failed saves retain
   the draft. Address results require confirmation. Photos use private Storage
   and checked reads. The list remains usable if the basemap fails.
5. **Sharing and GIS:** implement one authorization service contract used by
   detail pages, lists, attachments, GeoJSON, KML content, and network links.
   Test every visibility/actor combination and visibility transition. Public
   discovery and sitemap queries include only public rows. Unlisted capability
   URLs are rotatable and never placed in logs, analytics, third-party requests,
   or referrers. Token scopes snapshot layer IDs at issuance; each request
   rechecks issuer membership, association, expiry, and revocation.
6. **External data and import:** establish a safe-fetch boundary before any
   remote URL reaches a Worker. Import creates a new internal layer after a
   count/error preview. External layers remain read-only and clearly stale on
   refresh failure. License and re-export permission are recorded per source.
7. **Pilot readiness:** run the two synthetic scenarios, browser accessibility
   tests, GIS-client tests, load measurements, backup and object-restore
   rehearsal, and security review. Provider contracts, quotas, region, domain,
   SMTP, incident contacts, RPO/RTO, and on-call ownership are launch gates.

## Cross-cutting contracts

| Boundary                | Decision to implement and verify                                                                                                                                                                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Worker configuration    | Use runtime bindings for Supabase URL and publishable key. Never bundle a service-role key. Build and preview locally before connecting any real project.                                                                                                     |
| Session handling        | Use cookie-backed `@supabase/ssr` server clients, verified claims for identity, current database membership for authorization, secure cookie handling, origin checks on writes, and no shared caching.                                                        |
| Platform bootstrap      | A one-time, operator-run path with an audit record appoints the initial platform admin; ordinary organization flows cannot self-promote.                                                                                                                      |
| Feature writes          | Validate supported 2D WGS84 geometry, coordinate order, vertex and payload limits, title/description/property bounds, and an expected revision. Return a conflict rather than overwrite.                                                                      |
| List and viewport reads | Define maximum bbox, page size, sort key, and response byte budget. Pagination uses a stable cursor. An over-limit request fails explicitly; hidden-layer IDs, counts, and extent are absent.                                                                 |
| Export reads            | Resolve the audience and eligible layer IDs before serialization. Apply the same filtering to every page, attachment reference, KML link, and conditional request. Use private no-store until public cache invalidation is proven.                            |
| External fetches        | Parse and validate HTTPS URL, DNS answers and every redirect hop; reject private, loopback, link-local, metadata, credentialed, and unsupported-port destinations. Enforce timeout, compressed and decompressed byte, redirect, feature, and geometry limits. |
| Photos                  | Check authorization before download, validate decoded image type and dimensions, strip EXIF, store privately, and test direct bucket access denial.                                                                                                           |
| Audit and operations    | Record actor, organization, resource, action, timestamp, and a bounded summary for membership, sharing, token, and deletion changes. Do not log tokens, capability paths, or feature content.                                                                 |

## Verification matrix

Each implementation PR must name the relevant PRD IDs and show a working allow
case and a denied case at the actual read or write boundary. For sharing, test
anonymous, own-organization viewer/editor/admin, another-organization member,
expired/revoked token, and rotated capability against public, internal, and
unlisted map/layer combinations. Repeat at web detail, list, GeoJSON, KML,
network-link child, attachment, discovery, and direct Storage paths. A test of
only the UI is insufficient.

The first runtime slice is complete when `astro check`, a Worker build, a local
Worker request to `/`, protected-route redirection, and cross-origin POST denial
pass. Session refresh and invite acceptance still require a local Supabase
instance or preview project and belong to the next slice.
