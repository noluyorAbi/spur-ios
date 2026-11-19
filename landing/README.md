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
| `_src/` | The page template and the script that draws the invented map. Not deployed. |
| `assets/` | Favicon, touch icon, social card, demo video and poster, app screens. |
| `llms.txt`, `robots.txt`, `sitemap.xml`, `.well-known/security.txt` | For crawlers and agents. |
| `vercel.json` | Security headers and caching. |

## The map

The street grid, the river, the freeway and every coverage line are invented by
`_src/build.mjs`. Nothing is traced from real map data. Edit `_src/index.src.html`, then run:

```
node _src/build.mjs
```

It rewrites `index.html` with the map SVG filled in.

## Rules the page keeps

- Everything a reader or a crawler needs is in the HTML. Without JavaScript, and with
  `prefers-reduced-motion: reduce`, the page shows the finished state: roads coloured, the
  card at rest.
- No inline script or style, so the Content Security Policy in `vercel.json` stays strict.
  Colour SVG through classes, move things through `el.style` or the Web Animations API.
- System fonts only, the same fallback the app uses without its optional bundled typeface.
- Copy in English. German appears only as the app's own on-screen labels, marked `lang="de"`.
- Outbound links to the repository carry `utm_source=landing`.

## Preview

```
python3 -m http.server 4321 --directory .
```
