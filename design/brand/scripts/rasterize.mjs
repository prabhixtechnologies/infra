import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const svgDir = join(root, "svg");
const outDir = join(root, "raster");
mkdirSync(outDir, { recursive: true });

const jobs = [
  { file: "prabhix-mark.svg", name: "prabhix-mark", sizes: [32, 180, 192, 512, 1024] },
  { file: "prabhix-technologies-mark.svg", name: "prabhix-technologies-mark", sizes: [32, 180, 192, 512, 1024] },
  { file: "prabhix-mark-on-paper.svg", name: "prabhix-mark-on-paper", sizes: [192, 512, 1024] },
  { file: "mobistack-mark.svg", name: "mobistack-mark", sizes: [192, 512, 1024] },
  { file: "mobistack-mark-adaptive.svg", name: "mobistack-mark-adaptive", sizes: [1024] },
  { file: "favicon.svg", name: "favicon", sizes: [32, 48] },
];

for (const job of jobs) {
  const svg = readFileSync(join(svgDir, job.file));
  for (const width of job.sizes) {
    const png = new Resvg(svg, { fitTo: { mode: "width", value: width } }).render().asPng();
    const dest = join(outDir, `${job.name}-${width}.png`);
    writeFileSync(dest, png);
    console.log(dest);
  }
}
