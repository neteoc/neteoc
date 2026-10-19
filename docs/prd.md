# MVP product requirements

Status: high-level planning baseline, not an implemented product.

## Outcome

An organization can record geographic information, keep it current with field
updates, and share chosen maps and layers with colleagues, public visitors, and
GIS applications. A feature represents an arbitrary place, route, or area; it is
not inherently an incident, task, patient, or vehicle.

## People and permissions

| Actor              | Capability                                                                       |
| ------------------ | -------------------------------------------------------------------------------- |
| Platform admin     | Create organizations and appoint initial admins; tightly audited support access. |
| Organization admin | Manage invitations, roles, maps, layers, and content.                            |
| Editor             | Create/edit organization maps, internal layers, features, notes, and photos.     |
| Viewer             | Read their organization's internal content; cannot mutate it.                    |
| Anonymous visitor  | Read public resources or resources shared through an unlisted link.              |
| GIS client         | Read authorized exports; internal data requires a scoped, revocable token.       |

Membership is checked for the resource's owner organization, not merely a valid
login. Joining one organization never grants access to another's private data.

## Required capabilities and acceptance criteria

| ID     | Requirement                             | Acceptance evidence                                                                                                                                                                    |
| ------ | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MVP-01 | Invitation-only organizations and roles | Existing and new users can accept a single-use, expiring invitation; reused/revoked invitations fail; viewer writes and cross-tenant reads fail.                                       |
| MVP-02 | Maps with ordered reusable layers       | An editor attaches one layer to two maps, orders/toggles it independently, and sees an edit reflected in both; detaching it does not delete the layer.                                 |
| MVP-03 | Independent visibility and discovery    | Only public resources appear in anonymous listings/sitemaps; direct links and exports enforce the matrix in the architecture; changing visibility removes future access appropriately. |
| MVP-04 | Point, line, polygon editing            | Create, move/reshape, update, and remove features; reject invalid geometry; surface conflicting edits rather than overwrite them.                                                      |
| MVP-05 | Address and click placement             | Address search presents candidates for confirmation and adjustment; clicking the map works when an address is unknown or geocoding fails. No coordinate order swaps.                   |
| MVP-06 | Generic content and collaboration       | Features have title, description, optional status, bounded attributes, notes, and photos; save failures preserve the edit for retry and show that it is unsaved.                       |
| MVP-07 | Map and list views                      | Selection/filtering stays consistent between views; a large-screen view shows current information and update time; mobile users can refine locations and upload photos.                |
| MVP-08 | External read-only layers               | Supported KML, GeoJSON, and ArcGIS FeatureServer layer endpoints render; refresh timestamps, failures, and stale snapshots are visible; no upstream mutation occurs.                   |
| MVP-09 | Import                                  | A bounded KML or GeoJSON upload previews counts/errors and imports an editable independent layer; unsupported geometry or styles are reported.                                         |
| MVP-10 | GIS exports                             | Layer and map GeoJSON links and KML network links refresh in compatible clients and match web authorization; exports include stable feature IDs and source-layer identity.             |
| MVP-11 | Internal GIS tokens                     | Token scope, issuer membership, expiry, and revocation are enforced on every request; token cannot write, enumerate unrelated data, or gain newly attached layers implicitly.          |
| MVP-12 | Basemaps                                | Built-in configurable OSM-derived basemap options display attribution; a provider failure leaves features/list usable and shows an error.                                              |

## Workflow details

For a new observation, an editor opens a map, selects an editable internal
layer, clicks a location or confirms an address match, enters a title and
optional details, and saves. Another authorized editor can refine the geometry,
add photos and notes, or change status. Default status is unset; simple workflow
labels are optional. Store actor and timestamps for edits; preserve an audit
trail of access changes and deletions. Basic properties can hold generic
information such as fuel type without shipping a schema-builder UI.

Before sharing, show which layers are accessible to the intended audience. The
public directory includes public maps and standalone public layers. A map can
contain internal layers for members without revealing those layers' names,
counts, bounding boxes, or URLs to unauthorized visitors. Unlisted URLs are
shareable capabilities, not a promise of secrecy. Link rotation invalidates the
old capability. Visibility changes cannot recall already downloaded copies.

Refresh live views through polling first, with a proposed 30-second interval and
manual refresh. Show time of last successful update and stale/error state.
Realtime can follow if it improves usability without weakening access control. A
failed save must not be represented as completed work.

## Scope boundaries

Included exports are GeoJSON and KML (with network-linked refresh). Additional
standards, including OGC API Features, WMS/WFS serving, vector tiles, and
GeoPackage, are future options; do not advertise conformance before testing it.
The MVP can consume supported external formats without implementing all ArcGIS
service types. ArcGIS authenticated enterprise services, arbitrary raster
ingestion, KMZ, recursive remote KML network links, and full KML styling are
deferred.

Also deferred: offline operation, dispatch/routing, patient or injury records,
custom role builders, cross-organization write grants, live vehicle tracking,
external write-back, anonymous submissions, complex incident management,
billing, and general workflow automation. Cross-team sharing uses
public/unlisted links or multiple organization memberships.

## Quality and release criteria

- Demonstrate both reference scenarios with synthetic data without special-case
  schemas or code paths. All MVP acceptance criteria must pass.
- Test keyboard navigation, labels, contrast, non-color status cues, accessible
  forms, and list alternatives to map-only interactions; target WCAG 2.2 AA.
- Proposed pilot workload: 10 organizations, 25 concurrent users per
  organization, 10,000 features per layer, and 20 visible layers per map.
  Validate bounded viewport loading and export limits before promising larger
  workloads.
- Proposed performance targets: map/list usable within 3 seconds on a
  representative broadband device; normal saves within 2 seconds, excluding
  photo transfer. Measure p95 on a documented staging dataset and connection
  profile.
- No unresolved high/critical security findings without a narrowly documented,
  expiring exception; tenant isolation, export authorization, and storage tests
  pass.
- Restore rehearsal covers database **and** uploaded objects; establish backup
  frequency, retention, RPO/RTO, ownership, and provider costs before launch.
- A stakeholder walkthrough accepts the map/list workflow and sharing behavior.
  Performance and service targets above are proposed, not contractual promises.
