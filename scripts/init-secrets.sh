#!/usr/bin/env bash
# Generate the secret files Docker Compose mounts. Never overwrites existing files.
# Usage: scripts/init-secrets.sh [secrets-dir]   (default: ./secrets)
set -euo pipefail
dir="${1:-secrets}"
mkdir -p "$dir"
chmod 700 "$dir"

gen() { # name command...
  local f="$dir/$1"; shift
  if [ -e "$f" ]; then echo "keep   $f"; return; fi
  ( umask 077; "$@" > "$f" )
  echo "create $f"
}
rand() { head -c "$1" /dev/urandom | base64 | tr -d '\n=+/' | head -c "$2"; }

pg_pw="$(rand 48 40)"
gen postgres_password printf '%s' "$pg_pw"
# URL-safe password (alphanumeric only) so no escaping is needed
if [ ! -e "$dir/database_url" ]; then
  pg_pw="$(cat "$dir/postgres_password")"
fi
gen database_url printf 'postgresql://filedeck:%s@postgres:5432/filedeck' "$pg_pw"
gen csrf_secret sh -c "head -c 48 /dev/urandom | base64 | tr -d '\n'"
gen credential_keys sh -c "printf '{\"1\":\"%s\"}' \"\$(head -c 32 /dev/urandom | base64)\""
if [ ! -e "$dir/admin_password" ]; then
  gen admin_password sh -c "head -c 24 /dev/urandom | base64 | tr -d '\n=+/' | head -c 24"
  echo
  echo "Initial admin password (shown once, also stored in $dir/admin_password):"
  cat "$dir/admin_password"; echo
else
  echo "keep   $dir/admin_password"
fi
echo
echo "BACK UP $dir/credential_keys SEPARATELY from the database: without it stored server credentials are unrecoverable."
