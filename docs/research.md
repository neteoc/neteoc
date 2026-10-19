# Technology research

Checked 2026-10-19 against primary project documentation and current package
registries. Recheck versions, service limits, and provider terms when each
feature is implemented. The Supabase changelog included an October 2026
deprecation of `@supabase/server` framework adapters; avoid building on those
adapters. It also announced TLS cipher changes and PostgreSQL extension changes,
neither of which alters this foundation. See the
[changelog](https://supabase.com/changelog.md).

| Area              | Decision and evidence                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Developer runtime | [Bun](https://bun.sh/docs/runtime) for installs, scripts, and tests; lock `bun.lock` and version `1.4.3`. Production runs on Cloudflare Workers, not the Bun server runtime.                                                                                                                                                                                                                                    |
| Frontend/hosting  | [Astro Cloudflare deployment guide](https://docs.astro.build/en/guides/deploy/cloudflare/) now directs new projects to Workers with Static Assets for on-demand routes. The user approved this target. Use the Cloudflare adapter when the app is scaffolded.                                                                                                                                                   |
| Backend           | [Supabase PostGIS](https://supabase.com/docs/guides/database/extensions/postgis) supports Point, LineString, Polygon, and GiST indexes. Install in `extensions`, not `public`; use EPSG:4326.                                                                                                                                                                                                                   |
| Auth/data access  | [Supabase RLS guide](https://supabase.com/docs/guides/database/postgres/row-level-security) requires both grants and policies on exposed tables. Test allow and deny cases. Keep organization membership in database rows.                                                                                                                                                                                      |
| Photos            | [Supabase Storage access control](https://supabase.com/docs/guides/storage/security/access-control) covers private object permissions. Start there; R2 offers no identified MVP gap.                                                                                                                                                                                                                            |
| Auth email        | [Custom SMTP guidance](https://supabase.com/docs/guides/auth/auth-smtp) says default SMTP is for exploration. Configure the user's Postmark account through Supabase Auth SMTP before real invitations.                                                                                                                                                                                                         |
| Maps              | [MapLibre GL JS](https://maplibre.org/maplibre-gl-js/docs/) is a WebGL map renderer. Investigate editing-library compatibility and keyboard accessibility in a spike. Avoid loading browser-only map code during Astro SSR.                                                                                                                                                                                     |
| GeoJSON           | Follow [RFC 7946](https://datatracker.ietf.org/doc/html/rfc7946): WGS84 lon/lat order, valid geometry, and standards-based FeatureCollections.                                                                                                                                                                                                                                                                  |
| KML               | [KML NetworkLink](https://developers.google.com/kml/documentation/kmlreference#networklink) enables refreshable Google Earth consumption. Implement link and content endpoints with repeat authorization.                                                                                                                                                                                                       |
| ArcGIS            | [Feature Service Query API](https://developers.arcgis.com/rest/services-reference/enterprise/query-feature-service-layer/) offers JSON/GeoJSON query patterns and pagination. Probe each service's advertised capabilities.                                                                                                                                                                                     |
| Basemaps          | [OSMF tile policy](https://operations.osmfoundation.org/policies/tiles/) requires attribution, caching, no bulk prefetch, and permits blocking best-effort service. Configure a production-grade provider if usage or availability warrants it.                                                                                                                                                                 |
| Address search    | [Public Nominatim policy](https://operations.osmfoundation.org/policies/nominatim/) limits aggregate use to 1 request/second and requires identification/caching. Do not assume it is a scalable production geocoder. Select a contract-backed geocoder before launch.                                                                                                                                          |
| Action safety     | [GitHub secure use guidance](https://docs.github.com/en/actions/reference/security/secure-use) supports least-privilege permissions and immutable SHA pins. GitHub Actions is the CI/CD runner.                                                                                                                                                                                                                 |
| Static analysis   | [Semgrep](https://semgrep.dev/docs/semgrep-ci/sample-ci-configs) local custom rules first; [Trivy filesystem scanner](https://trivy.dev/docs/latest/references/configuration/cli/trivy_filesystem/) for supported dependencies, configuration, and secrets; Bun audit for current package dependencies; [TruffleHog](https://github.com/trufflesecurity/trufflehog) for staged and historical secret detection. |

Current registry versions observed: Astro `7.4.1`, Cloudflare adapter `14.4.1`,
Wrangler `4.151.2`, Supabase JS `2.118.0`, Supabase SSR `0.12.7`, MapLibre
`6.15.0`, and Bun `1.4.3`. These are **research values**, not dependencies yet;
install compatibility-checked exact versions when implementing the app. Current
selected tool versions and archive hashes are in `scripts/tool-versions.json`.
All GitHub Actions are SHA-pinned; version comments and release links are in the
workflow. See
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) for
commit format.

## Issues to resolve during implementation

- Confirm Astro/Cloudflare adapter and Supabase cookie/session integration on
  Workers, including refresh and secure server rendering, in a small spike.
- Benchmark a map editing package with MapLibre, touch input, and accessible
  list alternatives. Choose it after testing; MapLibre alone is only a renderer.
- Confirm KML and GeoJSON behavior in QGIS and Google Earth, especially the
  authentication scheme for internal feeds. Never put internal tokens in URLs.
- Confirm external data licenses and whether re-export is permitted per
  provider.
- Decide domains, hosting region, vendor accounts/quotas, basemap/geocoder
  contracts, email domain, and recovery targets before a production pilot.
