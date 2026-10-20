import { describe, expect, test } from 'bun:test';
import {
  DEFAULT_PAGE_SIZE,
  FEATURE_BYTE_BUDGET,
  MAX_BBOX_SPAN_DEGREES,
  MAX_PAGE_SIZE,
  MAX_RESPONSE_BYTES,
  WORLD_BBOX,
  decodeCursor,
  encodeCursor,
  parseFeatureQuery,
  parseLayerId,
} from '../src/lib/feature-query';
import { GET } from '../src/pages/api/v1/layers/[layerId]/features';

const LAYER = '9c3a2e4d-6f5b-4a7c-8d8e-1f2a3b4c5d6e';
const OTHER_LAYER = '670e69b7-579b-486a-ad7d-5e3153e9e724';
const FEATURE = 'f0000000-0000-4000-8000-000000000001';
const CURSOR = { createdAt: '2026-10-01T00:00:10+00:00', id: FEATURE };
// The shape list_layer_features returns: snake case, as jsonb.
const SQL_CURSOR = { created_at: CURSOR.createdAt, id: CURSOR.id };

function params(query: string): URLSearchParams {
  return new URLSearchParams(query);
}

function errorOf(query: string) {
  const result = parseFeatureQuery(LAYER, params(query));
  if (result.ok) throw new Error(`expected a refusal for "${query}"`);
  return result.error;
}

describe('feature query defaults', () => {
  test('no parameters read the whole layer in pages of the default size', () => {
    const result = parseFeatureQuery(LAYER, params(''));
    expect(result).toEqual({
      ok: true,
      query: {
        layerId: LAYER,
        bbox: WORLD_BBOX,
        limit: DEFAULT_PAGE_SIZE,
        cursor: null,
      },
    });
  });

  test('the response budget leaves room for the envelope', () => {
    expect(FEATURE_BYTE_BUDGET + 4096).toBe(MAX_RESPONSE_BYTES);
  });
});

describe('bbox limits', () => {
  test('accepts a box inside WGS84 and reads it in lon,lat order', () => {
    const result = parseFeatureQuery(
      LAYER,
      params('bbox=-104.9,39.7,-104.8,39.8'),
    );
    expect(result.ok && result.query.bbox).toEqual({
      minLon: -104.9,
      minLat: 39.7,
      maxLon: -104.8,
      maxLat: 39.8,
    });
  });

  test('accepts a span of exactly the maximum and refuses one past it', () => {
    expect(
      parseFeatureQuery(LAYER, params(`bbox=0,0,${MAX_BBOX_SPAN_DEGREES},1`))
        .ok,
    ).toBe(true);
    expect(errorOf(`bbox=0,0,${MAX_BBOX_SPAN_DEGREES + 0.0001},1`).code).toBe(
      'bbox_too_large',
    );
    expect(
      errorOf(`bbox=0,-60,1,${-60 + MAX_BBOX_SPAN_DEGREES + 0.0001}`).code,
    ).toBe('bbox_too_large');
  });

  test.each([
    ['too few parts', 'bbox=1,2,3'],
    ['too many parts', 'bbox=1,2,3,4,5'],
    ['non-numeric', 'bbox=a,b,c,d'],
    ['exponent notation', 'bbox=1e2,0,2,3'],
    ['whitespace', 'bbox=%201,2,3,4'],
    ['NaN', 'bbox=NaN,0,1,1'],
    ['Infinity', 'bbox=-Infinity,0,1,1'],
    ['longitude past 180', 'bbox=0,0,181,1'],
    ['longitude below -180', 'bbox=-181,0,0,1'],
    ['latitude past 90', 'bbox=0,0,1,91'],
    ['inverted longitude', 'bbox=2,0,1,1'],
    ['inverted latitude', 'bbox=0,2,1,1'],
  ])('refuses %s', (_, query) => {
    expect(errorOf(query).code).toBe('invalid_bbox');
  });
});

describe('page size limits', () => {
  test('accepts the maximum and refuses one past it without truncating', () => {
    const result = parseFeatureQuery(LAYER, params(`limit=${MAX_PAGE_SIZE}`));
    expect(result.ok && result.query.limit).toBe(MAX_PAGE_SIZE);
    expect(errorOf(`limit=${MAX_PAGE_SIZE + 1}`).code).toBe('limit_too_large');
  });

  test.each(['0', '-1', '1.5', 'abc', '', '1000000000'])(
    'refuses limit "%s"',
    (value) => {
      expect(errorOf(`limit=${value}`).code).toMatch(
        /^(invalid_limit|limit_too_large)$/,
      );
    },
  );
});

describe('sort and unknown parameters', () => {
  test('accepts the one supported sort key', () => {
    expect(parseFeatureQuery(LAYER, params('sort=created_at')).ok).toBe(true);
  });

  test.each(['-created_at', 'id', 'title'])('refuses sort "%s"', (value) => {
    expect(errorOf(`sort=${value}`).code).toBe('unsupported_sort');
  });

  test('refuses an unknown filter rather than ignoring it', () => {
    // A silently ignored filter would return rows the caller did not ask for.
    expect(errorOf('layer_name=Hidden').code).toBe('unknown_parameter');
    expect(errorOf(`layer=${OTHER_LAYER}`).code).toBe('unknown_parameter');
  });

  test('refuses a repeated parameter', () => {
    expect(errorOf('limit=10&limit=20').code).toBe('duplicate_parameter');
  });
});

describe('stable cursor', () => {
  test('round-trips for the layer it was minted for', () => {
    const cursor = encodeCursor(LAYER, CURSOR);
    expect(decodeCursor(cursor, LAYER)).toEqual(CURSOR);
  });

  test('is opaque and URL-safe', () => {
    expect(encodeCursor(LAYER, CURSOR)).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  test('a cursor minted for another layer is refused as an invalid cursor', () => {
    const cursor = encodeCursor(OTHER_LAYER, CURSOR);
    expect(decodeCursor(cursor, LAYER)).toBeNull();
    expect(errorOf(`cursor=${cursor}`).code).toBe('invalid_cursor');
  });

  test('a forbidden layer cursor and a malformed cursor get the same error', () => {
    // The error for a cursor minted for another layer must not differ from one that
    // was never valid, so no response reveals which layers exist.
    const forbidden = errorOf(`cursor=${encodeCursor(OTHER_LAYER, CURSOR)}`);
    const malformed = errorOf('cursor=not-a-cursor!!');
    expect(forbidden).toEqual(malformed);
  });

  test.each([
    ['not base64', '!!!'],
    ['not JSON', btoa('not json').replace(/=+$/, '')],
    ['an array', btoa('[]').replace(/=+$/, '')],
    ['an extra field', encodeWith({ extra: 1 })],
    ['a bad version', encodeWith({ v: 2 })],
    ['a bad timestamp', encodeWith({ t: '2026-10-01 00:00:10' })],
    ['a bad id', encodeWith({ i: 'not-a-uuid' })],
    ['an oversized value', 'a'.repeat(600)],
  ])('refuses a cursor that is %s', (_, cursor) => {
    expect(decodeCursor(cursor, LAYER)).toBeNull();
  });

  test('a cursor with a bad timestamp is refused before reaching the database', () => {
    expect(
      errorOf(`cursor=${encodeWith({ t: '2026-13-45T00:00:00Z' })}`).code,
    ).toBe('invalid_cursor');
  });
});

describe('layer identifiers', () => {
  test('accepts a UUID and lowercases it', () => {
    expect(parseLayerId(LAYER.toUpperCase())).toBe(LAYER);
  });

  test('refuses anything that is not a UUID', () => {
    expect(parseLayerId('layer-a')).toBeNull();
    expect(parseLayerId('')).toBeNull();
  });
});

function encodeWith(fields: Record<string, unknown>): string {
  const base = {
    v: 1,
    l: LAYER,
    s: 'created_at',
    t: CURSOR.createdAt,
    i: CURSOR.id,
  };
  return btoa(JSON.stringify({ ...base, ...fields }))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

interface RpcCall {
  name: string;
  args: Record<string, unknown>;
}

function routeContext(options: {
  query?: string;
  layerId?: string;
  claims?: boolean;
  rpc?: (call: RpcCall) => { data: unknown; error: { message: string } | null };
}) {
  const calls: RpcCall[] = [];
  const supabase = {
    auth: {
      getClaims: async () =>
        options.claims === false
          ? { data: null, error: { message: 'no session' } }
          : { data: { claims: { sub: 'user' } }, error: null },
    },
    rpc: async (name: string, args: Record<string, unknown>) => {
      const call = { name, args };
      calls.push(call);
      return options.rpc
        ? options.rpc(call)
        : {
            data: {
              features: [],
              has_more: false,
              next: null,
              oversized_feature_id: null,
            },
            error: null,
          };
    },
  };
  const url = `https://neteoc.example/api/v1/layers/${options.layerId ?? LAYER}/features?${options.query ?? ''}`;
  return {
    calls,
    context: {
      params: { layerId: options.layerId ?? LAYER },
      request: new Request(url),
      locals: { supabase },
    } as unknown as Parameters<typeof GET>[0],
  };
}

async function read(context: Parameters<typeof GET>[0]) {
  const response = await GET(context);
  return { status: response.status, body: await response.json() };
}

describe('GET /api/v1/layers/{layerId}/features', () => {
  test('refuses an unauthenticated caller without a database call', async () => {
    const { calls, context } = routeContext({ claims: false });
    const { status, body } = await read(context);
    expect(status).toBe(401);
    expect(body.error.code).toBe('not_authenticated');
    expect(calls).toHaveLength(0);
  });

  test('refuses an over-limit page size explicitly, before any query', async () => {
    const { calls, context } = routeContext({ query: 'limit=500' });
    const { status, body } = await read(context);
    expect(status).toBe(400);
    expect(body.error.code).toBe('limit_too_large');
    expect(calls).toHaveLength(0);
  });

  test('refuses an over-limit box explicitly, before any query', async () => {
    const { calls, context } = routeContext({ query: 'bbox=-180,-90,180,90' });
    const { status, body } = await read(context);
    expect(status).toBe(400);
    expect(body.error.code).toBe('bbox_too_large');
    expect(calls).toHaveLength(0);
  });

  test('passes the validated query to the RPC with the response budget', async () => {
    const { calls, context } = routeContext({
      query: 'bbox=-104.9,39.7,-104.8,39.8&limit=25',
    });
    const { status } = await read(context);
    expect(status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls[0].name).toBe('list_layer_features');
    expect(calls[0].args).toEqual({
      p_layer_id: LAYER,
      p_min_lon: -104.9,
      p_min_lat: 39.7,
      p_max_lon: -104.8,
      p_max_lat: 39.8,
      p_limit: 25,
      p_after_created_at: undefined,
      p_after_id: undefined,
      p_byte_budget: FEATURE_BYTE_BUDGET,
    });
  });

  test('returns a next cursor only while more rows exist', async () => {
    const feature = { type: 'Feature', id: FEATURE };
    const more = routeContext({
      rpc: () => ({
        data: {
          features: [feature],
          has_more: true,
          next: SQL_CURSOR,
          oversized_feature_id: null,
        },
        error: null,
      }),
    });
    const first = await read(more.context);
    expect(first.body.has_more).toBe(true);
    expect(decodeCursor(first.body.next_cursor, LAYER)).toEqual(CURSOR);

    const last = routeContext({
      rpc: () => ({
        data: {
          features: [feature],
          has_more: false,
          next: SQL_CURSOR,
          oversized_feature_id: null,
        },
        error: null,
      }),
    });
    expect((await read(last.context)).body.next_cursor).toBeNull();
  });

  test('a forbidden layer and a nonexistent layer get identical responses', async () => {
    const empty = {
      features: [],
      has_more: false,
      next: null,
      oversized_feature_id: null,
    };
    const forbidden = await read(
      routeContext({
        layerId: OTHER_LAYER,
        rpc: () => ({ data: empty, error: null }),
      }).context,
    );
    const missing = await read(
      routeContext({
        layerId: '00000000-0000-4000-8000-000000000000',
        rpc: () => ({ data: empty, error: null }),
      }).context,
    );
    expect(forbidden.status).toBe(200);
    expect(missing).toEqual(forbidden);
  });

  test('reports an oversized first feature by id, not as a complete page', async () => {
    const { context } = routeContext({
      rpc: () => ({
        data: {
          features: [],
          has_more: true,
          next: null,
          oversized_feature_id: FEATURE,
        },
        error: null,
      }),
    });
    const { status, body } = await read(context);
    expect(status).toBe(422);
    expect(body.error.code).toBe('feature_exceeds_response_budget');
    expect(body.error.feature_id).toBe(FEATURE);
    expect(body.features).toBeUndefined();
  });

  test('does not return database error text to the caller', async () => {
    const { context } = routeContext({
      rpc: () => ({
        data: null,
        error: { message: 'relation "secret_layers" does not exist' },
      }),
    });
    const { status, body } = await read(context);
    expect(status).toBe(500);
    expect(JSON.stringify(body)).not.toContain('secret_layers');
  });

  test('fails closed when the page is not the shape the database should return', async () => {
    const { context } = routeContext({
      rpc: () => ({ data: { features: 'x' }, error: null }),
    });
    expect((await read(context)).status).toBe(500);
  });

  test('fails closed when a page would exceed the response limit', async () => {
    const big = { type: 'Feature', pad: 'x'.repeat(MAX_RESPONSE_BYTES) };
    const { context } = routeContext({
      rpc: () => ({
        data: {
          features: [big],
          has_more: false,
          next: null,
          oversized_feature_id: null,
        },
        error: null,
      }),
    });
    expect((await read(context)).status).toBe(500);
  });

  test('reports an unavailable service when Supabase is not configured', async () => {
    const { context } = routeContext({});
    const unconfigured = {
      ...context,
      locals: { supabase: null },
    } as unknown as Parameters<typeof GET>[0];
    const response = await GET(unconfigured);
    expect(response.status).toBe(503);
  });
});

// Each boundary is asserted as a pair: the accepted side and the refused side. A test
// for one side alone lets a later edit move the other side without any failure.
describe('cursor timestamp boundaries match PostgreSQL', () => {
  const accepts = (createdAt: string) =>
    decodeCursor(encodeWith({ t: createdAt }), LAYER) !== null;

  test.each([
    ['+15:59 is accepted', '2026-10-01T00:00:00+15:59', true],
    ['+16:00 is refused', '2026-10-01T00:00:00+16:00', false],
    ['-15:59 is accepted', '2026-10-01T00:00:00-15:59', true],
    ['-16:00 is refused', '2026-10-01T00:00:00-16:00', false],
    ['+23:00 is refused', '2026-10-01T00:00:00+23:00', false],
    ['year 0001 is accepted', '0001-01-01T00:00:00+00:00', true],
    ['year 0000 is refused', '0000-01-01T00:00:00+00:00', false],
    ['year 0000 in Z form is refused', '0000-12-31T23:59:59Z', false],
    ['2000-02-29 is accepted (leap)', '2000-02-29T00:00:00Z', true],
    ['2100-02-29 is refused (not leap)', '2100-02-29T00:00:00Z', false],
    ['2026-02-29 is refused', '2026-02-29T00:00:00Z', false],
    ['hour 24 is refused', '2026-10-01T24:00:00Z', false],
  ])('%s', (_, createdAt, expected) => {
    expect(accepts(createdAt)).toBe(expected);
  });
});

describe('forged cursors fail as client errors, not server faults', () => {
  test.each([
    ['offset past 15:59', '2026-10-01T00:00:00+16:00'],
    ['year 0', '0000-01-01T00:00:00+00:00'],
  ])(
    'a cursor with %s is 400 invalid_cursor and never reaches the database',
    async (_, createdAt) => {
      const { calls, context } = routeContext({
        query: `cursor=${encodeWith({ t: createdAt })}`,
      });
      const { status, body } = await read(context);
      expect(status).toBe(400);
      expect(body.error.code).toBe('invalid_cursor');
      expect(calls).toHaveLength(0);
    },
  );
});

// The route maps only the function's own validation error (22023) to 400. Every other
// SQLSTATE, including a date-range error from a validator gap, stays a 500 with no text.
describe('database error mapping', () => {
  const failing = (code: string) =>
    routeContext({
      rpc: () => ({
        data: null,
        error: { code, message: `database said ${code}` },
      }),
    });

  test('the function’s own validation (22023) is a 400 with its fixed message', async () => {
    const { status, body } = await read(failing('22023').context);
    expect(status).toBe(400);
    expect(body.error.code).toBe('invalid_request');
    expect(body.error.message).toBe('database said 22023');
  });

  test.each([
    ['a date-range error from a validator gap (22008)', '22008'],
    ['a grant error (42501)', '42501'],
    ['an unclassified error (XX000)', 'XX000'],
  ])('%s stays a 500 with no database text', async (_, code) => {
    const { status, body } = await read(failing(code).context);
    expect(status).toBe(500);
    expect(body.error.code).toBe('query_failed');
    expect(JSON.stringify(body)).not.toContain(code);
  });
});
