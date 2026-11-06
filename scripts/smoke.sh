#!/usr/bin/env bash
# End-to-end smoke test of the real Docker stack, in an isolated Compose project with throwaway secrets/data.
# It builds the images, starts everything, logs in through the web container, creates a LOCAL server + root,
# lists a directory, checks symlink containment and that the database is not exposed, then exercises uploads (chunks,
# resume, verification), range downloads, ZIPs, cross-folder copy/move and live events. Then tears down.
#   scripts/smoke.sh            # run and clean up
#   KEEP=1 scripts/smoke.sh     # leave the stack running for inspection
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${SMOKE_PORT:-18088}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filedeck-smoke.XXXXXX")"
export COMPOSE_PROJECT_NAME="filedeck-smoke"
export FILEDECK_SECRETS_DIR="$WORK/secrets" FILEDECK_DATA_DIR="$WORK/data"
export PUBLIC_URL="http://127.0.0.1:$PORT" FILEDECK_BIND=127.0.0.1 FILEDECK_HTTP_PORT="$PORT"
export SESSION_COOKIE_SECURE=false SESSION_COOKIE_NAME=filedeck_session   # plain HTTP, test only
export FILEDECK_UID="$(id -u)" FILEDECK_GID="$(id -g)"
COMPOSE=(docker compose --env-file /dev/null)

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; docker compose logs --tail=40 2>&1 | tail -80; exit 1; }
cleanup() { [ "${KEEP:-0}" = 1 ] && { echo "left running: $PUBLIC_URL (work dir $WORK)"; return; }; "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$FILEDECK_DATA_DIR"/{Documents,Photos}
echo hello > "$FILEDECK_DATA_DIR/readme.txt"
echo report > "$FILEDECK_DATA_DIR/Documents/q3.md"
ln -s /etc "$FILEDECK_DATA_DIR/escape"          # absolute link out of the root
./scripts/init-secrets.sh "$WORK/secrets" >/dev/null
ADMIN_PW="$(cat "$WORK/secrets/admin_password")"

echo "== building and starting the stack"
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 240 || fail "stack did not become healthy"
pass "all services healthy"

jar="$WORK/cookies"
api() { # method path [json] [extra-header]  (sends Origin + CSRF like the browser)
  local m="$1" p="$2" d="${3:-}" h="${4:-}"
  local args=(-sS -X "$m" -b "$jar" -c "$jar" -H "Origin: $PUBLIC_URL" -H "X-FileDeck-Activity: user")
  [ -n "$d" ] && args+=(-H "Content-Type: application/json") # a JSON content-type with no body is rejected
  [ -n "$h" ] && args+=(-H "$h")
  [ -n "${CSRF:-}" ] && args+=(-H "X-CSRF-Token: $CSRF")
  [ -n "$d" ] && args+=(-d "$d")
  curl "${args[@]}" "$PUBLIC_URL/api/v1$p"
}
field() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

[ "$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/")" = 200 ] && pass "SPA served by web" || fail "SPA not served"
curl -sI "$PUBLIC_URL/" | grep -qi "content-security-policy" && pass "CSP header present" || fail "no CSP header"
[ "$(curl -s "$PUBLIC_URL/api/v1/health/ready")" = '{"status":"ready","database":"up"}' ] && pass "api ready via web proxy" || fail "api health"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/api/v1/auth/me")" = 401 ] && pass "unauthenticated request rejected" || fail "auth not enforced"

bad="$(api POST /auth/login '{"username":"admin","password":"wrong-password-1"}' | field "['error']['code']")"
[ "$bad" = INVALID_CREDENTIALS ] && pass "bad password rejected" || fail "bad login gave $bad"
api POST /auth/login "{\"username\":\"admin\",\"password\":\"$ADMIN_PW\"}" >/dev/null
grep -q "HttpOnly" "$jar" && pass "session cookie is HttpOnly" || fail "cookie not HttpOnly"
CSRF="$(api GET /auth/csrf | field "['csrfToken']")"

[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -b "$jar" -H "Origin: $PUBLIC_URL" "$PUBLIC_URL/api/v1/auth/logout")" = 403 ] \
  && pass "POST without CSRF token rejected" || fail "CSRF not enforced"

SID="$(api POST /servers '{"name":"smoke local","type":"LOCAL"}' | field "['id']")"
bad_root="$(api POST "/servers/$SID/roots" '{"name":"etc","providerPath":"/etc","virtualPath":"/etc"}' | field "['error']['code']")"
[ "$bad_root" = OUTSIDE_ROOT ] && pass "root outside /mnt rejected" || fail "arbitrary mount allowed ($bad_root)"
RID="$(api POST "/servers/$SID/roots" '{"name":"data","providerPath":"/mnt/data","virtualPath":"/data"}' | field "['id']")"

listing="$(api GET "/servers/$SID/roots/$RID/files?sort=name")"
names="$(echo "$listing" | field "['entries']" | python3 -c "import sys,ast; print(','.join(e['name']+':'+e['type'] for e in ast.literal_eval(sys.stdin.read())))")"
[ "$names" = "Documents:directory,Photos:directory,escape:symlink,readme.txt:file" ] && pass "directory listed: $names" || fail "unexpected listing: $names"
esc="$(api GET "/servers/$SID/roots/$RID/files?path=/escape" | field "['error']['code']")"
[ "$esc" = OUTSIDE_ROOT ] && pass "symlink escaping the root denied" || fail "symlink escape not denied ($esc)"
trav="$(api GET "/servers/$SID/roots/$RID/files?path=/../etc" | field "['error']['code']")"
[ "$trav" = OUTSIDE_ROOT ] && pass "path traversal denied" || fail "traversal not denied ($trav)"
[ "$(api GET "/servers/$SID/roots/$RID/files?path=/Documents" | field "['total']")" = 1 ] && pass "subdirectory listed" || fail "subdir listing"

echo "== file operations, trash, search, preview, layout"
F="/servers/$SID/roots/$RID"
[ "$(api POST "$F/files/directories" '{"path":"/made"}' | field "['name']")" = made ] && pass "folder created" || fail "mkdir"
[ "$(api POST "$F/files/rename" '{"items":[{"path":"/made","newName":"renamed"}]}' | field "['results'][0]['newPath']")" = /renamed ] && pass "renamed" || fail "rename"
clash="$(api POST "$F/files/rename" '{"items":[{"path":"/renamed","newName":"Documents"}]}' | field "['results'][0]['code']")"
[ "$clash" = CONFLICT ] && pass "name clash reported, not overwritten" || fail "rename clash gave $clash"
res="$(api POST "$F/files/duplicate" '{"items":[{"path":"/readme.txt"}]}' "Idempotency-Key: smoke-key-0001")"
again="$(api POST "$F/files/duplicate" '{"items":[{"path":"/readme.txt"}]}' "Idempotency-Key: smoke-key-0001")"
[ "$res" = "$again" ] && pass "idempotency key replays the same response" || fail "idempotency: $res vs $again"
n="$(api GET "$F/files?includeHidden=true" | field "['entries']" | python3 -c "import sys,ast; print(sum(1 for e in ast.literal_eval(sys.stdin.read()) if e['name'].startswith('readme')))")"
[ "$n" = 2 ] && pass "exactly one duplicate exists" || fail "duplicate count $n"
tid="$(api POST "$F/files/trash" '{"items":[{"path":"/readme.txt"}]}' | field "['results'][0]['trashId']")"
[ -n "$tid" ] && pass "moved to the trash" || fail "trash"
api GET "$F/files?includeHidden=true" | grep -q "filedeck-trash" && fail "the trash directory is visible" || pass "trash directory hidden from listings"
[ "$(api GET "$F/files?path=/.filedeck-trash" | field "['error']['code']")" = RESERVED_PATH ] && pass "trash path rejected in user paths" || fail "reserved path"
[ "$(api GET "$F/trash" | field "['entries'][0]['originalPath']")" = /readme.txt ] && pass "trash lists the original path" || fail "trash list"
[ "$(api POST "$F/trash/restore" "{\"ids\":[\"$tid\"]}" | field "['results'][0]['status']")" = ok ] && pass "restored from the trash" || fail "restore"
[ "$(api GET "$F/files/search?q=q3" | field "['entries'][0]['path']")" = /Documents/q3.md ] && pass "search finds /Documents/q3.md" || fail "search"
[ "$(api GET "$F/files/preview/info?path=/readme.txt" | field "['text']")" = hello ] && pass "text preview" || fail "preview"
[ "$(api DELETE "$F/files" '{"items":[{"path":"/renamed"}]}' | field "['error']['code']")" = VALIDATION_ERROR ] && pass "permanent delete needs the explicit flag" || fail "permanent flag"
api PUT /window-layout "{\"version\":1,\"activeId\":\"w1\",\"windows\":[{\"id\":\"w1\",\"kind\":\"finder\",\"frame\":{\"x\":10,\"y\":10,\"w\":800,\"h\":500},\"state\":\"normal\",\"z\":1,\"serverId\":\"$SID\",\"rootId\":\"$RID\",\"path\":\"/Documents\",\"view\":\"column\",\"sort\":{\"key\":\"name\",\"order\":\"asc\"}}]}" >/dev/null
[ "$(api GET /window-layout | field "['windows'][0]['path']")" = /Documents ] && pass "window layout saved" || fail "layout save"

echo "== transfers: upload, resume, download, ZIP, copy/move, live events"
raw() { # method path file [extra headers...]  (binary body, like a browser chunk)
  local m="$1" p="$2" f="$3"; shift 3
  local args=(-sS -o /dev/null -w '%{http_code}' -X "$m" -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-FileDeck-Activity: user" -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/octet-stream")
  for h in "$@"; do args+=(-H "$h"); done
  curl "${args[@]}" --data-binary "@$f" "$PUBLIC_URL/api/v1$p"
}
MiB=1048576
head -c $((5 * MiB / 2)) /dev/urandom > "$WORK/big.bin"           # 2.5 MiB -> three 1 MiB chunks
FULL_SHA="$(sha256sum "$WORK/big.bin" | cut -d' ' -f1)"
SIZE="$(stat -c %s "$WORK/big.bin")"
mkdir -p "$WORK/chunks" && split -b "$MiB" -d "$WORK/big.bin" "$WORK/chunks/c"
curl -sS -N -m 60 -b "$jar" -H "Accept: text/event-stream" "$PUBLIC_URL/api/v1/events" > "$WORK/events.txt" 2>/dev/null &
EVENTS_PID=$!
sleep 1

INIT="{\"serverId\":\"$SID\",\"rootId\":\"$RID\",\"destinationPath\":\"/uploaded/big.bin\",\"fileSize\":\"$SIZE\",\"sha256\":\"$FULL_SHA\",\"chunkSize\":$MiB,\"conflictPolicy\":\"FAIL\"}"
UP="$(api POST /transfers/uploads "$INIT")"
TID="$(echo "$UP" | field "['id']")"
[ "$(echo "$UP" | field "['chunkCount']")" = 3 ] && pass "upload initialised (3 chunks)" || fail "upload init: $UP"
i=0
for c in "$WORK"/chunks/c0[01]; do
  off=$((i * MiB)); len=$(stat -c %s "$c")
  code="$(raw PUT "/transfers/$TID/chunks/$i" "$c" "X-Chunk-SHA256: $(sha256sum "$c" | cut -d' ' -f1)" "Content-Range: bytes $off-$((off + len - 1))/$SIZE")"
  [ "$code" = 204 ] || fail "chunk $i returned $code"; i=$((i + 1))
done
pass "two chunks acknowledged"
bad="$(raw PUT "/transfers/$TID/chunks/2" "$WORK/chunks/c02" "X-Chunk-SHA256: $(printf 0%.0s {1..64})" "Content-Range: bytes $((2 * MiB))-$((SIZE - 1))/$SIZE")"
[ "$bad" = 422 ] && pass "a damaged chunk is rejected" || fail "damaged chunk gave $bad"
RESUMED="$(api POST /transfers/uploads "$INIT")"
[ "$(echo "$RESUMED" | field "['id']")" = "$TID" ] && pass "the same upload resumes instead of duplicating" || fail "resume gave a new transfer"
[ "$(api GET "/transfers/$TID/chunks" | field "['acknowledged']")" = "[[0, 1]]" ] && pass "server reports exactly the acknowledged chunks" || fail "acknowledged ranges"
[ "$(api POST "/transfers/$TID/complete" "{}" | field "['error']['code']")" = MISSING_CHUNKS ] && pass "complete is refused while chunks are missing" || fail "complete with missing chunks"
c2="$(raw PUT "/transfers/$TID/chunks/2" "$WORK/chunks/c02" "X-Chunk-SHA256: $(sha256sum "$WORK/chunks/c02" | cut -d' ' -f1)" "Content-Range: bytes $((2 * MiB))-$((SIZE - 1))/$SIZE")"
[ "$c2" = 204 ] || fail "last chunk returned $c2"
api POST "/transfers/$TID/complete" "{}" >/dev/null
for _ in $(seq 1 60); do st="$(api GET "/transfers/$TID" | field "['status']")"; [ "$st" = COMPLETED ] || [ "$st" = FAILED ] && break; sleep 1; done
[ "$st" = COMPLETED ] && pass "worker verified and committed the upload" || fail "upload ended $st"
[ "$(sha256sum "$FILEDECK_DATA_DIR/uploaded/big.bin" | cut -d' ' -f1)" = "$FULL_SHA" ] && pass "stored file has the original SHA-256" || fail "stored file differs"
[ "$(api GET "/transfers/$TID" | field "['verificationLevel']")" = SHA256_DESTINATION ] && pass "destination was independently verified" || fail "verification level"

D="$PUBLIC_URL/api/v1$F/files/download?path=/uploaded/big.bin"
hdr="$(curl -sSI -b "$jar" "$D")"
echo "$hdr" | grep -qi '^accept-ranges: bytes' && echo "$hdr" | grep -qi '^etag:' && echo "$hdr" | grep -qi "^content-length: $SIZE" && pass "download headers (length, ranges, ETag)" || fail "download headers: $hdr"
[ "$(curl -s -b "$jar" -H 'Range: bytes=100-199' "$D" | sha256sum | cut -d' ' -f1)" = "$(tail -c +101 "$WORK/big.bin" | head -c 100 | sha256sum | cut -d' ' -f1)" ] && pass "range download returns the right bytes" || fail "range bytes"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -H "Range: bytes=$((SIZE + 5))-" "$D")" = 416 ] && pass "unsatisfiable range gives 416" || fail "416"
ETAG="$(echo "$hdr" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -H 'If-Match: "stale"' "$D")" = 412 ] && pass "resuming against a changed file is refused (412)" || fail "if-match"
[ "$(curl -s -b "$jar" "$PUBLIC_URL/api/v1$F/files/checksum?path=/uploaded/big.bin" | field "['sha256']")" = "$FULL_SHA" ] && pass "checksum manifest matches" || fail "manifest"
[ "$(curl -s -b "$jar" "$D" | sha256sum | cut -d' ' -f1)" = "$FULL_SHA" ] && pass "full download matches the SHA-256" || fail "full download"

Z="$(api POST "$F/files/zip" '{"paths":["/Documents","/uploaded"]}')"
curl -s -b "$jar" "$PUBLIC_URL$(echo "$Z" | field "['url']")" -o "$WORK/out.zip"
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; n=sorted(z.namelist()); assert 'Documents/q3.md' in n and 'uploaded/big.bin' in n, n" "$WORK/out.zip" && pass "ZIP download is valid and complete" || fail "zip"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" "$PUBLIC_URL$(echo "$Z" | field "['url']")")" = 404 ] && pass "a ZIP link works only once" || fail "zip ticket reuse"

PID2="$(api POST "/servers/$SID/roots" '{"name":"photos","providerPath":"/mnt/data/Photos","virtualPath":"/photos"}' | field "['id']")"
CP="$(api POST /transfers/server-copy "{\"source\":{\"serverId\":\"$SID\",\"rootId\":\"$RID\"},\"items\":[{\"path\":\"/uploaded/big.bin\"}],\"destination\":{\"serverId\":\"$SID\",\"rootId\":\"$PID2\",\"path\":\"/\"},\"move\":false}")"
CTID="$(echo "$CP" | field "['transfers'][0]['id']")"
for _ in $(seq 1 60); do st="$(api GET "/transfers/$CTID" | field "['status']")"; [ "$st" = COMPLETED ] || [ "$st" = FAILED ] && break; sleep 1; done
[ "$st" = COMPLETED ] && [ "$(sha256sum "$FILEDECK_DATA_DIR/Photos/big.bin" | cut -d' ' -f1)" = "$FULL_SHA" ] && pass "cross-folder copy verified" || fail "copy ended $st"
[ -f "$FILEDECK_DATA_DIR/uploaded/big.bin" ] && pass "a copy leaves the source" || fail "copy removed the source"
MV="$(api POST /transfers/server-copy "{\"source\":{\"serverId\":\"$SID\",\"rootId\":\"$PID2\"},\"items\":[{\"path\":\"/big.bin\"}],\"destination\":{\"serverId\":\"$SID\",\"rootId\":\"$RID\",\"path\":\"/Documents\"},\"move\":true}")"
MTID="$(echo "$MV" | field "['transfers'][0]['id']")"
for _ in $(seq 1 60); do st="$(api GET "/transfers/$MTID" | field "['status']")"; [ "$st" = COMPLETED ] || [ "$st" = FAILED ] && break; sleep 1; done
[ "$st" = COMPLETED ] && [ "$(sha256sum "$FILEDECK_DATA_DIR/Documents/big.bin" | cut -d' ' -f1)" = "$FULL_SHA" ] && [ ! -e "$FILEDECK_DATA_DIR/Photos/big.bin" ] && pass "move verified, then the source removed" || fail "move ended $st"

sleep 1; kill "$EVENTS_PID" 2>/dev/null || true; wait "$EVENTS_PID" 2>/dev/null || true
grep -q 'event: transfer.completed' "$WORK/events.txt" && grep -q '^id: [0-9]' "$WORK/events.txt" && pass "live events delivered with stable ids" || fail "no live events: $(head -c 400 "$WORK/events.txt")"
LAST_ID="$(grep '^id: ' "$WORK/events.txt" | head -1 | cut -d' ' -f2)"
REPLAYED="$(curl -sS -N -m 3 -b "$jar" -H "Last-Event-ID: $LAST_ID" "$PUBLIC_URL/api/v1/events" 2>/dev/null || true)"
grep -q 'event: transfer' <<<"$REPLAYED" && pass "a reconnecting client replays what it missed" || fail "event replay"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" "$PUBLIC_URL/api/v1/transfers?limit=5")" = 200 ] && pass "the transfers list answers directly (no redirect through nginx)" || fail "transfers list without a trailing slash"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/api/v1/events")" = 401 ] && pass "events need a session" || fail "events unauthenticated"

echo "== editor: versioned saves, conflicts, limits, CSP"
put_text() { # path version [body-file] [extra header]  -> prints "<status> <body>"
  local path="$1" ver="$2" file="${3:-}" extra="${4:-}"
  local args=(-sS -w '\n%{http_code}' -X PUT -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-FileDeck-Activity: user" -H "X-CSRF-Token: $CSRF" -H "Content-Type: text/plain; charset=utf-8")
  [ -n "$ver" ] && args+=(-H "X-Expected-Version: $ver")
  [ -n "$extra" ] && args+=(-H "$extra")
  curl "${args[@]}" --data-binary "@$file" "$PUBLIC_URL/api/v1$F/files/content?path=$path"
}
code_of() { tail -n1; }
printf 'name: demo\nlist:\n  - a\n' > "$FILEDECK_DATA_DIR/demo.yml"
RD="$(api GET "$F/files/content?path=/demo.yml")"
[ "$(echo "$RD" | field "['kind']")" = text ] && [ "$(echo "$RD" | field "['content']")" = $'name: demo\nlist:\n  - a' ] && pass "text file opens with its content" || fail "editor read: $RD"
V1="$(echo "$RD" | field "['versionToken']")"
[ "$(echo "$RD" | field "['guarantees']['compareAndSwap']")" = check-then-commit ] && pass "provider guarantees are disclosed" || fail "guarantees"
printf 'name: demo\nlist:\n  - a\n  - b\n' > "$WORK/new.yml"
SAVE="$(put_text /demo.yml "$V1" "$WORK/new.yml")"
[ "$(echo "$SAVE" | code_of)" = 200 ] && cmp -s "$WORK/new.yml" "$FILEDECK_DATA_DIR/demo.yml" && pass "save replaces the file with the new bytes" || fail "save: $SAVE"
V2="$(echo "$SAVE" | head -n1 | field "['versionToken']")"
[ "$V2" != "$V1" ] && pass "save returns a new version" || fail "version did not change"
printf 'name: demo\nstale: write\n' > "$WORK/stale.yml"
STALE="$(put_text /demo.yml "$V1" "$WORK/stale.yml")"
[ "$(echo "$STALE" | code_of)" = 409 ] && [ "$(echo "$STALE" | head -n1 | field "['error']['code']")" = FILE_VERSION_CONFLICT ] && cmp -s "$WORK/new.yml" "$FILEDECK_DATA_DIR/demo.yml" && pass "a stale save is a 409 and overwrites nothing" || fail "stale save: $STALE"
[ "$(put_text /demo.yml "" "$WORK/new.yml" | code_of)" = 400 ] && pass "a save without the expected version is refused" || fail "missing precondition"
printf '\xff\xfe\x00bad' > "$WORK/bad.bin"
[ "$(put_text /demo.yml "$V2" "$WORK/bad.bin" | code_of)" = 422 ] && cmp -s "$WORK/new.yml" "$FILEDECK_DATA_DIR/demo.yml" && pass "non-text bytes are never saved as text" || fail "binary save"
[ "$(put_text /fresh.txt absent "$WORK/new.yml" | code_of)" = 200 ] && [ "$(put_text /fresh.txt absent "$WORK/new.yml" | code_of)" = 409 ] && pass "create-new works once and never overwrites" || fail "create new"
printf '\x89PNG\r\n\x1a\n\x00\x01\x02' > "$FILEDECK_DATA_DIR/pic.png"
[ "$(api GET "$F/files/content?path=/pic.png" | field "['kind']")" = binary ] && pass "a binary file is not offered as text" || fail "binary classification"
head -c $((6 * 1024 * 1024)) /dev/zero | tr '\0' 'a' > "$WORK/six.txt"
V3="$(api GET "$F/files/content?path=/demo.yml" | field "['versionToken']")"
BIG="$(put_text /demo.yml "$V3" "$WORK/six.txt")"
[ "$(echo "$BIG" | code_of)" = 200 ] && [ "$(stat -c %s "$FILEDECK_DATA_DIR/demo.yml")" = $((6 * 1024 * 1024)) ] && pass "a 6 MiB save goes through the proxy" || fail "6 MiB save: $(echo "$BIG" | code_of)"
[ "$(api GET "$F/files/content?path=/demo.yml" | field "['requiresOptIn']")" = True ] && pass "a 6 MiB file needs the opt-in to edit" || fail "opt-in"
head -c $((22 * 1024 * 1024)) /dev/zero | tr '\0' 'a' > "$WORK/huge.txt"
V4="$(api GET "$F/files/content?path=/demo.yml&allowLarge=true" | field "['versionToken']")"
[ "$(put_text /demo.yml "$V4" "$WORK/huge.txt" | code_of)" = 413 ] && pass "a 22 MiB save is refused" || fail "22 MiB save"
printf 'name: demo\nlist:\n  - a\n' > "$FILEDECK_DATA_DIR/demo.yml"
RO="$(api POST "/servers/$SID/roots" '{"name":"docs-ro","providerPath":"/mnt/data/Documents","virtualPath":"/docs-ro","readOnly":true}' | field "['id']")"
ROPUT="$(curl -sS -w '\n%{http_code}' -X PUT -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-FileDeck-Activity: user" -H "X-CSRF-Token: $CSRF" -H "Content-Type: text/plain" -H "X-Expected-Version: x" --data-binary "@$WORK/new.yml" "$PUBLIC_URL/api/v1/servers/$SID/roots/$RO/files/content?path=/q3.md")"
[ "$(echo "$ROPUT" | code_of)" = 403 ] && [ "$(echo "$ROPUT" | head -n1 | field "['error']['code']")" = READ_ONLY_ROOT ] && pass "a read-only root refuses saves" || fail "read-only root: $ROPUT"
CSP="$(curl -sI "$PUBLIC_URL/" | tr -d '\r' | grep -i '^content-security-policy')"
echo "$CSP" | grep -q "worker-src 'self'" && echo "$CSP" | grep -q "style-src 'self' 'unsafe-inline'" && echo "$CSP" | grep -q "script-src 'self';" && pass "CSP: scripts and workers 'self', styles allow inline for Monaco" || fail "CSP: $CSP"
# a server with a terminal (it is unreachable on purpose: the browser check only needs the WebSocket to reach the API)
TS="$(api POST /servers '{"name":"termcheck","type":"SFTP","host":"127.0.0.1","port":9,"username":"x","timeoutMs":1500}' | field "['id']")"
api PUT "/servers/$TS/credential" '{"type":"PASSWORD","password":"whatever"}' >/dev/null
[ "$(api PUT "/servers/$TS/terminal-access" '{"enabled":true,"userIds":[]}' | field "['enabled']")" = True ] && pass "an administrator can enable the terminal on a server" || fail "enable terminal"
if [ "${SMOKE_BROWSER:-1}" = 1 ] && command -v google-chrome >/dev/null 2>&1; then
  BROWSER_PW="browser-check-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # a fresh user: a fresh desktop layout
  api POST /users "{\"username\":\"browsercheck\",\"password\":\"$BROWSER_PW\",\"role\":\"ADMIN\"}" >/dev/null
  if PUBLIC_URL="$PUBLIC_URL" CHECK_USER=browsercheck CHECK_PASSWORD="$BROWSER_PW" CHECK_FILE=demo.yml CHECK_TERMINAL_SERVER=termcheck node tests/e2e/csp-check.mjs; then pass "the editor and the terminal run in a real browser under the production CSP"; else fail "editor in the browser under the CSP"; fi
else
  echo "  SKIP browser check (no google-chrome or SMOKE_BROWSER=0)"
fi

echo "== terminal: WebSocket through nginx, origin and access rules"
TICKET_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-FileDeck-Activity: user" -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/json" -d '{}' "$PUBLIC_URL/api/v1/servers/$TS/terminal/tickets")"
[ "$TICKET_CODE" = 200 ] && pass "a terminal ticket is issued to an allowed user" || fail "ticket: $TICKET_CODE"
MON_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/json" -d '{}' "$PUBLIC_URL/api/v1/servers/$TS/monitor/sample")"
[ "$MON_CODE" = 502 ] && pass "monitoring an unreachable server answers with a clear error instead of hanging" || fail "monitor sample on unreachable server: $MON_CODE"
MON_NF="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/json" -d '{}' "$PUBLIC_URL/api/v1/servers/00000000-0000-4000-8000-000000000000/monitor/sample")"
[ "$MON_NF" = 404 ] && pass "monitoring an unknown server is a 404" || fail "monitor unknown: $MON_NF"
WSKEY="$(head -c 16 /dev/urandom | base64)"
ws_code() { curl -s -o /dev/null -w '%{http_code}' -m 3 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $WSKEY" -H "Origin: $1" ${2:+-b "$2"} "$PUBLIC_URL/api/v1/servers/$TS/terminal" 2>/dev/null || true; }
[ "$(ws_code "$PUBLIC_URL" "$jar" | head -c3)" = 101 ] && pass "the WebSocket upgrade passes through nginx (101)" || fail "websocket upgrade through nginx: $(ws_code "$PUBLIC_URL" "$jar")"
[ "$(ws_code "https://evil.example" "$jar")" = 403 ] && pass "a cross-site WebSocket is refused" || fail "cross-site websocket"
[ "$(ws_code "$PUBLIC_URL" "")" = 401 ] && pass "a WebSocket without a session is refused" || fail "unauthenticated websocket"

echo "== launcher: apps, URL rules, themes"
AID="$(api POST /apps '{"name":"Smoke app","url":"https://smoke.example.com/path?token=x","icon":"chart","category":"Smoke"}' | field "['id']")"
[ -n "$AID" ] && pass "a launcher app can be created" || fail "create app"
for BAD in 'javascript:alert(1)' 'data:text/html,x' 'file:///etc/passwd' 'https://user:pw@host.example/'; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -b "$jar" -H "Origin: $PUBLIC_URL" -H "X-FileDeck-Activity: user" -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/json" -d "{\"name\":\"x\",\"url\":\"$BAD\"}" "$PUBLIC_URL/api/v1/apps")" = 400 ] && pass "refused app url: $BAD" || fail "app url accepted: $BAD"
done
[ "$(api GET /apps | field "['apps'][0]['name']")" = "Smoke app" ] && pass "the app is listed" || fail "list apps"
[ "$(api DELETE "/apps/$AID" | wc -c)" -le 1 ] && [ "$(api GET /apps | field "['apps']")" = "[]" ] && pass "the app can be deleted" || fail "delete app"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/api/v1/apps")" = 401 ] && pass "apps need a session" || fail "apps unauthenticated"
THEME_INIT="$(curl -sI "$PUBLIC_URL/theme-init.js" | tr -d '\r')"
echo "$THEME_INIT" | head -1 | grep -q 200 && echo "$THEME_INIT" | grep -qi 'content-type: .*javascript' && pass "the theme bootstrap is served as a same-origin script (no inline script needed under the CSP)" || fail "theme-init.js: $THEME_INIT"

"${COMPOSE[@]}" ps --format '{{.Service}} {{.Publishers}}' | grep -E '^postgres .*[0-9]+->' && fail "postgres publishes a port" || pass "postgres not published to the host"
"${COMPOSE[@]}" ps --format '{{.Service}} {{.Publishers}}' | grep -E '^api .*[0-9]+->' && fail "api publishes a port" || pass "api not published (only web is)"
[ "$("${COMPOSE[@]}" exec -T api id -u)" != 0 ] && pass "api runs as non-root" || fail "api runs as root"
"${COMPOSE[@]}" exec -T api sh -c 'touch /app/x 2>/dev/null' && fail "api filesystem is writable" || pass "api root filesystem is read-only"
if "${COMPOSE[@]}" logs 2>&1 | grep -F -e "$ADMIN_PW" -e "$(cat "$WORK/secrets/postgres_password")" >/dev/null; then fail "a secret appears in the container logs"; else pass "no secrets in container logs"; fi

echo "== restart persistence"
"${COMPOSE[@]}" restart api worker >/dev/null
"${COMPOSE[@]}" up -d --wait --wait-timeout 120 >/dev/null
[ "$(api GET /auth/me | field "['user']['username']")" = admin ] && pass "session survives an api restart" || fail "session lost on restart"
[ "$(api GET /window-layout | field "['windows'][0]['view']")" = column ] && pass "window layout survives a restart" || fail "layout lost on restart"
echo "== lost admin password"
"${COMPOSE[@]}" exec -T -e NEW_PASSWORD='smoke-reset-password-1' api node reset-password.mjs admin | grep -q 'was reset' && pass "the reset command runs inside the api container" || fail "reset-password command"
[ "$(api GET /auth/me | field "['error']['code']")" = UNAUTHENTICATED ] && pass "a reset ends the user's sessions" || fail "session survived a password reset"
[ "$(api POST /auth/login "{\"username\":\"admin\",\"password\":\"$ADMIN_PW\"}" | field "['error']['code']")" = INVALID_CREDENTIALS ] && pass "the old password no longer works" || fail "old password still works after a reset"
[ "$(api POST /auth/login '{"username":"admin","password":"smoke-reset-password-1"}' | field "['user']['username']")" = admin ] && pass "the new password works" || fail "new password rejected"
echo "SMOKE TEST PASSED"
