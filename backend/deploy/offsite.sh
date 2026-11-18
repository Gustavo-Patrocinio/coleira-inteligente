#!/bin/sh
# Copies the nightly dumps in /backups to S3-compatible object storage (Oracle Cloud Object
# Storage, Backblaze B2, Cloudflare R2...), encrypted on this server with BACKUP_PASSPHRASE
# before upload (rclone crypt). The storage provider only ever sees encrypted bytes.
#
#   no arguments: loop forever (copy new dumps, prune old ones, every 6 h)
#   arguments:    run rclone with them against the same remotes, e.g.
#                 docker compose run --rm offsite ls safe:
#                 docker compose run --rm offsite copy safe:collar-2026-11-17.dump /backups
set -u
# all settings come from the environment (docker-compose.yml); an empty config file keeps
# rclone from complaining about a missing one
: > /tmp/rclone.conf
export RCLONE_CONFIG=/tmp/rclone.conf
: "${BACKUP_PASSPHRASE:?set BACKUP_PASSPHRASE in .env}"
: "${S3_BUCKET:?set S3_BUCKET in .env}"
RCLONE_CONFIG_SAFE_PASSWORD="$(rclone obscure "$BACKUP_PASSPHRASE")"
export RCLONE_CONFIG_SAFE_PASSWORD
export RCLONE_CONFIG_SAFE_REMOTE="store:${S3_BUCKET}/collar"

if [ "$#" -gt 0 ]; then exec rclone "$@"; fi

keep="${OFFSITE_KEEP_DAYS:-14}"
while true; do
  if rclone copy /backups safe: --include 'collar-*.dump' --max-age "${keep}d"; then
    echo "offsite: copy ok ($(rclone lsf safe: --include 'collar-*.dump' | wc -l) dumps stored)"
    rclone delete safe: --include 'collar-*.dump' --min-age "${keep}d" || echo "offsite: prune failed"
  else
    echo "offsite: copy FAILED, retrying in 6 h"
  fi
  sleep 21600
done
