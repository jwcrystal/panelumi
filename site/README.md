# site

The public landing page, published by `.github/workflows/pages.yml` to
`https://jwcrystal.github.io/panelumi/`.

One page, no build step and no dependencies: `index.html` plus the app icon
converted from `Resources/AppIcon.icns`. Preview it with any static server:

```bash
python3 -m http.server 8000 --directory site
```

## Keeping it true

- **Copy is bilingual.** Every block has an `.en` and a `.zh` span, and
  `data-lang` on `<html>` decides which one shows. Edit both sides together,
  and use the app's own wording from `Resources/zh-Hant.lproj`.
- **Colour lives in the tokens at the top of the page.** Dark is
  `:root[data-theme="dark"]`; the footer's 自動／淺色／深色 control picks it and
  remembers the choice, and 自動 follows `prefers-color-scheme`. The hero's
  desktop wallpaper is graphite in both appearances, because the icon is: no
  second hue anywhere.
- **The editor mock stays light in dark mode.** It is a screenshot of a page,
  and screenshots do not follow the system appearance.
- **The menu mock and the switch list come from one array.** `SWITCHES` in the
  page script mirrors `Sources/PanelumiKit/SwitchCatalog.swift` plus the two
  capture items added in `Sources/PanelumiCore/AppCatalog.swift`. Change a
  switch there first, then here; the hero menu, the grid and their groups all
  follow.
- **The illustrations are inline SVG**, drawn in the page: the menu-bar mock
  and the screenshot editor. There are no screenshot assets to re-capture, so
  a layout change in the app does not silently leave the page showing the old
  one — but it does mean the page has to be redrawn by hand when the menu or
  the toolbar changes.
- **The editor mock follows `CaptureToolbarView`** (`CaptureSession.swift`): a
  light material bar with the dark hint capsule above it, the ten tools in
  `CaptureSession.Tool` order, then the watermark chip, undo/redo, and the
  accent-filled copy button, save, pin and close. No options row, because no
  tool is picked in the picture.
- **Version strings are literal.** The menu mock's `Version 0.12.1`, the
  release-notes mock and its window title use the current version. Grep for
  `0.12.1` when `VERSION` changes.

## Publishing

The repository's Pages source must be **GitHub Actions** (Settings › Pages).
The workflow deploys whenever a push to `main` touches `site/`, and can be run
by hand from the Actions tab.
