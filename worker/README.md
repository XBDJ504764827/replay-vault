# replay-vault Worker

This Worker accepts the upload protocol used by the SourceMod plugin, stores
replays in a private R2 bucket, and indexes metadata in D1.

## Required Cloudflare resources

- One R2 bucket for replay objects.
- One D1 database for the `replays` table.
- One Worker secret named `API_KEY`.

The API key must be the same value as `replay_vault_key` in
`cfg/sourcemod/replay-vault.cfg`.

If the D1 table was created from an older version of the project documentation,
run `PRAGMA table_info(replays);` in the D1 Console. If `category` is missing,
run `migration-from-legacy.sql` once. The current Worker also writes an empty
`course_str` for jumps and cheats, so legacy `course_str NOT NULL` tables remain
compatible.

## Wrangler deployment

1. Install Node.js 18+ and run `npm install` in this directory.
2. Run `npx wrangler login`.
3. Create resources if they do not exist:

```sh
npx wrangler r2 bucket create replay-vault
npx wrangler d1 create replay-vault-db
```

4. Put the returned bucket name, D1 database name, and D1 database ID into
   `wrangler.toml`.
5. Initialize D1:

```sh
npx wrangler d1 execute replay-vault-db --remote --file=schema.sql
```

6. Set the upload secret and deploy:

```sh
npx wrangler secret put API_KEY
npx wrangler deploy
```

7. Set the Worker URL and the same API key in the SourceMod config:

```cfg
replay_vault_url "https://replay-vault.<your-subdomain>.workers.dev"
replay_vault_key "<the same API_KEY>"
```

## HTTP endpoints

- `GET /health` checks that the Worker is reachable.
- `POST /` or `POST /upload` receives a replay body.
- `GET /replay/{uuid}` downloads a replay from private R2.
- `GET /replay/{uuid}?meta=1` returns indexed metadata.
- `GET /list?map=...&steamid64=...&prefix=...&limit=100` lists metadata.

The Worker computes SHA-256 itself when the plugin does not send `X-SHA256`.
The scheduled trigger deletes D1 rows older than three days. Configure an R2
lifecycle rule with an empty prefix and three-day expiration separately in the
Cloudflare R2 dashboard so objects and D1 rows have the same retention.

## Dashboard-only deployment

Create a Worker in the Cloudflare dashboard and paste `src/index.js` into its
editor. Add an R2 binding named `REPLAYS`, a D1 binding named `DB`, a secret
named `API_KEY`, and variables `ALLOWED_ORIGIN` and `MAX_UPLOAD_BYTES`. Execute
`schema.sql` against the D1 database, then add the `0 0 * * *` cron trigger.
