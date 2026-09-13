/**
 * Browser pass: public marketing matrix + Identity-authenticated product journeys.
 *
 * Usage (servers must already be listening):
 *   $env:MARKETING_URL="http://127.0.0.1:3000"
 *   $env:ONEOPS_URL="http://127.0.0.1:5173"
 *   $env:MAILROOM_URL="http://127.0.0.1:5175"
 *   $env:MOBISTACK_URL="http://127.0.0.1:5176"
 *   $env:IDENTITY_URL="http://127.0.0.1:8081"
 *   $env:VERIFY_EMAIL="..."
 *   $env:VERIFY_PASSWORD="..."
 *   node verify-surfaces.mjs
 *
 * After Identity login, storageState is saved once the product callback lands
 * (cookies are host-only; Identity :8081 cookies are kept in the shared context).
 */
import { mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium } from "playwright";

const VIEWPORTS = [
  { name: "320", width: 320, height: 720 },
  { name: "375", width: 375, height: 812 },
  { name: "390", width: 390, height: 844 },
  { name: "414", width: 414, height: 896 },
  { name: "768", width: 768, height: 1024 },
  { name: "1024", width: 1024, height: 768 },
  { name: "1280", width: 1280, height: 800 },
  { name: "1440", width: 1440, height: 900 },
  { name: "1920", width: 1920, height: 1080 },
];

const AUTH_VIEWPORTS = VIEWPORTS.filter((v) =>
  ["320", "375", "768", "1280"].includes(v.name),
);

const FULL_MATRIX_PATHS = ["/", "/shop", "/shop/checkout"];
const SPOT_PATHS = ["/pricing", "/shop/cart", "/contact", "/legal/privacy"];

const report = {
  startedAt: new Date().toISOString(),
  pages: [],
  axe: [],
  keyboard: [],
  memory: [],
  auth: [],
  shopFlow: null,
  skipped: [],
};

function envUrl(name) {
  const value = process.env[name];
  return value && value.trim() ? value.replace(/\/$/, "") : null;
}

async function axeViolations(page) {
  const axePath = join(
    import.meta.dirname,
    "node_modules",
    "axe-core",
    "axe.min.js",
  );
  await page.addScriptTag({ path: axePath });
  return page.evaluate(async () => {
    const results = await window.axe.run(document, {
      runOnly: {
        type: "tag",
        values: ["wcag2a", "wcag2aa"],
      },
    });
    return results.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      nodes: v.nodes.length,
      targets: v.nodes.slice(0, 3).map((n) => n.target),
    }));
  });
}

/** Enable CSP bypass for this page before any document load (needed for axe). */
async function enableAxeCspBypass(page) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Page.setBypassCSP", { enabled: true });
}

async function setTheme(page, mode) {
  await page.evaluate((next) => {
    localStorage.setItem("theme", next);
    document.documentElement.classList.toggle("dark", next === "dark");
    document.documentElement.dataset.theme = next;
  }, mode);
}

async function overflowX(page) {
  return page.evaluate(
    () => document.documentElement.scrollWidth > document.documentElement.clientWidth + 2,
  );
}

async function firstTabTarget(page) {
  await page.keyboard.press("Tab");
  return page.evaluate(
    () =>
      document.activeElement?.textContent?.trim()?.slice(0, 80) ||
      document.activeElement?.getAttribute("aria-label") ||
      document.activeElement?.tagName,
  );
}

/** SPA soft navigate — avoids full reload that drops in-memory OIDC access tokens. */
async function softNavigate(page, origin, path) {
  const target = `${origin}${path}`;
  if (page.url().startsWith(origin)) {
    const link = page.locator(`a[href="${path}"], a[href="${target}"]`).first();
    if ((await link.count()) > 0) {
      await link.click({ timeout: 3000 }).catch(() => {});
      await page.waitForTimeout(400);
      if (page.url().startsWith(origin) && !page.url().includes("/login")) {
        return;
      }
    }
    await page.evaluate((p) => {
      window.history.pushState({}, "", p);
      window.dispatchEvent(new PopStateEvent("popstate"));
    }, path);
    await page.waitForTimeout(500);
    return;
  }
  await page.goto(target, { waitUntil: "domcontentloaded", timeout: 45000 });
}

async function sampleSurface(page, origin, path, viewport, { soft = false } = {}) {
  await page.setViewportSize({ width: viewport.width, height: viewport.height });
  try {
    if (soft) await softNavigate(page, origin, path);
    else {
      await page.goto(`${origin}${path}`, {
        waitUntil: "domcontentloaded",
        timeout: 45000,
      });
    }
  } catch (err) {
    report.pages.push({ origin, path, viewport: viewport.name, error: String(err) });
    return;
  }
  await page.waitForTimeout(250);
  const entry = {
    origin,
    path,
    viewport: viewport.name,
    title: await page.title().catch(() => ""),
    h1: await page
      .locator("h1")
      .first()
      .innerText()
      .catch(() => ""),
    overflowX: await overflowX(page),
    url: page.url(),
  };
  report.pages.push(entry);
  return entry;
}

async function axeAndKeyboard(page, origin, path, { soft = false } = {}) {
  await page.setViewportSize({ width: 1280, height: 800 });
  if (soft) await softNavigate(page, origin, path);
  else {
    await page
      .goto(`${origin}${path}`, { waitUntil: "networkidle", timeout: 45000 })
      .catch(() =>
        page.goto(`${origin}${path}`, { waitUntil: "domcontentloaded", timeout: 45000 }),
      );
  }
  try {
    report.axe.push({ origin, path, violations: await axeViolations(page) });
  } catch (err) {
    report.axe.push({ origin, path, error: String(err) });
  }
  report.keyboard.push({
    origin,
    path,
    firstFocus: await firstTabTarget(page),
  });
}

/**
 * Hosted Identity: identify → password. Works from an OIDC authorize redirect
 * or a direct /login visit. Leaves the Identity session cookie on :8081.
 * If Identity SSO already has a session, returns as soon as we leave Identity.
 */
async function identityPasswordLogin(page, email, password) {
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    const url = page.url();
    if (!url.includes(":8081") && !url.includes("/oauth2/")) {
      return;
    }
    if (url.includes("/oauth2/authorize")) {
      await page.waitForTimeout(250);
      continue;
    }
    // Prefer role/label over :visible — more reliable across Identity stages.
    const passwordField = page.locator("#password");
    if ((await passwordField.count()) > 0 && (await passwordField.isVisible().catch(() => false))) {
      await passwordField.fill(password);
      await page.getByRole("button", { name: /sign in|continue/i }).first().click();
      await page.waitForTimeout(600);
      continue;
    }
    const emailField = page.locator("#email");
    if ((await emailField.count()) > 0 && (await emailField.isVisible().catch(() => false))) {
      await emailField.fill(email);
      await page.getByRole("button", { name: /continue/i }).first().click();
      await page.waitForTimeout(600);
      continue;
    }
    await page.waitForTimeout(300);
  }
  throw new Error(`Identity login did not finish (last url=${page.url()})`);
}

async function oidcSignInToProduct(context, productUrl, email, password, label) {
  const page = await context.newPage();
  await enableAxeCspBypass(page);
  const started = Date.now();
  try {
    await page.goto(productUrl, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.waitForTimeout(600);

    // MobiStack keeps a gateway with an explicit Sign in button (no auto-redirect).
    const signIn = page.getByRole("button", { name: /^sign in$/i });
    if ((await signIn.count()) > 0 && (await signIn.first().isVisible().catch(() => false))) {
      await signIn.first().click();
      await page.waitForTimeout(500);
    }

    if (
      page.url().includes(":8081") ||
      /\/(login|sign-in|oauth2)/.test(page.url()) ||
      (await page.locator("#email, #password").count()) > 0
    ) {
      await identityPasswordLogin(page, email, password);
    }

    // Must be on the product origin, past callback/login shells, with app chrome ready.
    await page.waitForFunction(
      (origin) => {
        const href = location.href;
        if (!href.startsWith(origin)) return false;
        if (/\/(login|sign-in|auth\/callback)/.test(href)) return false;
        const h1 = document.querySelector("h1")?.textContent?.trim() ?? "";
        if (/sign in once|^welcome$/i.test(h1)) return false;
        if (/restoring your session/i.test(h1)) return false;
        return true;
      },
      productUrl,
      { timeout: 90000 },
    );
    const statePath = join(tmpdir(), "prabhix-verify", `${label}-storage.json`);
    await mkdir(join(tmpdir(), "prabhix-verify"), { recursive: true });
    await context.storageState({ path: statePath });
    report.auth.push({
      label,
      productUrl,
      landed: page.url(),
      ms: Date.now() - started,
      storageState: statePath,
      ok: true,
    });
    return page;
  } catch (err) {
    report.auth.push({
      label,
      productUrl,
      landed: page.url(),
      ms: Date.now() - started,
      ok: false,
      error: String(err),
    });
    await page.close().catch(() => {});
    return null;
  }
}

async function clickThroughShop(page, origin) {
  const steps = [];
  await page.goto(`${origin}/shop`, { waitUntil: "domcontentloaded", timeout: 45000 });
  steps.push({
    path: "/shop",
    h1: await page
      .locator("h1, h2")
      .first()
      .innerText()
      .catch(() => ""),
  });
  const product = page
    .locator("a[href^='/shop/']")
    .filter({ hasNot: page.locator("[href='/shop']") })
    .first();
  if ((await product.count()) > 0) {
    await product.click({ timeout: 8000 }).catch(() => {});
    steps.push({ path: page.url().replace(origin, ""), status: "pdp" });
    const add = page.getByRole("button", { name: /add to cart|buy|purchase/i }).first();
    if ((await add.count()) > 0) {
      await add.click({ timeout: 8000 }).catch(() => {});
    }
  } else {
    steps.push({ path: "/shop", note: "catalog empty — not mocked" });
  }
  await page.goto(`${origin}/shop/cart`, { waitUntil: "domcontentloaded", timeout: 45000 });
  steps.push({
    path: "/shop/cart",
    h1: await page
      .locator("h1, h2")
      .first()
      .innerText()
      .catch(() => ""),
  });
  await page.goto(`${origin}/shop/checkout`, { waitUntil: "domcontentloaded", timeout: 45000 });
  steps.push({
    path: "/shop/checkout",
    h1: await page
      .locator("h1, h2")
      .first()
      .innerText()
      .catch(() => ""),
  });
  const pay = page.getByRole("button", { name: /pay|razorpay|place order|checkout/i }).first();
  if ((await pay.count()) > 0) {
    await pay.click({ timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(1500);
    steps.push({
      path: "/shop/checkout",
      razorpayAttempted: true,
      note: "opened pay control if present; did not fake a paid order",
      url: page.url(),
    });
  }
  return steps;
}

async function runMarketing(browser, origin) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await enableAxeCspBypass(page);

  for (const path of [...FULL_MATRIX_PATHS, ...SPOT_PATHS]) {
    const matrix = FULL_MATRIX_PATHS.includes(path)
      ? VIEWPORTS
      : VIEWPORTS.filter((v) => ["320", "375", "768", "1280", "1920"].includes(v.name));
    for (const vp of matrix) {
      await page.setViewportSize({ width: vp.width, height: vp.height });
      for (const theme of path === "/" || path === "/shop" ? ["light", "dark"] : ["dark"]) {
        await page.goto(`${origin}${path}`, { waitUntil: "domcontentloaded", timeout: 45000 });
        await setTheme(page, theme);
        await page.waitForTimeout(200);
        report.pages.push({
          origin,
          path,
          viewport: vp.name,
          theme,
          title: await page.title(),
          h1: await page
            .locator("h1")
            .first()
            .innerText()
            .catch(() => ""),
          overflowX: await overflowX(page),
        });
      }
    }
  }

  for (const path of ["/", "/shop", "/shop/cart", "/shop/checkout", "/pricing", "/contact"]) {
    await axeAndKeyboard(page, origin, path);
  }

  report.shopFlow = await clickThroughShop(page, origin);

  // Heap with expose-gc: flush between laps so a climb is a real retainer.
  const samples = [];
  for (let i = 0; i < 12; i += 1) {
    await page.goto(`${origin}/`, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.goto(`${origin}/shop`, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.goto(`${origin}/pricing`, { waitUntil: "domcontentloaded", timeout: 45000 });
    const heap = await page.evaluate(() => {
      if (typeof gc === "function") gc();
      return performance.memory?.usedJSHeapSize ?? null;
    });
    samples.push(heap);
  }
  const usable = samples.filter((n) => typeof n === "number");
  report.memory.push({
    origin,
    routeLoop: "home → shop → pricing × 12 with gc()",
    usedJSHeapSize: samples,
    firstMb: usable.length ? +(usable[0] / 1048576).toFixed(1) : null,
    lastMb: usable.length ? +(usable[usable.length - 1] / 1048576).toFixed(1) : null,
    note:
      usable.length === 0
        ? "performance.memory unavailable"
        : usable[usable.length - 1] - usable[0] < 8 * 1048576
          ? "heap stable after GC (prior climb was GC-off)"
          : "heap still climbing after GC — inspect retainers",
  });

  await context.close();
}

async function runSignInShell(browser, origin, label) {
  if (!origin) {
    report.skipped.push(`${label}: no URL`);
    return;
  }
  const page = await browser.newPage();
  try {
    await sampleSurface(page, origin, "/", AUTH_VIEWPORTS.find((v) => v.name === "375"));
    await axeAndKeyboard(page, origin, "/");
  } catch (err) {
    report.skipped.push(`${label}: ${err}`);
  } finally {
    await page.close();
  }
}

async function driveAuthenticatedProduct(context, origin, label, paths) {
  if (!origin) {
    report.skipped.push(`${label} auth: no URL`);
    return;
  }
  const email = process.env.VERIFY_EMAIL;
  const password = process.env.VERIFY_PASSWORD;
  if (!email || !password) {
    report.skipped.push(`${label} auth: VERIFY_EMAIL/PASSWORD unset`);
    return;
  }

  const page = await oidcSignInToProduct(context, origin, email, password, label);
  if (!page) return;

  // MobiStack may land on workspaces with no shop — create one via the create tab.
  if (label === "MobiStack" && /workspaces|set up your first shop/i.test(page.url() + (await page.locator("h1").first().innerText().catch(() => "")))) {
    await page.getByRole("tab", { name: /create shop/i }).click().catch(() => {});
    await page.waitForTimeout(300);
    const name = page.getByLabel(/shop name/i);
    if ((await name.count()) > 0) {
      await name.fill("Laptop Verify Shop");
      await page.getByRole("button", { name: /create/i }).last().click().catch(() => {});
      await page.waitForTimeout(2500);
    }
    const open = page.getByRole("button", { name: /open shop/i }).first();
    if ((await open.count()) > 0) {
      await open.click().catch(() => {});
      await page.waitForTimeout(1500);
    }
  }

  for (const path of paths) {
    for (const vp of AUTH_VIEWPORTS) {
      await sampleSurface(page, origin, path, vp, { soft: true });
    }
    await axeAndKeyboard(page, origin, path, { soft: true });
  }
  await page.close().catch(() => {});
}

const marketing = envUrl("MARKETING_URL");
const mobistack = envUrl("MOBISTACK_URL");
const oneops = envUrl("ONEOPS_URL");
const mailroom = envUrl("MAILROOM_URL");
const identity = envUrl("IDENTITY_URL") || "http://localhost:8081";

if (!marketing && !mobistack && !oneops && !mailroom) {
  console.error("Set MARKETING_URL and optionally MOBISTACK_URL, ONEOPS_URL, MAILROOM_URL");
  process.exit(1);
}

const browser = await chromium.launch({
  headless: true,
  args: ["--js-flags=--expose-gc", "--enable-precise-memory-info"],
});

try {
  if (marketing && process.env.SKIP_MARKETING !== "1") await runMarketing(browser, marketing);
  else if (!marketing) report.skipped.push("marketing: MARKETING_URL unset");
  else report.skipped.push("marketing: SKIP_MARKETING=1");

  // Public/sign-in shells — skip when we are about to drive authenticated journeys
  // (auto-OIDC shells race Identity login if left mid-redirect).
  if (!process.env.VERIFY_EMAIL) {
    await runSignInShell(browser, mobistack, "MobiStack");
    await runSignInShell(browser, oneops, "OneOps");
    await runSignInShell(browser, mailroom, "Mailroom");
  } else {
    report.skipped.push("sign-in shells: skipped because VERIFY_EMAIL set");
  }

  // Shared browser context keeps Identity :8081 session for SSO across products.
  if (process.env.VERIFY_EMAIL && process.env.VERIFY_PASSWORD) {
    const authContext = await browser.newContext();
    const idPage = await authContext.newPage();
    await enableAxeCspBypass(idPage);
    await idPage.goto(`${identity}/login`, { waitUntil: "domcontentloaded", timeout: 30000 });
    report.keyboard.push({
      origin: identity,
      path: "/login",
      firstFocus: await firstTabTarget(idPage),
    });
    try {
      report.axe.push({
        origin: identity,
        path: "/login",
        violations: await axeViolations(idPage),
      });
    } catch (err) {
      report.axe.push({ origin: identity, path: "/login", error: String(err) });
    }
    await idPage.close();

    await driveAuthenticatedProduct(authContext, oneops, "OneOps", [
      "/",
      "/chat",
      "/visitors",
      "/commerce/products",
      "/members",
    ]);
    await driveAuthenticatedProduct(authContext, mailroom, "Mailroom", [
      "/",
      "/queue",
      "/settings/mailboxes",
    ]);
    await driveAuthenticatedProduct(authContext, mobistack, "MobiStack", [
      "/workspaces",
      "/",
      "/sales",
      "/repairs",
      "/inventory",
    ]);
    await authContext.close();
  } else {
    report.skipped.push("authenticated journeys: VERIFY_EMAIL/PASSWORD unset");
  }
} finally {
  await browser.close();
}

report.finishedAt = new Date().toISOString();
const dir = join(tmpdir(), "prabhix-verify");
await mkdir(dir, { recursive: true });
const out = join(dir, "surfaces.json");
await writeFile(out, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
console.error(`Wrote ${out}`);
