#!/usr/bin/env python3
"""Inject frameless screenshots into an app-store-screenshots scaffold.

Reads the scaffold's `app-store-screenshots.json`, resolves each slide's
`screenshot` template (which may contain a `{locale}` placeholder), and copies
`<src>/<locale>/<slug>.png` to that path under `<scaffold>/public`.

Why this exists as a script: the naive manual version (hand-copied `cp` per
locale per slide) is exactly where a locale silently ends up with 5 files
instead of 6. This script asserts the expected count and prints a per-locale
table so a short set is impossible to miss.

Usage
-----
    python3 inject_screenshots.py \
        --scaffold app-store-screenshots \
        --src fastlane/screenshots \
        --device iphone \
        --slugs 01-on-this-day,02-journey-map,03-journey-home,04-memory,05-poster,06-photo-detail \
        [--locales en,de,es,fr,ja,ko,pt,zh-Hans,zh-Hant] \
        [--dry-run]

`--locales` defaults to the scaffold's own `locales` array — the two must agree,
otherwise the editor shows a locale whose images were never copied.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scaffold", required=True, help="path to app-store-screenshots/")
    ap.add_argument("--src", required=True, help="dir holding <locale>/<slug>.png")
    ap.add_argument("--device", default="iphone", help="engine device id")
    ap.add_argument("--platform", default="apple", help="public/screenshots/<platform>")
    ap.add_argument("--slugs", required=True, help="comma-separated source slugs, in slide order")
    ap.add_argument(
        "--src-pattern",
        default="{slug}.png",
        help="source filename template, e.g. '{slug}.png' or 'APP-6.9-{slug}.png' (default: {slug}.png)",
    )
    ap.add_argument("--locales", default="", help="comma-separated; default = config locales")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    scaffold = Path(args.scaffold)
    cfg_path = scaffold / "app-store-screenshots.json"
    src_root = Path(args.src)
    slugs = [s for s in args.slugs.split(",") if s]

    if not cfg_path.exists():
        print(f"✗ 找不到配置：{cfg_path}", file=sys.stderr)
        return 2
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))

    locales = [l for l in (args.locales.split(",") if args.locales else cfg.get("locales", [])) if l]
    if not locales:
        print("✗ 没有任何语言区可用", file=sys.stderr)
        return 2

    slides = cfg.get("slidesByDevice", {}).get(args.device, [])
    if not slides:
        print(f"✗ 配置里没有 {args.device} 的幻灯片", file=sys.stderr)
        return 2
    if len(slides) != len(slugs):
        print(
            f"✗ 幻灯片数 {len(slides)} ≠ slug 数 {len(slugs)}；顺序与数量必须一一对应",
            file=sys.stderr,
        )
        return 2

    missing_cfg_locales = [l for l in locales if l not in cfg.get("locales", [])]
    if missing_cfg_locales:
        print(f"✗ 这些语言区不在配置的 locales 里：{missing_cfg_locales}", file=sys.stderr)
        return 2

    failures: list[str] = []
    rows: list[str] = []
    for loc in locales:
        copied = 0
        for slide, slug in zip(slides, slugs):
            tpl = slide.get("screenshot", "")
            if "{locale}" not in tpl:
                failures.append(f"{loc}: slide {slide.get('id')} 的路径没有 {{locale}} 占位")
                continue
            rel = tpl.replace("{locale}", loc).lstrip("/")
            dest = scaffold / "public" / rel
            src = src_root / loc / args.src_pattern.replace("{slug}", slug)
            if not src.exists():
                failures.append(f"{loc}: 缺源文件 {src}")
                continue
            if not args.dry_run:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)
            copied += 1
        flag = "✓" if copied == len(slugs) else "✗"
        rows.append(f"  {flag} {loc:8s} {copied}/{len(slugs)}")

    print(f"device={args.device}  platform={args.platform}  slides={len(slugs)}  locales={len(locales)}")
    print("\n".join(rows))
    if failures:
        print("\n失败明细：", file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1
    print("\n全部语言区文件数一致。" + ("（dry-run，未写入）" if args.dry_run else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
