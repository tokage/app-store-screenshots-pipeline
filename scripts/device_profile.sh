#!/usr/bin/env bash
# 设备身份唯一出口：从 fastlane/device-profiles.json 取一台设备的全部相关值。
#
# 用法
#   bash scripts/device_profile.sh --list
#   bash scripts/device_profile.sh --get ascType duo
#   eval "$(bash scripts/device_profile.sh --export duo)"    # 得到 DEV_* 变量
#
# 为什么不允许在别处写设备名：设备不只是"一个名字"。它同时决定模拟器类型、runtime、
# ASC 显示槽、允许像素、产物目录、种子库目录、美化工程的 device 键、导出尺寸目录、
# 是否折叠。这些值分散在 init/shoot/use_store/Snapfile/Fastfile/上传脚本里各写一遍时，
# 加第二台设备必然漏改一处 —— 而漏改的表现不是报错，是**静默抓错设备**或
# **静默抓到外屏尺寸**，要等到商店页上才发现。
#
# 退出码：0 成功；2 参数或文件错误。

set -uo pipefail

PROFILES="${DEVICE_PROFILES:-fastlane/device-profiles.json}"
CMD=""; KEY=""; NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles)   PROFILES="${2:?}"; shift 2 ;;
    --profiles=*) PROFILES="${1#*=}"; shift ;;
    --list)       CMD="list"; shift ;;
    --get)        CMD="get"; KEY="${2:?}"; shift 2 ;;
    --export)     CMD="export"; NAME="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    -*)           echo "未知参数: $1" >&2; exit 2 ;;
    *)            if [[ "$CMD" == "get" && -z "$NAME" ]]; then NAME="$1"; else echo "多余参数: $1" >&2; exit 2; fi; shift ;;
  esac
done

[[ -n "$CMD" ]] || { echo "用法: $0 --list | --get <字段> [档案] | --export <档案>" >&2; exit 2; }
[[ -f "$PROFILES" ]] || { echo "✗ 找不到 ${PROFILES}（可用 --profiles 指定）" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ 需要 python3 解析 JSON" >&2; exit 2; }

python3 - "$PROFILES" "$CMD" "${KEY:-}" "${NAME:-}" <<'PY'
import json, os, sys

path, cmd, key, name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(path, encoding="utf-8"))
profiles = data.get("profiles", {})

def expand(value):
    # seedDir 一类路径允许写 ~，取值时展开成 $HOME —— 档案文件因此不必写机器专属绝对路径
    return os.path.expanduser(value) if isinstance(value, str) else value

def scalar(v):
    # ⛔ 布尔必须序列化成 shell 惯例的 1/0。直接 str(True) 会得到 "True"，
    # 而下游一律写 [ "$DEV_FOLDABLE" = "1" ] —— 于是折叠设备被当成非折叠、
    # 静默跳过姿态，最后抓出外屏尺寸。这是最坏的失败模式：不报错。
    if isinstance(v, bool):
        return "1" if v else "0"
    return expand(v)

def values(p):
    # 列表值在 shell 里要能安全拼接，所以逐项展开、空格分隔
    return {k: (" ".join(scalar(x) for x in v) if isinstance(v, list) else scalar(v)) for k, v in p.items()}

if cmd == "list":
    default = data.get("default", "")
    print(f"{'档案':14s} {'ASC 槽':12s} {'像素':22s} {'折叠':4s} {'产物目录'}")
    for n, p in profiles.items():
        mark = " *" if n == default else "  "
        px = " ".join(map(str, p.get("pixels", [])))
        print(f"{n + mark:14s} {str(p.get('ascType', '-')):12s} {px:22s} "
              f"{'是' if p.get('foldable') else '否':4s} {p.get('shotsDir', '-')}")
    raise SystemExit(0)

if not name:
    name = data.get("default", "")
if not name:
    print("✗ 没指定档案，且 JSON 里没有 default", file=sys.stderr)
    raise SystemExit(2)
if name not in profiles:
    print(f"✗ 没有档案 {name}；可选：{', '.join(profiles)}", file=sys.stderr)
    raise SystemExit(2)

vals = values(profiles[name])

if cmd == "get":
    if key not in vals:
        print(f"✗ 档案 {name} 没有字段 {key}；可选：{', '.join(vals)}", file=sys.stderr)
        raise SystemExit(2)
    print(vals[key])
    raise SystemExit(0)

if cmd == "export":
    for k, v in vals.items():
        env = "DEV_" + "".join("_" + c if c.isupper() else c.upper() for c in k)
        # 单引号包裹，内部单引号做转义，避免 eval 时被拆词
        print(f"export {env}='{str(v).replace(chr(39), chr(39) + chr(92) + chr(39) + chr(39))}'")
    print(f"export DEV_PROFILE='{name}'")
    raise SystemExit(0)
PY
