# AGENTS.md

Guidance for coding agents (and humans) working in this repository.

SwitchDeck is a native macOS menu-bar utility: Swift 5.9, SwiftPM, macOS 14+,
no third-party dependencies, Apache-2.0-licensed. Three modules:

- `SwitchKit` — the library: switch definitions, config, ordering, hotkeys,
  text recognition, update check. `AppIdentity` holds the update feed,
  links and support folder name, so a package that depends on
  `SwitchDeckCore` can supply its own. Unit-tested in `Tests/SwitchKitTests`.
- `SwitchDeckCore` — the AppKit/SwiftUI app code: menu, settings, screenshot
  editor, permissions, as a library. Tested in `Tests/ScreenshotTests`.
- `SwitchDeck` — the thin executable: calls `SwitchDeckLauncher.run()`.

## Build and test

```bash
swift build                      # debug build
swift test                       # all unit tests
./scripts/check-localizations.sh # every t("...") key has a zh-Hant entry
./scripts/check-version.sh       # VERSION, its release notes, and the tag agree
./scripts/build-app.sh           # assemble build/SwitchDeck.app (release)
./scripts/smoke.sh               # print every switch and its live state
```

CI (`.github/workflows/ci.yml`) runs build, the localisation check, the version
check, tests and the app bundle on every push to `main` and every pull request.
Run the same steps locally before opening a PR.

The version lives in `VERSION` and nowhere else. `scripts/check-version.sh`
requires `docs/releases/<version>.md` and, when a tag is passed, that the tag is
`v<version>`; `scripts/build-app.sh` sets both bundle version keys from it, so
`CFBundleVersion` is never counted by hand. Bump the file and add the notes in
the same commit — the release workflow stops before building when they disagree
with the tag.

Tests that grab real screen pixels are skipped unless
`SWITCHDECK_LIVE_CAPTURE_TESTS=1` is set and the terminal has the Screen
Recording permission.

## Scope

This repository is the complete app. Changes here should fit what it already
does: menu switches, shortcuts, screenshots with the in-place editor, text and
QR recognition, audio recording, settings and permissions. For a larger new
feature, open an issue first so the direction can be agreed before code is
written.

- **Before implementing any new feature or new switch, stop and confirm with
  the maintainer that it belongs in this repository.** Don't start on your own
  judgement, even for something that looks like a natural extension.
- Every shipped switch and annotation tool must keep working and stay
  ungated. Don't remove, hide or restrict any of them. `FreeScopeContractTests`
  (switch IDs) and `FreeScopeAnnotationContractTests` (annotation tools) hold
  the frozen lists; changing them needs the maintainer.

When adding a switch, follow `docs/adding-a-switch.md`. User-visible strings go
through `t("...")` and need a Traditional Chinese entry in
`Resources/zh-Hant.lproj/Localizable.strings`.

## Stop points (maintainer only)

Agents and contributors must not do the following; leave them to the
maintainer:

- Push tags or create GitHub releases. Pushing a `v*` tag publishes a release
  through `.github/workflows/release.yml`.
- Change repository visibility, settings, branch protection or secrets.
- Create, use or commit signing keys, certificates, notarization credentials or
  any other secret. `scripts/setup-signing.sh` makes a local, self-signed
  identity on your own machine only; never commit its output.
- Change `LICENSE`.

## Hygiene

- Never commit secrets, tokens, personal paths or links to private resources.
- Keep commits focused, with a short imperative subject (`fix(screenshot): …`).
- Issues and PRs live in this repo's GitHub Issues; see `docs/agents/`.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, driven with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map to the same label strings in GitHub. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
