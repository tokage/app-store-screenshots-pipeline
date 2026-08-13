# listing.json contract

`listing.json` is the Stage 0 output and the Stage 2 input. It is written to the app
project root and is git-tracked. It is the single source of truth that drives the pipeline
and decouples capture (fastlane) from beautify (the web engine).

## Schema

```jsonc
{
  "schemaVersion": "1.0",
  "appName": "OneDayMemory",
  "bundleId": "com.example.onedaymemory",
  "platforms": ["ios", "android"],
  "locales": [
    { "code": "en-US", "name": "English" },
    { "code": "zh-Hans", "name": "简体中文" }
  ],
  "devices": ["iphone", "ipad", "android", "android-10", "feature-graphic"],
  "tagline": "Remember every day",
  "valueProposition": "One tap to capture a moment, organized by when it happened.",
  "features": [
    { "title": "Quick capture", "description": "Save a thought before it slips away." }
  ],
  "screenshotSpec": {
    "countPerDevice": 4,
    "perLocale": true
  },
  "source": {
    "prd": "docs/PRD.md",
    "xcstrings": "App/Resources/en.xcstrings",
    "fastfile": "fastlane/Fastfile",
    "readme": "README.md"
  },
  "capturedBy": "fastlane@raw_screenshots",
  "generatedAt": "2026-08-13T13:57:00+08:00"
}
```

## Field notes

- `devices` uses the engine's device ids, not marketing names: `iphone`, `ipad`,
  `watch-45mm`, `android`, `android-7`, `android-10`, `feature-graphic`.
- `platform` is derived from `devices` for screenshot routing: `iphone`/`ipad`/`watch-45mm`
  → `apple`; `android`/`android-7`/`android-10`/`feature-graphic` → `android`.
- `source` records which file each field came from, so the user can verify and the skill
  can re-probe on re-entry without guessing.
- `capturedBy` documents the capture method; useful when screenshots were supplied
  manually.

## Screenshot directory convention

Capture output (fastlane, ignored by git):

```
fastlane/screenshots/<locale>/<device>-<NN>.png
```

Injected into the engine (derived, ignored by git):

```
app-store-screenshots/public/screenshots/<platform>/<device>/<locale>/<NN>.png
```

`<NN>` is zero-padded order. The engine reads from the second layout; the first is the
capture home and the single source of truth for pixels. Beautify never depends on how the
screenshots were produced.
