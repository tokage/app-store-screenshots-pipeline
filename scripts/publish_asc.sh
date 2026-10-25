#!/usr/bin/env bash
# 把本地 canonical 元数据推到 App Store Connect，并当场回读验收。
#
# 用法
#   # 第一步：只看计划（不写线上）
#   bash scripts/publish_asc.sh --app-id 1234567890 --version 1.7.0 --dir asc-metadata/canonical
#
#   # 第二步：确认无误后真推（审批 → 应用 → 回读比对）
#   bash scripts/publish_asc.sh --app-id 1234567890 --version 1.7.0 --dir asc-metadata/canonical --confirm
#
# 为什么必须两步：`asc metadata apply` 一旦执行就是线上变更，而它最危险的两种失败
# 都不报错——`--if-exists` 默认 `fail` 会让整批中断（一半推了一半没推），
# `--allow-deletes` 会删掉本地没覆盖的语言区。所以这里把这两个参数都锁死，
# 并且从不相信 apply 的退出码，只相信回读。
#
# 三条硬约束（都踩过）：
#   1. `--if-exists update` 必填；                        2. 绝不传 `--allow-deletes`；
#   3. `apply` 报 `plan drifted` **不等于没写入**（drift 校验跑在写入之后），
#      唯一可信的验收是 `pull` 回读逐字段比对。
#
# 退出码：0 通过；1 验收不一致；2 参数或环境错误。

set -uo pipefail

APP_ID=""; VERSION=""; DIR=""; REVIEW_DIR=""; CONFIRM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)     APP_ID="${2:?}"; shift 2 ;;
    --app-id=*)   APP_ID="${1#*=}"; shift ;;
    --version)    VERSION="${2:?}"; shift 2 ;;
    --version=*)  VERSION="${1#*=}"; shift ;;
    --dir)        DIR="${2:?}"; shift 2 ;;
    --dir=*)      DIR="${1#*=}"; shift ;;
    --review-dir) REVIEW_DIR="${2:?}"; shift 2 ;;
    --review-dir=*) REVIEW_DIR="${1#*=}"; shift ;;
    --confirm)    CONFIRM="1"; shift ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    -*)           echo "未知参数: $1" >&2; exit 2 ;;
    *)            echo "多余参数: $1" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 2; }

[[ -n "$APP_ID" ]]  || die "缺 --app-id"
[[ -n "$VERSION" ]] || die "缺 --version（元数据与截图都是版本作用域，必须指到具体版本）"
[[ -n "$DIR" ]]     || die "缺 --dir（canonical 根目录）"
[[ -d "$DIR" ]]     || die "目录不存在: $DIR"
[[ -d "$DIR/version/$VERSION" ]] || die "$DIR/version/$VERSION 不存在——这个版本没有本地文案"
REVIEW_DIR="${REVIEW_DIR:-.asc/metadata/review-$VERSION}"

export PATH="/opt/homebrew/bin:$PATH"
command -v asc >/dev/null 2>&1 || die "PATH 里没有 asc"
command -v python3 >/dev/null 2>&1 || die "PATH 里没有 python3"

echo "▶ App $APP_ID · 版本 $VERSION · 源 $DIR · 审批产物 $REVIEW_DIR"

# ---------- 1. 离线校验（不连网就能拦下 schema / 超长 / URL 语法问题） ----------
echo "▶ 离线校验"
VALIDATE_JSON="$(mktemp)"
trap 'rm -f "$VALIDATE_JSON"' EXIT
if ! asc metadata validate --dir "$DIR" --output json > "$VALIDATE_JSON" 2>&1; then
  echo "✗ validate 未通过：" >&2
  python3 - "$VALIDATE_JSON" <<'PY' >&2 || cat "$VALIDATE_JSON" >&2
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d.get("issues", []), ensure_ascii=False, indent=2)[:2000])
PY
  exit 1
fi
python3 - "$VALIDATE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  ✓ files={d.get('filesScanned')} error={d.get('errorCount')} warning={d.get('warningCount')}")
PY

# ---------- 2. 生成计划（只看不写） ----------
echo "▶ 生成计划"
rm -rf "$REVIEW_DIR"
asc metadata plan --app "$APP_ID" --version "$VERSION" --dir "$DIR" \
  --if-exists update --review-dir "$REVIEW_DIR" \
  --output table 2>&1 | tail -40

python3 - "$REVIEW_DIR/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))["plan"]
adds, ups, dels = plan.get("adds", []), plan.get("updates", []), plan.get("deletes", [])
print(f"\n  计划：新增 {len(adds)} · 更新 {len(ups)} · 删除 {len(dels)}")
for kind, items in (("新增", adds), ("更新", ups)):
    for it in items:
        print(f"    {kind} {it.get('key')}")
if dels:
    print("  ✗ 计划里出现删除项，说明本地覆盖不全 —— 拒绝继续", file=sys.stderr)
    raise SystemExit(1)
PY
[[ $? -ne 0 ]] && exit 1

if [[ -z "$CONFIRM" ]]; then
  echo
  echo "▷ 只看了计划，没有写线上。逐条确认后加 --confirm 再跑一次。"
  echo "  重点看「更新」项的 from：名称、副标题被意外改动是这里唯一能发现的地方。"
  exit 0
fi

# ---------- 3. 审批 + 应用 ----------
echo "▶ 审批"
asc metadata approve --review-dir "$REVIEW_DIR" --all >/dev/null 2>&1 \
  || die "approve 失败（先看上面的 plan 输出）"

echo "▶ 应用"
APPLY_LOG="$(mktemp)"
asc metadata apply --app "$APP_ID" --version "$VERSION" --dir "$DIR" \
  --if-exists update --review-dir "$REVIEW_DIR" --confirm >"$APPLY_LOG" 2>&1
APPLY_RC=$?
if [[ $APPLY_RC -ne 0 ]]; then
  if head -1 "$APPLY_LOG" | grep -q "plan drifted"; then
    echo "  · apply 报 plan drifted —— 已知误报（drift 校验跑在写入之后），不重跑，直接回读判定"
  else
    echo "✗ apply 真的失败了：" >&2
    head -3 "$APPLY_LOG" >&2
    exit 1
  fi
fi

# ---------- 4. 回读验收（唯一可信的那一步） ----------
VERIFY_DIR="$(mktemp -d)"
echo "▶ 回读比对"
asc metadata pull --app "$APP_ID" --version "$VERSION" --dir "$VERIFY_DIR" --force >/dev/null 2>&1 \
  || die "pull 失败，无法验收"

python3 - "$DIR" "$VERIFY_DIR" "$VERSION" <<'PY'
import json, sys
from pathlib import Path

local_root, live_root, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
ok = bad = missing = 0
for scope, sub in (("app-info", local_root / "app-info"), ("version", local_root / "version" / version)):
    for local in sorted(sub.glob("*.json")):
        live_path = live_root / ("app-info" if scope == "app-info" else f"version/{version}") / local.name
        if not live_path.is_file():
            print(f"  ✗ {scope}/{local.name} 线上没有这个区")
            missing += 1
            continue
        want = json.loads(local.read_text(encoding="utf-8"))
        got = json.loads(live_path.read_text(encoding="utf-8"))
        # 本地没写的 key 是 no-op，不参与比对
        diffs = [k for k, v in want.items() if (got.get(k) or "").strip() != (v or "").strip()]
        if diffs:
            print(f"  ✗ {scope}/{local.name} 不一致：{', '.join(diffs)}")
            for k in diffs:
                print(f"      from: {(got.get(k) or '')[:60]!r}")
                print(f"      to  : {(want.get(k) or '')[:60]!r}")
            bad += 1
        else:
            ok += 1
print(f"\n  逐字段一致 {ok} · 不一致 {bad} · 线上缺区 {missing}")
raise SystemExit(0 if bad == 0 and missing == 0 else 1)
PY
RC=$?
if [[ $RC -ne 0 ]]; then
  echo "✗ 线上与本地不一致：以回读为准，不要相信 apply 的输出" >&2
  exit 1
fi
echo "✓ 推送完成，且回读逐字段一致。"
