#!/usr/bin/env node
// TR-001 acceptance: stream a large file through the real HTTP API and prove the stored copy has the same SHA-256.
//   FILEDECK_URL=https://files.example.com FILEDECK_USER=admin FILEDECK_PASSWORD=... \
//   FILEDECK_SERVER_ID=<uuid> FILEDECK_ROOT_ID=<uuid> SIZE_GIB=20 node scripts/acceptance-upload.mjs
// SIZE_MIB overrides SIZE_GIB for small runs. Memory stays at ~3 chunks no matter the size; disk needs SIZE free on
// the staging volume AND on the destination. The file is generated on the fly, never stored locally.
import { createHash } from 'node:crypto';

const env = (k, d) => process.env[k] ?? d ?? (() => { throw new Error(`set ${k}`); })();
const URL_ = env('FILEDECK_URL').replace(/\/$/, '');
const API = `${URL_}/api/v1`;
const MiB = 1024 * 1024;
const SIZE = process.env.SIZE_MIB ? Number(process.env.SIZE_MIB) * MiB : Number(env('SIZE_GIB', '20')) * 1024 * MiB;
const CHUNK = 8 * MiB;
const count = Math.ceil(SIZE / CHUNK);
const name = `acceptance-${Date.now()}.bin`;

function windowBytes(index) {
  const length = Math.min(CHUNK, SIZE - index * CHUNK);
  const out = Buffer.allocUnsafe(length);
  let x = ((index * 2654435761 + 12345) >>> 0) || 1;
  for (let i = 0; i + 4 <= length; i += 4) {
    x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0;
    out.writeUInt32LE(x, i);
  }
  return out;
}

const log = (m) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${m}`);
const login = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json', origin: URL_ }, body: JSON.stringify({ username: env('FILEDECK_USER'), password: env('FILEDECK_PASSWORD') }) });
if (!login.ok) throw new Error(`login failed (${login.status})`);
const cookie = login.headers.getSetCookie()[0].split(';')[0];
const csrf = (await (await fetch(`${API}/auth/csrf`, { headers: { cookie } })).json()).csrfToken;
const H = (extra = {}) => ({ cookie, origin: URL_, 'x-csrf-token': csrf, 'x-filedeck-activity': 'user', ...extra });
async function call(method, path, body) {
  const r = await fetch(API + path, { method, headers: H(body ? { 'content-type': 'application/json' } : {}), body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  if (!r.ok) throw new Error(`${method} ${path} -> ${r.status} ${t}`);
  return t ? JSON.parse(t) : null;
}

log(`hashing ${(SIZE / MiB).toFixed(0)} MiB (${count} chunks)…`);
const whole = createHash('sha256');
const chunkHashes = [];
for (let i = 0; i < count; i++) {
  const b = windowBytes(i);
  whole.update(b);
  chunkHashes.push(createHash('sha256').update(b).digest('hex'));
}
const sha = whole.digest('hex');
log(`sha256 ${sha}`);

const sid = env('FILEDECK_SERVER_ID');
const rid = env('FILEDECK_ROOT_ID');
const t = await call('POST', '/transfers/uploads', { serverId: sid, rootId: rid, destinationPath: `/${name}`, fileSize: String(SIZE), sha256: sha, chunkSize: CHUNK, conflictPolicy: 'FAIL' });
log(`transfer ${t.id}`);

let next = 0;
let done = 0;
const started = Date.now();
async function sender() {
  for (;;) {
    const i = next++;
    if (i >= count) return;
    const b = windowBytes(i);
    for (let attempt = 1; ; attempt++) {
      const r = await fetch(`${API}/transfers/${t.id}/chunks/${i}`, {
        method: 'PUT', headers: H({ 'content-type': 'application/octet-stream', 'x-chunk-sha256': chunkHashes[i], 'content-range': `bytes ${i * CHUNK}-${i * CHUNK + b.length - 1}/${SIZE}` }), body: b,
      });
      if (r.status === 204) break;
      if (attempt >= 5 || ![408, 429, 500, 502, 503, 504].includes(r.status)) throw new Error(`chunk ${i}: ${r.status} ${await r.text()}`);
      await new Promise((ok) => setTimeout(ok, 1000 * attempt));
    }
    done++;
    if (done % 25 === 0 || done === count) log(`uploaded ${done}/${count} (${((done * CHUNK) / MiB / ((Date.now() - started) / 1000)).toFixed(0)} MiB/s)`);
  }
}
await Promise.all([sender(), sender(), sender()]);

await call('POST', `/transfers/${t.id}/complete`);
log('finalizing (server verifies, writes and reads back)…');
let final;
for (;;) {
  final = await call('GET', `/transfers/${t.id}`);
  if (['COMPLETED', 'FAILED', 'CANCELLED', 'CONFLICT'].includes(final.status)) break;
  await new Promise((ok) => setTimeout(ok, 2000));
}
if (final.status !== 'COMPLETED') throw new Error(`TR-001 FAILED: transfer ended ${final.status} ${final.errorCode ?? ''} ${final.errorMessage ?? ''}`);

const m = await call('GET', `/servers/${sid}/roots/${rid}/files/checksum?path=${encodeURIComponent(`/${name}`)}`);
if (m.sha256 !== sha || m.size !== String(SIZE)) throw new Error(`TR-001 FAILED: stored file differs (size ${m.size}, sha ${m.sha256})`);
log(`TR-001 PASSED: ${name} stored with matching SHA-256 (verification level ${final.verificationLevel})`);
if (process.env.KEEP !== '1') {
  await call('DELETE', `/servers/${sid}/roots/${rid}/files`, { items: [{ path: `/${name}` }], permanent: true }).catch(() => log(`left ${name} in place (delete it by hand)`));
}
