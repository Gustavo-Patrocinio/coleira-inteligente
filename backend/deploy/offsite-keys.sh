#!/usr/bin/env bash
# Asks for the off-site backup secrets without echoing them and writes them into .env
# (DEPLOY-ORACLE.md, step 5). Run it on the server, in this folder: bash offsite-keys.sh
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "no .env here; run setup-ubuntu.sh first" >&2; exit 1; }

ask() { # name, prompt
  local v
  read -r -s -p "$2: " v; echo >&2
  [ -n "$v" ] || { echo "empty, nothing changed" >&2; exit 1; }
  # docker compose reads .env itself: $, quotes, spaces and # would be mangled
  if [[ "$v" =~ [^A-Za-z0-9+/=._-] ]]; then
    echo "only letters, digits and + / = . _ - please (e.g. openssl rand -base64 24); nothing changed" >&2
    exit 1
  fi
  printf '%s' "$v"
}
key=$(ask S3_ACCESS_KEY_ID "Access key (Customer secret keys list)")
secret=$(ask S3_SECRET_ACCESS_KEY "Secret key (shown once when generated)")
pass=$(ask BACKUP_PASSPHRASE "Backup passphrase (saved in your password manager)")
again=$(ask BACKUP_PASSPHRASE "Same passphrase again")
[ "$pass" = "$again" ] || { echo "passphrases differ, nothing changed" >&2; exit 1; }

set_var() { # name, value: replaces the line or appends it, without sed (values may hold any character)
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" .env > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > .env; rm -f "$tmp"
}
set_var S3_ACCESS_KEY_ID "$key"
set_var S3_SECRET_ACCESS_KEY "$secret"
set_var BACKUP_PASSPHRASE "$pass"
chmod 600 .env
echo "Saved. Start the off-site copies: docker compose --profile offsite up -d"
