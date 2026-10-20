// Request parsing and cursor encoding for the layer feature read. Pure functions
// with no I/O, so the limits and the error contract are tested without a database.
// The database enforces the same bounds in list_layer_features; this module refuses
// over-limit requests before any query runs. See docs/layer-feature-queries.md.

export const DEFAULT_PAGE_SIZE = 50;
export const MAX_PAGE_SIZE = 200;
// Each axis of a requested box may span at most this many degrees. A wider view
// is served by the list form, which has no box, and pages through the layer.
export const MAX_BBOX_SPAN_DEGREES = 90;
export const MAX_RESPONSE_BYTES = 256 * 1024;
// Bytes reserved for the response envelope (type, has_more, next_cursor, and
// separators) beyond the feature bytes. The database budget is the response limit
// minus this reserve, so the serialized body stays under MAX_RESPONSE_BYTES.
export const RESPONSE_ENVELOPE_RESERVE_BYTES = 4096;
export const FEATURE_BYTE_BUDGET =
  MAX_RESPONSE_BYTES - RESPONSE_ENVELOPE_RESERVE_BYTES;

const SORT_KEY = 'created_at';
const CURSOR_VERSION = 1;
const MAX_CURSOR_LENGTH = 512;
const KNOWN_PARAMETERS = new Set(['bbox', 'limit', 'sort', 'cursor']);
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DECIMAL_PATTERN = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/;
const LIMIT_PATTERN = /^[0-9]{1,6}$/;
// The form PostgreSQL returns for a timestamptz inside jsonb, with an offset.
const TIMESTAMP_PATTERN =
  /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?(Z|[+-]([0-9]{2}):([0-9]{2}))$/;

export interface Bbox {
  minLon: number;
  minLat: number;
  maxLon: number;
  maxLat: number;
}

export interface Cursor {
  createdAt: string;
  id: string;
}

export interface FeatureQuery {
  layerId: string;
  // Null is the list form: the whole layer, with no spatial filter in the database.
  bbox: Bbox | null;
  limit: number;
  cursor: Cursor | null;
}

export interface ApiError {
  status: 400;
  code: string;
  message: string;
}

export type ParseResult =
  { ok: true; query: FeatureQuery } | { ok: false; error: ApiError };

function refuse(code: string, message: string): { ok: false; error: ApiError } {
  return { ok: false, error: { status: 400, code, message } };
}

export function parseLayerId(raw: string): string | null {
  return UUID_PATTERN.test(raw) ? raw.toLowerCase() : null;
}

export function parseFeatureQuery(
  layerId: string,
  params: URLSearchParams,
): ParseResult {
  const seen = new Set<string>();
  for (const key of params.keys()) {
    if (!KNOWN_PARAMETERS.has(key)) {
      return refuse('unknown_parameter', `Unknown query parameter "${key}".`);
    }
    if (seen.has(key)) {
      return refuse(
        'duplicate_parameter',
        `Query parameter "${key}" appears more than once.`,
      );
    }
    seen.add(key);
  }

  const bboxRaw = params.get('bbox');
  const bbox =
    bboxRaw === null ? { ok: true as const, bbox: null } : parseBbox(bboxRaw);
  if (!bbox.ok) return bbox;

  const limit = parseLimit(params.get('limit'));
  if (!limit.ok) return limit;

  const sort = params.get('sort');
  if (sort !== null && sort !== SORT_KEY) {
    return refuse('unsupported_sort', `Sort must be "${SORT_KEY}" or omitted.`);
  }

  const cursorRaw = params.get('cursor');
  let cursor: Cursor | null = null;
  if (cursorRaw !== null) {
    const decoded = decodeCursor(cursorRaw, layerId);
    if (decoded === null)
      return refuse(
        'invalid_cursor',
        'The cursor is not valid for this request.',
      );
    cursor = decoded;
  }

  return {
    ok: true,
    query: { layerId, bbox: bbox.bbox, limit: limit.limit, cursor },
  };
}

function parseBbox(
  raw: string,
): { ok: true; bbox: Bbox } | { ok: false; error: ApiError } {
  const parts = raw.split(',');
  if (
    parts.length !== 4 ||
    !parts.every((part) => DECIMAL_PATTERN.test(part))
  ) {
    return refuse(
      'invalid_bbox',
      'bbox must be minLon,minLat,maxLon,maxLat in decimal degrees.',
    );
  }
  const [minLon, minLat, maxLon, maxLat] = parts.map(Number);
  if (![minLon, minLat, maxLon, maxLat].every(Number.isFinite)) {
    return refuse('invalid_bbox', 'bbox must be finite.');
  }
  if (
    minLon < -180 ||
    maxLon > 180 ||
    minLat < -90 ||
    maxLat > 90 ||
    minLon > maxLon ||
    minLat > maxLat
  ) {
    return refuse(
      'invalid_bbox',
      'bbox must be WGS84 with minLon <= maxLon and minLat <= maxLat. Boxes that cross the antimeridian are not supported.',
    );
  }
  if (
    maxLon - minLon > MAX_BBOX_SPAN_DEGREES ||
    maxLat - minLat > MAX_BBOX_SPAN_DEGREES
  ) {
    return refuse(
      'bbox_too_large',
      `bbox may span at most ${MAX_BBOX_SPAN_DEGREES} degrees in each direction. Omit bbox to page through the layer.`,
    );
  }
  return { ok: true, bbox: { minLon, minLat, maxLon, maxLat } };
}

function parseLimit(
  raw: string | null,
): { ok: true; limit: number } | { ok: false; error: ApiError } {
  if (raw === null) return { ok: true, limit: DEFAULT_PAGE_SIZE };
  if (!LIMIT_PATTERN.test(raw)) {
    return refuse(
      'invalid_limit',
      'limit must be a whole number from 1 to 200.',
    );
  }
  const limit = Number(raw);
  if (limit < 1)
    return refuse(
      'invalid_limit',
      'limit must be a whole number from 1 to 200.',
    );
  if (limit > MAX_PAGE_SIZE) {
    return refuse(
      'limit_too_large',
      `limit may be at most ${MAX_PAGE_SIZE}. Requests are not truncated.`,
    );
  }
  return { ok: true, limit };
}

export function encodeCursor(layerId: string, cursor: Cursor): string {
  return toBase64Url(
    JSON.stringify({
      v: CURSOR_VERSION,
      l: layerId,
      s: SORT_KEY,
      t: cursor.createdAt,
      i: cursor.id,
    }),
  );
}

// Returns null for any cursor that is malformed, tampered, or minted for another
// layer. The caller reports one error for all of them, so the response does not
// distinguish a cursor for a hidden layer from a cursor that was never valid.
export function decodeCursor(raw: string, layerId: string): Cursor | null {
  if (raw.length === 0 || raw.length > MAX_CURSOR_LENGTH) return null;
  const text = fromBase64Url(raw);
  if (text === null) return null;

  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload))
    return null;
  const fields = payload as Record<string, unknown>;
  if (Object.keys(fields).sort().join(',') !== 'i,l,s,t,v') return null;
  if (
    fields.v !== CURSOR_VERSION ||
    fields.s !== SORT_KEY ||
    fields.l !== layerId
  )
    return null;
  if (typeof fields.t !== 'string' || !isCalendarTimestamp(fields.t))
    return null;
  if (typeof fields.i !== 'string' || !UUID_PATTERN.test(fields.i)) return null;
  return { createdAt: fields.t, id: fields.i.toLowerCase() };
}

// The pattern checks shape only. The calendar and clock fields must also be real,
// so a value such as month 13 is refused here rather than failing the cast in SQL.
// PostgreSQL has no year 0 and displaces a timestamptz by at most 15:59. The shape
// check alone accepts both, and PostgreSQL then fails the cast with a server error.
// These bounds are the database's own, so a value that passes here casts there.
const MAX_OFFSET_HOURS = 15;
const MAX_OFFSET_MINUTES = 59;

function isCalendarTimestamp(value: string): boolean {
  const match = TIMESTAMP_PATTERN.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  if (year < 1 || month < 1 || month > 12) return false;
  if (day < 1 || day > daysInMonth(year, month)) return false;
  if (hour > 23 || minute > 59 || second > 59) return false;
  if (
    match[9] !== undefined &&
    (Number(match[9]) > MAX_OFFSET_HOURS ||
      Number(match[10]) > MAX_OFFSET_MINUTES)
  )
    return false;
  return true;
}

function daysInMonth(year: number, month: number): number {
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][
    month - 1
  ];
}

function toBase64Url(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function fromBase64Url(raw: string): string | null {
  if (!/^[A-Za-z0-9_-]+$/.test(raw) || raw.length % 4 === 1) return null;
  const base64 = raw.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}
