---
name: app-store-screenshots-pipeline
description: Orchestrates the full App Store / Google Play screenshot pipeline for any iOS or Android project — read the listing from project docs, optionally capture frameless screenshots with fastlane, scaffold a Next.js beautify engine into the filesystem, inject the config and screenshots, then launch it with bun for the user to fine-tune. Stops before export and ASC publishing, which are user operations.
version: 1.0.0
agent_created: true
---

# App Store & Google Play Screenshots Pipeline

## What this skill does

A single orchestration skill that turns a project's listing into editable, export-ready
store screenshots. It chains four stages and then **hands off to the user**:

1. **Read listing** — extract app name, platforms, locales, devices, tagline, features,
   and screenshot spec from the project's own docs (PRD, README, `.xcstrings`, Fastfile,
   Snapfile). Produce a `listing.json` contract and confirm with the user.
2. **Capture (optional)** — if the machine is macOS + Xcode + fastlane and the app has a
   fastlane capture config, run `fastlane raw_screenshots` to produce **frameless**
   screenshots. Degrades gracefully off-Mac.
3. **Scaffold + inject** — copy the bundled Next.js beautify engine into
   `<app-root>/app-store-screenshots/`, map `listing.json` into
   `app-store-screenshots.json`, and copy the frameless PNGs into `public/screenshots/`.
4. **Launch + hand off** — `bun run dev` (fallback `npm run dev`), open the editor, and
   stop. The user fine-tunes, exports, and (optionally) publishes by hand.

The skill **does not** perform export or App Store Connect publishing. Fine-tuning and
export are inherently iterative and belong to the user.

## When to use

Triggers: "prepare App Store screenshots", "run the screenshot pipeline",
"make Play Store assets for <app>", "scaffold store screenshots for this project".

The skill is project-agnostic: install it once at the user level and invoke it from any
project. Each project gets its own `<app-root>/app-store-screenshots/` scaffold.

## Prerequisites (machine level)

- **bun** on the machine that runs beautify (any OS). Fallback to Node + npm.
- **fastlane + Xcode + ruby** only on macOS, and only for the capture stage. If absent,
  capture is skipped and the pipeline continues with manually supplied screenshots.
- The app repo should carry fastlane capture config (`.snapfile` / `Fastfile` / UI test
  target / `DemoDataBuilder`). Without it, the user provides frameless PNGs manually.

## Stage 0 — Read listing

1. Resolve the target app root. Default to the current working directory; accept a
   user-specified path.
2. Probe, in priority order:
   - `README.md`, `docs/PRD.md`, any `*.md` PRD.
   - `*.xcstrings` (find in the repo) — source of locales.
   - `fastlane/Fastfile`, `fastlane/Snapfile`, `fastlane/Appfile`.
3. Extract fields with heuristics (record the source file for each):
   - `appName`: README title, Fastfile `app_identifier` basename, or ASC metadata.
   - `bundleId`: Fastfile `app_identifier` / Appfile.
   - `platforms`: `ios` if `.xcstrings`/iOS snapshot lanes exist; `android` if a gradle
     or android lane exists. Default both when unclear.
   - `locales`: languages from `.xcstrings` (`sourceLanguage` + `strings` keys) or
     Snapfile `languages`.
   - `devices`: Snapfile `devices` mapped to engine ids (`iphone`, `ipad`,
     `watch-45mm`, `android`, `android-7`, `android-10`, `feature-graphic`). Default
     `iphone` + `android`.
   - `tagline`, `valueProposition`, `features`: from PRD/README headings and bullets.
   - `screenshotSpec.countPerDevice`: Snapfile slot count or default `4`.
4. Write `listing.json` (schema in `references/listing-contract.md`) to the app root.
   This file is **git-tracked** — it is the source of truth for the run.
5. **Gate.** Present a summary card: app name, platforms, locales, devices, feature
   count, screenshot count per device. Ask the user to confirm or adjust. **Do not
   proceed until confirmed.**

## Stage 1 — Capture (frameless screenshots)

1. Environment probe:
   - `uname` == `Darwin`?
   - `xcodebuild -version` present?
   - `fastlane --version` present?
   - fastlane capture config present (`fastlane/Snapfile` or a snapshot lane)?
2. If all present: run `bundle exec fastlane raw_screenshots` (or the project's snapshot
   lane **without** `frameit`). Output lands in `fastlane/screenshots/`. Use the project's
   own lane name when known; `raw_screenshots` is the default.
3. **Degradation** when not macOS / no fastlane / no config:
   - Skip capture. Tell the user: "Capture needs macOS + Xcode + fastlane. Run this stage
     on a Mac with the app's fastlane capture configured, or place frameless screenshots
     manually at `fastlane/screenshots/<locale>/<device>-<NN>.png`. The pipeline continues
     to beautify with whatever screenshots are available."
4. If `fastlane/screenshots/` already contains PNGs, offer to reuse them instead of
   re-capturing. Ask the user.

## Stage 2 — Scaffold + inject

1. `TARGET = <app-root>/app-store-screenshots/`.
2. If `TARGET` does **not** exist:
   - Copy the bundled engine `resources/template/app-store-screenshots/` → `TARGET`.
   - Write `TARGET/.gitignore` (see `references/git-boundary.md`) if absent.
3. Map `listing.json` → `TARGET/app-store-screenshots.json`:
   - `appName`, `tagline` → copy; `features` → slide copy.
   - `locales`, `devices` → engine device ids.
   - Keep the engine's expected `schemaVersion` and default export sizes (already aligned
     to store requirements).
   - Reference screenshots at
     `public/screenshots/<platform>/<device>/<locale>/<NN>.png` after injection. Do not
     invent paths for files that do not exist.
4. Copy frameless PNGs (when present):
   - Source: `fastlane/screenshots/<locale>/<device>-<NN>.png` (or the user-provided dir).
   - Dest: `TARGET/public/screenshots/<platform>/<device>/<locale>/<NN>.png`, where
     `platform` = `apple` for `iphone`/`ipad`/`watch-45mm` and `android` for `android*`.
   - Preserve the numeric `<NN>` order.
5. **Non-destructive re-entry.** If `TARGET/app-store-screenshots.json` already exists
   (the skill ran before), **do not overwrite it**. Only re-copy screenshots when the user
   explicitly asks ("refresh screenshots only"). All manual edits persist.

## Stage 3 — Launch + hand off

1. Detect runtime: `bun --version`. If present →
   `cd TARGET && bun install && bun run dev`. Otherwise →
   `npm install && npm run dev`.
2. Wait for the dev server (poll the port Next reports, default 3000). Open the URL for
   the user.
3. **The skill ends here.** Tell the user:
   - Fine-tune copy, layout, and theme in the browser. This is repeatable — reopen the URL
     any time; edits persist in `app-store-screenshots.json`.
   - Export promotion screenshots with the editor's export button.
   - Optionally publish to App Store Connect with fastlane in their own terminal. The skill
     does not do this.

## Hard limits (never do)

- Never run export.
- Never run `fastlane deliver` or any App Store Connect publishing.
- Never overwrite the user's `app-store-screenshots.json` on re-entry.
- Never pretend capture works on a non-Mac machine.

## File asset & git boundary (ADR-002)

Track: `listing.json`, `app-store-screenshots/app-store-screenshots.json`,
`app-store-screenshots/bun.lock` / `package.json` / `next.config.*` / `tsconfig.json`,
and the app repo's fastlane config + UI test source + `Gemfile`.

Ignore: `fastlane/screenshots/**/*.png` (regenerable), `app-store-screenshots/node_modules/`,
`.next/`, `public/screenshots/`, `exports/`, `src/` (regenerated by this skill), `.env`,
`*.p8`. Full `.gitignore` snippets are in `references/git-boundary.md`.

## Bundled engine

`resources/template/app-store-screenshots/` is a self-contained Next.js + ShadCN editor
that reads `app-store-screenshots.json` and `public/screenshots/**` and exports at every
Apple/Google-required resolution via `modern-screenshot`. It is regenerated by this skill,
so `src/` is intentionally git-ignored in scaffolds. The engine's device frames, theme
presets, and per-locale editing are the beautify surface the user interacts with.
