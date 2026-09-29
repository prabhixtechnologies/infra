# UI/UX plan — getting the apps, webs and views to industry level

Companion to [UX-STANDARD.md](UX-STANDARD.md), which is the contract this plan delivers. Read the
verdict and § "Why it looks unfinished" first; the phases only make sense once the four structural
causes are clear.

---

## Status — phases 0 to 6 delivered, 2026-09-29

Everything below this section was written as a pre-work audit. It is kept because the analysis of
*why* the front end looked unfinished is still the best record of it, but it is no longer a
description of the product. Read it as the baseline, not the present.

| Phase | State |
|---|---|
| 0 — Broken things | Done. All 14 verified defects fixed. |
| 1 — Token system | Done. One `tokens.json` generates the CSS, the Tailwind preset, the Dart theme and the docs. Five brands x two modes, 310 contrast assertions in CI. |
| 2 — Primitive library | Done. 45 primitives with a preset and seven test suites, up from the 20 in the scorecard. Five of the planned remainder (date picker, time picker, menubar, sidebar, chart) were dropped after checking for consumers: the whole workspace holds two date inputs, `charts.tsx` already exists, the three app shells are genuinely app-specific, and nothing resembles a menubar. |
| 3 — Interaction layer | Done. Context menus with right-click and 700 ms touch long-press, list engine, URL state, command palette, hotkeys, unsaved-changes guards. |
| 4 — Flutter | Done. Gestures, semantics, tooltips, autofill, all four apps on the generated theme. |
| 5 — Marketing + Identity | Done except product screenshots, which need a seeded stack to capture. |
| 6 — Guardrails | Done. Seven gates across eight repos: token sync and contrast, colour literals (including Flutter's named palette), mojibake, peer dependencies, one `h1` per page, the sign-in brand panel, and axe in seven suites across five repos. |

Released to Play Internal testing on 2026-09-29: Admin, Mailroom and OneOps at `1.1.0+4`,
MobiStack at `1.3.0+9`.

### The one thing the phases did not anticipate

Every brand was defined, every theme block generated, every pair contrast-asserted — and the
marketing site still drew all three products in the same teal. `@theme` emits
`:root { --color-accent: var(--px-accent) }`, and a custom property is substituted on the element
that *declares* it, so the accent resolved once at the root and descendants inherited a finished
colour. `data-brand` on a card did nothing. It survived this long because `[data-theme="dark"]`
sits on `<html>`, which *is* `:root`, so dark mode always worked, and each single-brand app sets
its brand at the root too. Only a page showing two products at once could expose it.

The fix was `@theme inline` for the colour aliases, plus a descendant form of the dark selector so
a brand declared below the root resolves in either mode.

It is worth recording how it was found, because it is the gap in Phase 6: it passed typecheck, 73
tests and all six gates that existed at the time, and was caught by looking at the rendered page.
The gates assert that a colour is *legible*. None of them asserts that two things which should
differ do.

That gap is now closed, and the reservation recorded here was right about the hard part. Committed
screenshot baselines shared between Linux CI and a Windows desktop *would* have flaked on font
rendering before catching anything, so the suite does not use any: the load-bearing tests compare
two renders from the same run against each other, which cancels out fonts, platform and rasteriser
and leaves only what the brand changed. Baselines exist for the different question of whether
anything drifted since last time, and are opt-in and generated on Linux. See § Closed since.

### Still open

- **Marketing product screenshots.** Needs a seeded stack; locally the apps only reach sign-in.
- **Public-ECR pull quota.** `429 Data limit exceeded` blocks container image pushes for MobiStack,
  and intermittently Platform, Mailroom and Infra. Every code job passes. Pushing in waves with
  `Infra/scripts/push-waves.ps1` avoids it in practice; the durable fix is two IAM permissions on
  `PrabhixPlatformDeployer`, and the base images are already mirrored into `prabhix/third-party/*`.
### Closed since

- **`data-density` did nothing.** Found by the visual suite on its first run, fixed now. The
  attribute was set on `<html>`, documented in `TOKENS.md`, and generated five custom properties
  that nothing read — searching all eight repositories for `--px-density-` found only the lines in
  `build-tokens.mjs` that wrote it. The primitives sized themselves with fixed Tailwind spacing, so
  an app could ask for compact and render comfortable, and had done since the tokens landed.

  `Button`, `Input`, `Select`, `ToggleGroup`, `Tabs`, `Accordion` and the table rows now read
  `--px-density-control`, `-pad-x`, `-pad-y` and `-row`. Two things had to be settled first. The
  token said a comfortable control was 40px while every control shipped at 44px, which nobody had
  reconciled because the number had no consequence; the shipped sizes won, so comfortable is 44px
  (the WCAG 2.5.5 AAA pointer target `button.tsx` chose deliberately for tablet use) and compact is
  36px rather than 32px — a real reduction, still well clear of the 24px AA floor in 2.5.8. And
  `bodyRole` emitted a role *name*, which CSS cannot dereference, so `build-tokens.mjs` now resolves
  it against `scale.type` into a size and a line height that a utility can consume.

  In practice this changes one shipped surface: the **Admin console**, which is `oneOps/web` with
  `APP=admin` and the only compact app that uses the UI package. MobiStack sets `compact` but has no
  Tailwind and no `@prabhixtechnologies/ui`, and Mailroom and Platform are comfortable. The OneOps
  app keeps its 44px controls and sees only table metrics move.

  Validated by planting the regression: reverting `Button` to a hardcoded `min-h-11` fails with
  `default button under compact — Expected: 36, Received: 44`.


- **Visual regression.** Done. `web-kit/gallery` is a private Vite workspace holding every primitive
  on one page, with brand, mode and density in the query string. 20 Playwright tests run in CI on
  every push. The load-bearing ones compare renders from the same run against each other rather than
  against stored bytes — five brands must not render alike, dark must not render like light, and a
  `data-brand` below the root must take its own accent — so they need no committed baselines and give
  the same answer on any platform. Pixel baselines exist behind `VR_BASELINE=1` for the separate
  question of whether anything changed since last time.

  Validated by reintroducing the original bug, and the first attempt is the part worth keeping:
  eleven tests passed with the defect present. A brand on `<html>` cannot reproduce it, because the
  root is exactly where the broken alias resolved correctly — what failed was a brand scope *below*
  the root. Details and the rest of the traps in `web-kit/gallery/README.md`.

---

## Verdict

*As audited, before the work below was done. Superseded by § Status.*

The backend and the security work are ahead of the front end by a wide margin, and the gap is not a
matter of taste. Measured against the tools these products compete with, the front end is missing
three whole layers that those tools have:

1. **A design system.** What exists is 20 CSS variables and 20 React primitives. There is no spacing
   scale, no type scale, no elevation scale, no state colours, no z-index scale, no density mode, and
   no warning or info colour. So every app invented its own, and they disagree.
2. **An interaction layer.** There are **zero** right-click context menus in the entire portfolio.
   There is **one** `HapticFeedback` call across 55k lines of Dart. There are **zero** `Semantics`
   labels. Keyboard support exists on exactly one screen (OneOps chat) out of roughly sixty. The
   products can only be operated by clicking precisely on the thing you want, which is the slowest
   possible way to run a repair counter or a mail queue.
3. **Designed non-happy-path states.** Loading is a centred spinner, empty is often a bare sentence,
   and errors frequently print the raw exception — `'$e'` in Dart, `error.message` in React. Those are
   the states users hit most on a bad shop-floor connection, and they are where the products look
   abandoned.

None of this is a rewrite. It is roughly four months of focused work, and the first week is mostly
fixing things that are outright broken.

## What was audited

Every UI surface in the workspace — about 131,000 lines across seven repositories — read by six
parallel audits, with the load-bearing claims re-verified directly afterwards.

| Surface | Tree | Code |
|---|---|---|
| Four Flutter apps + shared packages | `Mobile/apps`, `Mobile/packages` | 389 files / 55.4k lines |
| OneOps web + Admin web (one tree, two builds) | `oneOps/web/src` | 184 files / 27.7k lines |
| MobiStack web console | `MobiStack/web/src` | 96 files / 18.3k lines |
| Mailroom webmail | `Mailroom/web/src` | 35 files / 4.4k lines |
| Marketing site | `Platform/marketing/src` | 173 files / 12.9k lines |
| Design system + hosted login | `web-kit/packages`, `Identity/src/main/resources` | 36 files / 3.1k lines |

Every count and every defect in this document was verified against the code directly, not inferred.

---

## Why it looks unfinished

Four structural facts explain nearly every individual complaint. Fixing the symptoms without fixing
these means re-fixing them in six months.

### The token file is 68 lines, copied four times by hand

`Infra/design/prabhix-tokens.css`, `web-kit/packages/brand/prabhix-tokens.css` and
`Identity/src/main/resources/static/assets/prabhix-tokens.css` are byte-identical today — and are
kept that way manually. `Infra/design/brand/README.md:3` instructs "copy these files into each
product — do not import across repos." There is no generator, no CI check, and no Dart output at all,
so the four Flutter apps each keep their own hand-typed hex array in `lib/theme/prabhix_theme.dart`.
MobiStack's Flutter accent is `#0A8F78` where web is `#0E7490`. The portfolio drifts by construction.

Because the token set stops at 20 semantic colours, everything else is improvised: **268**
`EdgeInsets` and **269** `SizedBox` literals in Dart, **92** inline `fontSize`, nine different border
radii, **197** hardcoded hex values in `MobiStack/web/src/styles.css`, and `--px-accent-strong`
invented locally in `oneOps/web/src/index.css:12`.

And one token is doing a job it cannot do. `--px-border` is `#d5dee8` on `#ffffff`, a contrast ratio
of **1.36:1** (dark theme: `#1c3342` on `#0d1a24`, **1.35:1**). That is perfectly fine for a
decorative divider, and WCAG does not ask for more. The problem is that it is also the *only* border
token, so it is what draws input outlines, select triggers, checkbox edges and card boundaries —
and a boundary that identifies a control needs 3:1 under WCAG 1.4.11. Every text field in the
portfolio is therefore drawn with a line six times fainter than the floor, which is both a real
accessibility failure and why forms read as smudges rather than edges. The fix is a second token:
`border` stays subtle for dividers, `border-strong` clears 3:1 and draws every control.

### `@prabhixtechnologies/ui` is a source folder, and only one app uses it

Twenty primitives present out of a 55-item production checklist. Missing: **context-menu**,
data-table, form/field wiring, sheet/drawer, card, alert, empty-state, pagination, breadcrumb,
spinner, radio-group, combobox, date-picker, file-dropzone, copy-button, scroll-area, accordion,
tree-view, virtualized-list, segmented-control, stepper, chart primitives, and fourteen more.

It also has no build (`package.json` exports point at `./src/index.ts`), no published artifact, no
tests, and no Storybook. It ships no Tailwind preset, so each app re-aliases the tokens in its own
`index.css` — which is how they drift even when the token file matches.

Adoption: OneOps and Admin use it through a re-export layer. **MobiStack web: zero imports. Mailroom
web: zero imports. Marketing: zero imports.** Mailroom forks button, badge and avatar; MobiStack
hand-rolled `Modal`, `Menu`, `DataTable`, `Toast` and `GlobalSearch`. Four apps, four design systems,
one of which happens to live in a package.

### There is no interaction layer

Verified by grep across all four web apps and `web-kit`:

| Capability | Count in the entire portfolio |
|---|---|
| Right-click context menus | **0** |
| Flutter `Semantics` / `semanticLabel` | **0** |
| Flutter `HapticFeedback` calls | **1** |
| Flutter `Dismissible` / `ReorderableListView` / `InteractiveViewer` | **0** |
| Flutter `LayoutBuilder` (any responsive layout) | **0** |
| Flutter `autofillHints` / form `validator:` | **0** / **0** |
| Web pages serializing filter state to the URL | 7 of ~50 list surfaces |
| Web surfaces with list keyboard navigation | 1 (OneOps chat) |
| Web optimistic updates / undo | **0** |
| Web unsaved-changes guards | **0** |
| Web copy-to-clipboard affordances | 1 |
| Web breadcrumbs | **0** |
| Web sticky table headers | **0** |

`react-hook-form@7.57.0` is installed in OneOps and used **zero** times; every form is hand-rolled
`useState` with manual `isEmpty` checks.

### The happy path is the only path

**22** `CircularProgressIndicator` against **1** shimmer skeleton in Flutter. Raw exception text
reaches users in at least a dozen places (`MobiStack/web/src/ui/ErrorBoundary.tsx:50`,
`Mobile/apps/mobistack/lib/widgets/live_api_list.dart:119`,
`Mobile/apps/oneops/lib/screens/more_screen.dart:93`, `oneOps/web/src/features/ops/InfraPage.tsx:137`).
Toast coverage is patchy to absent — OneOps helpdesk and mail settings fire **no** toasts at all, so
assigning a ticket or saving a routing rule succeeds silently. None of the three consoles has a real
`404`; all of them silently redirect unknown URLs home.

---

## Scorecard

*Scored at audit time. Every row's "Notes" column describes a state that the phases below have
since changed — the primitive library has a preset and tests, MobiStack has a scanner path,
Mailroom has a mail keyboard, Identity's pages render and its fonts load, and all four Flutter
apps have a dark theme. Kept as the baseline these were measured against.*

Ten is the standard in [UX-STANDARD.md](UX-STANDARD.md). These are honest, not kind.

| Surface | Visual | Layout / IA | Interaction | States | A11y | Notes |
|---|---|---|---|---|---|---|
| `web-kit` design system | 3 | — | 2 | — | 5 | 20 of 55 primitives, no build, no tests, no preset |
| OneOps web | 7 | 6 | 4 | 6 | 6 | Best-engineered surface; chat is the reference, inbox is not |
| Admin web | 5 | 6 | 3 | 5 | 6 | Reads as "OneOps plus a badge", not a control tower |
| MobiStack web | 6 | 6 | 2 | 6 | 5 | Command palette is dead code; no scanner input path |
| Mailroom web | 6 | 5 | 2 | 7 | 4 | Best empty states in the portfolio; no mail keyboard at all |
| Marketing site | 5 | 6 | 6 | 7 | 5 | Well-built, but zero product imagery anywhere |
| Identity login | 4 | 6 | 3 | 5 | 5 | Two pages render unstyled; house fonts never load |
| Flutter — MobiStack | 7 | 5 | 4 | 6 | 2 | Only app with a dark theme and a real widget kit |
| Flutter — Mailroom | 6 | 5 | 6 | 7 | 2 | Only app with swipe, multi-select and haptics |
| Flutter — OneOps | 4 | 5 | 2 | 4 | 2 | Stock `ListTile`s, plain-text errors, light-only |
| Flutter — Admin | 4 | 4 | 2 | 4 | 2 | Whole app is one screen with five tabs, unrouted |

Two useful patterns already exist and should be copied rather than reinvented: Mailroom Flutter's
mailbox (`Mobile/apps/mailroom/lib/screens/mailbox_screen.dart` — swipe, long-press selection, undo,
haptics, shimmer, sync bar) and OneOps web's chat (`oneOps/web/src/features/chat/ChatPage.tsx` —
shortcuts, virtualization, SSE, live region). Both are close to the standard. Neither has been
generalised.

---

## Phase 0 — Fix what is broken

One week. None of this is design work; these are defects a user can hit today.

| # | Defect | Evidence |
|---|---|---|
| 1 | **MobiStack's command palette is dead code.** `GlobalSearch` is defined but never mounted anywhere — the dashboard's "Search / Scan" and "Scan barcode" buttons dispatch an event nothing listens to, and `Ctrl+K` does nothing. | `MobiStack/web/src/ui/GlobalSearch.tsx:49`, `pages/DashboardPage.tsx:475`; zero `<GlobalSearch` in the tree |
| 2 | **Two Identity pages render unstyled.** Logout-confirm and magic-link-confirm use `.login-page`, `.login-card` and `.btn-primary`; none of the three is defined in any Identity stylesheet. Users see raw browser HTML mid-auth. | `templates/logout-confirm.html:12-20`, `templates/magic-link-confirm.html:12-20` vs `static/assets/login.css` |
| 3 | **MobiStack Flutter voids a sale on long-press with no confirmation** and no undo. An accidental press on a row destroys a financial record. | `Mobile/apps/mobistack/lib/screens/sales_screen.dart:344` |
| 4 | **Web device-seat enforcement is switched off.** `usePresence(false)` means no heartbeat, while Settings displays seat counts as if it were enforced. | `MobiStack/web/src/ui/AppShell.tsx:53` |
| 5 | **OneOps Flutter fulfils an order with no confirmation.** | `Mobile/apps/oneops/lib/screens/orders_screen.dart:55` |
| 6 | **MobiStack Flutter bottom nav highlights the wrong tab** on `/inventory`, `/sales` and `/repairs` — `indexWhere` misses and falls back to `0`. | `Mobile/apps/mobistack/lib/screens/shell_screen.dart:31` |
| 7 | **Mailroom drafts cannot be opened.** `useDrafts` is implemented and never called; `ComposeDialog` accepts a `draft` prop nothing passes. | `Mailroom/web/src/features/mail/mailbox.ts:175`, `MailPage.tsx:392` |
| 8 | **Identity swallows the account-lockout message.** The service raises specific copy, the controller overwrites it with a generic error, so a locked-out user is told nothing useful. | `LoginController.java:92`, `CredentialService.java:137` |
| 9 | **Email HTML renders into the app DOM.** Mailroom sanitizes with DOMPurify but injects via `dangerouslySetInnerHTML` with no iframe isolation, so a message's CSS can reach app chrome. | `Mailroom/web/src/features/mail/ThreadPane.tsx:204` |
| 10 | **The homepage's MobiStack "screenshot" is a grey skeleton placeholder.** On the public front door. | `Platform/marketing/src/app/page.tsx:192-206` |
| 11 | **Mailroom Flutter's second nav tab goes to the same route as the first**, and its drawer links to a `/queue` stub that says the feature moved. | `Mobile/apps/mailroom/lib/screens/shell_screen.dart:29`, `screens/queue_screen.dart:22` |
| 12 | **MobiStack Flutter's `/compatibility` route opens private notes**, while the catalog lives at `/commons`. | `Mobile/apps/mobistack/lib/app.dart:191` |
| 13 | **No real `404` or `403` in any console.** Unknown URLs redirect home, hiding the broken link. | `oneOps/web/src/routes.tsx:30`, `MobiStack/web/src/App.tsx:227`, `Mailroom/web/src/App.tsx:52` |
| 14 | **MobiStack's global search shows results in a snackbar** that cannot be navigated to. | `Mobile/apps/mobistack/lib/screens/more_screen.dart:88` |

Acceptance: each defect has a regression test. The palette, the two Identity pages and the sale-void
confirmation are user-visible enough to ship on their own.

## Phase 1 — One token system, many colours

Three weeks. Nothing later works without this.

### The colour direction

The portfolio should not read as one teal product repeated four times. It should read as a family:
one structural system, four recognisable identities. That is also the honest description of where the
code already is — the products have *already* diverged on colour, just unsystematically. Mailroom
runs a warm paper surface with a clay accent and a complete dark theme
(`Mailroom/web/src/index.css:12-27`); MobiStack runs a warm neutral counter surface
(`MobiStack/web/src/styles.css:17-21`) while keeping the house teal; OneOps runs the house teal on a
cool neutral. This phase makes that intentional and systematic instead of accidental and duplicated.

**The rule that keeps a multi-colour system from becoming a mess: hue carries identity, role carries
meaning, and the two never overlap.** Status hues are reserved. Product hues take the remaining
well-separated arcs of the wheel. Structure — neutral ramp, spacing, type, radius, elevation — is
shared by everyone, always.

Each product carries **two** accents, not one. A single accent can only tint; a pair can compose —
it gives every product its own gradient, its own two-tone illustration, its own chart pairing and its
own section headers, all generated rather than art-directed per screen. The second accent is chosen
to sit far enough from the first to be legible beside it, and far enough from the status hues to
never be mistaken for one.

| Identity | Accent pair | Anchors | Surface | Why |
|---|---|---|---|---|
| Prabhix Technologies — marketing, Identity, house | **Cyan → Indigo** | `#0e7490` `#4338ca` | Cool | The existing corporate mark and mesh; it stays the parent brand |
| OneOps | **Indigo → Fuchsia** | `#4338ca` `#a21caf` | Cool | A broad business suite should read as a system of record; the fuchsia keeps it from reading as sober enterprise blue |
| Admin console | **Violet → Cyan** | `#6d28d9` `#0e7490` | Cool, `compact` | Internal tooling earns its own identity so a control tower is never mistaken for a customer product |
| MobiStack | **Ochre → Teal** | `#b45309` `#0f766e` | Warm | A counter tool used standing up, fast, under shop lighting; the teal is ochre's complement, so the pair reads as deliberate |
| Mailroom | **Clay → Teal** | `#9c3d2f` `#0f766e` | Warm | Already built, already good — promoted from a one-off to a full ramp and given a partner hue |

Reserved status hues, never used as a product accent: **success** green `#15803d`, **warning** amber
`#b45309` used only in soft-tint roles, **danger** red `#b42318`, **info** blue `#1d4ed8`. MobiStack's
ochre accent and the amber warning share an arc, so within MobiStack warning is restricted to tinted
banners and badges and never appears as a solid fill — separation by role, which is how every mature
system handles this.

Two further palettes, both currently missing entirely and both the reason charts and labels look
improvised:

- **Categorical (data-viz)** — 10 hues for charts, avatars and grouped series, ordered so the first
  four are distinguishable under the common forms of colour blindness, and re-lightened rather than
  re-hued for the dark theme.
- **Tag palette** — 15 user-assignable colours for Mailroom tags and OneOps labels, each *derived*
  from a ramp by one rule rather than hand-picked, so every swatch's text pairing is provably AA in
  both themes. Today MobiStack and OneOps hardcode tag presets and accept a free colour input
  (`oneOps/web/src/features/settings/mail/TagsPage.tsx:18`), which is how unreadable labels get made.
- **Gradients** — four per theme (`brand`, `brand-soft`, `brand-fade`, `mesh`), composed from that
  theme's accent pair. This is the part that makes a UI read as colourful rather than merely tinted,
  and it is the part that is currently hand-written per hero section or absent.

That is **16 ramps** — neutral, sand, and fourteen hues — plus the categorical and tag palettes, in
place of today's 20 hand-written values.

### The generator — built

`web-kit/packages/brand/tokens.json` is the single source and the generator is live:

```
npm --prefix web-kit/packages/brand run build    # regenerate every artifact
npm --prefix web-kit/packages/brand run check    # CI gate: fail on drift or contrast regression
node web-kit/packages/brand/scripts/palette-sheet.mjs   # Infra/design/palette-sheet.png
```

One source file now produces every token across six artifacts, up from 30 hand-written values, and
the build asserts **230 role contrast pairs plus 30 tag swatches** — five themes times two modes
times every required pairing. It caught six genuine WCAG failures on its first run, including a dark
`border-strong` at 2.71:1 and MobiStack's focus ring at 2.82:1, both now fixed in the source rather
than patched per app. `Infra/design/palette-sheet.png` renders all five themes, both modes, every
gradient and every tag swatch on one page for review, and `web-kit/packages/brand/TOKENS.md` is the
generated reference with the full contrast table.

Selecting a product identity is one attribute, which is the whole point:

```html
<html data-brand="mobistack" data-theme="dark" data-density="compact">
```

On Flutter the same source produces `Mobile/packages/prabhix_theme`, whose `prabhixTheme(brand:
'mobistack', brightness: …)` returns a full Material 3 theme and installs a `PxPalette`
`ThemeExtension`. Widgets read `context.px.surfaceSelected` instead of a mutable global, so a theme
change rebuilds through the normal inherited-widget path and animates between palettes.

```
tokens.json ──┬──→ prabhix-tokens.css        (CSS custom properties, light + dark)
              ├──→ tailwind-preset.css        (@theme block, consumed by all four webs)
              ├──→ prabhix_tokens.dart        (Mobile/packages/prabhix_theme)
              └──→ tokens.md                  (generated reference)
```

1. **Expand the set** to everything in [UX-STANDARD § 1](UX-STANDARD.md#1-tokens): the ramps and
   palettes above; semantic aliases over them; `-hover`/`-active`/`-selected`/`-disabled` state
   variants; spacing, type roles, radius, elevation 0–5, z-index, split duration/easing, container
   widths, and a `compact` density mode.
2. **Fix the border contrast bug** — darken `border` to clear 3:1 in both themes, and add
   `border-strong` for emphasis.
3. **Ship the Tailwind preset and the four product themes from the package.** An app picks its theme
   in one line; it never redefines a colour. Delete the hand-written `@theme` blocks in
   `oneOps/web/src/index.css:10-102` and `Mailroom/web/src/index.css:32-93`.
4. **Reduce MobiStack's fork to a declared theme.** Its warm counter surface, ochre accent and
   compact density become a generated product theme, not 197 loose hex values in `styles.css`.
5. **Generate the Dart theme** into a new `Mobile/packages/prabhix_theme`, and delete the four
   hand-typed `Px` classes. Replace MobiStack's mutable global `Px.active`
   (`Mobile/apps/mobistack/lib/app.dart:236`) with a `ThemeExtension` so widgets rebuild on theme
   change instead of reading a global.
6. **Kill the manual copies.** Identity consumes the generated CSS at build time; `Infra/design`
   becomes generated output. CI fails if any copy differs from `tokens.json`.
7. **Self-host Fraunces and Source Sans 3** in the brand package. Identity's CSP is `style-src
   'self'`, so the hosted login has silently rendered in system fallbacks while marketing and the
   consoles loaded Google Fonts — the sign-in page has never once matched the brand.

Acceptance: `tokens.json` is the only place a literal appears; the four copies are generated; a CI
contrast check passes every semantic pair of every product theme in both light and dark; the Flutter
apps build from the generated theme; Identity renders in Fraunces; each product is recognisable from
a screenshot of a single screen with the logo cropped out.

## Phase 2 — A real primitive library

Three weeks, overlapping Phase 1.

1. **Make `@prabhixtechnologies/ui` a package.** `tsup` build to `dist`, proper exports map, `sideEffects`,
   versioning, and publish. Remove the `file:` + raw-`src` arrangement.
2. **Storybook + tests as the gate.** Every primitive: all variants, both themes, both densities,
   200% text scale, `axe` clean, visual-regression snapshot. This is what stops the drift returning.
3. **Build the missing primitives**, in this order — the first five unblock Phase 3:

   | Priority | Primitives |
   |---|---|
   | 1 | **context-menu**, data-table (sort/filter/select/paginate/sticky/virtualized), form + field + error wiring, empty-state, alert/banner |
   | 2 | sheet/drawer, card, pagination, breadcrumb, spinner/progress, radio-group, combobox, copy-button, kbd |
   | 3 | date-picker, time-picker, file-dropzone, scroll-area, accordion/collapsible, segmented-control, toggle-group, stepper, hover-card |
   | 4 | tree-view, resizable panels, chart primitives, code block, menubar, sidebar primitives |

4. **Fix the existing primitives**: `button` `sm` and `default` are both `min-h-11`
   (`button.tsx:18`); `switch` hardcodes a white thumb (`switch.tsx:19`); `tooltip` hardcodes
   `bg-ink`/`text-white` (`tooltip.tsx:18`); `dialog` uses a raw `bg-black/60` scrim
   (`dialog.tsx:18`); `badge` renders a `div`; none of the animations respect reduced motion inside
   the package.
5. **Promote what the apps already proved.** `PageHeader`, `EmptyState`/`ErrorState`, `CursorList`,
   `ResponsiveTable`/`MobileCard`, `RelativeTime`, `Money`, `PermissionGate` and the command-palette
   pattern all exist in `oneOps/web` and should move up.
6. **Migrate MobiStack and Mailroom onto the package**, retiring their forked `Modal`, `Menu`,
   `DataTable`, `Toast`, `button`, `badge` and `avatar`.

Acceptance: 55 of 55 primitives present with stories; zero locally-reimplemented primitives in any
app; a single `DataTable` behind every table in the portfolio.

## Phase 3 — The interaction layer

Four weeks. This is the phase that changes how the products feel, and the one the standard exists
for. Everything here is [UX-STANDARD § 3](UX-STANDARD.md#3-interaction) applied surface by surface.

1. **Context menus everywhere.** Right-click on pointer, long-press on touch, `Shift+F10` from the
   keyboard, same items in all three. Every row in: OneOps inbox and chat, commerce products, orders,
   customers, members, files, event logs, Admin tenants and identity tables, MobiStack inventory,
   sales history, repairs, catalog results, invoice lines, and Mailroom message rows. Zero exist
   today, so this is the single largest perceived jump available.
2. **A shared list engine.** One hook powering focused-row-distinct-from-selected-row, `j`/`k`, Enter
   to open, type-ahead, `x` to select, shift-range, `Cmd+A`, a selection toolbar with bulk actions,
   and focus advance after a destructive action. Applied to every list. OneOps chat already proves
   the pattern (`ChatPage.tsx:367-407`); the inbox next to it has none of it.
3. **URL state everywhere.** Search, filters, sort, tab, page and open record in the URL on all ~50
   list surfaces. Includes giving chat a `/chat/:conversationId` route — today the open conversation
   lives only in component state (`ChatPage.tsx:257`), so a staff member cannot send a colleague a
   link to a conversation.
4. **Command palette as the spine.** `⌘K` on every surface, with entity search (tickets, orders,
   members, SKUs, devices, threads), verbs (assign, resolve, void, copy ID), and recents. Today it is
   static navigation in OneOps and dead code in MobiStack.
5. **Keyboard maps + `?` cheat sheet** per surface. Mailroom gets the full mail set (`j/k`, `e`, `#`,
   `r`/`a`/`f`, `x`, `s`, `u`, `?`, `⌘Enter`) — it currently has four keys, and webmail is the most
   keyboard-sensitive product category there is. `⌘Enter` on every composer, of which zero have it.
6. **MobiStack scanner input.** A dedicated scan mode: rapid-keystroke detection, newline auto-submit,
   exact SKU/IMEI match added straight to the ticket, field refocused after checkout, `/` to focus
   from anywhere. The copy already says "scan a barcode" (`SalesPage.tsx:190`) over an ordinary
   debounced text field. For a counter app this is the difference between usable and not.
7. **Destructive-action discipline.** Confirm or optimistic-with-undo, exactly one, everywhere.
   Starting with the unconfirmed suspend/activate in `TenantsPage.tsx:68` and the silent
   `fulfillOrder`.
8. **Feedback discipline.** Toasts on every mutation — closing the gap in OneOps helpdesk and mail
   settings, which have none. Optimistic apply plus undo for archive, delete, move and void. Chat and
   inbox stick-to-bottom with a "new messages" pill.
9. **Forms.** Adopt the `react-hook-form` + `zod` that is already a dependency and unused, behind the
   Phase 2 `Form` primitive. Unsaved-changes guards on product edit, settings, and every composer.
10. **Small affordances that read as polish**: copy buttons on every ID, key, SKU, IMEI and
    correlation ID; tooltips on every icon-only control (OneOps mounts `TooltipProvider` and never
    uses a single trigger); breadcrumbs on nested routes; sticky table headers; real `404`/`403`;
    per-page hover cursors on interactive rows.

Acceptance: the § 3 checklist passes on every list surface in all four web builds; a keyboard-only
operator can run the full inbox, sales and mail flows without a mouse.

## Phase 4 — Flutter to the same standard

Four weeks. The mobile apps are further behind than the webs, and the shared-code story is worse:
four near-identical copies of `chrome.dart` (~320 lines each), four `AccountScreen`s, four themes.

1. **`Mobile/packages/prabhix_ui`.** Theme from Phase 1, plus the chrome, atmosphere, empty state,
   error state, sync bar, skeleton list, and list row that currently exist three or four times over.
   MobiStack's `shop_ui.dart` and Mailroom's `mail_ui.dart` are the raw material.
2. **Navigation.** `StatefulShellRoute.indexedStack` in all three shells so tab switches preserve
   scroll, filters and selection — today they dispose state via `NoTransitionPage`. Route the Admin
   app properly instead of five tabs inside one `PlatformScreen`. `PopScope` on every screen with
   unsaved input. Deep links beyond the one OneOps chat handler.
3. **Gestures.** Generalise the Mailroom mailbox pattern: swipe actions, long-press context menus,
   multi-select with a bulk bar, undo toasts, pull-to-refresh on every network list, haptics on
   selection / swipe commit / destructive confirm / successful scan. Currently one file has swipe, one
   call site has haptics, and only Mailroom has multi-select.
4. **Semantics.** `semanticLabel` on every icon-only control, live regions on sync and offline
   banners, 48dp minimum targets (removing `VisualDensity.compact` from primary actions), and a pass
   at 200% text scale — several screens hardcode `fontSize: 42` and fixed tile widths.
5. **States.** Shared skeletons replacing the 22 centred spinners; the designed empty state with a CTA
   everywhere (OneOps and Admin currently use bare `Text`); mapped error copy replacing every `'$e'`;
   the Mailroom/MobiStack offline banner adopted by OneOps and Admin.
6. **Dark theme** for Admin, Mailroom and OneOps — only MobiStack has one, and the others hardcode
   light surfaces such as `Colors.amber.shade100` chat bubbles
   (`chat_detail_screen.dart:192`).
7. **Forms and input.** `Form` + validators, `autofillHints`, `TextInputAction` chains, keyboard-inset
   handling on composers, correct keyboard types. All four counts are currently zero.
8. **Lists and layout.** `ListView.builder` for the 41 eager `ListView`s; cursor pagination on the
   admin and catalog lists; `LayoutBuilder` breakpoints for tablet, since there are none at all.

Acceptance: one shared UI package; § 3.6 gesture contract met on every list; zero `Semantics` gaps on
icon controls; dark theme in all four apps.

## Phase 5 — The funnel: marketing and sign-in

Two weeks. This is where customers form their first impression, and it is cheap to fix.

**Marketing.** The site is well built — App Router, RSC, `next/font`, reduced-motion respected, axe
tests, consent banner. Its problem is singular and severe: **it contains no product imagery at all.**
Zero `next/image`, zero `<img>`, zero `alt` attributes; `public/` holds a manifest and an 832-byte
favicon. Shop products render as gradient tiles with their first letter. The homepage's MobiStack
showcase is a grey wireframe. For a software company, showing no software is the whole credibility
gap.

1. Real screenshots: OneOps inbox / chat / billing, MobiStack counter and mobile, Mailroom mailbox,
   Admin console. Two or three annotated captures per product.
2. An image pipeline — `next/image`, responsive sizes, AVIF/WebP — and wire the shop's
   `galleryFileIds` instead of telling shoppers the CDN is not configured.
3. An integration logo strip, and named or logoed social proof in place of fully anonymised quotes.
4. Ship the `StatBand` component that is built, tested, and never rendered on any page.
5. Add `<h1>` to the ~12 routes that have none — `Section` defaults to `h2`, so most pages have no
   top-level heading, which hurts both SEO and screen readers.
6. A primary CTA above the fold on platform, products, docs and about; product-specific CTA labels
   instead of eight "Learn more"s.
7. Fix the form focus rings (`outline-none` with no replacement in `contact-form.tsx:175` and five
   other places), use `text-danger` instead of `text-red-500`, and either add
   `@tailwindcss/typography` or delete the inert `prose` classes.
8. Server-render the pricing page (a 497-line client component) and defer the tracker and chat widget.
9. Decide the Admin story — it is a product in the portfolio and absent from the site entirely.
10. Either ship real docs or rename the nav item; `/docs` currently promises documentation and
    delivers "request access" cards.

**Identity.** Every customer of every product sees this page first.

1. Phase 0 fixes the two unstyled pages; Phase 1 gives it the real fonts.
2. ~~Client-aware branding — a MobiStack user should see the MobiStack lockup, resolved from the
   authorization request, not the generic house mark.~~ **Done.** `SignInBrand` maps the pending
   request's `client_id` to a theme through an allowlist, and login, signup and the magic-link
   confirmation carry it as `data-brand`. The sign-in panel mixes its base and both glows from
   that theme's accent pair, so Mailroom's sign-in is clay and MobiStack's is ochre. Logout and
   the account page stay on the house brand deliberately — both are global rather than any one
   product's, and logout has no pending request to read. Strengths are near the contrast ceiling
   and `Identity/scripts/brand-panel-check.mjs` is what proves it; it also caught `.stage-foot`
   sitting at 2.80:1, which predated this work.
3. Submit loading state and double-submit protection on plain form POSTs.
4. Show/hide password toggle, caps-lock hint, strength meter on signup.
5. Host password reset on Identity instead of bouncing to a product console mid-auth.
6. Passkey polish: always-visible explanation, distinct copy for cancel versus failure, inline
   `role="alert"` errors. Extract the ~120 lines of WebAuthn codec duplicated between `login.js` and
   `account.js`.
7. Surface rate-limit and lockout states as page copy, and add a branded OAuth consent template.

## Phase 6 — Guardrails

Ongoing, set up during Phase 1. Without these the drift returns within two releases.

| Gate | Enforcement |
|---|---|
| No literals | ESLint rule banning hex/rgb in `.tsx`; `custom_lint` banning `Color(0x`, inline `fontSize`, and raw `EdgeInsets` numerics in Dart |
| Tokens in sync | CI diff of every generated copy against `tokens.json` |
| Contrast | CI check of every semantic pair in both themes against WCAG AA |
| A11y | `axe` on every Storybook story and every route smoke test; zero violations |
| Visual regression | Snapshots per primitive per theme per density |
| No local primitives | Import rule forbidding app-local `Modal`, `Menu`, `DataTable`, `Toast`, `Button` |
| No raw errors | Lint rule against rendering `error.message` / `'$e'` in a widget or component |
| Interaction contract | The [§ 6 review checklist](UX-STANDARD.md#6-review-checklist) in the PR template |

---

## Sequencing and effort

Phases 1 and 2 overlap; 3, 4 and 5 are independent once 1 and 2 land.

| Phase | Weeks | Depends on |
|---|---|---|
| 0 — Broken things | 1 | — |
| 1 — Token system | 3 | — |
| 2 — Primitive library | 3 | Phase 1 (can start in week 2) |
| 3 — Interaction layer (web) | 4 | Phase 2 priority-1 primitives |
| 4 — Flutter | 4 | Phase 1 |
| 5 — Marketing + Identity | 2 | Phase 1 |
| 6 — Guardrails | — | Set up in Phase 1, enforced from then on |

Roughly **15–17 weeks** serially for one person; about **10** with Flutter and marketing running in
parallel with the web work.

### If there is less time than that

The subset with the best ratio of perceived quality to effort — about four weeks, and it is what I
would do first:

1. All of Phase 0 (one week, mostly defects, several of them embarrassing).
2. Token expansion plus the border-contrast fix and self-hosted fonts (Phase 1, items 1–3 and 7).
   Every surface gets visibly crisper for a change in one file.
3. `context-menu` and `data-table` in `@prabhixtechnologies/ui`, then context menus on every row in all four web
   builds (Phase 2 priority 1, Phase 3 item 1). Nothing else available raises the perceived tier as
   much per hour spent.
4. The shared list engine and URL state on the ten highest-traffic list pages (Phase 3 items 2–3).
5. Marketing screenshots (Phase 5 item 1). One afternoon of capture work fixes the front door.

---

## Kill list for this document

Deliberately excluded, so nobody looks for them later:

- **Rewrites.** No framework changes, no re-platforming. Every phase is additive or a migration onto
  something additive.
- **Replacing the house brand.** The Prabhix Technologies cyan, Fraunces + Source Sans 3, and the
  marks stay as the parent identity. What changes is that each product gains its own accent ramp and
  surface temperature underneath it (Phase 1), which is the opposite of a rebrand — it is finally
  implementing one. The place it matters most, the sign-in page, has never even loaded the fonts.
- **Colour as decoration.** A multi-colour system is more hues under tighter rules, not more hues
  sprinkled per screen. Every added colour is a named ramp in `tokens.json` with a contrast-checked
  role. A screen that reaches for a hue that is not in its product theme is still a defect.
- **Native platform divergence.** Flutter stays Material on both platforms. Cupertino adaptivity is a
  P2 in the audit and is not worth the surface area yet.
- **Internationalisation.** Not in scope here, but the type scale and layout work in Phase 1 should
  not assume English string lengths.
- **New features.** Snooze, filters/rules, threading depth and attachment handling are missing from
  Mailroom, and `/docs` is a stub. Those are product decisions, tracked in
  [ROADMAP.md](ROADMAP.md), not UI debt.
