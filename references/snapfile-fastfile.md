# Snapfile 与 Fastfile 模板

## 0. 语言探测：生成 `languages` 数组的唯一来源（必须先做）

**`languages` 数组绝不能凭经验硬编码。** fastlane snapshot 不会自动读取 Xcode 项目的 `knownRegions` 或 `Localizable.xcstrings`，但数组里的语言又必须**真实存在于项目本地化资源**里——否则某语言 run 会静默失败（0 张图）或第二种语言断言超时。因此生成 Snapfile 前，必须先从项目实际配置读出支持的语言，再派生 `languages`。

### 探测命令（按优先级，取第一个有结果者）
```bash
# ① 首选：Localizable.xcstrings 里实际存在的 localizations（最权威，反映 App 真正翻译的语言）
python3 -c "
import json, glob, sys
fs = glob.glob('**/Localizable.xcstrings', recursive=True)
if not fs: sys.exit(1)
d = json.load(open(fs[0]))
langs = {d.get('sourceLanguage', 'en')}
for s in d.get('strings', {}).values():
    langs |= set(s.get('localizations', {}).keys())
print(' '.join(sorted(langs)))
"

# ② 备选 A：Xcode 工程的 knownRegions
grep -A20 'knownRegions' project.pbxproj | grep -oE '"(en|Base|zh-Hans|zh-Hant|ja|ko|fr|de|es|pt|it|ru)"'

# ③ 备选 B：已生成的 .lproj 目录
ls -d *.lproj 2>/dev/null | sed 's/.lproj//'

# ④ 备选 C：Info.plist 的 CFBundleLocalizations
/usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" path/to/Info.plist 2>/dev/null
```

### 映射到 fastlane `languages` 代码（BCP-47，对应 `-AppleLanguages`）
读到的区域码需转成 fastlane 接受的形式。**`Base` 必须丢弃**（回退到 `sourceLanguage`）；`en` 统一写成 `en-US`：

| 项目区域码 | fastlane `languages` 值 |
|---|---|
| `en` / `Base` | `en-US`（Base 落到 sourceLanguage，en 用区域限定形式） |
| `zh-Hans` | `zh-Hans` |
| `zh-Hant` | `zh-Hant` |
| `ja` | `ja-JP` |
| `ko` | `ko-KR` |
| `fr` | `fr-FR` |
| `de` | `de-DE` |
| `es` | `es-ES` |
| `pt` | `pt-BR` |
| `it` | `it-IT` |
| `ru` | `ru-RU` |

> 例：探测得到 `en zh-Hans zh-Hant` → `languages(["en-US", "zh-Hans", "zh-Hant"])`。

## 1. Snapfile
```ruby
# fastlane/Snapfile
# 设备来自探测结果，不要写死型号。下方为示例，运行时替换为 probe_environment.py 输出。
devices([
  "iPhone 16 Pro (18.0)",
  "iPhone 16 (18.0)",
  "iPad Pro 13-inch (M4) (18.0)"
])

# languages 必须由「语言探测」（本节第 0 条）派生，禁止凭经验硬编码。
# 下方为示例，实际值 = 项目 Localizable.xcstrings / knownRegions 里真实存在的语言。
languages(["en-US", "zh-Hans"])

# 截图输出目录：fastlane 官方约定，snapshot 默认写到这里，frameit 同读此目录。
# 不要改成其他路径。
output_directory "./fastlane/screenshots"

# 防止 UI 测试失败时 clone 雪崩拖垮 Mac；它不是修复死锁，只是止损。
number_of_retries(0)
concurrent_simulators(false)

# 只跑截图测试，避免触发主 App 测试。
only_testing(["RouteLensUITests/ScreenshotsTests"])

# 可选：截图前清理旧图
clear_previous_screenshots(true)
```

**截图目录约定**：`snapshot` 默认输出到 `fastlane/screenshots/`（fastlane 官方约定）；`frameit`（`fastlane screenshots`）读取同一目录加框。配置时显式写明此目录，不要改路径或遗漏说明。

## 2. Fastfile
```ruby
# fastlane/Fastfile
default_platform(:ios)

platform :ios do
  desc "仅编译（不运行测试），用于 fastlane 跑图前快速验证代码可否通过编译"
  lane :compile_check do
    scan(
      scheme: "RouteLensUITests",
      project: "./RouteLens.xcodeproj",
      build_for_testing: true,
      clean: false
    )
  end

  desc "跑 UI 测试出图"
  lane :raw_screenshots do
    snapshot
  end

  desc "给已出图加设备边框（纯图像处理，不跑模拟器）"
  lane :screenshots do
    frameit(white: true)
  end

  # 可选：上传 App Store Connect
  # lane :deliver_screenshots do
  #   deliver(skip_metadata: true, skip_binary_upload: true, overwrite_screenshots: true)
  # end
end
```

> 注意：`precheck` 是 fastlane 内置工具名，自定义 lane **禁止**命名为 `precheck`，否则警告 `Lane name 'precheck' should not be used because it is the name of a fastlane tool`。上例已改用 `compile_check`。

## 3. SnapshotHelper 写文件守卫 fallback
fastlane 自带 `SnapshotHelper.swift` 在写截图时用 `SIMULATOR_DEVICE_NAME` 命名文件。该环境变量在部分设备/语言组合下**不注入**，会导致静默失败（0 张图）。加 `UIDevice.current.name` 兜底：
```swift
private func resolvedSimulatorName() -> String {
    if let env = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"], !env.isEmpty {
        return env
    }
    return UIDevice.current.name   // 兜底：真实设备/缺失环境变量时使用
}
```

## 4. 探测替换
运行顶层步骤 1 提供的 `probe_environment.py` 探测脚本，或手动：
```bash
xcrun simctl list runtimes   # 取可用最高 iOS 版本
xcrun simctl list devices    # 取该 runtime 下设备名
```
把设备名（含 `(版本)` 后缀）填入 Snapfile `devices`。App scheme 名从 `.xcworkspace/xcshareddata/xcschemes/` 读取，不要臆测。

## 5. 失败分支
- `xcrun simctl list devices` 为空 → 先用 Simulator 新建对应设备。
- 编译门禁失败 → 先修代码再跑图。
- frameit 找不到设备边框 → 安装 `fastlane frameit` 所需设备模板或跳过加框。
