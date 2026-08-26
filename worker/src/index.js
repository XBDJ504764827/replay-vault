const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_RE = /^[0-9a-f]{64}$/i;
const SAFE_SEGMENT_RE = /^(?!\.{1,2}$)[a-z0-9_.-]{1,128}$/;
const DATE_RE = /^\d{4}(?:\.\d{2}){5}$/;
const UUID_FILENAME_RE = /^(\d{4}(?:\.\d{2}){5})_([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.replay$/i;
const MODE_RE = /^(kzt|skz|vnl)$/;
const MAX_KEY_LENGTH = 1024;
const DEFAULT_MAX_UPLOAD_BYTES = 50 * 1024 * 1024;
const RETENTION_SECONDS = 3 * 24 * 60 * 60;

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function allowedOrigin(env) {
  return env.ALLOWED_ORIGIN || "*";
}

function corsHeaders(env, extra = {}) {
  return {
    "Access-Control-Allow-Origin": allowedOrigin(env),
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type,X-API-Key,X-UUID,X-Key,X-Map,X-Course,X-SteamID64,X-Mode,X-TimeType,X-Date,X-Time-Ms,X-Timestamp,X-SHA256,X-Replay-Type",
    "Access-Control-Expose-Headers": "Content-Length,Content-Disposition,ETag",
    "Access-Control-Max-Age": "86400",
    ...extra,
  };
}

function json(env, value, status = 200, extra = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: corsHeaders(env, {
      "Content-Type": "application/json; charset=utf-8",
      ...extra,
    }),
  });
}

function requireBinding(env, name) {
  if (!env[name]) {
    throw new HttpError(500, "configuration_error", `Missing binding: ${name}`);
  }
  return env[name];
}

function safeEqual(left, right) {
  const a = String(left);
  const b = String(right);
  let difference = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i += 1) {
    difference |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return difference === 0;
}

function authenticateUpload(request, env) {
  if (!env.API_KEY) {
    throw new HttpError(500, "configuration_error", "API_KEY secret is not configured");
  }
  const supplied = request.headers.get("X-API-Key") || "";
  if (!safeEqual(supplied, env.API_KEY)) {
    throw new HttpError(401, "unauthorized", "Invalid API key");
  }
}

function header(request, name, required = true) {
  const value = (request.headers.get(name) || "").trim();
  if (required && value === "") {
    throw new HttpError(400, "missing_header", `Missing header: ${name}`);
  }
  return value;
}

function parseInteger(value, name, min = null, max = null) {
  if (!/^-?\d+$/.test(value)) {
    throw new HttpError(400, "invalid_header", `Invalid integer header: ${name}`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || (min !== null && parsed < min) || (max !== null && parsed > max)) {
    throw new HttpError(400, "invalid_header", `Out-of-range header: ${name}`);
  }
  return parsed;
}

function parseReplayKey(key, uuid) {
  if (key.length === 0 || key.length > MAX_KEY_LENGTH || key !== key.toLowerCase()) {
    throw new HttpError(400, "invalid_key", "Invalid X-Key");
  }

  const parts = key.split("/");
  if (parts.some((part) => !SAFE_SEGMENT_RE.test(part))) {
    throw new HttpError(400, "invalid_key", "Invalid characters in X-Key");
  }

  const fileName = parts[parts.length - 1];
  const fileMatch = fileName.match(UUID_FILENAME_RE);
  if (!fileMatch || fileMatch[2].toLowerCase() !== uuid) {
    throw new HttpError(400, "invalid_key", "X-Key filename does not match X-UUID");
  }

  const base = { map: parts[0], date: fileMatch[1], uuid };
  if (!SAFE_SEGMENT_RE.test(base.map) || !DATE_RE.test(base.date)) {
    throw new HttpError(400, "invalid_key", "Invalid map or date in X-Key");
  }

  if (parts[1] === "runs" && parts.length === 7) {
    const [, , courseStr, steamid64, mode, timetype] = parts;
    if (!/^main$|^b[1-9][0-9]*$/.test(courseStr) || !/^\d{17,20}$/.test(steamid64)
      || !MODE_RE.test(mode) || !/^(pro|nub)$/.test(timetype)) {
      throw new HttpError(400, "invalid_key", "Invalid runs key structure");
    }
    return { ...base, category: "run", courseStr, steamid64, mode, timetype,
      jumptype: null, block: null, reason: null };
  }

  if (parts[1] === "jumps" && (parts.length === 6 || parts.length === 7)) {
    const [, , steamid64, mode, jumptype] = parts;
    if (!/^\d{17,20}$/.test(steamid64) || !MODE_RE.test(mode)
      || !SAFE_SEGMENT_RE.test(jumptype)) {
      throw new HttpError(400, "invalid_key", "Invalid jumps key structure");
    }
    let block = null;
    if (parts.length === 7) {
      const blockMatch = parts[5].match(/^block_([1-9][0-9]*)$/);
      if (!blockMatch) throw new HttpError(400, "invalid_key", "Invalid jump block");
      block = Number(blockMatch[1]);
    }
    return { ...base, category: "jump", courseStr: null, steamid64, mode,
      timetype: "jump", jumptype, block, reason: null };
  }

  if (parts[1] === "cheaters" && parts.length === 6) {
    const [, , steamid64, mode, reason] = parts;
    if (!/^\d{17,20}$/.test(steamid64) || !MODE_RE.test(mode)
      || !SAFE_SEGMENT_RE.test(reason)) {
      throw new HttpError(400, "invalid_key", "Invalid cheaters key structure");
    }
    return { ...base, category: "cheat", courseStr: null, steamid64, mode,
      timetype: "cheat", jumptype: null, block: null, reason };
  }

  throw new HttpError(400, "invalid_key", "Unsupported X-Key structure");
}

function parseUploadMetadata(request) {
  const uuid = header(request, "X-UUID").toLowerCase();
  if (!UUID_V4_RE.test(uuid)) {
    throw new HttpError(400, "invalid_uuid", "X-UUID must be a UUIDv4");
  }

  const key = header(request, "X-Key");
  const parsedKey = parseReplayKey(key, uuid);
  const map = header(request, "X-Map");
  const steamid64 = header(request, "X-SteamID64");
  const mode = header(request, "X-Mode").toLowerCase();
  const timeType = header(request, "X-TimeType").toLowerCase();
  const date = header(request, "X-Date");
  const replayType = (request.headers.get("X-Replay-Type") || "").trim().toLowerCase();

  if (map !== parsedKey.map || !SAFE_SEGMENT_RE.test(map)) {
    throw new HttpError(400, "metadata_mismatch", "X-Map does not match X-Key");
  }
  if (steamid64 !== parsedKey.steamid64) {
    throw new HttpError(400, "metadata_mismatch", "X-SteamID64 does not match X-Key");
  }
  if (mode !== parsedKey.mode || !MODE_RE.test(mode)) {
    throw new HttpError(400, "metadata_mismatch", "X-Mode does not match X-Key");
  }
  if (date !== parsedKey.date) {
    throw new HttpError(400, "metadata_mismatch", "X-Date does not match X-Key");
  }
  if (replayType !== "" && replayType !== parsedKey.category) {
    throw new HttpError(400, "metadata_mismatch", "X-Replay-Type does not match X-Key");
  }

  let course = -1;
  let courseStr = parsedKey.courseStr;
  if (parsedKey.category === "run") {
    course = parseInteger(header(request, "X-Course"), "X-Course", 0, 99);
    const expectedCourseStr = course === 0 ? "main" : `b${course}`;
    if (expectedCourseStr !== parsedKey.courseStr) {
      throw new HttpError(400, "metadata_mismatch", "X-Course does not match X-Key");
    }
    if (timeType !== parsedKey.timetype) {
      throw new HttpError(400, "metadata_mismatch", "X-TimeType does not match X-Key");
    }
  } else {
    course = parseInteger(header(request, "X-Course"), "X-Course", -1, -1);
    courseStr = null;
    if (timeType !== parsedKey.timetype) {
      throw new HttpError(400, "metadata_mismatch", "X-TimeType does not match replay type");
    }
  }

  const timeMs = parseInteger(header(request, "X-Time-Ms"), "X-Time-Ms", 0, 2147483647);
  const timestampHeader = request.headers.get("X-Timestamp");
  const timestamp = timestampHeader
    ? parseInteger(timestampHeader.trim(), "X-Timestamp", 0, 4102444800)
    : Math.floor(Date.now() / 1000);
  const suppliedSha256 = (request.headers.get("X-SHA256") || "").trim().toLowerCase();
  if (suppliedSha256 !== "" && !SHA256_RE.test(suppliedSha256)) {
    throw new HttpError(400, "invalid_sha256", "Invalid X-SHA256");
  }

  return { ...parsedKey, key, map, course, courseStr: courseStr || "", steamid64, mode,
    timetype: timeType, timeMs, timestamp, suppliedSha256 };
}

function maxUploadBytes(env) {
  const configured = Number(env.MAX_UPLOAD_BYTES || DEFAULT_MAX_UPLOAD_BYTES);
  if (!Number.isSafeInteger(configured) || configured < 1) return DEFAULT_MAX_UPLOAD_BYTES;
  return Math.min(configured, 200 * 1024 * 1024);
}

async function readBody(request, limit) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > limit) {
    throw new HttpError(413, "payload_too_large", "Replay is larger than MAX_UPLOAD_BYTES");
  }
  if (!request.body) throw new HttpError(400, "empty_body", "Replay body is empty");

  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        await reader.cancel();
        throw new HttpError(413, "payload_too_large", "Replay is larger than MAX_UPLOAD_BYTES");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (total === 0) throw new HttpError(400, "empty_body", "Replay body is empty");

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

async function sha256Hex(body) {
  const digest = await crypto.subtle.digest("SHA-256", body.buffer);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function findReplay(env, uuid) {
  const db = requireBinding(env, "DB");
  return db.prepare("SELECT * FROM replays WHERE uuid = ?1").bind(uuid).first();
}

function rowMetadata(row) {
  return {
    exists: true,
    uuid: row.uuid,
    key: row.key,
    map: row.map,
    category: row.category,
    course: row.course,
    course_str: row.course_str,
    steamid64: row.steamid64,
    mode: row.mode,
    timetype: row.timetype,
    jumptype: row.jumptype,
    block: row.block,
    reason: row.reason,
    date: row.date,
    timestamp: row.timestamp,
    time_ms: row.time_ms,
    sha256: row.sha256,
    size: row.size,
    created_at: row.created_at,
  };
}

async function handleUpload(request, env) {
  authenticateUpload(request, env);
  requireBinding(env, "REPLAYS");

  const metadata = parseUploadMetadata(request);
  const body = await readBody(request, maxUploadBytes(env));
  const sha256 = await sha256Hex(body);
  if (metadata.suppliedSha256 && metadata.suppliedSha256 !== sha256) {
    throw new HttpError(400, "sha256_mismatch", "X-SHA256 does not match request body");
  }

  const existing = await findReplay(env, metadata.uuid);
  if (existing) {
    if (existing.key === metadata.key && existing.sha256 === sha256) {
      const existingObject = await env.REPLAYS.head(existing.key);
      if (existingObject) {
        return json(env, { stored: false, uuid: metadata.uuid, key: existing.key,
          sha256, size: existing.size }, 200);
      }
    }
    if (existing.key !== metadata.key || existing.sha256 !== sha256) {
      throw new HttpError(409, "uuid_conflict", "UUID already exists with different content");
    }
  }

  const customMetadata = {
    uuid: metadata.uuid,
    category: metadata.category,
    map: metadata.map,
    course: String(metadata.course),
    course_str: metadata.courseStr || "",
    steamid64: metadata.steamid64,
    mode: metadata.mode,
    timetype: metadata.timetype,
    jumptype: metadata.jumptype || "",
    block: metadata.block === null ? "" : String(metadata.block),
    reason: metadata.reason || "",
    date: metadata.date,
    timestamp: String(metadata.timestamp),
    time_ms: String(metadata.timeMs),
    sha256,
    size: String(body.byteLength),
  };

  const bucket = env.REPLAYS;
  await bucket.put(metadata.key, body.buffer, {
    httpMetadata: {
      contentType: "application/octet-stream",
      contentDisposition: `attachment; filename="${metadata.uuid}.replay"`,
    },
    customMetadata,
  });

  const createdAt = new Date().toISOString();
  try {
    const result = await env.DB.prepare(`
      INSERT OR IGNORE INTO replays
      (uuid, key, map, category, course, course_str, steamid64, mode, timetype,
       jumptype, block, reason, date, timestamp, time_ms, sha256, size, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      metadata.uuid, metadata.key, metadata.map, metadata.category, metadata.course,
      metadata.courseStr, metadata.steamid64, metadata.mode, metadata.timetype,
      metadata.jumptype, metadata.block, metadata.reason, metadata.date,
      metadata.timestamp, metadata.timeMs, sha256, body.byteLength, createdAt,
    ).run();

    const inserted = Number(result.meta?.changes || 0) > 0;
    const row = await findReplay(env, metadata.uuid);
    if (!row || row.key !== metadata.key || row.sha256 !== sha256) {
      throw new Error("D1 row does not match uploaded replay");
    }

    return json(env, {
      stored: inserted,
      uuid: metadata.uuid,
      key: metadata.key,
      sha256,
      size: body.byteLength,
    }, inserted ? 201 : 200);
  } catch (error) {
    await bucket.delete(metadata.key);
    throw error;
  }
}

function uuidFromPath(pathname) {
  const parts = pathname.split("/").filter(Boolean);
  if (parts.length !== 2 || parts[0] !== "replay") {
    throw new HttpError(404, "not_found", "Replay route not found");
  }
  let uuid;
  try {
    uuid = decodeURIComponent(parts[1]).toLowerCase();
  } catch {
    throw new HttpError(400, "invalid_uuid", "Invalid UUID encoding");
  }
  if (!UUID_V4_RE.test(uuid)) throw new HttpError(400, "invalid_uuid", "Invalid UUID");
  return uuid;
}

async function handleReplay(request, env) {
  const uuid = uuidFromPath(new URL(request.url).pathname);
  const row = await findReplay(env, uuid);
  if (!row) return json(env, { exists: false, uuid }, 404);

  const url = new URL(request.url);
  if (url.searchParams.get("meta") === "1" || url.searchParams.get("meta") === "true") {
    return json(env, rowMetadata(row));
  }

  const bucket = requireBinding(env, "REPLAYS");
  const object = await bucket.get(row.key);
  if (!object) return json(env, { exists: true, available: false, uuid, key: row.key }, 404);

  const headers = new Headers(corsHeaders(env));
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Content-Type", "application/octet-stream");
  headers.set("Content-Disposition", `attachment; filename="${uuid}.replay"`);
  headers.set("X-Replay-UUID", uuid);
  return new Response(object.body, { status: 200, headers });
}

function escapeLikePrefix(value) {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`) + "%";
}

async function handleList(request, env) {
  const db = requireBinding(env, "DB");
  const url = new URL(request.url);
  const map = (url.searchParams.get("map") || "").trim().toLowerCase();
  const steamid64 = (url.searchParams.get("steamid64") || "").trim();
  const prefix = (url.searchParams.get("prefix") || "").trim().toLowerCase();
  const limit = parseInteger(url.searchParams.get("limit") || "100", "limit", 1, 100);

  const conditions = [];
  const values = [];
  if (map !== "") {
    if (!SAFE_SEGMENT_RE.test(map)) throw new HttpError(400, "invalid_query", "Invalid map");
    conditions.push("map = ?");
    values.push(map);
  }
  if (steamid64 !== "") {
    if (!/^\d{17,20}$/.test(steamid64)) throw new HttpError(400, "invalid_query", "Invalid steamid64");
    conditions.push("steamid64 = ?");
    values.push(steamid64);
  }
  if (prefix !== "") {
    if (prefix.length > MAX_KEY_LENGTH || !/^[a-z0-9._/-]+$/.test(prefix)) {
      throw new HttpError(400, "invalid_query", "Invalid prefix");
    }
    conditions.push("key LIKE ? ESCAPE '\\'");
    values.push(escapeLikePrefix(prefix));
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
  const result = await db.prepare(`
    SELECT uuid, key, map, category, course, course_str, steamid64, mode, timetype,
           jumptype, block, reason, date, timestamp, time_ms, sha256, size, created_at
    FROM replays ${where} ORDER BY timestamp DESC LIMIT ?
  `).bind(...values, limit).all();
  return json(env, { items: result.results || [], count: result.results?.length || 0, limit });
}

async function cleanup(env) {
  const db = requireBinding(env, "DB");
  const cutoff = Math.floor(Date.now() / 1000) - RETENTION_SECONDS;
  const result = await db.prepare("DELETE FROM replays WHERE timestamp < ?").bind(cutoff).run();
  console.log(JSON.stringify({ event: "cleanup", cutoff, deleted: result.meta?.changes || 0 }));
}

async function fetchHandler(request, env) {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(env) });

  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/health") {
    const ready = Boolean(env.API_KEY && env.REPLAYS && env.DB);
    return json(env, { ok: true, ready, service: "replay-vault" }, ready ? 200 : 503);
  }
  if (request.method === "POST" && (url.pathname === "/" || url.pathname === "/upload")) {
    return handleUpload(request, env);
  }
  if (request.method === "GET" && url.pathname.startsWith("/replay/")) {
    return handleReplay(request, env);
  }
  if (request.method === "GET" && url.pathname === "/list") {
    return handleList(request, env);
  }
  return json(env, { error: "not_found", message: "Route not found" }, 404);
}

export default {
  async fetch(request, env) {
    try {
      return await fetchHandler(request, env);
    } catch (error) {
      if (error instanceof HttpError) {
        console.error(JSON.stringify({ error: error.code, message: error.message }));
        return json(env, { error: error.code, message: error.message }, error.status);
      }
      console.error(error);
      return json(env, { error: "internal_error", message: "Internal server error" }, 500);
    }
  },

  async scheduled(_event, env) {
    await cleanup(env);
  },
};
