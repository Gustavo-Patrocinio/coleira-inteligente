#!/usr/bin/env bash
# End-to-end check of a running server over its public address: health, register, a dog,
# password change (old session refused), forgot-password answer, account deletion. Leaves
# nothing behind (the throwaway account is deleted). Needs only bash and curl.
#
#   bash smoke-test.sh https://collar.example.com
set -euo pipefail
base="${1:?usage: $0 https://<server>}"
base="${base%/}"
email="smoke-$(date +%s)-$RANDOM@example.invalid"
pass1="smoke test password one"
pass2="smoke test password two"
body=$(mktemp)
tok="" # the current session, so a failed run still deletes its throwaway account
cleanup() {
  [ -n "$tok" ] && curl -s -o /dev/null -m 10 -X DELETE -H "authorization: Bearer $tok" "$base/v1/me"
  rm -f "$body"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
token() { sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$body"; }
# status code of a request: req METHOD PATH [TOKEN] [JSON]
req() {
  local args=(-s -o "$body" -w '%{http_code}' -m 20 -X "$1" "$base$2")
  [ -n "${3:-}" ] && args+=(-H "authorization: Bearer $3")
  [ -n "${4:-}" ] && args+=(-H 'content-type: application/json' -d "$4")
  curl "${args[@]}"
}
check() { # expected actual what
  [ "$1" = "$2" ] || fail "$3: expected $1, got $2 ($(head -c 200 "$body"))"
  echo "ok   $3"
}

check 200 "$(req GET /health)" "health (API and database)"
check 201 "$(req POST /v1/auth/register '' "{\"email\":\"$email\",\"password\":\"$pass1\"}")" "register"
t1=$(token)
tok=$t1
check 200 "$(req GET /v1/me "$t1")" "me"
check 201 "$(req POST /v1/dogs "$t1" '{"name":"Smoke","timezone":"America/Sao_Paulo"}')" "create a dog"
check 200 "$(req POST /v1/me/password "$t1" "{\"current_password\":\"$pass1\",\"new_password\":\"$pass2\"}")" "change password"
t2=$(token)
tok=$t2
check 401 "$(req GET /v1/me "$t1")" "old session refused after the change"
check 200 "$(req GET /v1/me "$t2")" "new session works"
code=$(req POST /v1/auth/forgot '' "{\"email\":\"$email\"}")
case "$code" in
  202) echo "ok   forgot password: email on (a code was sent to the throwaway address)" ;;
  501) echo "ok   forgot password: email off on this server (DEPLOY.md, Email)" ;;
  *) fail "forgot password: got $code" ;;
esac
check 204 "$(req DELETE /v1/me "$t2")" "delete the account"
tok=""
check 401 "$(req GET /v1/me "$t2")" "deleted account refused"
echo "all good: $base"
