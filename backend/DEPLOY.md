# Putting the backend on the internet (HTTPS)

At home, the app can talk to the backend on your computer over the LAN
(`http://192.168.x.x:3000`). To use the app away from home, or to let the base station and
other people's phones reach it, the backend needs a public address with **HTTPS** (iOS refuses
plain HTTP outside the local network).

`backend/deploy/` runs everything with Docker Compose:

| Container | What it does |
|---|---|
| `db` | Postgres 16 + TimescaleDB. No public port |
| `api` | this backend (`Dockerfile`): migrations on start, alerts job every hour |
| `caddy` | HTTPS reverse proxy; gets and renews the Let's Encrypt certificate on its own |
| `backup` | `pg_dump` every night into `deploy/backups/`, keeps 14 days |
| `offsite` | optional: copies the dumps to S3-compatible object storage, encrypted on the server (step 5) |

Tested locally on 2026-11-17: image builds, migrations run, `/health` answers, register works,
the nightly dump restores into an empty database (steps below).

## 1. A server

Any Linux VPS with 1 vCPU, 1 GB RAM and 20 GB disk is plenty for tens of dogs (a dog is
~21 KB of data per day). Examples: Hetzner CX22, Oracle Cloud free tier (Ampere), DigitalOcean,
Magalu Cloud. A Raspberry Pi 4 at home also works if your router can forward ports 80 and 443.

**Oracle Cloud, step by step (free ARM VM, encrypted backups in Object Storage, one setup
script):** [DEPLOY-ORACLE.md](DEPLOY-ORACLE.md).

Install Docker:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out and back in
```

Open ports **80** and **443** (TCP, plus 443/UDP for HTTP/3) in the provider's firewall.
Port 80 is needed: Let's Encrypt checks the domain through it.

## 2. A domain name

Create a DNS **A record** (and AAAA for IPv6) pointing a name at the server's IP, e.g.
`collar.yourdomain.com`. No domain? A free subdomain from DuckDNS (`yourname.duckdns.org`)
works. Wait until `ping collar.yourdomain.com` answers with the server's IP.

## 3. Start it

```bash
git clone https://github.com/Gustavo-Patrocinio/coleira-inteligente.git
cd coleira-inteligente/backend/deploy
cp .env.example .env
nano .env        # DOMAIN=collar.yourdomain.com, and two secrets: openssl rand -hex 32
docker compose up -d --build
docker compose logs -f caddy     # wait for "certificate obtained successfully"
curl https://collar.yourdomain.com/health    # {"ok":true}
```

On the phone's login screen, use `https://collar.yourdomain.com` as the server.

## 4. Updating

```bash
cd coleira-inteligente && git pull
cd backend/deploy && docker compose up -d --build api
```

Migrations run when the api starts; they are additive and run once.

## 5. Backups and restore

Dumps land in `backend/deploy/backups/collar-YYYY-MM-DD.dump`. A backup only on the same
server is not a backup: the `offsite` container copies them to any S3-compatible storage
(Oracle Object Storage, Backblaze B2, Cloudflare R2, AWS S3...), **encrypted on the server**
with `BACKUP_PASSPHRASE` (rclone crypt), every 6 hours, keeping 14 days like the local dumps (`OFFSITE_KEEP_DAYS`; the privacy
policy promises 14).
Fill in the `BACKUP_PASSPHRASE` and `S3_*` lines of `.env` (keep the passphrase in a password
manager too: without it the copies cannot be read) and start with the profile:

```bash
docker compose --profile offsite up -d
docker compose logs offsite                     # offsite: copy ok (N dumps stored)
docker compose run --rm offsite lsl safe:       # list the stored copies
docker compose run --rm offsite copy safe:collar-2026-11-17.dump /backups/   # bring one back
```

Oracle Cloud specifics (bucket, keys, endpoint): [DEPLOY-ORACLE.md](DEPLOY-ORACLE.md), step 5.

Restore into a fresh database (TimescaleDB needs the pre/post restore calls):

```bash
docker compose exec db psql -U collar -c "CREATE DATABASE restored"
docker compose exec db psql -U collar -d restored -c "SELECT timescaledb_pre_restore();"
docker compose cp backups/collar-2026-11-17.dump db:/tmp/b.dump
docker compose exec db pg_restore -U collar -d restored /tmp/b.dump
docker compose exec db psql -U collar -d restored -c "SELECT timescaledb_post_restore();"
```

Then point `DATABASE_URL` at `restored` (or rename the databases) and restart `api`.
`pg_dump` prints warnings about circular foreign keys on TimescaleDB's catalog tables; they
are expected and the restore above handles them.

## 6. Push notifications (optional)

Without this, alerts still show in the app; with it, the owner's phone also gets a
notification when an alert is created. The server talks to Firebase Cloud Messaging (FCM)
directly; nothing is sent to Firebase except the phone's token and the lock-screen text
("Thor scratched more than usual", no numbers).

1. In the [Firebase console](https://console.firebase.google.com), create a project (free).
2. Project settings → Service accounts → **Generate new private key**: a JSON file.
3. On the server, in `backend/deploy/`: `mkdir -p secrets`, copy the file to
   `secrets/fcm.json`, `chmod 600 secrets/fcm.json`, and add to `.env`:
   `FCM_SERVICE_ACCOUNT_FILE=/secrets/fcm.json`.
4. `docker compose up -d`. The log says `push notifications on (FCM)`.

The app must be built against the same Firebase project (`app/README.md`, *Push
notifications*). Treat the JSON like a password: anyone holding it can send notifications to
your users. It is not in git (`secrets/` is ignored).

## 7. Email: password reset (optional)

Without it, someone who forgets their password cannot get back in on their own (the app says
the server cannot send email, and you would have to change it for them in the database). With
it, the app's *Forgot password?* emails a 6-digit code that lasts 15 minutes.

1. An SMTP provider: any works (many have a free tier of a few hundred emails a day, plenty
   here). Verify the sender address it asks you to, and copy its SMTP host, port, user and
   password (often an "SMTP key", not your login password).
2. In `deploy/.env`:

   ```
   SMTP_URL=smtps://<user>:<password>@<host>:465
   MAIL_FROM=Smart Collar <the-verified-sender@example.com>
   ```

   Port 587 instead of 465: `smtp://...:587` (STARTTLS). Characters like `@` or `:` inside the
   user or password must be URL-encoded (`@` → `%40`).
3. `docker compose --profile offsite up -d api`. The log says `password reset by email on
   (SMTP)`. Try it from the app's sign-in screen with your own account.

The provider sees the recipient's email address and the code (privacy policy, *Who else sees
it*).

## 8. Security checklist

- [ ] `.env` has long random `POSTGRES_PASSWORD` and `JWT_SECRET` (never commit it; changing
      `JWT_SECRET` logs everyone out)
- [ ] Only ports 22, 80 and 443 open; SSH with keys, password login off
- [ ] Dependencies without known vulnerabilities: `npm audit --omit=dev` in `backend/` (CI
      fails on high/critical ones; Dependabot opens update PRs)
- [ ] Unattended OS security updates on (`sudo apt install unattended-upgrades`)
- [ ] Off-site backups on (`--profile offsite`), the passphrase saved outside the server,
      and a restore tested once
- [ ] If other people use your instance: the privacy notice and consent in the app (LGPD),
      and `DELETE /v1/me` works for them (it deletes the account and all its data)
