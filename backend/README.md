# Backend (Phase 4)

TypeScript API (Fastify + Zod) on Postgres 16 + TimescaleDB. It receives the collar's
per-minute summaries (contract 4.7) from the home base station or the phone, keeps one row
per collar per minute, computes each dog's daily metrics and baseline, and raises alerts.

## Run it

```bash
cd backend
docker compose up -d          # Postgres 16 + TimescaleDB on localhost:54329
npm install
cp .env.example .env          # then set JWT_SECRET
npm run migrate
npm run dev                   # http://localhost:3000/health
npm test                      # unit + integration tests (uses a throwaway database)
npm run typecheck
```

Self-hosting on the internet with HTTPS (Caddy + Let's Encrypt), nightly backups and restore:
[DEPLOY.md](DEPLOY.md) (`deploy/docker-compose.yml`).

## API

| Method | Path | Auth | What it does |
|---|---|---|---|
| GET | `/health` | — | liveness |
| POST | `/v1/auth/register` | — | `{email, password}` → `{token}` (JWT, 30 days) |
| POST | `/v1/auth/login` | — | `{email, password}` → `{token}` |
| POST | `/v1/dogs` | user | `{name, timezone, birth_date?, weight_kg?}` |
| PATCH | `/v1/dogs/:id` | user | edit the profile: `name, sex (male\|female), neutered, breed, birth_date, weight_kg, timezone` (null clears) |
| DELETE | `/v1/dogs/:id` | user | removes the dog with its collars, minutes, metrics and alerts |
| GET | `/v1/dogs` | user | the user's dogs |
| POST | `/v1/dogs/:id/devices` | user | pair a collar `{serial, name?}` → `{device_id, token}` (token shown once). Same collar on the same dog again (new phone): same row, new token. On another of the owner's dogs: new row from now, the old dog keeps its history. Another account's active collar: 409 |
| GET | `/v1/dogs/:id/devices` | user | the dog's active collars with last data minute and battery |
| DELETE | `/v1/devices/:id` | user | unpair: the token stops working, the minutes stay |
| POST | `/v1/ingest` | device | `{records: base64 of N × 15-byte records, via: base_station \| app}` → `{received, inserted, duplicates, rejected[]}` |
| GET | `/v1/dogs/:id/days/:day` | user | local day: totals per class, 15-min blocks, night wake-ups |
| GET | `/v1/dogs/:id/sleep/:day` | user | sleep estimated from movement: the night ending on `day` (bedtime, wake time, rest, awakenings, longest stretch, coverage) and that day's naps |
| GET | `/v1/dogs/:id/trends?days=30` | user | daily metrics (active, scratching, night wake-ups, coverage) |
| GET | `/v1/dogs/:id/alerts` | user | latest alerts |
| POST | `/v1/alerts/:id/feedback` | user | `{feedback: useful \| false_alarm}` |
| GET | `/v1/me` | user | account: email, accepted privacy notice version, research opt-in |
| PATCH | `/v1/me` | user | `{name}` |
| POST | `/v1/me/password` | user | `{current_password, new_password}` (10+ characters; rate-limited like login) |
| PUT | `/v1/me/consent` | user | `{version, research_opt_in}`: records consent (LGPD) with a timestamp |
| PUT | `/v1/me/push-token` | user | `{token, platform: android\|ios}`: this phone gets push notifications for new alerts (FCM; `DEPLOY.md`) |
| DELETE | `/v1/me/push-token` | user | `{token}`: stop notifying this phone (sign-out) |
| GET | `/v1/me/export` | user | all of the user's data as JSON (LGPD) |
| DELETE | `/v1/me` | user | deletes the account and everything under it (LGPD) |

Login and register are limited to 20 attempts per IP per 15 minutes (`TRUST_PROXY=true` behind
Caddy so the real client IP counts). User endpoints take `Authorization: Bearer <jwt>`; ingestion takes `Authorization: Bearer
dev_...`. A dog that is not yours is a 404, never a 403, so IDs reveal nothing.

## Design

- **Ingestion is idempotent:** primary key `(device_id, minute_ts)` with
  `ON CONFLICT DO NOTHING`. The base station and the phone can both upload the same minutes;
  retries are harmless. Each row records which path delivered it (`via`).
- **One decoder:** clients upload the collar's raw 15-byte records; only
  `src/summary.ts` interprets them, and bad records are rejected one by one with a reason.
- **Local time:** days and nights use the dog's IANA time zone.
- **Alerts** (ADR 0011, `src/metrics.ts`): daily totals vs median + MAD of the previous 28
  days of the same day type; robust |z| > 3; needs 14 complete days of history and a complete
  day. Runs inside the server every `ALERTS_EVERY_MIN` minutes or with `npm run job:alerts`.
  New alerts become push notifications when FCM is configured (`src/push.ts`, `DEPLOY.md`):
  sent once per alert (`alerts.notified_at`), lock-screen text without numbers, tokens FCM
  reports as gone are deleted.
- **Storage:** `activity_minute` is a TimescaleDB hypertable (7-day chunks) with an hourly
  continuous aggregate (`activity_hourly`). Migrations are plain SQL in `migrations/`.

## Not done yet

- Hourly "normal band" endpoint for the app's timeline (data is already aggregated).
