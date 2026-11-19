# The backend on Oracle Cloud (free Ampere VM)

A concrete walk-through of [DEPLOY.md](DEPLOY.md) on Oracle Cloud Infrastructure (OCI):
an Always Free ARM VM runs the whole stack (database, API, HTTPS, nightly backups) and an
encrypted copy of the backups goes to OCI Object Storage. Cost: R$ 0 inside the Always Free
limits (Ampere A1 up to 4 OCPU / 24 GB in total, 200 GB of disks, 20 GB of Object Storage).

> **Status (2026-11-18):** done end to end on a real VM (A1.Flex, 2 OCPU / 12 GB, Ubuntu
> 24.04 aarch64): the script set everything up, Caddy got the certificate, register / me /
> delete worked over HTTPS and the first nightly dump was written. The off-site copy was
> on since the same day: the first dump reached Object Storage encrypted and downloaded back
> byte for byte.

## 1. Create the VM

Console → Compute → Instances → **Create instance**:

| Field | Value |
|---|---|
| Name | `collar-backend` |
| Image | **Canonical Ubuntu 24.04** (not Minimal), aarch64 |
| Shape | Ampere → **VM.Standard.A1.Flex**, 1–2 OCPU, 6–12 GB, burstable off |
| Networking | existing VCN and public subnet, **Assign a public IPv4 address** on |
| SSH keys | *Generate a key pair for me* → **Save private key** (keep it safe) |
| Boot volume | default (~47 GB) |

The cost estimate on the review page ignores the free tier; Always Free shapes are not billed.

*Out of capacity for shape VM.Standard.A1.Flex* is common: retry later (early morning works
best) or with 1 OCPU / 6 GB, which is plenty (DEPLOY.md, *A server*). Pay As You Go accounts
get capacity much more easily and still pay nothing inside the Always Free limits; set a
budget alert first (Billing → Budgets, R$ 1).

## 2. Open ports 80 and 443

Instance page → the subnet link → **Security Lists** → the default list → **Add Ingress
Rules**:

| Source CIDR | Protocol | Destination port |
|---|---|---|
| `0.0.0.0/0` | TCP | `80` |
| `0.0.0.0/0` | TCP | `443` |
| `0.0.0.0/0` | UDP | `443` (HTTP/3, optional) |

Port 80 must be open: Let's Encrypt checks the domain through it. The VM's own firewall is
handled by the setup script (step 4).

## 3. A domain name

No domain of your own? **sslip.io** turns the IP into a name with no sign-up: for the public
IP `203.0.113.7` the name is `203-0-113-7.sslip.io`. It works for HTTPS. If you later buy a
domain, point an A record at the IP, change `DOMAIN` in `.env` and restart Caddy. The app's
server address changes too, so every phone has to sign in again with the new address.

## 4. Install and start

From your computer (Windows PowerShell, macOS or Linux), with the key from step 1:

```bash
ssh -i path/to/ssh-key.key ubuntu@203.0.113.7
```

On Windows, if ssh says the key's permissions are too open:
`icacls path\to\ssh-key.key /inheritance:r /grant:r "$env:USERNAME:R"`.

On the VM:

```bash
git clone https://github.com/Gustavo-Patrocinio/coleira-inteligente.git
cd coleira-inteligente/backend/deploy
bash setup-ubuntu.sh 203-0-113-7.sslip.io
```

The script installs Docker, opens 80/443 in the VM's firewall, turns on automatic security
updates, writes `.env` with new random secrets, builds and starts everything, and waits for
`https://<domain>/health`. It ends with **OK** and the address to type in the app.

Log out and back in once (so `docker` works without `sudo`), then:

```bash
cd ~/coleira-inteligente/backend/deploy
docker compose ps                 # db, api, caddy, backup: running / healthy
docker compose logs -f api        # Ctrl+C to leave
```

In the app: **Server** = `https://203-0-113-7.sslip.io`, then create the account as usual.

## 5. Encrypted backups in Object Storage

The `backup` container already dumps the database every night into `deploy/backups/`. The
`offsite` container copies each dump to Object Storage, **encrypted on the VM** with a
passphrase only you have, and deletes copies older than 14 days (the retention the privacy policy states).

1. **Bucket:** Console → Storage → Buckets → *Create bucket*. Name `collar-backups`, Standard
   tier, in the **root compartment** (the S3-compatible API looks there by default).
   Visibility stays **private**.
2. **Namespace and region:** on the bucket page, *Namespace* (a short random string). The
   region of São Paulo is `sa-saopaulo-1`.
3. **Access key:** your profile (top right) → *User settings* → *Tokens and keys* →
   **Customer secret keys** → *Generate secret key*, name `collar-backup`. Copy the
   **secret** now (shown once); the **access key** is the id in the list afterwards.
4. **Passphrase:** make one (`openssl rand -base64 24`) and save it in your password
   manager **before** going on. Without it the off-site copies cannot be read, by anyone.
5. On the VM, put the bucket settings in `.env` (`nano .env`; they are not secret):

   ```
   S3_ENDPOINT=https://<namespace>.compat.objectstorage.sa-saopaulo-1.oraclecloud.com
   S3_REGION=sa-saopaulo-1
   S3_BUCKET=collar-backups
   ```

   and the three secrets with `bash offsite-keys.sh`: it asks for the access key, the secret
   and the passphrase (twice) without showing them, and writes them into `.env`.

6. Start it and check:

   ```bash
   docker compose --profile offsite up -d
   docker compose logs offsite          # "offsite: copy ok (1 dumps stored)"
   docker compose run --rm offsite lsl safe:
   ```

   The first dump is made when the `backup` container starts, so there is something to copy
   right away. In the console the bucket shows `collar/collar-YYYY-MM-DD.dump.bin`: encrypted.

From now on, start the stack with `docker compose --profile offsite up -d` (also after
`git pull`), or the off-site copies stop.

**Restore drill (do it once):** bring a dump back from Object Storage and restore it into a
scratch database as in DEPLOY.md, *Backups and restore*:

```bash
docker compose run --rm offsite copy safe:collar-2026-11-18.dump /backups/
```

**The VM is gone:** create a new one (steps 1–4), put the same `BACKUP_PASSPHRASE` and S3
settings in `.env`, copy the newest dump back as above and restore it into the `collar`
database (DEPLOY.md). The phones keep working once the domain points at the new VM.

## 6. Day to day

| Task | Command (in `backend/deploy`) |
|---|---|
| Update to the latest code | `git pull && docker compose --profile offsite up -d --build` |
| Logs | `docker compose logs -f api` |
| Restart everything | `docker compose --profile offsite restart` |
| Disk and memory | `df -h /` and `free -h` |
| Check everything end to end (from any computer) | `bash smoke-test.sh https://<domain>` |
| Restore drill from the off-site copies (monthly) | `bash restore-check.sh` |

The VM restarts on its own after kernel updates now and then; every container has
`restart: unless-stopped` and comes back by itself.

**Get an email when it is down:** on GitHub, the repository's *Settings → Secrets and
variables → Actions → Variables → New repository variable*: `HEALTH_URL` =
`https://<domain>/health`. The *Uptime* workflow checks it every 30 minutes (including the
database) and GitHub emails you when a run fails.

**Password reset by email:** DEPLOY.md, *Email*; the SMTP lines go in the same `.env`, then
`docker compose --profile offsite up -d api`.

## Something went wrong

| Problem | Fix |
|---|---|
| The script stops at "Not answering yet" | Security List rules from step 2 (`docker compose logs caddy`: *Timeout during connect (likely firewall problem)*). After adding them, `docker compose restart caddy` retries at once instead of waiting for its back-off |
| `permission denied` on `docker` | log out and back in (the script added you to the `docker` group) |
| `offsite: copy FAILED` / `SignatureDoesNotMatch ... secret key ... could not be found` | a new Customer secret key takes a few minutes to work everywhere: wait 5 minutes and `docker compose --profile offsite restart offsite`. Still failing: wrong endpoint/namespace/keys in `.env` |
| `bad password?` when restoring | a different `BACKUP_PASSPHRASE` from the one that made the copy |
| Out of capacity when creating the VM | step 1: retry later, smaller shape |
