# Landing page

The one page site at https://spur-ios.vercel.app. Static HTML, CSS and a little vanilla
JavaScript, no framework, no build step on the host and no request to any other host.

It is drawn in the app's own design language. The tokens in `styles.css` are the ones in
`Spur/UI/DesignSystem`: background, surfaces, the one accent, the ink opacities, the coverage
colours (amber one way, green both ways), the radii 10, 22 and 28, the 4 and 8 point spacing, the
type scale from 11 to 84 and a single weight. Glass panels, the BEREIT pill, the GPS chip, the
speed card with the START button and the tab bar copy the app's components.

## Files

| File | What it is |
|------|------------|
| `index.html` | The page. Generated from `_src/index.src.html`, see below. |
| `styles.css` | All styling, dark and light from `prefers-color-scheme`. |
| `app.js` | The simulated drive in the hero, the layer switch, the gap buttons, the tab bar, copy. |
| `_src/` | The page template, the script that draws the invented map, and the social card page. Not deployed. |
| `assets/` | Favicon, touch icon, social card (`og-card.png`), demo video and poster, app screens. |
| `llms.txt`, `robots.txt`, `sitemap.xml`, `.well-known/security.txt` | For crawlers and agents. |
| `vercel.json` | Security headers and caching. |

## The map

The street grid, the river, the freeway and every coverage line are invented by
`_src/build.mjs`. Nothing is traced from real map data. Edit `_src/index.src.html`, then run:

```
node _src/build.mjs
```

It rewrites `index.html` with the map SVG filled in, and `_src/og.html`, the social card page.

## The social card

`assets/og-card.png` is the hero alone at 1200 by 630: the finished map, the card at rest, the
headline and a legend for the two colours, in the dark set. `_src/og.html` is the built page without its
script plus `_src/og.css`. To render it again, serve this directory, open `/_src/og.html` at a
1200 by 630 viewport with device scale 2 and a dark colour scheme, take a screenshot and scale it
down to 1200 by 630.

## Rules the page keeps

- Everything a reader or a crawler needs is in the HTML. Without JavaScript, and with
  `prefers-reduced-motion: reduce`, the page shows the finished state: roads coloured, the
  card at rest. The caption then says why the drive does not play, and with reduced motion
  START is dimmed. Notes that promise a working control are written by `app.js`, not the HTML.
- The drive starts only once most of its route is on screen above the tab bar, and pauses when
  most of it has left. A phone that loads with the map below the fold does not miss it.
- No inline script or style, so the Content Security Policy in `vercel.json` stays strict.
  Colour SVG through classes, move things through `el.style` or the Web Animations API.
- System fonts only, the same fallback the app uses without its optional bundled typeface.
- Copy in English. German appears only as the app's own on-screen labels, marked `lang="de"`.
- Outbound links to the repository carry `utm_source=landing`.

## Preview

```
python3 -m http.server 4321 --directory .
```
