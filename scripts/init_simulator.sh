#!/usr/bin/env bash
# 绑定一台模拟器：**每种规格只创建一次，之后所有项目复用它**。
#
# 为什么需要它：
#   `xcrun simctl create` 从不查重 —— 无脑跑一次就多一台设备（每台约 1–3 GB）。
#   轮次一多，机器上会堆出十几台几乎一样的设备 + 一堆 `Clone N` 克隆体，
#   CoreSimulator 越跑越慢，最后 `simctl` 整体挂住。
#
# 查重维度是**规格**，不是名字：
#   一台设备的物理规格只有 (deviceType, runtime) 两个维度，`name` 只是显示标签。
#   按 name 查重会让「每个项目一套」——10 个项目就是 20 台同规格设备。
#   按规格查重则是「全机每种规格一台」，项目数增加不产生新设备。
#
# 四层判据（命中即停）
#   L1  udidFile 里的 UDID 还活着且 available               → 直接用（最快，跑多少轮都是同一台）
#   L2  同 deviceType + 同 runtime（同名优先）               → 复用，UDID 写回文件
#   L3  同 deviceType + 同主版本 runtime（iOS-18-0/18-1）    → 复用，提示改档案 runtime
#   L4  同 deviceType 但 runtime 大版本不符（或完全没有）    → 建一台，旧档交给 --prune
#
# 独占与共享：
#   默认共享。共享的前提是**串行**（模拟器的 AX 会话同时只能被一个 UI 测试接管）
#   且每次跑前 erase —— 后者本脚本默认就做（`--no-erase` 关掉）。
#   需要并行时别建独立设备，用 `xcrun simctl clone` 克隆、跑完即删；
#   需要长期独享（两项目要不同 iOS 版本或不同种子库）时，给 name 加项目前缀。
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
TAKE_OVER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles)   PROFILES_ARGS=(--profiles "${2:?}"); shift 2 ;;
    --profiles=*) PROFILES_ARGS=(--profiles "${1#*=}"); shift ;;
    --no-erase)   DO_ERASE=0; shift ;;
    --prune)      DO_PRUNE=1; shift ;;
    --plan)       PLAN_ONLY=1; shift ;;
    --status-bar) STATUS_ONLY=1; shift ;;
    --take-over)  TAKE_OVER=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
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

# L2 / L3 / L4：按规格找。一次调用返回全部同规格候选，第一行决定动作。
# 输出列：action \t udid \t name \t runtime \t state
if [[ -z "$BOUND" ]]; then
  MATCH_ALL="$(devices_json | python3 -c '
import json,sys
want_name, typ, rt = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(sys.stdin)["devices"]

def major(r):
    # com.apple.CoreSimulator.SimRuntime.iOS-18-0 -> 18
    parts = r.rsplit(".", 1)[-1].split("-")
    return parts[1] if len(parts) > 1 else ""

same = []
for r, arr in d.items():
    for x in arr:
        if x.get("deviceTypeIdentifier") == typ and x.get("isAvailable", False):
            same.append((r, x))

def emit(action, r, x):
    print("\t".join([action, x["udid"], x["name"], r, x.get("state", "?")]))

# 同名优先：自己的设备永远排在别人前面，共享时才轮到别人的
same.sort(key=lambda p: (p[1]["name"] != want_name, p[1]["name"]))

exact = [p for p in same if p[0] == rt]
if exact:
    emit("reuse-exact", *exact[0]); sys.exit(0)

mv = major(rt)
ver = [p for p in same if mv and major(p[0]) == mv]
if ver:
    emit("reuse-version", *ver[0])
    for p in ver[1:]:
        emit("stale", *p)
    sys.exit(0)

for p in same:
    emit("stale", *p)
print("create\t\t\t\t")
' "$NAME" "$TYPE" "$RUNTIME" 2>/dev/null)"

  ACTION="$(printf '%s\n' "$MATCH_ALL" | head -1 | cut -f1)"
  IFS=$'\t' read -r _ M_UDID M_NAME M_RUNTIME M_STATE <<< "$(printf '%s\n' "$MATCH_ALL" | head -1)"

  # 接管前先查占用：设备正 Booted 说明可能有人正在跑，erase 会直接踩掉对方的 app 容器。
  # 放在打印之前 —— 否则会先告诉你"直接共用"，再告诉你"不能接管"，自相矛盾。
  if [[ -n "$M_UDID" && "$M_STATE" == "Booted" && "$M_NAME" != "$NAME" ]]; then
    echo "" >&2
    echo "⚠ 命中的 ${M_NAME} (${M_UDID}) 当前正在运行，且不是本档案的设备。" >&2
    echo "  它可能正被另一个项目或另一个任务使用，接管（含 erase）会终止对方的测试。" >&2
    echo "  确认要接管请加 --take-over；否则先 shutdown 它，或改档案 name 指向自己的设备。" >&2
    (( TAKE_OVER )) || exit 3
  fi

  case "$ACTION" in
    reuse-exact)
      BOUND="$M_UDID"; BOUND_RUNTIME="$M_RUNTIME"
      if [[ "$M_NAME" == "$NAME" ]]; then
        echo ">> 复用本档案设备：${M_NAME} (${M_UDID})"
      else
        echo ">> 复用同规格设备：${M_NAME} (${M_UDID})"
        echo "   档案名是 ${NAME}，但规格相同（${TYPE##*.} / ${M_RUNTIME##*.}），直接共用 —— 不新建。"
      fi
      ;;
    reuse-version)
      BOUND="$M_UDID"; BOUND_RUNTIME="$M_RUNTIME"
      echo ">> 复用设备：${M_NAME} (${M_UDID})"
      echo "   runtime 与档案略有差异（档案 ${RUNTIME##*.}，实际 ${M_RUNTIME##*.}），小版本不影响截图尺寸。"
      echo "   若要与档案严格一致，把档案的 runtime 改成 ${M_RUNTIME}。"
      ;;
    *)
      BOUND=""; BOUND_RUNTIME=""
      ;;
  esac

  if [[ -n "$BOUND" && "$M_NAME" != "$NAME" ]]; then
    echo "   提示：本档案以后会一直用这台。想让它归本档案管，可改档案 name 为 ${M_NAME}。"
  fi
fi

if [[ -z "$BOUND" ]]; then
  # 走到这里说明同规格一台都没有（或 runtime 大版本已换代）。
  # 若有旧 runtime 的同规格设备，先列出来 —— 它们就是该被 --prune 清掉的。
  STALE="$(printf '%s\n' "$MATCH_ALL" | awk -F'\t' '$1 == "stale"')"
  if [[ -n "$STALE" ]]; then
    echo ">> 同规格但 runtime 大版本不符的旧设备（新机建好后可用 --prune 清掉）："
    printf '%s\n' "$STALE" | while IFS=$'\t' read -r _ u n r st; do
      echo "   ${n}  ${r##*.}  (${st})  ${u}"
    done
    echo ""
  fi
  echo ">> 首次创建模拟器：${NAME} (${TYPE##*.} / ${RUNTIME##*.})"
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
# 只删**精确属于本档案**的：同名重复档（含 runtime 换代留下的旧档）与克隆体。
# ⛔ 绝不用 `simctl delete all` —— 那会连别的项目的设备一起删。
# ⛔ 判据必须是精确匹配，不能是子串：档案叫 `ASC-DUO` 时，`VR-ASC-DUO` 和
#    `ODM-ASC-DUO` 都包含这个子串，按子串删就是删别人的设备。
# ⛔ 同规格但名字不同的设备一律不删 —— 它们不是垃圾，是别的项目的独占设备。
prune_devices() {
  local keep="$1"
  devices_json | python3 -c '
import json,re,sys
keep, name = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["devices"]

def family(n):
    # 三种合法写法，其余一律不算
    if n == name:
        return "重复档"
    if re.fullmatch(re.escape(name) + r" Clone \d+", n):
        return "克隆体"
    if re.fullmatch(r"Clone \d+ of " + re.escape(name), n):
        return "克隆体"
    return None

def human(nbytes):
    if not isinstance(nbytes, int) or nbytes <= 0:
        return "?"
    v = float(nbytes)
    for unit in ("B", "KB", "MB", "GB"):
        if v < 1024 or unit == "GB":
            return f"{v:.0f}{unit}" if unit in ("B", "KB") else f"{v:.1f}{unit}"
        v /= 1024.0

for rt, arr in d.items():
    for x in arr:
        n, u = x.get("name", ""), x.get("udid", "")
        if u == keep:
            continue
        why = family(n)
        if not why:
            continue
        booted = x.get("state") == "Booted"
        print("\t".join([u, n, rt.split(".")[-1],
                         "运行中·跳过" if booted else why,
                         human(x.get("dataPathSize"))]))
' "$keep" "$NAME"
}

PRUNE_LIST="$(prune_devices "$UDID")"
if [[ -n "$PRUNE_LIST" ]]; then
  COUNT="$(printf '%s\n' "$PRUNE_LIST" | wc -l | tr -d ' ')"
  if (( DO_PRUNE )); then
    echo ">> 清理 $COUNT 台多余设备"
    while IFS=$'\t' read -r u n rt why size; do
      if [[ "$why" == 运行中* ]]; then
        echo "   跳过 $n ($rt) —— 正在运行"
        continue
      fi
      echo "   删除 $n ($rt, ${why}, ${size}) $u"
      run xcrun simctl delete "$u"
    done <<< "$PRUNE_LIST"
  else
    echo ">> 发现 $COUNT 台可清理（未删除；加 --prune 清理）"
    printf '%s\n' "$PRUNE_LIST" | while IFS=$'\t' read -r u n rt why size; do
      echo "   $n  ${rt}  ${why}  ${size}  ${u}"
    done
  fi
fi

# 同规格的其他设备：只报不删。它们可能是别的项目的独占设备，删了就是踩别人。
OTHER_SPEC="$(devices_json | python3 -c '
import json,sys
keep, typ = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["devices"]
for rt, arr in d.items():
    for x in arr:
        if x.get("udid") == keep or x.get("deviceTypeIdentifier") != typ:
            continue
        if not x.get("isAvailable", False):
            continue
        print("\t".join([x["name"], rt.split(".")[-1], x.get("state", "?")]))
' "$UDID" "$TYPE")"
if [[ -n "$OTHER_SPEC" ]]; then
  echo ">> 同规格的其他设备（属其他项目，本脚本不碰）："
  printf '%s\n' "$OTHER_SPEC" | while IFS=$'\t' read -r n rt st; do
    echo "   $n  ${rt}  ${st}"
  done
  echo "   想收敛成共享一台：让那些项目的档案改用同一个 name，或确认无用后手动 simctl delete。"
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
