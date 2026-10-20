# Layer feature reads: viewport and list

Status: implemented for issue #13 (PRD MVP-07). The endpoint serves one layer.
Reads across several layers of a map are deliberately not part of this slice.
They depend on the audience contract in #19, which every read path must share,
so building one now would write the authorization twice. Sorting by anything
other than `created_at`, and export, are also out of scope.

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

Each request is checked in the route before any query runs, and each refusal
returns `400` with a stable `error.code`. The database enforces the same bounds,
so a direct RPC caller cannot exceed them either.

| Condition                                                      | Code                                       |
| -------------------------------------------------------------- | ------------------------------------------ |
| `limit` above 200                                              | `limit_too_large`                          |
| `limit` not a whole number from 1 to 200                       | `invalid_limit`                            |
| bbox malformed, non-finite, outside WGS84, or inverted         | `invalid_bbox`                             |
| bbox span above 90 degrees on either axis                      | `bbox_too_large`                           |
| `sort` other than `created_at`                                 | `unsupported_sort`                         |
| unknown or repeated parameter                                  | `unknown_parameter`, `duplicate_parameter` |
| malformed cursor, or one minted for another layer              | `invalid_cursor`                           |
| the function's own validation rejects a value (SQLSTATE 22023) | `invalid_request`                          |

Over-limit requests are refused, never clamped. A clamped page looks like a
complete result, and a client would not know rows were missing.

Every other database error returns `500 query_failed` with no database text,
because the text can name objects the caller should not learn about. A 500 from
this read is therefore a fault or a validator gap. Cursor timestamps are checked
against PostgreSQL's bounds, and the boundary tests guard that check.

Cursor timestamps follow PostgreSQL's own bounds, which the validator tests
assert as pairs: a displacement of `+15:59` and `-15:59` is accepted, and
`+16:00` and `-16:00` are refused. Year `0001` is accepted, and year `0000` is
refused.

A page whose first feature is larger than the byte budget returns `422` with
`feature_exceeds_response_budget` and that feature's ID. The page cannot move
past it, and skipping it would present an incomplete set as complete. At the
default budget this branch cannot be reached. The largest legal feature measured
70,445 bytes of JSON, against a 258,048-byte budget, so the branch is a
fail-closed guard for a later change to the constraints or the budget.

## Stable cursor

The cursor is
`base64url({"v":1,"l":layer,"s":"created_at","t":created_at,"i":id})`. The
client treats it as opaque. It is not signed. A forged cursor can only position
a read inside rows the caller can already read, so signing would add nothing to
access control.

Rows are ordered by `(created_at, id)`, and the next page starts strictly after
the last returned pair. The order is total because:

- `id` is the primary key, so it is unique.
- The composite order includes `id`, so rows that share a `created_at` have a
  defined order. The test fixture has three rows that share one value.
- Both columns are immutable after insert. Column grants omit them from
  `update`, and `app_private.stamp_feature_write` refuses any change to them.

What the cursor guarantees, and what it does not:

- A row committed before a walk starts is returned once by that walk, unless it
  is deleted or lies outside the box. Its position does not move, and an
  in-place update keeps the position and returns the current content.
- A walk is not a snapshot. Each page is a separate statement, so a page can see
  writes that the previous page did not.
- **`created_at` is the transaction start time, and clients cannot set it.** A
  transaction that starts before another but commits after it can insert a row
  whose `created_at` falls behind a cursor the walk has already passed. That
  walk never returns the row. A fresh walk does. This is a real limit of a
  `now()`-based keyset, not a wording detail. The read does not guarantee commit
  order. Whether it needs a commit-ordered guarantee is for #14 to decide, and
  this slice does not change the cursor for that purpose.

An offset would shift when a row is inserted or deleted before the window. The
next page would then repeat a row or skip one. A keyset position is a point in
an order that committed rows keep, which is why the cursor does not drift with
writes that commit in time order.

## Leak surface

The function is `security invoker`, so `features_read_member` decides which rows
exist for the caller. First, the function probes `public.layers`. The layer row
is the only thing RLS hides by layer, and the probe is one primary-key lookup. A
layer the caller cannot read and a layer that does not exist both return this
document, at the same cost:

```json
{
  "features": [],
  "has_more": false,
  "next": null,
  "oversized_feature_id": null
}
```

Without the probe, a forbidden layer's rows are scanned and filtered one by one
under RLS. That work is proportional to the layer's size, so the latency
revealed that a large hidden layer exists. Measured below, the probe removes
that difference.

The test compares whole payloads, not one field, and checks that neither the
layer title, a feature title, nor the layer ID appears in a forbidden response.
A visible empty layer returns the same bytes. The route never returns `404` for
a layer, so the status code does not distinguish the cases either.

The same applies to refusals that depend on the caller's rows. A byte budget
error is raised only for rows the caller can read. A cursor minted for another
layer fails the same way as a malformed cursor, and both checks run before any
query.

### Latency measurement

Measured with `clock_timestamp()` around each call, as an `authenticated`
caller, on a 200,000-row fixture (20 layers of 10,000 features, the target layer
among them). Full-world box, limit 50, so the 10,000-row layer is processed in
full for the visible and the pre-fix forbidden cases. Thirty calls each, after
one warm-up. PostgreSQL 17.11 on a local Apple silicon host.

| Caller and layer                           | Before the probe (avg / median, ms) | After the probe (avg / median, ms) |
| ------------------------------------------ | ----------------------------------- | ---------------------------------- |
| Visible: member reads own 10,000-row layer | 4.01 / 3.96                         | 3.98 / 3.86                        |
| Forbidden: no membership, 10,000-row layer | 0.86 / 0.85                         | 0.017 / 0.015                      |
| Nonexistent: random layer ID               | 0.17 / 0.17                         | 0.013 / 0.013                      |

Before the probe, a forbidden large layer cost about five times a nonexistent
one. After it, the two are within about 4 microseconds of each other, below
run-to-run noise for a single host. A visible layer still costs what its rows
cost, and that difference is intended, because the caller can read the layer.

This is a measurement on one host, not a proof of constant time. Absolute
figures vary by host and load. The ratio before and after is the evidence.

The SQL suite cannot observe latency. It guards the probe's presence with a
catalog assertion on the function source, a structural proxy that fails if the
probe statement is removed or written after the features read. It does not prove
the probe runs first at runtime, or that it is cheap. The latency measurement
above is the real evidence, and the assertion is brittle under refactoring by
design: a failure there means the function changed shape and the timing claim
needs a new measurement.

## Access implications

- Read access is organization membership, as in `features_read_member`. The
  layer's visibility tier (#19) is not part of this slice, so no public,
  unlisted, or internal distinction exists yet. That tier must add its own
  checks here.
- `anon` has no execute privilege. An anonymous request gets `401` from the
  route, and the function refuses an anonymous RPC with a grant error.
- No write path is added. Revision checks belong to #14.

## Numeric fidelity of attributes

`attributes` is a `jsonb` column. PostgreSQL stores its numbers exactly. The
route returns them through the supabase-js client, which parses the response
with `JSON.parse`, and then serializes it again. JavaScript numbers are IEEE
doubles, so the response changes some values, and it does so without an error:

- A number beyond the double range reads as `Infinity` and serializes as `null`.
  For example, `1e500` is returned as `null`.
- An integer beyond 2^53 loses its low digits. For example,
  `12345678901234567890` is returned as `12345678901234567000`.
- A decimal with more digits than a double keeps its nearest double. For
  example, `0.1000000000000000055511151231257827` is returned as `0.1`.

A caller that needs exact values cannot detect these changes from the response.
This slice does not fix that. Keeping exact numbers would mean returning the raw
`jsonb` text or parsing numbers as strings, and that is a contract decision for
the consumers of the attributes. It is recorded here so that a reader of the
data knows the limit.

## Index decision

The planner's choice was measured on the function's own statement, not on a
copy. The fixture is 20 layers of 10,000 features each, 200,000 features in
total. The plan for the first medium-viewport page, captured by `auto_explain`
from the function on the CI PostGIS 17 image, uses `features_layer_id_idx`,
reads all 10,000 layer rows from the heap, filters geometry, and sorts the 324
matches. The plan is reproduced by `tests/perf/layer_viewport_plan.sql`. Its
timings are not comparable with the figures above, because the CI image runs
under emulation.

No index is added in this PR. Three candidates were created and dropped as
committed DDL, and each was measured through the function, median of 30 calls,
on the same fixture. The candidate is `btree (layer_id, created_at, id)`, which
lets the planner walk the layer in page order and stop after the limit.

| Box (matches in layer) | No added index (ms) | With `(layer_id, created_at, id)` (ms) |
| ---------------------- | ------------------- | -------------------------------------- |
| Small (12)             | 1.93                | 2.01                                   |
| Medium (324)           | 2.44                | 1.05                                   |
| Large (2,501)          | 2.93                | 0.73                                   |
| Empty (0)              | 1.85                | 3.29                                   |

With the candidate, the planner reads the layer in `created_at` order and stops
after 51 matches. For a populated box that is much less work, and the medium box
reads about 2,000 rows instead of 10,000. For an empty box the planner must walk
the whole layer through the index, with a heap visit per row, and is slower than
the bitmap scan. Adding the index would therefore trade a faster populated map
for a slower empty one. The absolute difference is about 2 ms either way, and a
write cost applies to every feature insert. The decision belongs to the lead,
and this PR records the measurement rather than making it.

A `(layer_id, geom)` GiST index was also measured through the function. It
changed latency by less than the noise (2.53 ms against 2.56 ms median on the
medium box), and the planner did not use it for the layer predicate. The GiST
index on `geom` is used when the query has no layer predicate, so it is usable
but not chosen here.

The earlier evidence in this document used a hand-copied query, and it reported
no plan change for the ordered candidate. That was wrong for the function, and
the measurements above replace it.

## Deferred

- Reads across several layers of a map. This is deliberate. Such a read depends
  on `map_layers` ordering and on the audience contract in #19, which every read
  path must share. It is the next read after #19, and it will reuse this
  function's authorization rather than repeat it.
- Sort keys other than `created_at`, such as `-created_at`. Each needs its own
  cursor position and index evidence.
- A commit-ordered cursor guarantee for writes that commit out of start order.
  The caveat above is recorded. #14 decides whether the read needs one.
- Middleware fail-open for `/api/*`. The middleware gives every `/api/` route
  the session client and the no-store headers, but it does not require a
  session. Each route must check authentication itself, and a future route that
  forgets is unprotected. The correct design is a default-deny check in the
  middleware for `/api/` routes, with an allow-list for public ones. Follow-up,
  with a test that asserts the headers and a `401` shape on every `/api/` route.
- Import write actor, which is #43 item 1 and belongs to #24.
- Exact numeric attributes, described above.
