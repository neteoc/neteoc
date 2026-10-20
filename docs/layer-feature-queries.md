# Layer feature reads: viewport and list

Status: implemented for issue #13 (PRD MVP-07). The endpoint serves one layer.
Map-level reads across several layers, sorting other than `created_at`, and
export are not part of this read.

## Endpoint

`GET /api/v1/layers/{layerId}/features`

| Parameter | Meaning                                                             | Default      |
| --------- | ------------------------------------------------------------------- | ------------ |
| `bbox`    | `minLon,minLat,maxLon,maxLat` in WGS84 degrees. Omit for the layer. | whole layer  |
| `limit`   | Whole number, 1 to 200.                                             | 50           |
| `sort`    | Only `created_at`.                                                  | `created_at` |
| `cursor`  | Opaque value from `next_cursor`.                                    | first page   |

Any other parameter, or a repeated one, is refused. A filter the server does not
know would be ignored silently, and a silent filter returns rows the caller did
not ask for.

Response, `200`:

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": "f0000000-0000-4000-8000-000000000001",
      "geometry": { "type": "Point", "coordinates": [-104.9, 39.7] },
      "properties": {
        "title": "...",
        "description": null,
        "status": null,
        "attributes": {},
        "revision": 1,
        "created_at": "2026-10-01T00:00:01+00:00",
        "updated_at": "2026-10-01T00:00:01+00:00"
      }
    }
  ],
  "has_more": true,
  "next_cursor": "eyJ2IjoxLCJsIjoi..."
}
```

`next_cursor` is `null` when `has_more` is `false`. The response carries no
total count, no layer name, and no extent. Responses are `private, no-store`.

## Limits and refusals

Every refusal happens before a query runs, and each returns `400` with a stable
`error.code`. The database enforces the same bounds, so a direct RPC caller
cannot exceed them either.

| Condition                                              | Code                                       |
| ------------------------------------------------------ | ------------------------------------------ |
| `limit` above 200                                      | `limit_too_large`                          |
| `limit` not a whole number from 1 to 200               | `invalid_limit`                            |
| bbox malformed, non-finite, outside WGS84, or inverted | `invalid_bbox`                             |
| bbox span above 90 degrees on either axis              | `bbox_too_large`                           |
| `sort` other than `created_at`                         | `unsupported_sort`                         |
| unknown or repeated parameter                          | `unknown_parameter`, `duplicate_parameter` |
| malformed cursor, or one minted for another layer      | `invalid_cursor`                           |

Over-limit requests are refused, never clamped. A clamped page looks like a
complete result, and a client would not know rows were missing.

A page whose first feature is larger than the byte budget returns `422` with
`feature_exceeds_response_budget` and that feature's ID. The page cannot move
past the feature, and skipping it would present an incomplete set as complete.
At the default budget this branch cannot be reached. The largest legal feature
measured 70,445 bytes of JSON, against a 258,048-byte budget, so the branch is a
fail-closed guard for a later change to the constraints or the budget.

Database failures return `500 query_failed` with no database text, because the
text can name objects the caller should not learn about.

## Stable cursor

The cursor is
`base64url({"v":1,"l":layer,"s":"created_at","t":created_at,"i":id})`. The
client treats it as opaque. It is not signed. A forged cursor can only position
a read inside rows the caller can already read, so signing would add nothing to
access control.

Rows are ordered by `(created_at, id)`, and the next page starts strictly after
the last returned pair. This is a total order for three reasons:

- `id` is the primary key, so it is unique.
- The composite order includes `id`, so rows that share a `created_at` have a
  defined order. The test fixture has three rows that share one value.
- Both columns are immutable after insert. The column grants omit them from
  `update`, and `app_private.stamp_feature_write` refuses any change to them.

An offset would shift when a row is inserted or deleted before the window. The
next page would then repeat a row or skip one. A keyset position is a point in
an order that existing rows keep, so existing rows are neither repeated nor
skipped. A row changed in place keeps its position and returns with its current
content.

A walk is not a snapshot. A row created behind the cursor is not returned by a
walk that has already passed its position, and a new walk returns it. Each page
is its own statement. This is the one case where the read is not consistent, and
it is tested.

## Leak surface

The function is `security invoker`, so `features_read_member` decides which rows
exist for the caller. A layer the caller cannot read and a layer that does not
exist both produce this document:

```json
{
  "features": [],
  "has_more": false,
  "next": null,
  "oversized_feature_id": null
}
```

The test compares the whole payload, not one field, and checks that neither the
layer title, a feature title, nor the layer ID appears in it. The route never
returns `404` for a layer, so the status code does not distinguish the two cases
either.

The same applies to refusals that depend on the caller's rows. A byte budget
error is raised only for rows the caller can read. A cursor minted for another
layer fails the same way as a malformed cursor, and both checks run before any
query.

Residual: response time is not hidden. A forbidden layer's rows are scanned and
then filtered, so its latency may differ from a missing layer's. This was not
measured. The response body does not reveal the difference. Hiding latency would
need a constant-cost path, which this read does not have.

## Access implications

- Read access is organization membership, as in `features_read_member`. The
  layer's visibility tier (#19) is not part of this slice, so no public,
  unlisted, or internal distinction exists yet. That tier must add its own
  checks here.
- `anon` has no execute privilege. An anonymous request gets `401` from the
  route, and the function refuses an anonymous RPC with a grant error.
- No write path is added. Revision checks belong to #14.

## Index decision

The planner's choice was measured on a synthetic fixture: twenty layers of
10,000 features each, 200,000 features in total, in one organization. The target
layer holds 10,000 of them. Plans were captured as the `authenticated` role,
without `enable_seqscan = off`, with RLS applied, and after `vacuum analyze`.

Result: the planner uses `features_layer_id_idx` and filters geometry in the
heap. The GiST index on `geom` is not chosen for this query shape. Disabling
`enable_seqscan` leaves the plan unchanged. Without the layer predicate, the
same box query uses the GiST index, so the index itself is usable.

Candidates, each created and dropped as committed DDL and measured the same way:

| Index                                  | Planner choice          | Medium viewport, ms (median of 6) |
| -------------------------------------- | ----------------------- | --------------------------------- |
| none added (baseline)                  | `features_layer_id_idx` | 2.1                               |
| `gist (layer_id, geom)` via btree_gist | `features_layer_id_idx` | 1.8                               |
| `btree (layer_id, created_at, id)`     | `features_layer_id_idx` | 1.7                               |

Neither candidate changed the plan, and the timing differences are within
run-to-run noise. No index was added. The layer read scans all 10,000 layer rows
in the heap, so its cost follows the size of the layer, not the box. At 10,000
rows that is about 2 ms on a warm cache. Revisit this if a layer grows past that
size, and then measure again rather than assuming a composite index will help.

The plan for the medium viewport, from `EXPLAIN (ANALYZE, BUFFERS)` on the
200,000-row fixture, is recorded in the pull request.

## Deferred

- Map-level reads across several layers, which depend on `map_layers` and layer
  visibility (#19).
- `sort=-created_at` and other sort keys. Each needs its own cursor position and
  index evidence.
- The import path's write-actor question from #43, which is not part of this
  read.
