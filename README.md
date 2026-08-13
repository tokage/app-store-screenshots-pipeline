# app-store-screenshots-pipeline

A WorkBuddy skill that runs the full App Store / Google Play screenshot
pipeline as one orchestrated flow:

1. **Read listing** — extract app metadata from `PRD` / `README` /
   `.xcstrings` / `Fastfile`, produce a `listing.json`, and **pause for your
   confirmation**.
2. **Capture frameless screenshots** — run `fastlane raw_screenshots`
   (macOS + Xcode + fastlane only; gracefully skipped on other platforms).
3. **Scaffold + inject** — copy a Next.js beautify editor into the project,
   map `listing.json` into its config, and drop the screenshots in place.
   Re-runs never overwrite your edited config.
4. **Launch + hand off** — start the editor with `bun` and open it for you
   to fine-tune. **The skill ends here.**

Exporting the promo images and ASC publishing are deliberately left to you.
This keeps the skill small and avoids touching high-stakes store operations.

## Install

```bash
git clone https://github.com/tokage/app-store-screenshots-pipeline.git
cp -r app-store-screenshots-pipeline ~/.workbuddy/skills/
```

Then trigger it in any project by saying, for example:
*"prepare App Store screenshots for <project>"*.

## Prerequisites

- **`bun`** on any machine that runs the beautify editor.
- **`fastlane` + Xcode + a built app** on macOS — required only for the
  capture step; the skill degrades gracefully without them.

## Attribution

The bundled web engine in `resources/template/app-store-screenshots/` is a
modified copy of
[ParthJadhav/app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots)
(MIT, © 2026 Parth Jadhav). See `NOTICE` and the engine's `LICENSE`.

## License

- Orchestration (this skill's `SKILL.md`, `references/`, repo `README`,
  `LICENSE`): MIT — Copyright (c) 2026 刘俊.
- Vendored engine: MIT — Copyright (c) 2026 Parth Jadhav (see
  `resources/template/app-store-screenshots/LICENSE`).
