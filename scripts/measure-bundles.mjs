/**
 * Record production JS/CSS asset sizes from each web app's dist output.
 * Run after `npm run build` in each app. Does not invent numbers.
 */
import { mkdir, readdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const roots = [
  { name: "marketing", dir: join("..", "..", "Platform", "marketing", ".next-build", "static") },
  { name: "marketing-legacy", dir: join("..", "..", "Platform", "marketing", ".next", "static") },
  { name: "mobistack-web", dir: join("..", "..", "MobiStack", "web", "dist") },
  { name: "oneops-web", dir: join("..", "..", "oneOps", "web", "dist") },
  { name: "mailroom-web", dir: join("..", "..", "Mailroom", "web", "dist") },
];

async function walk(dir, acc = []) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const entry of entries) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      await walk(path, acc);
    } else if (/\.(js|css|mjs)$/i.test(entry.name)) {
      const info = await stat(path);
      acc.push({ file: path.replace(/\\/g, "/"), bytes: info.size });
    }
  }
  return acc;
}

const report = { measuredAt: new Date().toISOString(), apps: [] };
const here = import.meta.dirname;

for (const app of roots) {
  const dir = join(here, app.dir);
  const files = await walk(dir);
  const js = files.filter((f) => /\.(m?js)$/i.test(f.file));
  const css = files.filter((f) => /\.css$/i.test(f.file));
  const sum = (list) => list.reduce((n, f) => n + f.bytes, 0);
  report.apps.push({
    name: app.name,
    found: files.length > 0,
    dir: dir.replace(/\\/g, "/"),
    jsBytes: sum(js),
    cssBytes: sum(css),
    totalBytes: sum(files),
    largestJs: [...js].sort((a, b) => b.bytes - a.bytes).slice(0, 8),
  });
}

const dir = join(tmpdir(), "prabhix-verify");
await mkdir(dir, { recursive: true });
const out = join(dir, "bundle-sizes.json");
await writeFile(out, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
console.error(`Wrote ${out}`);
