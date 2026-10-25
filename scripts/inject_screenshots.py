#!/usr/bin/env python3
"""把无框抓图注入美化工程，并在拷贝前逐张验真。

为什么是一个脚本而不是一串 `cp`：手工拷贝这一步的真实失败模式是"某一区少一张"或
"某一张其实是上一轮的旧图"——两者都不报错，只在商店页上表现为少一格或图文不符。
本脚本把四道门写死在这里：

  1. 张数    幻灯片数必须等于 slug 数，且每个语言区都真的拷到了
  2. 尺寸    给了 `--expect-size` 时逐张比对（抓错设备的第一症状）
  3. 一致    所有语言区同一格的像素尺寸必须相同（防"一半内屏一半外屏"）
  4. 覆盖    target 已存在且像素不同，必须显式 `--force` 才覆盖

用法
-----
    python3 inject_screenshots.py \
        --scaffold app-store-screenshots \
        --src fastlane/screenshots-duo \
        --device iphone-duo \
        --slugs 01-on-this-day,02-journey-map,03-journey-home,04-memory,05-poster,06-photo-detail \
        --src-pattern "ODM-ASC-DUO-{slug}.png" \
        --expect-size 2007x2853 \
        --dry-run

`--locales` 不传时取工程自己的 locales；两边必须一致，否则编辑器里会有一个
图片从未拷进来的语言区。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pixel_size(path: Path) -> tuple[int, int] | None:
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        Image = None  # noqa: N806
    if Image is not None:
        try:
            with Image.open(path) as im:
                return im.size
        except Exception:
            pass
    # 退回 macOS 自带的 sips，省掉一个必然失败的依赖
    import shutil as _sh
    import subprocess
    if not _sh.which("sips"):
        return None
    try:
        out = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    w = h = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            w = int(line.split(":")[1])
        elif line.startswith("pixelHeight:"):
            h = int(line.split(":")[1])
    return (w, h) if w and h else None


def platform_of(device: str) -> str:
    return "apple" if device.startswith(("iphone", "ipad", "watch")) else "android"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scaffold", required=True, help="美化工程目录（含 app-store-screenshots.json）")
    ap.add_argument("--src", required=True, help="抓图根目录，下面按 <locale>/ 分")
    ap.add_argument("--device", default="iphone", help="工程里的 device 键")
    ap.add_argument("--slugs", required=True, help="逗号分隔，与幻灯片顺序一一对应")
    ap.add_argument("--src-pattern", default="{slug}.png", help="源文件名模板，可用 {slug} {locale}")
    ap.add_argument("--locales", default="", help="逗号分隔；默认取工程配置的 locales")
    ap.add_argument("--expect-size", default="", help="源图必须是的像素，`WxH`")
    ap.add_argument("--force", action="store_true", help="允许覆盖已存在且像素不同的目标文件")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    scaffold = Path(args.scaffold).expanduser()
    cfg_path = scaffold / "app-store-screenshots.json"
    if not cfg_path.is_file():
        print(f"✗ 找不到 {cfg_path}", file=sys.stderr)
        return 2
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))

    slugs = [s.strip() for s in args.slugs.split(",") if s.strip()]
    slides = cfg.get("slidesByDevice", {}).get(args.device, [])
    if not slides:
        print(f"✗ 配置里没有 {args.device} 的幻灯片", file=sys.stderr)
        return 2
    if len(slides) != len(slugs):
        print(f"✗ 幻灯片数 {len(slides)} ≠ slug 数 {len(slugs)}；顺序与数量必须一一对应", file=sys.stderr)
        return 2

    locales = [x.strip() for x in args.locales.split(",") if x.strip()] or list(cfg.get("locales", []))
    if not locales:
        print("✗ 没有任何语言区可用", file=sys.stderr)
        return 2
    stray = [l for l in locales if l not in cfg.get("locales", [])]
    if stray:
        print(f"✗ 这些语言区不在工程配置的 locales 里：{stray}", file=sys.stderr)
        return 2

    want = None
    if args.expect_size:
        try:
            w, h = args.expect_size.lower().split("x")
            want = (int(w), int(h))
        except ValueError:
            print(f"✗ --expect-size 无法解析：{args.expect_size}", file=sys.stderr)
            return 2
    else:
        print("! 未给 --expect-size：少了「抓错设备」这道门，建议补上", file=sys.stderr)

    src_root = Path(args.src).expanduser()
    platform = platform_of(args.device)
    failures: list[str] = []
    rows: list[str] = []
    observed: dict[str, set[tuple[int, int]]] = {}   # slide index -> 各语言区出现的尺寸

    for loc in locales:
        copied = skipped = 0
        for idx, (slide, slug) in enumerate(zip(slides, slugs)):
            tpl = slide.get("screenshot", "")
            # screenshot 可能是多语言对象（{en: "..."}），取任一非空值当路径模板
            if isinstance(tpl, dict):
                tpl = next((v for v in tpl.values() if v), "")
            if "{locale}" not in (tpl or ""):
                failures.append(f"{loc}: 第 {idx + 1} 格的 screenshot 没有 {{locale}} 占位")
                continue
            rel = tpl.replace("{locale}", loc).lstrip("/")
            dest = scaffold / "public" / rel
            name = args.src_pattern.replace("{slug}", slug).replace("{locale}", loc)
            src = src_root / loc / name
            if not src.is_file():
                failures.append(f"{loc}: 缺源文件 {src}")
                continue

            size = pixel_size(src)
            if size is None:
                failures.append(f"{loc}: 读不到 {src.name} 的尺寸")
            else:
                observed.setdefault(str(idx), set()).add(size)
                if want and size != want:
                    failures.append(f"{loc}: {src.name} 是 {size[0]}×{size[1]}，要求 {want[0]}×{want[1]}")

            if dest.is_file():
                if md5_of(dest) == md5_of(src):
                    skipped += 1
                    continue
                if not args.force:
                    failures.append(f"{loc}: {dest.name} 已存在且内容不同（要覆盖加 --force）")
                    continue

            if not args.dry_run:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)
            copied += 1

        ok = copied + skipped
        rows.append(f"  {'✓' if ok == len(slugs) else '✗'} {loc:8s} 拷{copied} 跳过{skipped} / {len(slugs)}")

    mixed = {k: v for k, v in observed.items() if len(v) > 1}
    for k, sizes in mixed.items():
        failures.append(f"第 {int(k) + 1} 格跨区尺寸不一致：{sorted(f'{w}×{h}' for w, h in sizes)}")

    print(f"device={args.device}  platform={platform}  slides={len(slugs)}  locales={len(locales)}"
          + ("  (dry-run，未写入)" if args.dry_run else ""))
    print("\n".join(rows))
    if failures:
        print("\n失败明细：", file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1
    print("\n✓ 张数、尺寸、跨区一致、覆盖保护四项全过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
