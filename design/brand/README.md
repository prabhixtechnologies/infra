# Prabhix brand kit

Three identities, one geometry. Copy these files into each product — do not import across repos.

## Architecture

| Identity | Legal / voice | Mark | Field | Use on |
|---|---|---|---|---|
| **Prabhix** | House / parent | PA monogram | Ink `#0C1524` | Corporate, legal, “by Prabhix” |
| **Prabhix Technologies** | Tech corporation | Same PA | Teal `#0E7490` | Marketing, Identity, OneOps, Mailroom |
| **MobiStack** | Product | Stacked M | Teal `#0E7490` | MobiStack web, mobile, store listings |

P is Priti, A is Abhishek. Do not replace the path data with a live font “P”.

## Colour

| Token | Hex | Role |
|---|---|---|
| House ink | `#0C1524` | Parent field, body text |
| Paper | `#F3F6FB` | Light surfaces |
| Teal | `#0E7490` | Tech corp + product field, light accent |
| Cyan | `#22D3EE` | A in the house mark, dark-mode accent |
| Cyan soft | `#A5F3FC` | A in the teal mark |
| Danger / success | `#B42318` / `#067647` | Status only |

Type: Fraunces (display) + Source Sans 3 (body). MobiStack wordmark is Source Sans, extra-bold.

## Files

- `svg/prabhix-mark.svg` — 36² house icon
- `svg/prabhix-mark-on-paper.svg` — for light toolbars
- `svg/prabhix-lockup.svg` — mark + wordmark
- `svg/prabhix-technologies-mark.svg` — 36² teal icon (favicons, OneOps, Mailroom, Identity)
- `svg/prabhix-technologies-lockup.svg` — site header
- `svg/mobistack-mark.svg` — 64² app icon
- `svg/mobistack-mark-adaptive.svg` — transparent foreground
- `svg/mobistack-lockup.svg` — “A Prabhix product”
- `svg/favicon.svg` — same as technologies mark
- `raster/` — 1024 / 512 / 192 / 180 / 32 PNG after `node scripts/rasterize.mjs`

## Clear space

Keep a gap equal to the mark’s corner radius around the square. Do not place the mark on a second coloured square. Do not recolour the A independently of the table above.
