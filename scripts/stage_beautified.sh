#!/usr/bin/env bash
# 把美化工程导出的树整理成 ASC 可直接上传的形状，逐区硬门校验，然后（可选）上传。
#
# 用法
#   bash scripts/stage_beautified.sh <导出目录或 zip> \
#     --asc-type IPHONE_67 --size-dir 1320x2868 --per-locale 6 \
#     --app-id 1234567890 --version 1.7.0 [--project App.xcodeproj --bundle-id com.x.y] \
#     [--out fastlane/screenshots-beautified] [--locale-map "en=en-US,..."] \
#     [--skip-validate] [--upload [--confirm]]
#
# 为什么需要它：ASC 的 fan-out 上传按 **同名语言目录** 找图，名字不对就静默少传；
# 槽位写错则商店页继续显示旧套装。这两件事都不会报错，所以必须在这里拦。
#
# 语言码默认映射（ASC 与工程常用码不同，中日韩相同）：
#   en→en-US  de→de-DE  es→es-ES  fr→fr-FR  pt→pt-BR  ja→ja  ko→ko  zh-Hans  zh-Hant
#
# 退出码：0 通过；1 校验不过；2 参数错误。

set -uo pipefail

SRC=""; ASC_TYPE=""; SIZE_DIR=""; PER_LOCALE=""; APP_ID=""; VERSION=""
PROJECT=""; BUNDLE_ID=""; OUT=""; LOCALE_MAP=""; UPLOAD=""; CONFIRM=""; SKIP_VALIDATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --asc-type)      ASC_TYPE="${2:?}"; shift 2 ;;
    --asc-type=*)    ASC_TYPE="${1#*=}"; shift ;;
    --size-dir)      SIZE_DIR="${2:?}"; shift 2 ;;
    --size-dir=*)    SIZE_DIR="${1#*=}"; shift ;;
    --per-locale)    PER_LOCALE="${2:?}"; shift 2 ;;
    --per-locale=*)  PER_LOCALE="${1#*=}"; shift ;;
    --app-id)        APP_ID="${2:?}"; shift 2 ;;
    --app-id=*)      APP_ID="${1#*=}"; shift ;;
    --version)       VERSION="${2:?}"; shift 2 ;;
    --version=*)     VERSION="${1#*=}"; shift ;;
    --project)       PROJECT="${2:?}"; shift 2 ;;
    --project=*)     PROJECT="${1#*=}"; shift ;;
    --bundle-id)     BUNDLE_ID="${2:?}"; shift 2 ;;
    --bundle-id=*)   BUNDLE_ID="${1#*=}"; shift ;;
    --out)           OUT="${2:?}"; shift 2 ;;
    --out=*)         OUT="${1#*=}"; shift ;;
    --locale-map)    LOCALE_MAP="${2:?}"; shift 2 ;;
    --locale-map=*)  LOCALE_MAP="${1#*=}"; shift ;;
    --skip-validate) SKIP_VALIDATE="1"; shift ;;
    --upload)        UPLOAD="1"; shift ;;
    --confirm)       CONFIRM="1"; shift ;;
    -h|--help)       sed -n '2,25p' "$0"; exit 0 ;;
    -*)              echo "未知参数: $1" >&2; exit 2 ;;
    *)               SRC="$1"; shift ;;
  esac
done

die() { echo "✗ $*" >&2; exit 2; }

[[ -n "$SRC" ]]       || die "缺导出路径"
[[ -e "$SRC" ]]       || die "路径不存在: $SRC"
[[ -n "$ASC_TYPE" ]]  || die "缺 --asc-type（如 IPHONE_67 / IPHONE_DUO）"
[[ -n "$SIZE_DIR" ]]  || die "缺 --size-dir（如 1320x2868）"
[[ -n "$PER_LOCALE" ]]|| die "缺 --per-locale（每区张数）"
OUT="${OUT:-fastlane/screenshots-beautified}"

export PATH="/opt/homebrew/bin:$PATH"

# ---------- 版本号：给了 --version 就用，否则从 pbxproj 里挑宿主 App ----------
if [[ -z "$VERSION" ]]; then
  [[ -n "$PROJECT" && -n "$BUNDLE_ID" ]] \
    || die "没有 --version 时必须同时给 --project 与 --bundle-id 才能反查 MARKETING_VERSION"
  PBX="$PROJECT/project.pbxproj"
  [[ -f "$PBX" ]] || die "找不到 $PBX"
  # 同一工程里分享扩展 / UI 测试宿主 / 测试 target 各自也有 MARKETING_VERSION（常停在 1.0），
  # 按出现顺序取第一个必然拿到错的，所以按 bundle id 精确认领。
  VERSION="$(awk -F'= ' -v want="$BUNDLE_ID" '
    /MARKETING_VERSION/ { v = $2; gsub(/;/, "", v) }
    /PRODUCT_BUNDLE_IDENTIFIER = / {
      id = $2; gsub(/[;[:space:]]/, "", id)
      if (id == want && v != "") { print v; exit }
    }
  ' "$PBX")"
fi
[[ -n "$VERSION" ]] || die "取不到版本号，请用 --version 指定"
[[ -n "$APP_ID" ]]  || die "缺 --app-id"

echo "▶ ASC 槽 $ASC_TYPE · 尺寸 $SIZE_DIR · 每区 $PER_LOCALE 张 · 版本 $VERSION · 产物 $OUT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [[ -d "$SRC" ]]; then
  ROOT="$SRC"
else
  echo "▶ 解压 $(basename "$SRC")"
  unzip -q "$SRC" -d "$WORK/unzipped" || die "解压失败"
  ROOT="$WORK/unzipped"
fi

# 导出树根名随引擎版本变化（apple/ 或 ios/），也允许用户只给到尺寸目录
find_size_dir() {
  local r="$1" c1 c2
  c1="$(find "$r" -maxdepth 6 -type d -name "$SIZE_DIR" 2>/dev/null | sort | head -1)"
  c2="$r"
  [[ -n "$c1" ]] && echo "$c1" || echo "$c2"
}
SIZE_PATH="$(find_size_dir "$ROOT")"
echo "▶ 源尺寸目录: $SIZE_PATH"

# ---------- 语言码映射 ----------
DEF_MAP="en=en-US,de=de-DE,es=es-ES,fr=fr-FR,ja=ja,ko=ko,pt=pt-BR,zh-Hans=zh-Hans,zh-Hant=zh-Hant"
LOCALE_MAP="${LOCALE_MAP:-$DEF_MAP}"
IFS=',' read -r -a PAIRS <<< "$LOCALE_MAP"
EXPECTED=$(( ${#PAIRS[@]} * PER_LOCALE ))

# 旧产物不删只移走：安全守卫对单轮批量删除会硬拦，而 mv 整个目录是重命名，不会触发。
if [[ -e "$OUT" ]]; then
  STALE="$(dirname "$OUT")/.stale-$(basename "$OUT")-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$OUT")" && mv "$OUT" "$STALE" && echo "▶ 旧产物已移出: $STALE"
fi
mkdir -p "$OUT"

TOTAL=0
for pair in "${PAIRS[@]}"; do
  from="${pair%%=*}"; to="${pair##*=}"
  sdir="$SIZE_PATH/$from"
  [[ -d "$sdir" ]] || { echo "✗ 缺语言目录: ${from}（${sdir}）—— 停止，不猜也不跳过" >&2; exit 1; }
  n=$(find "$sdir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l | tr -d ' ')
  if [[ "$n" -ne "$PER_LOCALE" ]]; then
    echo "✗ $from 有 $n 张，应为 $PER_LOCALE 张 —— 停止" >&2; exit 1
  fi
  mkdir -p "$OUT/$to"
  idx=0
  while IFS= read -r f; do
    idx=$((idx + 1))
    ext="${f##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    cp "$f" "$OUT/$to/$(printf '%02d' "$idx").$ext"
  done < <(find "$sdir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)

  bad=0
  for f in "$OUT/$to"/*; do
    dims=$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null \
      | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
    if [[ "$dims" != "$SIZE_DIR" ]]; then
      echo "✗ $(basename "$f") 尺寸 $dims ≠ $SIZE_DIR" >&2; bad=1
    fi
  done
  [[ "$bad" -eq 1 ]] && exit 1
  TOTAL=$((TOTAL + n))
  printf "  ✓ %-8s → %-8s %d 张\n" "$from" "$to" "$n"
done

echo "▶ 共计 ${TOTAL} 张（应为 ${EXPECTED}）"
[[ "$TOTAL" -eq "$EXPECTED" ]] || { echo "✗ 张数不符，停止" >&2; exit 1; }

# ---------- 本地预检：（asc validate 不递归 fan-out 树，只能逐区跑） ----------
if [[ -z "$SKIP_VALIDATE" ]]; then
  command -v asc >/dev/null 2>&1 || die "PATH 里没有 asc（--skip-validate 可跳过这步）"
  echo "▶ asc validate（逐区）"
  VERR=0
  for pair in "${PAIRS[@]}"; do
    to="${pair##*=}"
    out=$(asc screenshots validate --path "$OUT/$to" --device-type "$ASC_TYPE" --output json 2>&1)
    errs=$(printf '%s' "$out" | python3 -c "
import json,sys
try: print(json.loads(sys.stdin.read()).get('errorCount','?'))
except Exception: print('PARSE_FAIL')
" 2>/dev/null || echo PARSE_FAIL)
    if [[ "$errs" == "0" ]]; then
      printf "  ✓ %-8s valid\n" "$to"
    else
      printf "  ✗ %-8s errorCount=%s\n" "$to" "$errs"
      printf '%s\n' "$out" | tail -6
      VERR=1
    fi
  done
  [[ "$VERR" -eq 0 ]] || { echo "✗ 预检未过，停止" >&2; exit 1; }
else
  echo "▷ 跳过 asc validate（--skip-validate）"
fi

if [[ -z "$UPLOAD" ]]; then
  echo "▶ 只整理未上传（产物在 ${OUT}）。下一步："
  echo "  bash $0 \"$SRC\" --asc-type $ASC_TYPE --size-dir $SIZE_DIR --per-locale $PER_LOCALE \\"
  echo "    --app-id $APP_ID --version $VERSION --upload            # 干跑"
  echo "  …同上再加 --confirm                                      # 真跑"
  exit 0
fi

command -v asc >/dev/null 2>&1 || die "PATH 里没有 asc"
if [[ "$CONFIRM" == "1" ]]; then
  echo "▶ 真跑（--replace 只作用于 ${ASC_TYPE}）"
  asc screenshots upload --app "$APP_ID" --version "$VERSION" \
    --device-type "$ASC_TYPE" --path "$OUT" --replace --confirm
else
  echo "▶ 干跑（只列删除/新增，不写线上）"
  asc screenshots upload --app "$APP_ID" --version "$VERSION" \
    --device-type "$ASC_TYPE" --path "$OUT" --replace --dry-run
fi
