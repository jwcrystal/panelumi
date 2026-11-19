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
  `:root[data-theme="dark"]`; the header's appearance button opens a three-row
  menu (follow the system / light / dark), remembers the choice, and the first
  row follows `prefers-color-scheme`, including while the page is open. It
  shares one tray with the language switch, because both are page preferences
  rather than navigation.
- **The dark theme has its own temperature.** Its surfaces are warm charcoal
  rather than neutral grey, there is a 4.5% film grain over the page, and every
  section heading carries a short accent rule. All three are dark-only: in
  light mode the page stays exactly as it was.
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
- **Version strings are literal.** The menu mock's version row, the
  release-notes mock and its window title spell out the current version. Grep
  `site/` for whatever `VERSION` says when it changes.

## Publishing

The repository's Pages source must be **GitHub Actions** (Settings › Pages).
The workflow deploys whenever a push to `main` touches `site/`, and can be run
by hand from the Actions tab.
