#!/usr/bin/env bash
# 绑定一台模拟器：**只创建一次，之后一直复用它**。
#
# 为什么需要它：
#   `xcrun simctl create` 从不查重 —— 无脑跑一次就多一台设备（每台约 1–3 GB）。
#   轮次一多，机器上会堆出十几台同名设备 + 一堆 `Clone N` 克隆体，CoreSimulator
#   越跑越慢，最后 `simctl` 整体挂住。绑定 = 名字 + UDID 落盘，四层判据依次兜底。
#
# 复用的四层判据（命中即停）
#   L1  udidFile 里的 UDID 还活着且 available          → 直接用（最快，跑多少轮都是同一台）
#   L2  按 name + runtime 精确匹配                     → 复用，并把 UDID 写回文件
#   L3  按 name 匹配到但 runtime 不符（系统升级过）     → 复用，提示 `--prune` 清旧档
#   L4  都没有                                          → create 一台，此后永远走 L1
#
# 用法
#   bash scripts/init_simulator.sh                       # 默认档案，重置后启动
#   bash scripts/init_simulator.sh iphone-duo            # 指定档案
#   bash scripts/init_simulator.sh iphone-duo --no-erase # 保留设备状态（只重启）
#   bash scripts/init_simulator.sh iphone-duo --plan     # 只打印将要做什么，不动系统
#   bash scripts/init_simulator.sh iphone-duo --prune    # 删掉本档案名下的重复设备与克隆体
#   bash scripts/init_simulator.sh iphone-duo --status-bar   # 只重置状态栏
#
# 退出码：0 就绪；1 运行失败；2 参数/档案/UDID 问题。

set -uo pipefail

PROFILE=""
PROFILES_ARGS=()
DO_ERASE=1
DO_PRUNE=0
PLAN_ONLY=0
STATUS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles)   PROFILES_ARGS=(--profiles "${2:?}"); shift 2 ;;
    --profiles=*) PROFILES_ARGS=(--profiles "${1#*=}"); shift ;;
    --no-erase)   DO_ERASE=0; shift ;;
    --prune)      DO_PRUNE=1; shift ;;
    --plan)       PLAN_ONLY=1; shift ;;
    --status-bar) STATUS_ONLY=1; shift ;;
    -h|--help)    sed -n '2,28p' "$0"; exit 0 ;;
    -*)           echo "未知参数: $1" >&2; exit 2 ;;
    *)            PROFILE="$1"; shift ;;
  esac
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⛔ 取值与 eval 必须分两步：`eval "$(...)"` 会吞掉命令替换的退出码，
# 档案名写错时 python 已经 exit 2，脚本却带着空变量继续跑。
# 数组展开写成 ${arr[@]+...}：macOS 自带 bash 3.2 在 set -u 下展开空数组会直接报错。
if ! EXPORTS="$(bash "$SELF_DIR/device_profile.sh" ${PROFILES_ARGS[@]+"${PROFILES_ARGS[@]}"} --export "${PROFILE:-}")"; then
  exit 2
fi
eval "$EXPORTS"

NAME="${DEV_NAME:-}"
TYPE="${DEV_SIM_TYPE:-}"
RUNTIME="${DEV_RUNTIME:-}"
UDID_FILE="${DEV_UDID_FILE:-}"
PIXELS="${DEV_PIXELS:-}"

[[ -n "$NAME" && -n "$TYPE" && -n "$RUNTIME" ]] || {
  echo "✗ 档案 ${DEV_PROFILE:-?} 缺 name / simType / runtime，无法绑定设备" >&2; exit 2; }
[[ -n "$UDID_FILE" ]] || { echo "✗ 档案 ${DEV_PROFILE:-?} 缺 udidFile" >&2; exit 2; }

command -v xcrun >/dev/null 2>&1 || { echo "✗ 需要 Xcode 命令行工具" >&2; exit 2; }

run() {
  if (( PLAN_ONLY )); then
    printf '   [plan] %s\n' "$*"
    return 0
  fi
  "$@"
}

# 全表 JSON 交给 python 判定，避免 grep 名字时把 `Clone 1` 也算进来。
# 输出三列：udid<TAB>state<TAB>runtime
devices_json() {
  xcrun simctl list devices -j 2>/dev/null
}

# ---------------------------------------------------------------- 1. 绑定 UDID
BOUND=""
BOUND_RUNTIME=""

# L1：文件里记的还活着就继续用 —— 这是"不重复创建"的主路径。
if [[ -f "$UDID_FILE" ]]; then
  SAVED="$(tr -d '[:space:]' < "$UDID_FILE")"
  if [[ -n "$SAVED" ]]; then
    HIT="$(devices_json | python3 -c '
import json,sys
want = sys.argv[1]
d = json.load(sys.stdin)["devices"]
for rt, arr in d.items():
    for x in arr:
        if x.get("udid") == want and x.get("isAvailable", False):
            print(x["udid"] + "\t" + rt); sys.exit(0)
sys.exit(1)
' "$SAVED" 2>/dev/null)" && [[ -n "$HIT" ]] && {
      BOUND="${HIT%%$'\t'*}"
      BOUND_RUNTIME="${HIT##*$'\t'}"
      echo ">> 复用已绑定设备：${NAME} (${BOUND})"
    }
  fi
fi

# L2 / L3：按名字找。同名可能有多条（旧 runtime 残留），一次全取出来。
if [[ -z "$BOUND" ]]; then
  CANDIDATES="$(devices_json | python3 -c '
import json,sys
name = sys.argv[1]
d = json.load(sys.stdin)["devices"]
for rt, arr in d.items():
    for x in arr:
        if x.get("name") == name and x.get("isAvailable", False):
            print(x["udid"] + "\t" + rt)
' "$NAME" 2>/dev/null)"

  if [[ -n "$CANDIDATES" ]]; then
    # L2：runtime 完全一致的优先
    EXACT="$(printf '%s\n' "$CANDIDATES" | awk -F'\t' -v rt="$RUNTIME" '$2 == rt {print; exit}')"
    if [[ -n "$EXACT" ]]; then
      BOUND="${EXACT%%$'\t'*}"; BOUND_RUNTIME="${EXACT##*$'\t'}"
      echo ">> 复用同名同 runtime 设备：${NAME} (${BOUND})"
    else
      # L3：runtime 升级过，复用旧的重置即可，但提醒清档
      FIRST="$(printf '%s\n' "$CANDIDATES" | head -1)"
      BOUND="${FIRST%%$'\t'*}"; BOUND_RUNTIME="${FIRST##*$'\t'}"
      echo ">> 复用同名设备，但 runtime 不符（档案要 ${RUNTIME##*.}，实际 ${BOUND_RUNTIME##*.}）：${BOUND}"
      echo "   建议跑 --prune 清掉重复档，或改档案里的 runtime 字段。"
    fi
  fi
fi

# L4：真的没有才建。但建之前先看一眼：同一类型 + 同一 runtime 下是否已有别的名字的设备。
# 命中就说明「大概率是档案里的 name 写错了，不是真没有」—— 盲建会让两台几乎一样的设备并存。
if [[ -z "$BOUND" ]]; then
  LOOKALIKE="$(devices_json | python3 -c '
import json,sys
typ, rt = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["devices"]
for r, arr in d.items():
    if r != rt:
        continue
    for x in arr:
        if x.get("deviceTypeIdentifier") == typ:
            print(x["name"] + "\t" + x["udid"])
' "$TYPE" "$RUNTIME" 2>/dev/null)"

  if [[ -n "$LOOKALIKE" ]]; then
    echo "⚠ 档案里没有叫 ${NAME} 的设备，但同类型同 runtime 下已有：" >&2
    while IFS=$'\t' read -r n u; do echo "    ${n}  ${u}" >&2; done <<< "$LOOKALIKE"
    echo "  若其中之一就是本项目那台（只是名字不同），改档案的 name 指向它，不要新建。" >&2
    echo "  一台模拟器占 1–3 GB，两台并存还会让后续脚本认错设备。" >&2
    echo "" >&2
  fi
fi

if [[ -z "$BOUND" ]]; then
  echo ">> 首次创建模拟器：${NAME} (${TYPE} / ${RUNTIME##*.})"
  if (( PLAN_ONLY )); then
    echo "   [plan] xcrun simctl create \"${NAME}\" \"${TYPE}\" \"${RUNTIME}\""
    BOUND="<新建>"
  else
    BOUND="$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME" 2>&1)" || {
      echo "✗ 创建失败：${BOUND}" >&2
      echo "  检查档案里的 simType / runtime 是否真实存在：" >&2
      echo "    xcrun simctl list devicetypes | grep -i <关键字>" >&2
      echo "    xcrun simctl list runtimes" >&2
      exit 1
    }
  fi
fi

UDID="$BOUND"

# 立刻落盘：即使后面步骤失败，下一轮也已经认得出这台设备，不会再建一台。
if [[ -n "$UDID" && "$UDID" != "<新建>" ]]; then
  if (( PLAN_ONLY )); then
    echo "   [plan] echo \$UDID > ${UDID_FILE}"
  else
    mkdir -p "$(dirname "$UDID_FILE")"
    printf '%s' "$UDID" > "$UDID_FILE"
  fi
fi

# ---------------------------------------------------------------- 2. 清场
# 只删本档案名下的：同名重复档 + UI 测试克隆体 + 挂掉的残骸。
# ⛔ 绝不用 `simctl delete all` —— 那会连别的项目的设备一起删。
# 判据统一为「名字里含本档案的 name」：克隆体在不同 Xcode 版本里有 `<name> Clone 1`
# 和 `Clone 1 of <name>` 两种写法，只匹配前缀会漏掉后者。
prune_devices() {
  local keep="$1"
  devices_json | python3 -c '
import json,sys
keep, name = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["devices"]
doomed = []
for rt, arr in d.items():
    for x in arr:
        n, u = x.get("name", ""), x.get("udid", "")
        if u == keep:
            continue
        # 必须与本档案的 name 相关，绝不碰别人的设备
        if n == name or name in n:
            doomed.append((u, n, rt.split(".")[-1], x.get("isAvailable", False)))
for u, n, rt, ok in doomed:
    print(f"{u}\t{n}\t{rt}\t{'可用' if ok else '残骸'}")
' "$keep" "$NAME"
}

PRUNE_LIST="$(prune_devices "$UDID")"
if [[ -n "$PRUNE_LIST" ]]; then
  COUNT="$(printf '%s\n' "$PRUNE_LIST" | wc -l | tr -d ' ')"
  if (( DO_PRUNE )); then
    echo ">> 清理本档案名下的 $COUNT 台多余设备"
    while IFS=$'\t' read -r u n rt _; do
      echo "   删除 $n ($rt) $u"
      run xcrun simctl delete "$u"
    done <<< "$PRUNE_LIST"
  else
    echo ">> 发现 $COUNT 台本档案名下的多余设备（未删除；加 --prune 清理）"
    printf '%s\n' "$PRUNE_LIST" | while IFS=$'\t' read -r u n rt st; do
      echo "   $n ($rt, $st) $u"
    done
  fi
fi

# ---------------------------------------------------------------- 3. 重置并启动
if (( STATUS_ONLY )); then
  :
else
  if [[ "$DO_ERASE" == "1" ]]; then
    echo ">> 重置设备（幂等起点；只动模拟器内部，不碰宿主文件）"
    run xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    run xcrun simctl erase "$UDID"
  fi
  echo ">> 启动"
  run xcrun simctl boot "$UDID"
fi

if (( PLAN_ONLY )); then
  echo ""
  echo "[plan] 未做任何改动。去掉 --plan 执行。"
  exit 0
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 4. 状态栏
# 商店图的状态栏必须是固定值，否则每张图的电量/时间都不一样。
echo ">> 固定状态栏 9:41 / 满信号 / WiFi / 满电"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100 >/dev/null 2>&1 || echo "   (状态栏覆盖失败，继续)"

(( STATUS_ONLY )) && { echo "$UDID"; exit 0; }

echo ""
echo "✓ 设备已绑定：${NAME}（${DEV_PROFILE:-?}）"
echo "  UDID   ${UDID}"
echo "  允许像素 ${PIXELS:-未配置}"
echo "  记在   ${UDID_FILE}"
echo "  下一轮直接读这个文件，不会再创建新设备。"
