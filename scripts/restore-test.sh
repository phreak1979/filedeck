#!/usr/bin/env bash
# Prove a backup restores: load it into a throwaway PostgreSQL container and verify structure and invariants.
# Never touches the live database.   Usage: scripts/restore-test.sh <backup.dump>
set -euo pipefail
dump="${1:?usage: restore-test.sh <backup.dump>}"
[ -s "$dump" ] || { echo "no such backup: $dump" >&2; exit 1; }
name="filedeck-restore-test-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$name" -e POSTGRES_PASSWORD=restore -e POSTGRES_DB=filedeck postgres:17-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
docker exec -i "$name" pg_restore -U postgres -d filedeck --no-owner < "$dump"
q() { docker exec "$name" psql -U postgres -d filedeck -tAc "$1"; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1 (expected $3, got $2)"; fail=1; fi; }
for t in User Session Server ServerRoot RootPermission Credential Transfer TransferChunk TransferEvent AuditLog FileBackup; do
  check "table $t exists" "$(q "select to_regclass('\"$t\"') is not null")" t
done
check "migrations recorded" "$(q "select count(*) > 0 from _prisma_migrations")" t
check "unique chunk index per transfer" "$(q "select count(*) from pg_indexes where indexname = 'TransferChunk_transferId_chunkIndex_key'")" 1
check "audit trigger present" "$(q "select count(*) from pg_trigger where tgname = 'AuditLog_append_only'")" 1
# the append-only guard must survive a restore (psql exits non-zero on the expected error, so capture output first)
probe="$(q "insert into \"AuditLog\"(id,action,result) values (gen_random_uuid(),'restore-test','SUCCESS'); update \"AuditLog\" set action='x';" 2>&1 || true)"
if grep -q immutable <<<"$probe"; then echo "  ok    audit rows are immutable after restore"; else echo "  FAIL  audit immutability lost"; fail=1; fi
echo "  info  users: $(q 'select count(*) from "User"'), servers: $(q 'select count(*) from "Server"'), audit rows: $(q 'select count(*) from "AuditLog"')"
[ "$fail" = 0 ] && echo "RESTORE TEST PASSED" || { echo "RESTORE TEST FAILED"; exit 1; }
