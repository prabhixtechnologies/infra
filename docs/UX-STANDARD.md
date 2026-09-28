# UX standard — the contract every surface is reviewed against

This is the normative half of the UI work. [UX-PLAN.md](UX-PLAN.md) is the phased plan that gets us
here; this document is what "done" means and what new code is reviewed against afterwards.

It is deliberately prescriptive. The reason the apps look unfinished is not that anyone lacked taste,
it is that there was no contract, so each screen decided for itself what a list row does, what an
empty state says, and whether a delete needs confirming. Twelve people-months of screens later,
nothing agrees with anything.

Scope: all four Flutter apps, all four web builds (OneOps, Admin, MobiStack, Mailroom), the marketing
site, and the Identity hosted login.

---

## 1. Tokens

**Never write a colour, size, radius, shadow, duration or z-index literal in product code.** One
source of truth, `web-kit/packages/brand/tokens.json`, generated into CSS custom properties, a
Tailwind preset, and a Dart theme. Details in [UX-PLAN.md § Phase 1](UX-PLAN.md#phase-1--one-token-system).

| Category | Contract |
|---|---|
| Colour | Two layers. Primitive ramps (`--px-cyan-50` … `--px-cyan-950`, and the same for the other thirteen hues and two neutrals) are never used in product code. Product code uses semantic aliases only: `surface`, `surface-raised`, `surface-sunken`, `ink`, `ink-muted`, `ink-faint`, `border`, `border-strong`, `accent`, `accent-ink`, `accent-2`, `accent-2-ink`, `danger`, `warning`, `success`, `info`, plus the `-subtle` and state suffixes below. The alias resolves to the current product theme, so the same component is cyan in OneOps and ochre in MobiStack without a single conditional. |
| Accents | Each theme carries **two** accents. `accent` is the primary — buttons, links, selection, focus. `accent-2` is the partner hue — the second half of every gradient, the alternate chart series, two-tone illustration, and the way a section header distinguishes itself without inventing a colour. A third hue inside one product is a defect. |
| Gradient | `--px-gradient-brand` (accent → accent-2), `-brand-soft`, `-brand-fade`, `-mesh`, plus the utilities `.px-gradient-brand` and `.px-gradient-text`. Generated per theme, so a hero is colourful without a hand-written `linear-gradient` anywhere in product code. Never place body text on `brand` or `mesh` — only on `-soft` and `-fade`, which are asserted against `ink`. |
| Gradient interpolation | Every generated ramp is `in oklab` with the blend hint at **68%**, not the implicit 50%. sRGB interpolation desaturates the middle of any two saturated hues, and MobiStack (ochre + teal) and Mailroom (clay + teal) pair complements, so an even blend spends the middle third of the bar on olive — a colour belonging to neither product. Weighting keeps the surface in the product's accent and lets the partner hue arrive at the end. A hand-written gradient that omits both is a defect. |
| Categorical | `--px-cat-1` … `--px-cat-10` for charts, grouped series and generated avatars. Never pick a chart colour by hand; never use a status hue for a series. |
| Tag | `--px-tag-*` — 15 user-assignable swatches, each *derived* from a ramp by one rule so its paired text colour is provably AA in both themes; the build asserts all 30. User-chosen colour never comes from a free colour picker. |
| State | Every interactive semantic colour ships `-hover`, `-active`, `-selected`, `-disabled`. If a hover colour is derived with `filter: brightness()` or an opacity hack, it is a bug. |
| Spacing | 4px base: `space-0/px/0.5/1/1.5/2/3/4/5/6/8/10/12/16/20/24`. No `margin: 13px`. |
| Type | Roles, not sizes: `display`, `title-lg/md/sm`, `body-lg/md/sm`, `label`, `caption`, `mono`. Each role fixes size, line-height, weight and tracking together. A component never sets `font-size` alone. |
| Radius | `radius-sm/md/lg/xl/full`. Five values, not the nine currently in use. |
| Elevation | `elevation-0` … `elevation-5`, each a composed shadow. One `--px-shadow` is not an elevation system. |
| Z-index | `z-base/sticky/dropdown/overlay/modal/toast/tooltip`. Never a bare `z-index: 9999`. |
| Motion | Duration and easing are separate tokens (`duration-instant/fast/normal/slow`, `ease-out/in-out/spring`). Both collapse to `0ms` under `prefers-reduced-motion`. |
| Layout | `container-sm/md/lg/xl`, `sidebar-width`, `sidebar-width-collapsed`, `header-height`. Reading measure caps at ~72ch. |
| Density | `comfortable` (default) and `compact`, switching row height, padding and type role together. MobiStack counter and Admin tables default to `compact`. |
| Focus | One composed `focus-ring` token (width, offset, colour). Every focusable element uses it. |

**Contrast floor.** Text ≥ 4.5:1, large text and every meaningful UI boundary ≥ 3:1, against both
themes. The current `--px-border` fails this at 1.36:1 light and 1.35:1 dark, which is why cards and
inputs read as smudges rather than edges — it is a token bug, not a styling preference.

**Hue carries identity; role carries meaning; they never overlap.** Each product has its own accent
pair and surface temperature — cyan/indigo for Prabhix Technologies, indigo/fuchsia for OneOps,
violet/cyan for Admin, ochre/teal for MobiStack, clay/teal for Mailroom — declared as a generated
theme and selected in one line. Status hues
(green, amber, red, blue) are reserved and never serve as a product accent. Where a product accent
shares an arc with a status, as MobiStack's ochre does with amber, the status is restricted to
tinted banner and badge roles and never appears as a solid fill.

What a product may vary: accent ramp, surface temperature, default density, and the chrome treatment
of its shell. What no product may vary: the spacing scale, the type roles, the radius ladder, the
elevation scale, the motion tokens, and the semantic alias names. Divergence is a declared theme in
`tokens.json`, or it is drift.

**`data-brand` is not limited to `<html>`.** Put it on any element and everything inside takes that
product's palette in whichever mode the page is in — which is how one page shows several products,
each in its own colour. It re-themes **surfaces too**, so every pairing inside the scope stays
within one theme and is already covered by the per-theme contrast gate. That makes it right for a
card that stands on its own, and too much for a row in a list or a single label that should keep
the host's surfaces and borrow only a hue. For those, use `--px-brand-<name>` with its `-text` and
`-ink` companions: a bare hue, mode-aware, and asserted against every surface in the portfolio
rather than only against its own product's.

**A `--color-*` alias goes in `@theme inline`, never a plain `@theme`.** This is the one rule here
whose breach is invisible. A plain `@theme` emits `:root { --color-accent: var(--px-accent) }`, and
a custom property is substituted at computed-value time on the element that *declares* it — so the
alias resolves once at the root and descendants inherit a finished colour. `bg-accent` inside a
`data-brand` scope then paints the root's accent. Nothing errors, every test passes, and the whole
portfolio renders in one hue. It hid for months because `[data-theme="dark"]` sits on `<html>`,
which *is* `:root`, so dark mode kept working. `@theme inline` omits the root declaration and
inlines the value into the utility, so it resolves against the element's own cascade. Colours only:
spacing, radius and type do not vary by brand, `--font-display` is read directly as a `var()`, and
Tailwind expands the layout namespaces inside `@media` preludes where a `var()` is invalid.

**Swatches are derived from a seed, never stored and never picked.** `toneFor(seed)` (and `pxTagFor`
in Dart — the same list and the same hash, both generated) maps a string to one of the 15 tag
swatches. Three rules govern its use:

- **Seed on the most stable identifier, not the display name.** A sender's address, not "Sam"; a
  workspace id, not its name. Renaming a thing should not recolour it, and one person writing under
  two display names should stay one colour.
- **Only where variety is open-ended and user-owned.** A conversation tag, a folder the user made, a
  person, a tenant. Not the seven system mail folders: those mean the same thing in every mailbox,
  and reading Trash as "the red one" is a learned signal worth more than decoration. Where identity
  and state collide on one element, state wins.
- **Colour is never the only signal.** Initials, the folder name, the tag text still carry the
  meaning. The swatch makes a list scannable; it never encodes anything on its own.

`--px-tag-*-ink` is asserted AA against its own `-bg`. It also clears 4.5:1 against every product
surface in both modes (6.46:1 worst case), which is what makes it usable for a tinted icon on a
sidebar and not just for a filled chip. If a surface is ever added that does not clear it, that
belongs in the contrast gate rather than in a reviewer's judgement.

---

## 2. Components

Use `@prabhix/ui`. If the primitive does not exist, add it to `@prabhix/ui` — do not build it locally.
A component that exists in three apps in three versions is worse than a missing one.

- Every primitive forwards refs, supports `asChild`, spreads `aria-*` and `data-*`, and styles its
  `data-state` consistently.
- Every primitive has a Storybook entry covering all variants, both themes, both densities, RTL, and
  a 200%-text-scale snapshot. No story, no merge.
- Every primitive passes `axe` with zero violations in its story.
- App-local components are for composition (`InboxRow`, `SaleTicket`), never for primitives
  (`Modal`, `Menu`, `DataTable`, `Toast`).

---

## 3. Interaction

This is the section the products currently fail hardest, and the one that most separates a tool
people trust from a tool people tolerate. Industry-grade software is defined by interaction depth far
more than by colour choices.

### 3.1 Every interactive element

| Requirement | Detail |
|---|---|
| Real semantics | A clickable thing is a `<button>`, `<a>`, or carries a role, `tabIndex`, and both Enter *and* Space handlers. A `<div onClick>` is a defect. |
| Visible focus | The `focus-ring` token, always. `outline: none` without a replacement ring is a defect. |
| Hit area | ≥ 44×44 CSS px on touch, ≥ 32×32 with 8px spacing on pointer. `VisualDensity.compact` on a primary action is a defect. |
| Label | Icon-only controls carry an accessible name *and* a tooltip. The tooltip is not the name. |
| Disabled vs busy | Disabled means "not allowed" and explains why on hover. Busy means "in flight" and shows a spinner in place. They are different states and look different. |

### 3.2 Every row, card and tile

Five affordances, on every one of them:

1. **Primary activation** — click / tap / Enter / Space. One obvious default action.
2. **Context menu** — right-click on pointer, long-press on touch, and `Shift+F10`/`ContextMenu` key
   from the keyboard. All three open the *same* menu with the *same* items.

   On web this is `RowActions` + `RowActionsTrigger` from `@prabhix/ui`: one `RowAction[]` feeds the
   right-click menu, the always-visible button, and the confirmation step, so the three cannot
   disagree. Two things about it are not obvious and were both found the hard way:

   - **The keyboard keys are handled explicitly, not inherited.** Browsers are supposed to turn
     `Shift+F10` and the `ContextMenu` key into a `contextmenu` event, and cannot be relied on to.
   - **Opening a Radix menu programmatically requires controlled state.** Radix menus open on
     `pointerdown`, so calling `.click()` on the trigger does nothing whatsoever. A keyboard path
     built that way looks correct in review and fails in use.

   The visible trigger is part of the contract, not a nicety. A right-click menu nobody knows about
   is not an affordance, and right-click is unavailable on touch.
3. **Hover actions** — the two or three most common actions revealed on pointer hover, each a real
   labelled button, each also present in the context menu.
4. **Swipe actions** on touch — one leading, one trailing, both reversible or confirmed, both
   duplicated in the context menu.
5. **Selection** — the row participates in list selection (§3.3) without its primary action firing.

The context menu is the canonical list of what can be done to an object. Hover actions, swipe
actions, toolbar buttons and keyboard shortcuts are all shortcuts *into* that list, never a superset
of it. If an action exists only in a toolbar, the row is incomplete.

### 3.3 Every list and table

| Requirement | Detail |
|---|---|
| Keyboard navigation | `↑`/`↓` and `j`/`k` move a *focused row* that is distinct from the *selected row* and the *open row*. `Home`/`End`, `PageUp`/`PageDown`. Type-ahead jumps to a matching row. |
| Open | `Enter` opens the focused row. `Escape` returns to the list and restores focus to the row you came from. |
| Focus advance | After archive / delete / resolve, focus moves to the next row. Never to `document.body`. |
| Selection | `x` or `Space` toggles, `Shift+click` and `Shift+↑/↓` extend a range, `Ctrl/Cmd+click` toggles one, `Cmd+A` selects all loaded. A selection toolbar appears with a count and the bulk actions. |
| Bulk actions | Anything doable to one row is doable to fifty, in one request, with progress and a per-item failure report. A client-side `for` loop of PUTs is not a bulk action. |
| Sort and filter | Sortable column headers with a visible direction indicator. Filters live in a consistent bar, show an active count, and have one-click clear. |
| URL state | Search, filters, sort, tab, page and the open record are all in the URL. A view you can see is a view you can paste into chat. This is the single most-violated rule in the codebase today. |
| Columns | Wide tables allow column visibility toggling and remember it per user. Sticky header, sticky first column when scrolled horizontally. |
| Volume | Cursor pagination. Virtualized above 100 rows. Never `limit=100` with no continuation. |
| States | Skeleton, empty, error and offline per §4 — not a shared spinner. |

### 3.4 Destructive and mutating actions

- Every destructive action has **either** a confirmation dialog **or** an optimistic apply with an
  undo toast. Exactly one of the two. Neither is a defect; both is friction.
- Confirmation dialogs name the object and the consequence ("Void invoice INV-4821? Stock for 3 lines
  returns to inventory."). "Are you sure?" is not a confirmation.
- Irreversible and multi-record destructive actions require typing the object's name.
- Every mutation locks against double-submit, shows a busy state on the control that started it, and
  reports success and failure. Silent success is a defect; users re-click and double-charge.
- Money, stock and mail-send actions are idempotent on a client-generated key.

### 3.5 Keyboard map

Global, on every web surface:

| Key | Action |
|---|---|
| `⌘/Ctrl+K` | Command palette — navigation *and* entity search *and* verbs |
| `?` | Shortcut cheat sheet for the current surface |
| `g` then key | Go to section (`g i` inbox, `g s` sales, `g c` catalog) |
| `/` | Focus search on the current surface |
| `Escape` | Close the topmost overlay, then clear selection, then blur search |
| `[` / `]` | Previous / next record within the current list |

Surface-specific, where the surface has the concept: `c` compose/create, `e` archive, `#` delete,
`r`/`a`/`f` reply / reply-all / forward, `s` star, `u` back to list, `⌘/Ctrl+Enter` send from any
multi-line composer, `⌘/Ctrl+S` save.

Rules: single-letter shortcuts never fire while focus is in a text input or an open dialog. Every
shortcut appears in `?`. Every shortcut has a mouse path — the keyboard is an accelerator, never the
only way.

### 3.6 Gestures on touch

| Gesture | Contract |
|---|---|
| Tap | Primary action. |
| Long-press | Opens the context menu — the same items as right-click on web. Fires selection haptic. |
| Swipe leading | Most common reversible action (archive, mark read). Undo toast. |
| Swipe trailing | Second action (delete, void). Confirms if irreversible. |
| Pull-to-refresh | On every screen backed by a network list, without exception. |
| Pinch | Zoom on any image, invoice, or device photo. |
| Drag | Reorder where order is user-meaningful (routing rules, repair priority). |
| Edge-back | Android predictive back honoured; screens with unsaved input intercept it and offer to discard. |

Haptics: selection tick on long-press and selection change, light impact on swipe commit and
successful scan, warning on destructive confirm, success on sale completion. One
`HapticFeedback` call in the whole Flutter workspace today is not a haptics policy.

### 3.7 Navigation

- Every screen is a route. Tab state is a route, not local component state, and survives a reload,
  a share, and the back button.
- Tab switches preserve scroll position, filters and selection.
- Nesting deeper than three levels needs breadcrumbs.
- Core actions reachable in ≤ 2 taps from the app's home; nothing important below 3.
- Real `404` and `403` pages with a recovery path. Silently redirecting an unknown URL to home tells
  the user their link is broken *and* hides which link it was.
- The active navigation item always matches the current route. Falling back to index `0` is a defect.

---

## 4. States

Every data surface designs five states. The empty and error states are where trust is won, and they
are currently the least-designed screens in the portfolio.

| State | Contract |
|---|---|
| Loading | Skeleton matching the final geometry, so nothing shifts when data lands. A centred spinner is acceptable only for full-page first paint under 400ms. Never conflate loading with empty ("Loading phones…" inside an empty-state component is a defect). |
| Empty — first run | Explain what this screen is for, show one primary CTA, and where useful a sample or import path. A brand-new shop with zero inventory should be guided, not greeted with a blank table. |
| Empty — filtered | Say which filters are hiding things, offer one-click clear. Distinct from first-run empty. |
| Empty — achieved | An empty inbox is a reward. Say so. |
| Error | Plain-language cause, a retry that actually retries, and a support path carrying a correlation ID. Users never see `error.message`, a stack, an axios string, or a Dart `'$e'`. Operators may reveal detail behind a "Details" disclosure. |
| Offline / stale | A persistent banner when offline, a "last updated" marker on stale data, a visible queue of pending mutations, and a sync indicator. Local notifications are not in-app offline UI. |

Feedback: toast for success and failure of every mutation, one toast system per app, positioned
consistently, dismissible, with the undo action where §3.4 requires it.

Forms: real form library with schema validation. Labels always visible. Validation after first blur,
then live. Errors at the field, summarised at the top for screen readers. Required marked. Help text
before the error, not instead of it. Busy submit. Unsaved-changes guard on navigate and unload.
`autocomplete` / `autofillHints` on every field a password manager or keyboard should know about.
Enter submits single-line forms; `⌘Enter` submits composers.

---

## 5. Accessibility floor

WCAG 2.2 AA is the floor, not the goal. Non-negotiable:

- Semantic structure: one `h1` per page, no skipped levels, landmark elements, skip link.
- Every control has an accessible name. Flutter widgets carry `Semantics` / `semanticLabel` — the
  current count across 55k lines of Dart is zero.
- `aria-live` (polite) for async arrivals: new mail, new ticket, sync completion, queue changes.
- Focus is trapped in modals, returned on close, and never lost to `body`.
- Usable at 200% text scale and 320px width without clipping or horizontal scroll.
- `prefers-reduced-motion` / `MediaQuery.disableAnimations` respected by CSS *and* JS *and* Flutter
  animation controllers.
- Colour is never the only carrier of meaning — status needs an icon or text too.
- Keyboard-only and screen-reader passes on the primary flow of each product before release.

---

## 6. Review checklist

A UI pull request is not reviewable until each line is true or explicitly waived in the description.

- [ ] No colour, spacing, radius, shadow, duration or z-index literal
- [ ] No component re-implemented that exists in `@prabhix/ui`
- [ ] Every row has primary action, context menu, hover actions, and participates in selection
- [ ] Every list has keyboard navigation, selection, bulk actions, and URL-serialized state
- [ ] Every destructive action confirms or offers undo — exactly one
- [ ] Every mutation has busy state, double-submit lock, and success/failure feedback
- [ ] Loading, empty (first-run and filtered), error, and offline states all designed
- [ ] No raw error text on any user-facing path
- [ ] Keyboard shortcuts registered in `?`, none firing inside inputs
- [ ] Touch: long-press menu, swipe actions, pull-to-refresh, haptics
- [ ] `axe` clean; keyboard-only pass done; 200% text scale pass done
- [ ] Both themes, both densities, 320px and ultrawide checked
- [ ] Storybook story added or updated

---

## Kill list for this document

Three habits this standard exists to end. They account for most of the gap between these products and
the tools they compete with.

1. **Deciding per screen.** Every screen re-answering "what does a row do" is why the apps feel like
   four different products written by four different people — which, across `sales_screen.dart`,
   `InboxPage.tsx`, `ThreadList.tsx` and `DataTable.tsx`, is effectively what happened.
2. **Building the happy path only.** Loading, empty, error and offline are four fifths of the states a
   user actually hits on a bad network in a shop with no stock, and they are where the products
   currently look abandoned.
3. **Treating the pointer as the only input.** No context menus, almost no keyboard, almost no
   gestures, and no semantics. A tool that can only be used by clicking precisely is a tool nobody
   gets fast at, and fast is the entire value proposition for a repair counter and a mail queue.
