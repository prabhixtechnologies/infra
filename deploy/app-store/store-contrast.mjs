#!/usr/bin/env node
// Contrast for the app-store product cards.
//
//   node store-contrast.mjs
//
// The three cards on the index page each wear a different product's accent, taken from a 600-step
// primitive so the value does not change between themes. That is convenient but it means neither
// theme's contrast gate covers them: the gate asserts a brand's own accent against that brand's
// own surfaces, and here three foreign accents sit on the house surface.
//
// It is also the one placement no gate can reach: the card is `color-mix(in srgb, var(--px-
// surface) 78%, transparent)` over the page background, so the labels sit on a colour that
// exists nowhere in the tokens. web-kit asserts --px-brand-*-text against bg, surface,
// surface-raised and surface-sunken; this composite is between two of them, and measuring it is
// the only way to know it lands on the right side.
//
// Reads the generated stylesheet, so it cannot drift from the tokens. The percentage below is
// copied from store.css by hand, which is the same weak spot Identity's brand-panel-check has.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "www/assets/prabhix-tokens.css"), "utf8");

const CARD_SURFACE = 0.78; // .app background

// The house card is the default state of .app, before any data-brand applies.
const CARDS = ["technologies", "mobistack", "oneops", "mailroom"];

/**
 * A declaration, from the first of the given blocks that sets it.
 *
 * The blocks have to be listed in cascade order and the search must not fall back to "anywhere
 * in the file". Semantic roles live in a per-brand, per-mode block; the cross-brand accents and
 * tag swatches live in a brand-independent one that only varies by mode. An earlier version of
 * this script searched the whole stylesheet as a last resort, found the light `:root` value of
 * `--px-brand-oneops-text`, measured it against the dark card and reported 1.63:1 — a failure
 * that existed only in the measurement.
 */
function read(name, selectors) {
  for (const selector of selectors) {
    const at = css.indexOf(selector);
    if (at < 0) throw new Error(`no block for ${selector}`);
    const found = css.slice(at, css.indexOf("}", at)).match(new RegExp(`${name}:\\s*([^;]+);`));
    if (found) return found[1].trim();
  }
  throw new Error(`no value for ${name} in ${selectors.length} block(s)`);
}

const rgb = (hex) => {
  const s = hex.replace("#", "");
  const f = s.length === 3 ? s.split("").map((c) => c + c).join("") : s;
  return [0, 2, 4].map((i) => parseInt(f.slice(i, i + 2), 16));
};
const over = (fg, bg, a) => fg.map((c, i) => c * a + bg[i] * (1 - a));
const lum = (c) => {
  const [r, g, b] = c.map((v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const ratio = (a, b) => {
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

// The index page is the house theme in both modes; the cards sit on it. Each mode lists the
// blocks that can set a name, nearest first: the house theme's roles, then the mode-only block
// holding the cross-brand accents, then the primitives in :root.
// The brand-independent block is anchored on the comment the generator writes above it, because
// the stylesheet has two blocks whose selector is exactly `:root {` and the first one holds the
// primitive ramps.
const CROSS_BRAND = "/* categorical series, tag swatches and cross-brand accents */\n:root {";
const MODES = {
  light: [':root,\n[data-brand="technologies"] {', CROSS_BRAND],
  dark: ['[data-brand="technologies"][data-theme="dark"] {', '[data-theme="dark"] {'],
};

let worst = { ratio: Infinity, what: "" };
const rows = [];

for (const [mode, selectors] of Object.entries(MODES)) {
  const bg = rgb(read("--px-bg", selectors));
  const surface = rgb(read("--px-surface", selectors));
  const card = over(surface, bg, CARD_SURFACE);

  for (const product of CARDS) {
    // .app-kicker and .app-cta both take --accent-text, which each card remaps to its own
    // product. The house card leaves it at the page's --px-accent-text.
    const name = product === "technologies" ? "--px-accent-text" : `--px-brand-${product}-text`;
    const r = ratio(rgb(read(name, selectors)), card);
    const what = `${product} label (${mode})`;
    rows.push({ what, ratio: r, name });
    if (r < worst.ratio) worst = { ratio: r, what };
  }
}

// 4.5:1. These are small bold labels — .app-kicker is 0.68rem, .app-cta 0.95rem — so neither
// qualifies for the 3:1 large-text allowance.
const MIN = 4.5;
const failures = rows.filter((r) => r.ratio < MIN);

for (const r of rows.sort((a, b) => a.ratio - b.ratio)) {
  console.log(`  ${r.ratio < MIN ? "FAIL" : "ok  "} ${r.ratio.toFixed(2)}:1  ${r.what.padEnd(28)} ${r.name}`);
}
console.log(`\nworst: ${worst.ratio.toFixed(2)}:1 (${worst.what}), floor ${MIN}:1`);

if (failures.length) {
  console.error(`\nFAILED: ${failures.length} of ${rows.length} below ${MIN}:1.`);
  process.exit(1);
}
console.log(`PASS — ${rows.length} assertions.`);
