#!/usr/bin/env python3
"""环境检查：这一步决定后面跳过教程直跑，还是只告诉用户缺什么。

只读。不安装、不登录、不改配置、不启动模拟器（只 list）。

输出四种状态之一，SKILL.md 按它路由：
    ready         依赖齐全，直接进主流程，不再讲配置
    partial       可选依赖缺失，跑可用部分并标注限制
    needs_setup   必需依赖缺失，只列缺的这几项
    unavailable   装了但坏了（版本不支持、认证失效），给恢复步骤

用法
    python3 scripts/check_environment.py [--app-root .] [--json]
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], timeout: int = 25) -> tuple[bool, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode == 0, (p.stdout or "") + (p.stderr or "")
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)


def item(name: str, required: bool, ok: bool, detail: str, fix: str) -> dict:
    return {"name": name, "required": required, "ok": ok, "detail": detail, "fix": "" if ok else fix}


def probe_machine() -> list[dict]:
    out: list[dict] = []
    is_mac = platform.system() == "Darwin"
    out.append(item("macOS", True, is_mac, platform.platform(),
                    "截图只能在 macOS 上做。其它系统可继续做美化与文案，抓图跳过。"))

    if is_mac:
        ok, txt = run(["xcodebuild", "-version"])
        first = txt.strip().splitlines()[0] if txt.strip() else "未安装"
        out.append(item("Xcode", True, ok, first,
                        "从 App Store 安装 Xcode，然后 sudo xcode-select -s /Applications/Xcode.app"))

        ok, txt = run(["xcrun", "simctl", "list", "runtimes", "-j"])
        rt_ok = ok and txt.strip().startswith("{")
        out.append(item("CoreSimulator runtime", True, rt_ok,
                        "有可用 runtime" if rt_ok else "无可用 runtime",
                        "Xcode → Settings → Components 下载一个 iOS runtime"))

    ok = shutil.which("fastlane") is not None
    out.append(item("fastlane", True, ok, shutil.which("fastlane") or "未安装",
                    "gem install fastlane（或项目里 bundle install）"))

    bun = shutil.which("bun")
    node = shutil.which("node")
    out.append(item("bun / node（美化工程）", True, bool(bun or node),
                    f"bun={bun or '无'} node={node or '无'}",
                    "装 bun（https://bun.sh）或 Node 20+；两者都没有则编辑器起不来"))

    asc = shutil.which("asc") or shutil.which("asc", path="/opt/homebrew/bin")
    out.append(item("asc CLI", False, bool(asc), asc or "未安装",
                    "brew install asc。没装也能做完美化与导出，只是上传那步要手动在 ASC 后台点。"))

    if asc:
        ok, txt = run([asc, "auth", "doctor"])
        authed = ok and "No stored credentials" not in txt
        out.append(item("asc 认证", False, authed,
                        "已登录" if authed else "未登录",
                        "asc auth login --key-id … --issuer-id … --private-key ~/.private_keys/AuthKey_xxx.p8"))
        # 环境变量会静默绕过钥匙串，症状是"明明登录了却读不到凭据"
        if "bypassed via ASC_BYPASS_KEYCHAIN" in txt:
            out.append(item("ASC_BYPASS_KEYCHAIN", False, False, "该变量已设置，键串被绕过",
                            "unset ASC_BYPASS_KEYCHAIN —— 它会让人误判成未登录"))

    path_env = shutil.which("sips") is not None
    out.append(item("sips（尺寸硬门）", True, path_env, "可用" if path_env else "PATH 里没有 sips",
                    'export PATH="/usr/bin:/bin:/opt/homebrew/bin:$PATH"'))

    shell_path = shutil.which("asc") or shutil.which("fastlane")
    if not shell_path:
        out.append(item("PATH 覆盖", False, False, "asc/fastlane 都不在 PATH",
                        'export PATH="/opt/homebrew/bin:$PATH"'))
    return out


def probe_project(root: Path) -> list[dict]:
    out: list[dict] = []
    xcodeproj = next(iter(sorted(root.glob("*.xcworkspace"))), None) or \
                next(iter(sorted(root.glob("*.xcodeproj"))), None)
    out.append(item("Xcode 工程", True, xcodeproj is not None,
                    xcodeproj.name if xcodeproj else "当前目录没有 .xcodeproj / .xcworkspace",
                    "在 app 根目录运行，或用 --app-root 指定"))

    fastfile = root / "fastlane" / "Fastfile"
    lanes: list[str] = []
    if fastfile.is_file():
        lanes = re.findall(r"^\s*lane\s+:(\w+)", fastfile.read_text(encoding="utf-8", errors="ignore"), re.M)
    out.append(item("fastlane 配置", True, fastfile.is_file(),
                    f"lanes: {', '.join(lanes[:6])}" if lanes else "有 fastlane 目录但没读到 lane",
                    "先配 fastlane（本 skill 的 references/snapfile-fastfile.md 有模板）"))

    xcstrings = list(root.rglob("*.xcstrings"))
    out.append(item("本地化资源", False, bool(xcstrings),
                    ", ".join(p.name for p in xcstrings[:3]) or "没找到 .xcstrings",
                    "语言列表需从 .xcstrings / knownRegions 派生，找不到就只能问用户"))

    profiles = root / "fastlane" / "device-profiles.json"
    out.append(item("设备档案", False, profiles.is_file(),
                    str(profiles.relative_to(root)) if profiles.is_file() else "缺 fastlane/device-profiles.json",
                    "单设备可让 skill 用探测结果生成；一旦要出第二台设备，这是唯一的身份出口"))

    scaffold = root / "app-store-screenshots" / "app-store-screenshots.json"
    out.append(item("美化工程", False, scaffold.is_file(),
                    "已存在（重入时不会覆盖你的改动）" if scaffold.is_file() else "尚未脚手架",
                    "第一次跑由本 skill 自动拷贝模板，无需手动准备"))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-root", default=".")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    root = Path(args.app_root).expanduser().resolve()

    checks = probe_machine() + probe_project(root)
    missing_required = [c for c in checks if c["required"] and not c["ok"]]
    missing_optional = [c for c in checks if not c["required"] and not c["ok"]]

    if not missing_required:
        state = "ready"
    elif any(c["name"] in ("macOS", "Xcode") for c in missing_required):
        state = "needs_setup"
    else:
        state = "needs_setup"
    if not missing_required and missing_optional:
        state = "partial"

    if args.json:
        print(json.dumps({"state": state, "appRoot": str(root), "checks": checks}, ensure_ascii=False, indent=2))
        return 0 if state in ("ready", "partial") else 1

    print(f"app-root: {root}")
    for c in checks:
        mark = "✓" if c["ok"] else ("✗" if c["required"] else "·")
        print(f"  {mark} {c['name']:22s} {c['detail']}")
    print()
    if state == "ready":
        print("ready —— 依赖齐全，直接进主流程。")
    elif state == "partial":
        print("partial —— 必需项齐了，以下可选能力不可用，相关步骤会跳过并标注：")
        for c in missing_optional:
            print(f"  · {c['name']}：{c['fix']}")
    else:
        print("needs_setup —— 只缺这几项，补齐即可（其余不用管）：")
        for c in missing_required:
            print(f"  ✗ {c['name']}：{c['fix']}")
    return 0 if state in ("ready", "partial") else 1


if __name__ == "__main__":
    raise SystemExit(main())
