// Integration checks for the replay-vault Worker.
//
// Covers the two behaviour changes added for the in-game viewer:
//   - `/list` now requires X-API-Key (UUID enumeration guard)
//   - X-Tickrate is validated, stored in D1 and returned by `/replay/{uuid}?meta=1`
//
// Run with: npm test
import assert from "node:assert/strict";
import worker from "../src/index.js";

const API_KEY = "test-key";
const uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5";
const key = `kz_test/runs/main/76561198123456789/kzt/pro/2025.08.24.14.30.45_${uuid}.replay`;

const objects = new Map();
const rows = new Map();

const REPLAYS = {
  async put(k, body, opts) { objects.set(k, { body, opts }); },
  async get(k) { return objects.get(k) || null; },
  async head(k) { return objects.get(k) || null; },
  async delete(k) { objects.delete(k); },
};

function prepare(sql) {
  const state = { sql, args: [] };
  const api = {
    bind(...args) { state.args = args; return api; },
    async first() {
      if (/SELECT \* FROM replays WHERE uuid/.test(state.sql)) {
        return rows.get(state.args[0]);
      }
      return undefined;
    },
    async run() {
      if (/INSERT OR IGNORE INTO replays/.test(state.sql)) {
        const cols = ["uuid", "key", "map", "category", "course", "course_str",
          "steamid64", "mode", "timetype", "jumptype", "block", "reason", "date",
          "timestamp", "time_ms", "tickrate", "sha256", "size", "created_at"];
        const row = {};
        cols.forEach((column, index) => { row[column] = state.args[index]; });
        if (!rows.has(row.uuid)) rows.set(row.uuid, row);
      }
      return { meta: { changes: 1 } };
    },
    async all() {
      return { results: [...rows.values()] };
    },
  };
  return api;
}

const env = { API_KEY, REPLAYS, DB: { prepare }, ALLOWED_ORIGIN: "*" };
const base = "https://worker.test";

// /list without the API key must be rejected.
let res = await worker.fetch(new Request(`${base}/list?steamid64=76561198123456789`), env);
assert.equal(res.status, 401, "list without key must be rejected");

// /list with the API key must succeed.
res = await worker.fetch(new Request(`${base}/list?steamid64=76561198123456789`, {
  headers: { "X-API-Key": API_KEY },
}), env);
assert.equal(res.status, 200, "list with key must succeed");

// Upload carrying X-Tickrate.
const body = new Uint8Array([0x7a, 0x6b, 0x6f, 0x67, 2, 0, 0, 0]);
const headers = {
  "X-API-Key": API_KEY,
  "X-UUID": uuid,
  "X-Key": key,
  "X-Map": "kz_test",
  "X-Course": "0",
  "X-Mode": "kzt",
  "X-TimeType": "pro",
  "X-Time-Ms": "83450",
  "X-Date": "2025.08.24.14.30.45",
  "X-SteamID64": "76561198123456789",
  "X-Replay-Type": "run",
  "X-Tickrate": "128",
};
res = await worker.fetch(new Request(`${base}/upload`, { method: "POST", headers, body }), env);
assert.equal(res.status, 201, `upload should be created, got ${res.status}`);

// Metadata exposes the stored tickrate.
res = await worker.fetch(new Request(`${base}/replay/${uuid}?meta=1`, {
  headers: { "X-API-Key": API_KEY },
}), env);
assert.equal(res.status, 200);
const meta = await res.json();
assert.equal(meta.tickrate, 128, `meta.tickrate should be 128, got ${meta.tickrate}`);
assert.equal(meta.map, "kz_test");

// /list returns the row including tickrate.
res = await worker.fetch(new Request(`${base}/list?steamid64=76561198123456789`, {
  headers: { "X-API-Key": API_KEY },
}), env);
const list = await res.json();
assert.equal(list.count, 1);
assert.equal(list.items[0].tickrate, 128);

// Out-of-range tickrate is rejected.
res = await worker.fetch(new Request(`${base}/upload`, {
  method: "POST",
  headers: {
    ...headers,
    "X-UUID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "X-Key": key.replace(uuid, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
    "X-Tickrate": "0",
  },
  body,
}), env);
assert.equal(res.status, 400, "tickrate 0 must be rejected");

console.log("worker integration checks: OK");
