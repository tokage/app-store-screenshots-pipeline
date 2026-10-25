#!/usr/bin/env bash
# 把折叠设备摆成「内屏 + 竖屏」并**验证真的摆成了**（非折叠档案直接跳过）。
#
# 为什么需要它：
#   折叠屏模拟器**每次开机都回到外屏折叠态**。抓内屏截图的土办法是"抓图前人工在
#   Device Hub 里展开一次"—— 忘了就抓出外屏尺寸，靠收货门的像素判据兜底，代价是整轮白跑。
#
#   `simctl` / `devicectl` 都没有 hinge 命令，`XCUIDevice.shared.orientation` 在折叠设备上
#   报成功但不生效（实测）。真正能改姿态的是 duoctl：它通过 `simctl spawn` 在模拟器内起
#   一个小 helper，发设备厂商自定义 HID 事件（usage page 0xFF61 / usage 0x5B，
#   hinge-slider-control 与 orientation-picker-control），由 locationd 折算成铰链角度与方向。
#   这正是 Device Hub 铰链滑杆走的那条路。
#
#   ⛔ 转完必须等画面转过去再判定：`rotate` 返回时只是事件发出去了，界面还在转。
#   立刻读状态会读到过渡中的画面（实测：duoctl state 已报 portrait，抓出来的图仍是上一姿态）。
#
# 用法
#   bash scripts/duo_pose.sh                    # 默认档案
#   bash scripts/duo_pose.sh iphone-duo         # 显式档案
#   bash scripts/duo_pose.sh iphone-duo --profiles fastlane/device-profiles.json
#   POSE_SETTLE=6 bash scripts/duo_pose.sh iphone-duo
#
# 退出码
#   0 已是内屏竖屏（或该档案不是折叠设备，无需摆姿态）
#   1 三轮都没摆成，或姿态对了但出图像素不在档案允许集里
#   2 缺 duoctl / 缺 UDID 文件 / 缺档案

set -uo pipefail

PROFILE=""
PROFILES_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles)   PROFILES_ARGS=(--profiles "${2:?}"); shift 2 ;;
    --profiles=*) PROFILES_ARGS=(--profiles "${1#*=}"); shift ;;
    -h|--help)    sed -n '2,28p' "$0"; exit 0 ;;
    -*)           echo "未知参数: $1" >&2; exit 2 ;;
    *)            PROFILE="$1"; shift ;;
  esac
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⛔ 必须先把取值和 eval 拆成两步：`eval "$(...)"` 会把命令替换的退出码丢掉，
# 档案名写错时 python 已经 exit 2，脚本却继续往下跑（静默用了空变量）。
# 数组展开写成 ${arr[@]+...}：macOS 自带 bash 3.2 在 set -u 下展开空数组会直接报错。
if ! EXPORTS="$(bash "$SELF_DIR/device_profile.sh" ${PROFILES_ARGS[@]+"${PROFILES_ARGS[@]}"} --export "${PROFILE:-}")"; then
  exit 2
fi
eval "$EXPORTS"

# 非折叠设备没有姿态可摆：静默通过，调用方无需分支。
if [[ "${DEV_FOLDABLE:-0}" != "1" ]]; then
  exit 0
fi

UDID_FILE="${DEV_UDID_FILE:-}"
[[ -n "$UDID_FILE" && -f "$UDID_FILE" ]] || { echo "✗ 缺 UDID 文件: ${UDID_FILE:-未配置 udidFile}" >&2; exit 2; }
export DUOCTL_UDID="$(cat "$UDID_FILE")"

# 转完到画面稳定之间的等待。物理上是一段系统级转场动画，给不足就会读到过渡帧。
SETTLE="${POSE_SETTLE:-4}"

if ! command -v duoctl >/dev/null 2>&1; then
  echo "✗ 缺 duoctl（折叠姿态唯一可脚本化的出口）" >&2
  echo "  brew install skarol/tap/duoctl" >&2
  echo "  不装就只能人工在 Device Hub 展开，且每次开机都要重来。" >&2
  exit 2
fi

# duoctl state 的 JSON 很小，直接用字段名判，不引入 jq / python 依赖。
pose_field() {
  duoctl state 2>/dev/null | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\}.*/\1/p" | head -1
}

verify() {
  local screen orientation
  screen="$(pose_field activeScreen)"
  orientation="$(pose_field orientation)"
  if [[ "$screen" == "inner" && "$orientation" == "portrait" ]]; then
    return 0
  fi
  echo "  ✗ 姿态未到位：activeScreen=${screen:-?} orientation=${orientation:-?}" >&2
  return 1
}

# 最多三轮：偶发「open 成功但界面还停在外屏」的过渡态，重来一遍即可。
attempt=0
while (( attempt < 3 )); do
  attempt=$((attempt + 1))
  duoctl open >/dev/null 2>&1
  sleep "$SETTLE"
  # ⛔ 不要在 rotate 之后立刻校验。
  duoctl rotate portrait >/dev/null 2>&1
  sleep "$SETTLE"
  verify && break
done

if ! verify; then
  echo "✗ [${DEV_PROFILE:-?}] 三轮都没摆成内屏竖屏，抓图会得到外屏尺寸。" >&2
  echo "  duoctl state 现状：" >&2
  duoctl state >&2
  exit 1
fi

# 像素预检：姿态对了不等于分辨率对了（横屏也满足「内屏」）。
# 用一次真抓图 + sips 比 DEV_PIXELS 允许集，避免「摆了两分钟才发现抓的是横屏」。
probe="${TMPDIR:-/tmp}/duo-pose-probe-$$.png"
duoctl screenshot "$probe" >/dev/null 2>&1
dims=$(sips -g pixelWidth -g pixelHeight "$probe" 2>/dev/null \
         | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
rm -f "$probe"

hit=0
for allowed in ${DEV_PIXELS:-}; do
  [[ "$dims" == "$allowed" ]] && hit=1 && break
done

if (( hit == 0 )); then
  echo "✗ [${DEV_PROFILE:-?}] 姿态已是内屏，但出图 ${dims:-未知} ∉ {${DEV_PIXELS:-空}}" >&2
  exit 1
fi

echo "✓ [${DEV_PROFILE:-?}] 内屏竖屏已就位（${dims}）"
exit 0
