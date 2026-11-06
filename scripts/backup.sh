#!/usr/bin/env bash
# Dump the FileDeck database (custom format) from the running Compose stack.
# Usage: scripts/backup.sh [output-dir]   (default ./backups)
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-backups}"
mkdir -p "$out"
file="$out/filedeck-$(date +%Y%m%d-%H%M%S).dump"
( umask 077; docker compose exec -T postgres pg_dump -U filedeck -d filedeck --format=custom --no-owner > "$file" )
[ -s "$file" ] || { echo "backup is empty, something went wrong" >&2; rm -f "$file"; exit 1; }
echo "wrote $file ($(du -h "$file" | cut -f1))"
echo "reminder: secrets/credential_keys is NOT in this dump — back it up separately."
