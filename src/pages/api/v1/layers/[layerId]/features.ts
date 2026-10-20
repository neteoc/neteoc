import type { APIRoute } from 'astro';
import {
  FEATURE_BYTE_BUDGET,
  MAX_RESPONSE_BYTES,
  encodeCursor,
  parseFeatureQuery,
  parseLayerId,
} from '../../../../../lib/feature-query';

// GET /api/v1/layers/{layerId}/features. The database decides which features the
// caller may read: the RPC runs as the caller, under features_read_member. This
// route validates the request first, so over-limit input never reaches the database.
// Middleware sets Cache-Control: private, no-store on every /api response.

interface LayerPage {
  features: unknown[];
  has_more: boolean;
  next: { created_at: string; id: string } | null;
  oversized_feature_id: string | null;
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

function errorResponse(
  status: number,
  code: string,
  message: string,
  details?: Record<string, string>,
): Response {
  return jsonResponse(status, { error: { code, message, ...details } });
}

function isLayerPage(value: unknown): value is LayerPage {
  if (typeof value !== 'object' || value === null) return false;
  const page = value as Record<string, unknown>;
  return (
    Array.isArray(page.features) &&
    typeof page.has_more === 'boolean' &&
    (page.next === null || typeof page.next === 'object') &&
    (page.oversized_feature_id === null ||
      typeof page.oversized_feature_id === 'string')
  );
}

export const GET: APIRoute = async ({ params, request, locals }) => {
  const supabase = locals.supabase;
  if (!supabase)
    return errorResponse(
      503,
      'unavailable',
      'The feature service is unavailable.',
    );

  const { data: claims, error: claimsError } = await supabase.auth.getClaims();
  if (claimsError || !claims?.claims) {
    return errorResponse(401, 'not_authenticated', 'Sign in to read features.');
  }

  const layerId = parseLayerId(params.layerId ?? '');
  if (layerId === null) {
    return errorResponse(
      400,
      'invalid_layer_id',
      'The layer ID must be a UUID.',
    );
  }

  const parsed = parseFeatureQuery(layerId, new URL(request.url).searchParams);
  if (!parsed.ok) {
    return errorResponse(
      parsed.error.status,
      parsed.error.code,
      parsed.error.message,
    );
  }
  const query = parsed.query;

  const { data, error } = await supabase.rpc('list_layer_features', {
    p_layer_id: query.layerId,
    p_min_lon: query.bbox.minLon,
    p_min_lat: query.bbox.minLat,
    p_max_lon: query.bbox.maxLon,
    p_max_lat: query.bbox.maxLat,
    p_limit: query.limit,
    // Omitted on the first page. The function's default null makes that the start of the order.
    p_after_created_at: query.cursor?.createdAt,
    p_after_id: query.cursor?.id,
    p_byte_budget: FEATURE_BYTE_BUDGET,
  });
  // SQLSTATE 22023 is the function's own validation. Its messages are fixed
  // strings, so they are safe to return, and the request was invalid, not the server.
  // Every other error is unexpected and stays a 500 with no database text, because
  // it can name objects the caller should not learn about. A validator that disagrees
  // with PostgreSQL shows up as a 500 here, which is how the gap gets noticed.
  if (error?.code === '22023') {
    return errorResponse(400, 'invalid_request', error.message);
  }
  if (error || !isLayerPage(data)) {
    return errorResponse(500, 'query_failed', 'The feature query failed.');
  }

  if (data.oversized_feature_id !== null) {
    // The first feature of this page is larger than the page budget. The page cannot
    // move past it, and skipping it would return a set that looks complete. The
    // caller is authorized for this feature, because the database returned its ID.
    return errorResponse(
      422,
      'feature_exceeds_response_budget',
      'A feature at the start of this page is larger than the response budget, so this list cannot return it.',
      { feature_id: data.oversized_feature_id },
    );
  }

  const nextCursor =
    data.has_more && data.next !== null
      ? encodeCursor(query.layerId, {
          createdAt: data.next.created_at,
          id: data.next.id,
        })
      : null;

  const body = JSON.stringify({
    type: 'FeatureCollection',
    features: data.features,
    has_more: data.has_more,
    next_cursor: nextCursor,
  });
  // The budget keeps the body under the limit. This check fails closed if a future
  // change to the serialization breaks that.
  if (new TextEncoder().encode(body).byteLength > MAX_RESPONSE_BYTES) {
    return errorResponse(500, 'query_failed', 'The feature query failed.');
  }

  return new Response(body, {
    status: 200,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
};
