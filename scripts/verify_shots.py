#!/usr/bin/env python3
"""收货门：抓完图之后、进美化之前，逐张核对。

这个脚本存在的理由：截图流程里所有的"静默失败"最终都长成同一副样子——
文件名字对、张数看着差不多、打开也像那么回事，但像素不对。以下四类都真实发生过：

  1. 某语言区少一张（某个 `if` 分支没进，不报错）
  2. 整批抓到外屏尺寸（1398×2034 而不是内屏 2007×2853）
  3. 某张是上一轮的旧文件（同名同尺寸，像素是旧的）
  4. 九区拍出来一模一样（切了语言但没真生效）

四类都能用"张数 + 尺寸 + mtime + 跨区 md5"当场判死，不需要人眼看图。

用法
-----
    python3 verify_shots.py --root fastlane/screenshots-duo \
        --expect-size 2007x2853 --expect-count 6 \
        --pattern "MYAPP-ASC-DUO-*.png" --since 2026-10-25T09:00:00

    # 只核某几个区
    python3 verify_shots.py --root fastlane/screenshots --locales en,de,ja \
        --expect-size 1320x2868 --expect-count 6

    # 尺寸允许多种（横竖都收）
    python3 verify_shots.py ... --expect-size 2007x2853,2853x2007

退出码：0 全过；1 有区不合格；2 参数或目录错误。
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------- pixel size ----------

def _size_via_sips(path: Path) -> tuple[int, int] | None:
    """macOS 自带的 sips，最稳。"""
    if not shutil.which("sips"):
        return None
    try:
        out = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    w = h = None
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            w = int(line.split(":")[1])
        elif line.startswith("pixelHeight:"):
            h = int(line.split(":")[1])
    return (w, h) if w and h else None


def _size_via_pil(path: Path) -> tuple[int, int] | None:
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        return None
    try:
        with Image.open(path) as im:
            return im.size
    except Exception:
        return None


def pixel_size(path: Path) -> tuple[int, int] | None:
    return _size_via_sips(path) or _size_via_pil(path)


# ---------- digest ----------

def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def slide_key(path: Path) -> str:
    """同一个"第几格"的跨区指纹。

    文件名里带两位序号（`XX-06-on-this-day.png`）时用序号；否则退回排序位置。
    序号比文件名可靠：各区文件名可能带本地化后缀。
    """
    parts = path.stem.split("-")
    for part in parts:
        if len(part) == 2 and part.isdigit():
            return part
    return path.stem


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="抓图根目录（下面按语言区分子目录）")
    ap.add_argument("--pattern", default="*.png", help="文件名通配符，默认 *.png")
    ap.add_argument("--expect-count", type=int, required=True, help="每区应有张数")
    ap.add_argument("--expect-size", required=True, help="允许的像素，`WxH`，多个用逗号分隔")
    ap.add_argument("--locales", default="", help="只核这些区，逗号分隔；默认核 root 下全部子目录")
    ap.add_argument("--since", default="", help="要求晚于这个时间（ISO8601，本地时区）；判旧文件")
    ap.add_argument("--allow-same-across-locales", action="store_true",
                    help="允许同一格跨区 md5 相同（只有确定不需要本地化时用）")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    args = ap.parse_args()

    root = Path(args.root).expanduser()
    if not root.is_dir():
        print(f"✗ 目录不存在: {root}", file=sys.stderr)
        return 2

    allowed: set[tuple[int, int]] = set()
    for spec in args.expect_size.split(","):
        spec = spec.strip().lower()
        if not spec:
            continue
        try:
            w, h = spec.split("x")
            allowed.add((int(w), int(h)))
        except ValueError:
            print(f"✗ --expect-size 无法解析: {spec}（应为 2007x2853）", file=sys.stderr)
            return 2

    since: datetime | None = None
    if args.since:
        try:
            since = datetime.fromisoformat(args.since)
            if since.tzinfo is None:
                since = since.astimezone()
        except ValueError:
            print(f"✗ --since 无法解析: {args.since}", file=sys.stderr)
            return 2

    if args.locales:
        locales = [x.strip() for x in args.locales.split(",") if x.strip()]
    else:
        locales = sorted(p.name for p in root.iterdir() if p.is_dir())
    if not locales:
        print(f"✗ {root} 下没有语言区目录", file=sys.stderr)
        return 2

    failures: list[str] = []
    rows: list[tuple[str, str, str, str]] = []
    digests: dict[str, dict[str, str]] = {}  # slide_key -> locale -> md5

    for loc in locales:
        loc_dir = root / loc
        if not loc_dir.is_dir():
            failures.append(f"{loc}: 语言区目录不存在")
            rows.append((loc, "✗", "—", "目录缺失"))
            continue
        files = sorted(loc_dir.glob(args.pattern))
        if len(files) != args.expect_count:
            failures.append(f"{loc}: 张数 {len(files)} ≠ {args.expect_count}")
        bad_size: list[str] = []
        stale: list[str] = []
        for f in files:
            size = pixel_size(f)
            if size is None:
                bad_size.append(f"{f.name}(读不到尺寸)")
            elif size not in allowed:
                bad_size.append(f"{f.name}({size[0]}×{size[1]})")
            if since is not None:
                mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=since.tzinfo)
                if mtime < since:
                    stale.append(f.name)
            digests.setdefault(slide_key(f), {})[loc] = md5_of(f)
        if bad_size:
            failures.append(f"{loc}: 尺寸不符 {', '.join(bad_size[:3])}")
        if stale:
            failures.append(f"{loc}: 旧文件 {', '.join(stale[:3])}")
        ok = "✓" if not bad_size and not stale and len(files) == args.expect_count else "✗"
        note = "—" if ok == "✓" else f"尺寸{len(bad_size)} 旧{len(stale)}"
        rows.append((loc, ok, f"{len(files)}/{args.expect_count}", note))

    # 同一格跨区必须各不相同，否则"本地化没生效"和"抓了九遍同一区"是同一个症状
    same_pairs: list[str] = []
    if not args.allow_same_across_locales:
        for key, per_locale in digests.items():
            seen: dict[str, str] = {}
            for loc, digest in per_locale.items():
                if digest in seen:
                    same_pairs.append(f"第 {key} 格：{seen[digest]} 与 {loc} 完全相同")
                else:
                    seen[digest] = loc
        if same_pairs:
            failures.append(f"跨区重复 {len(same_pairs)} 处（本地化可能没生效）")

    if args.json:
        import json
        print(json.dumps({
            "root": str(root),
            "expectCount": args.expect_count,
            "expectSize": sorted(f"{w}x{h}" for w, h in allowed),
            "rows": [{"locale": r[0], "ok": r[1] == "✓", "count": r[2], "note": r[3]} for r in rows],
            "crossLocaleDuplicates": same_pairs,
            "failures": failures,
            "ok": not failures,
        }, ensure_ascii=False, indent=2))
        return 0 if not failures else 1

    print(f"root={root}  每区={args.expect_count} 张  允许尺寸={sorted(f'{w}x{h}' for w, h in allowed)}")
    for loc, ok, count, note in rows:
        print(f"  {ok} {loc:8s} {count:>6s}  {note}")
    if failures:
        print("\n不合格明细：", file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        print("\n✗ 收货门未过，不要进下一步。", file=sys.stderr)
        return 1
    print("\n✓ 张数、尺寸、mtime、跨区 md5 四项全过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
