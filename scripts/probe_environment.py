#!/usr/bin/env python3
"""探测 iOS 项目的截图环境：可用 runtime、设备、App 名称与 scheme。

仅使用 Python 标准库。需要 macOS + Xcode 命令行工具（xcrun）。
输出 JSON 到 stdout（或 --json-out 指定文件），供填 Snapfile 的 devices 字段与确认 App 名称。

用法:
    python probe_environment.py /path/to/Project.xcworkspace
    python probe_environment.py /path/to/Project.xcodeproj
    python probe_environment.py . --json-out env.json
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (subprocess.SubprocessError, OSError):
        return None


def detect_runtime():
    """返回 (版本号, build_ident) 或 None。取可用最高 iOS runtime。"""
    res = run(["xcrun", "simctl", "list", "runtimes"])
    if not res or res.returncode != 0:
        return None
    best = None
    best_key = None
    for line in res.stdout.splitlines():
        m = re.search(r"iOS\s+(\d+\.\d+)\s+\((\d+\.\d+)\s+-\s+([^)]+)\)", line)
        if not m:
            continue
        version = m.group(1)
        try:
            key = tuple(int(x) for x in version.split("."))
        except ValueError:
            continue
        if best_key is None or key > best_key:
            best_key = key
            best = (version, m.group(3).strip())
    return best


def list_devices(runtime_version):
    if not runtime_version:
        return []
    res = run(["xcrun", "simctl", "list", "devices"])
    if not res or res.returncode != 0:
        return []
    devices = []
    in_section = False
    pat = re.compile(r"^\s*(.*?)\s*\(\s*" + re.escape(runtime_version) + r"\s*\)")
    for line in res.stdout.splitlines():
        if line.startswith("=="):
            in_section = runtime_version in line
            continue
        if not in_section:
            continue
        m = pat.search(line)
        if m:
            name = m.group(1).strip()
            devices.append(f"{name} ({runtime_version})")
    return devices


def find_info_plist(project_dir):
    candidates = [p for p in project_dir.rglob("*Info.plist") if "Test" not in p.parts]
    if candidates:
        return candidates[0]
    all_plist = list(project_dir.rglob("*Info.plist"))
    return all_plist[0] if all_plist else None


def read_app_meta(info_plist):
    if not info_plist or not info_plist.exists():
        return "", ""
    try:
        with open(info_plist, "rb") as fh:
            data = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException):
        return "", ""
    name = data.get("CFBundleDisplayName") or data.get("CFBundleName") or ""
    bundle = data.get("CFBundleIdentifier") or ""
    return name, bundle


def find_schemes(project_dir):
    schemes = set()
    for ext in (".xcworkspace", ".xcodeproj"):
        for container in project_dir.rglob(f"*{ext}"):
            scm = container / "xcshareddata" / "xcschemes"
            if scm.is_dir():
                schemes.update(sorted(p.stem for p in scm.glob("*.xcscheme")))
    return sorted(schemes)


def main():
    ap = argparse.ArgumentParser(description="探测 iOS 截图环境")
    ap.add_argument("project", nargs="?", default=".", help=".xcworkspace 或 .xcodeproj 目录")
    ap.add_argument("--json-out", help="把结果写到该路径而非 stdout")
    args = ap.parse_args()

    project_dir = Path(args.project).expanduser().resolve()
    if project_dir.suffix in (".xcodeproj", ".xcworkspace"):
        project_dir = project_dir.parent

    runtime = detect_runtime()
    runtime_version = runtime[0] if runtime else None
    devices = list_devices(runtime_version)
    info_plist = find_info_plist(project_dir)
    app_name, bundle_id = read_app_meta(info_plist)
    schemes = find_schemes(project_dir)

    result = {
        "runtime_hint": runtime_version,
        "runtime_identifier": runtime[1] if runtime else "",
        "devices": devices,
        "app_name": app_name,
        "bundle_id": bundle_id,
        "schemes": schemes,
        "info_plist": str(info_plist) if info_plist else "",
        "note": "把 devices 填入 Snapfile；runtime 上限为环境事实，非可选项。",
    }

    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out:
        Path(args.json_out).write_text(text, encoding="utf-8")
        print(f"written to {args.json_out}")
    else:
        print(text)


if __name__ == "__main__":
    main()
