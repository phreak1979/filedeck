// Bundles the API, worker and CLI into plain-Node ESM files. FileDeck workspace packages (TypeScript)
// are bundled in; third-party dependencies stay external and are installed in the image from the
// generated dist/server/package.json (versions pinned to what the lockfile resolved).
import { build } from 'esbuild';
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'dist/server');
mkdirSync(out, { recursive: true });

const manifests = ['apps/api', 'apps/worker', 'packages/shared', 'packages/db', 'packages/filesystem-core',
  'packages/provider-local', 'packages/provider-sftp', 'packages/transfer-core', 'packages/server-core'];
const external = new Set();
for (const m of manifests) {
  const pkg = JSON.parse(readFileSync(join(root, m, 'package.json'), 'utf8'));
  for (const dep of Object.keys(pkg.dependencies ?? {})) if (!dep.startsWith('@filedeck/')) external.add(dep);
}
external.add('prisma'); // CLI used by the entrypoint to run migrations

const entries = {
  api: 'apps/api/src/server.ts',
  worker: 'apps/worker/src/main.ts',
  'rotate-keys': 'apps/api/src/cli-rotate-keys.ts',
  'reset-password': 'apps/api/src/cli-reset-password.ts',
};

await build({
  entryPoints: Object.fromEntries(Object.entries(entries).map(([k, v]) => [k, join(root, v)])),
  outdir: out,
  outExtension: { '.js': '.mjs' },
  bundle: true,
  platform: 'node',
  target: 'node22',
  format: 'esm',
  sourcemap: false,
  logLevel: 'info',
  external: [...external].flatMap((d) => [d, `${d}/*`]),
  banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
});

// Pin each external to the version the workspace actually resolved.
const deps = {};
for (const dep of [...external].sort()) {
  let found = null;
  for (const m of manifests) {
    const p = join(root, m, 'node_modules', dep, 'package.json');
    if (existsSync(p)) { found = JSON.parse(readFileSync(p, 'utf8')).version; break; }
  }
  if (!found) {
    try { found = JSON.parse(readFileSync(createRequire(join(root, 'package.json')).resolve(`${dep}/package.json`), 'utf8')).version; } catch { /* below */ }
  }
  if (!found) throw new Error(`cannot resolve installed version of ${dep}`);
  deps[dep] = found;
}
writeFileSync(join(out, 'package.json'), JSON.stringify({ name: 'filedeck-server', private: true, type: 'module', dependencies: deps }, null, 2) + '\n');
console.log('externals:', deps);
