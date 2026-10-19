# Proposed architecture

## Components

Astro with TypeScript serves pages and authenticated server routes on Cloudflare
Workers with Static Assets. A client-only MapLibre island handles the map
editor. Bun installs dependencies, runs developer tooling, builds, and unit
tests; deployed Worker code uses web-standard APIs, not Bun-specific runtime
APIs.

Supabase owns Postgres/PostGIS, Auth, Storage, and optional Realtime. Use its
services before introducing equivalents. Supabase Storage meets the
photo-storage need, so R2 is not needed initially. Postmark custom SMTP supports
Supabase Auth invitations and recovery. No email is sent during repository
setup.

Browser reads/writes use user-scoped clients and database RLS. Astro endpoints
handle capability URLs, GIS tokens, exports, bounded imports, and provider
adapters. Avoid a second backend service unless runtime limits require one; then
prefer Supabase Edge Functions for backend work already close to Supabase. Do
not expose service credentials or assume a privileged client preserves user RLS.

## Conceptual data model

| Entity       | Key information and constraints                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Organization | UUID, name, created/updated timestamps.                                                                                  |
| Membership   | Unique organization/user pair, admin/editor/viewer role; protect the last admin.                                         |
| Invitation   | Organization, normalized email, role, expiry, acceptance/revocation state; single-use and server-managed.                |
| Map          | Organization, title, description, visibility, share UUID, default view, revision.                                        |
| Layer        | Organization, title, visibility, share UUID, kind (internal/external), source configuration, attribution, refresh state. |
| Map layer    | Unique map/layer pair, order, style/visibility defaults; enforce matching organization in database constraints.          |
| Feature      | Layer, geometry, title, description, optional status, bounded JSON properties, revision, actor/timestamps.               |
| Note         | Feature, author, plain text, created timestamp; append-only for normal users.                                            |
| Attachment   | Feature, private storage path, media metadata, author, validation state; access follows the layer.                       |
| GIS token    | Hashed random secret, issuer, organization, explicit read scopes, expiry/revocation; never persist plaintext secret.     |
| Audit event  | Organization, actor, action, resource IDs, timestamp, appropriate change summary; restricted and immutable to editors.   |

Use random UUIDs for resource IDs and separate rotatable UUIDv4 capabilities for
unlisted sharing. Tenant IDs must be constrained across features, attachments,
and associations, not trusted from browser input. Internal geometry is 2D
EPSG:4326 with GiST indexes and database checks for supported type, valid
geometry, finite coordinates, bounds, and payload size. GeoJSON uses longitude
then latitude. Validate on both API and database boundaries. Generated database
types follow committed migrations. No production schema is created by this
foundation.

## Authorization contract

| Audience / request                 | Public                     | Internal                                             | Unlisted                 |
| ---------------------------------- | -------------------------- | ---------------------------------------------------- | ------------------------ |
| Anonymous discovery                | Include                    | Exclude                                              | Exclude                  |
| Anonymous direct resource read     | Allow                      | Deny                                                 | Require valid share UUID |
| Member of owner organization       | Allow                      | Allow                                                | Allow                    |
| Member of another organization     | Same as anonymous          | Deny                                                 | Require valid share UUID |
| Scoped GIS token                   | Read within explicit scope | Read only within scope and current issuer membership | Read within scope        |
| Admin/editor of owner organization | Edit                       | Edit                                                 | Edit                     |
| Viewer or anonymous                | No writes                  | No writes                                            | No writes                |

For map composition, check both the map and each layer. Anonymous public-map
responses include only public layers (proposed conservative default). An
unlisted map capability permits attached public/unlisted layers; this
intentionally shares those layers with holders of the map link. Internal layers
still need membership or a valid GIS token. Member views may include all layers
in their organization. A readable standalone layer does not inherit an enclosing
map's restriction. Never include hidden-layer metadata in responses or export
manifests.

RLS protects every exposed table with explicit grants and per-operation
policies. An anonymous policy such as `visibility != 'internal'` is prohibited:
it would allow enumeration of unlisted rows. Capability reads must use a tightly
scoped endpoint/function that validates the capability and resource relationship
without grants to enumerate unlisted records. Any privileged function must have
a fixed search path, minimal execute grants, explicit checks, and adversarial
tests. Prefer invoker security and private schemas for privileged helpers. Do
not use user-editable Auth metadata for roles; use current membership rows so
removals take effect without waiting for a JWT refresh.

GIS tokens are application credentials, not Supabase platform personal-access
tokens or service-role keys. Proposed defaults: users may create tokens for
their own readable resources; admins can revoke organization tokens; 90-day
maximum expiry; show the secret once. At issuance, map scopes snapshot selected
layer IDs. Every read intersects scope with current membership and map
associations; newly attached layers require an explicit scope update. Removal,
revocation, expiry, or issuer membership removal must deny further reads. Store
a cryptographic digest and use constant-time validation where appropriate.
Prefer Authorization bearer headers; do not put internal credentials in URLs.
QGIS header authentication is a release test. Internal Google Earth network
links are not promised without a separate safe client-authentication design;
public/unlisted links remain supported.

## GIS transport and external sources

Proposed versioned routes:

- `GET /api/v1/layers/{id}/features.geojson`: bounded feature collection.
- `GET /api/v1/maps/{id}/features.geojson`: collection with `layer_id`
  properties.
- `GET /api/v1/layers/{id}/network.kml` and `/maps/{id}/network.kml`:
  network-link documents referencing authorized KML content endpoints.
- Capability equivalents under `/share/{shareUuid}/...`; authorize every linked
  request again. Do not forward a parent capability to unrelated resources.

Provide stable feature IDs, schema version, timestamps, content types, escaped
XML, ETag/conditional requests, bbox filters, bounded pagination where clients
support it, and explicit oversized-export errors. Test export geometry
round-trips, polygon rings/holes, multiline text, Unicode, longitude/latitude,
and deleted features. Network-linked KML represents map layers as named
folders/links. GeoJSON flattens supported features while preserving source-layer
identity. Basemaps are provider references, not vector features; disclose
omissions and do not redistribute tiles. External layers can be re-exported only
when the adapter supports their geometry and provider terms permit it. Return
explicit partial/unavailable-source status; never silently present stale or
truncated data as complete.

For ArcGIS, start with public FeatureServer layer queries: inspect supported
query formats, request WGS84 output, paginate using advertised capabilities, and
respect record limits. KML ingestion supports documented placemark geometries;
remote NetworkLinks, entities, scripts, embedded HTML, and remote icons are
untrusted. Use size, feature-count, complexity, timeout, redirect, and
decompression limits. Initial proposed limits: 10 MiB imports, 10,000
features/import, 5 MiB JPEG/PNG/WebP per photo, and bounded vertices per
feature; validate these in the GIS spike.

Fetch external sources through a controlled provider adapter with HTTPS and
validated public destinations. Block loopback, private/link-local ranges,
metadata hosts, credentialed URLs, unsupported ports, and redirect/DNS rebinding
escapes. Do not implement an arbitrary open proxy. Keep credentials server-side;
consider organization-admin-approved hosts. Treat incoming properties as text
and validate schema/geometry before persistence or rendering. Refresh initially
on bounded poll/manual demand with shared rate limits; store last-success and
source timestamp.

## Storage, caching, and operations

Keep attachments in private buckets even when features are public; a checked
endpoint or short-lived URL grants access according to current layer visibility.
Validate bytes and MIME type, cap dimensions and size, strip EXIF/location
metadata, and avoid executable formats. If signed URLs are used, document the
brief residual access window after revocation and keep it short. Storage paths
are not access control. Test direct object access and bucket listing.

Internal and capability responses use `Cache-Control: private, no-store`
initially; no shared cache may reuse a response between users or tokens. Public
responses may cache only after testing visibility-change invalidation.
Unlisted/internal pages and feeds use noindex headers and are absent from public
indexes; robots directives are discovery hints, not authorization. Redact
tokens, capability paths, personal information, and content from logs. Avoid
leaking share UUIDs through third-party requests/referrers. Choose basemap
privacy settings compatible with provider terms.

Use separate local, staging, and production projects and secrets; synthetic
preview data only. Enforce CSRF/origin protections on cookie-authenticated
writes, secure cookies, a tested CSP, rate limits, and restrictive CORS where
appropriate. Backup objects separately from database metadata. Prefer
forward-compatible migrations, expand/contract changes, and a tested
rollback/restore runbook.
