# 致命坑与死锁规避

以下为本次配发中真实踩过的坑，按出现概率排序。遇到现象先查对应坑，**不要 incremental 调参蒙混**。

## 坑 1：UI 测试在最新 runtime 上死锁（最致命）
**现象**：fastlane 一跑就弹出 `Clone N of iPhone …`，mobilecal 崩，fastlane **永不结束**，直到 `Cmd+C` 或 Mac 被拖垮断网。
**根因**：特定 Xcode 版本的 UI 测试框架（`XCUIInitializeForUITesting`）在**当前最高 iOS 模拟器 runtime** 初始化 Accessibility 子系统时死锁。这是工具链缺陷，与 Snapfile 配置、App 代码无关。
**解法**：UI 测试在**当前环境的可用 runtime** 上跑——把 Snapfile `devices` 钉到该 runtime（如 `18.0`），并让 UI 测试 target 的 `IPHONEOS_DEPLOYMENT_TARGET` 与之匹配。降级到可用 runtime 即绕开死锁。
**客观约束**：当前工具链模拟器 runtime 可用**上限为 iOS 18.0**（环境事实，非可选项）。Skill 须引导用户**探测当前最高可用 runtime**，以其为截图目标。

> **⚠️ 极易混淆：模拟器 Runtime ≠ 编译 Build SDK（两条独立轴）**
> - **Runtime（模拟器实际跑的 iOS 版本）**：由 `Snapfile` 的 `devices(["... (18.0)"])` 钉死，本坑约束的就是这一层，目的是避开 AX 死锁。**截图的 UI 外观 = 该 runtime 的外观**。
> - **Build SDK（编译 app 用的 SDK）**：由当前 `xcode-select` 指向的 Xcode 决定。例如机器只装 Xcode 26 → 自带 iOS 26.5 SDK，fastlane 永远用它编译。**它不受 `devices`/(18.0) 约束**。
> - 二者独立：即使 runtime 钉 18.0，build SDK 仍可能是 26.5。日志里 `falling back to SDK version '26.x'` 指的就是 build SDK，**不是模拟器在跑 26**——截图仍是在 18.0 模拟器里完成。
> - **推论（坑 9/坑 11 同源）**：不要写依赖「特定 SDK 才存在」的 SwiftUI 截图逻辑（如 `.tabBar` / `TabBarTabViewStyle`，在 iOS 26 SDK 被整体删除 → 编译报错）。截图切换应写成 **SDK 无关**：`TabView(selection:)` + 启动参数预选（见坑 9），无论 build SDK 是 18 还是 26 都编译通过。
> - 想把 build SDK 也钉回 18，只能额外装 Xcode 16 并 `sudo xcode-select -s` 切换——重量级且非必需，**不要写进默认流程**。
**禁止**：遇到死锁不硬扛，也不要把 `headless` / `concurrent_simulators` / `retries` 调参当作"修复"。

## 坑 2：lane 名 `precheck` 冲突
fastlane 内置 `precheck` 工具。自定义 lane 命名 `precheck` 会警告：`Lane name 'precheck' should not be used because it is the name of a fastlane tool`。改名（如 `compile_check`）。

## 坑 3：`simctl erase` 与 `delete` 混淆
- `xcrun simctl erase all`：只擦除设备**数据**，不删除设备对象。UI 测试克隆体（Clone N）残留在 daemon 里累积，最终拖垮 CoreSimulator。
- `xcrun simctl delete all`：删除设备**对象**，清掉僵尸克隆。
**用法**：清理失控的模拟器舰队用 `delete all`，不是 `erase all`。

## 坑 4：405 `server died` = CoreSimulator daemon 卡死
`405 Invalid device state / NSMachErrorDomain -308 server died` 是 **CoreSimulator daemon 真正卡死**，与坑 1 的 AX 死锁是**两个独立故障**。修复：`killall -9 CoreSimulatorService` + 重启 Mac，再 `xcrun simctl list runtimes` 确认 daemon 已恢复。

## 坑 5：调参只是创可贴
`headless(false)`、`concurrent_simulators(false)`、`number_of_retries(0)` 只能**防止 Mac 被拖垮**，不是修复崩溃本身。把它们当"稳定性修复"会误导后续排查。根因永远是对应的坑 1 / 坑 4。

## 坑 6：手动 Simulator 截图（fallback）
当 UI 测试在任何可用 runtime 仍死锁时，彻底绕开 XCTest：
1. Simulator 新建一个设备，Xcode 以 **App scheme**（非 UITests）Run，启动参数加 `-FASTLANE_SNAPSHOT YES`。
2. 手动导航到各界面，命令行截屏：
   ```bash
   xcrun simctl io booted screenshot "fastlane/screenshots/iPhone/01Records.png"
   ```
3. 之后单独跑 `fastlane screenshots`(frameit) 加框（纯图像处理，不碰模拟器）。

## 坑 7：`SIMULATOR_DEVICE_NAME` 静默失败
见 `snapfile-fastfile.md` 第 3 节。不加 fallback 会导致某些设备/语言组合 0 张图且无报错。

## 坑 8：UI 测试 target 的 `TEST_HOST` 与 `USES_XCTRUNNER` 互斥
**现象**：`xcodebuild ... scheme EbbsFlowUITests` 报
`Invalid configuration: <Target> sets both USES_XCTRUNNER and either TEST_HOST or RUNTIME_TEST_HOST`。
**根因**：`com.apple.product-type.bundle.ui-testing`（UI 测试包）会被 Xcode **隐式置 `USES_XCTRUNNER=YES`**（由产品类型触发，不在 pbxproj 里显式出现）。若再在它的 Build Configuration 里手写 `TEST_HOST` / `BUNDLE_LOADER` / `RUNTIME_TEST_HOST`，就与隐式 `USES_XCTRUNNER` 冲突。
**解法**：UI 测试 target 的 `buildSettings` **只留 `TEST_TARGET_NAME = <HostApp>`**，删除 `TEST_HOST`、`BUNDLE_LOADER`、`RUNTIME_TEST_HOST` 三行。UI 测试靠 XCTRunner 启动、由 `TEST_TARGET_NAME` 指定被启动的 App，不需要（也不能有）`TEST_HOST` 注入式配置——那套是 **Unit Test** 的写法。
**对照**：Unit Test target（注入式）才需要 `TEST_HOST = $(BUILT_PRODUCTS_DIR)/<App>.app/<App>` + `BUNDLE_LOADER = $(TEST_HOST)`；UI Test target 一律不要。
**静态自检**：改完 `grep -nE "TEST_HOST|BUNDLE_LOADER" project.pbxproj` 在 UI 测试配置段应**无残留**，并 `plutil -lint` OK。

## 坑 9：iPad 上 TabView 默认 sidebar，导致 `app.tabBars` 查询失败
**现象**：UI 测试在 iPhone 通过，但 iPad(regular width) 报 `XCTAssertTrue failed - <tab> tab 未出现`，卡在 `app.tabBars.buttons.element(boundBy: N)`。
**根因**：未显式设 `.tabViewStyle` 的 SwiftUI `TabView` 走 `automatic` 样式——**iPhone(compact) 渲染成底部 tab bar（有 `app.tabBars` 元素），iPad(regular) 渲染成侧边栏 sidebar（没有 `tabBars` 元素）**。用 `app.tabBars.buttons` 索引定位 tab 在侧边栏下直接落空。
**解法（推荐，零风险、iOS 26 安全）**：**不要去点 tab 按钮**，改用 `TabView(selection:)` 绑定 + 启动参数预选，让 UI 测试根本不依赖 tab 渲染形态：
```swift
// ContentView
@State private var selectedTab: Int = 0
init() {
    // 截图模式：`-FASTLANE_TAB guide` 直接预选 Guide，测试无需点击 tab 按钮
    if ProcessInfo.processInfo.arguments.contains("-FASTLANE_TAB"),
       let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-FASTLANE_TAB"),
       idx + 1 < ProcessInfo.processInfo.arguments.count,
       ProcessInfo.processInfo.arguments[idx + 1] == "guide" {
        _selectedTab = State(initialValue: 1)
    }
}
var body: some View {
    TabView(selection: $selectedTab) {
        CustomizeView().tabItem { Label("Customize", systemImage: "x") }.tag(0)
        UsageView().tabItem { Label("Guide", systemImage: "y") }.tag(1)
    }
}
```
```swift
// 测试：默认截 Customize；带参数重启预选 Guide，全程不点 tab 按钮
app.launch(); sleep(1); snapshot("01Customize")
app.terminate()
app.launchArguments.append(contentsOf: ["-FASTLANE_TAB", "guide"])
app.launch(); sleep(1); snapshot("02Guide")
```
此方案在 iPhone/iPad、底部栏/侧边栏、任意语言下都稳定，且**完全不碰 SwiftUI 的 tab 样式 API**（见坑 11：iOS 26 已移除 `.tabBar` / `TabBarTabViewStyle`）。
**已废弃的旧解法（勿用）**：早期曾用「截图模式强制 `.tabViewStyle(.tabBar)` / `TabBarTabViewStyle()`，测试用 `app.tabBars.buttons.element(boundBy:)` 索引定位」——在 iOS 26 SDK 下 `.tabBar` 与 `TabBarTabViewStyle` 已被整体移除（编译不过），且 `app.tabBars` 在 iPad 侧边栏仍为空，双重失效。
**注意**：别用 tab 的本地化文案（"Customize"/"定制"）做定位，否则 zh-Hans 跑测会失败。

## 坑 10：多语言轮询时部分设备/语言组合 0 张图（语言切换慢 + App 状态污染）
**现象**：`en-US` 在两台 iPhone 都出图，`zh-Hans` 只出一台；或某些设备在第二种语言下断言超时，报 `XCTAssertTrue failed - <tab> tab 未出现`。
**根因**：
1. 语言切换后的首次启动比普通冷启慢：系统要重新加载本地化缓存、可能触发首次启动的键盘/权限/setup 覆盖层，8 秒超时在 iPhone 16 / iPad 上容易翻车。
2. snapshot 默认不重新安装 App，上一语言的 `UserDefaults`、缓存、甚至是已加载的字符串缓存可能污染下一语言 run。
**解法**：
- UI 测试里把 `waitForExistence(timeout:)` 从 8 秒提到 **15 秒**（覆盖最慢模拟器，整体耗时不敏感）。
- Snapfile 加 `reinstall_app(true)`，确保每台设备 × 每种语言都是全新安装。
- 同时确认 App 的 `Localizable.xcstrings` 确实编入了目标语言，且 `project.pbxproj` 的 `knownRegions` 包含该语言（否则 `-AppleLanguages` 可能不生效）。
**验证**：重跑后应得到 `设备数 × 语言数 × 截图名数` 张图，每种语言目录下设备前缀齐全。

## 坑 11：iOS 26 SDK 移除 `TabViewStyle.tabBar` 与 `TabBarTabViewStyle`
**现象**：截图模式强制底部 tab bar 的代码编译报错，分两种：
- `type 'TabViewStyle' has no member 'tabBar'`（写了 `.tabViewStyle(.tabBar)`）
- `cannot find 'TabBarTabViewStyle' in scope`（写了 `.tabViewStyle(TabBarTabViewStyle())`）
典型于 Xcode 26 / iOS 26 系 SDK，构建日志会先打印 `falling back to SDK version '26.x'`。
**根因**：iOS 26 重做了 `TabView` 体系，**`TabViewStyle` 协议上的便捷静态成员 `.tabBar` 与具体类型 `TabBarTabViewStyle` 均被整体移除**（不是 deprecated，是直接不可见）。承载经典 `TabView { }.tabItem { }` 的样式强制通路已不存在——任何 `.tabViewStyle(TabBarTabViewStyle())` 写法都会编译失败。
**解法（不要再尝试强制 tab 样式）**：按坑 9 的推荐方案，改用 `TabView(selection:)` 绑定 + 启动参数预选，根本不依赖 tab 渲染形态：
- `ContentView` 用 `@State selectedTab` + `.tag(0/1)`，在 `init` 里读 `-FASTLANE_TAB` 启动参数预选；
- 测试第一次 `app.launch()` 截默认 tab，第二次 `app.launchArguments.append(["-FASTLANE_TAB","guide"])` 后 `app.launch()` 重启预选另一 tab。
此方案对 iPhone/iPad、底部栏/侧边栏、任意语言都稳定，且完全绕开已失效的 tab 样式 API。
**关联**：与坑 9 合并——坑 9 是「iPad sidebar 致 `app.tabBars` 查不到」，坑 11 是「强制 `.tabBar`/`TabBarTabViewStyle` 在 iOS 26 编译不过」；两者同属「截图模式处理 tab 定位」问题，统一用「选择绑定 + 启动参数预选」解决。

## 坑 12：widget 主屏截图——**SpringBoard 自动化已否决**，改 App 内预览或手动提供
**场景**：App 提供 iOS 桌面组件（widget）时，商店截图常需要 widget 图。fastlane 的 snapshot 只截 App 进程内画面，**截不到主屏 widget**。
**⚠️ 已否决路径（勿再尝试）**：UI 测试内 SpringBoard 自动化添加 widget 后截主屏——多次实测不可闭环：
- `springboard.icons.firstMatch` 在 iOS 18 模拟器 a11y 树返回空；
- App 图标可能不在当前主屏页（新装 App 排到第 2 页后），`descendants` 跨页元素 `exists` 可能 true 但 `isHittable` false，链路断裂；
- 长按主屏中央 (0.5,0.5) 是图标区，弹快捷菜单而非编辑模式，`AddWidgetButton` 找不到；
- `reinstall_app(true)` 每轮卸载重装会**移除已添加 widget**，每语言 run 都得重走一遍；
- 每一步都受 iOS 版本/语言/布局影响且**无法在沙箱环境验证** → 只能"改完让用户跑"，属瞎猜 + 重试，被用户否决。
**正确做法（二选一）**：
1. **App 内 widget 预览页（推荐自动化）**：App 内新增截图模式专用页面，复用 widget 同源渲染视图，`snapshot` 直接截 App 进程内画面（与 01/02/03 完全同路径，语言由 `-AppleLanguages` 注入）。这是唯一逻辑闭环的自动化方案。
2. **用户手动提供**：用户在模拟器/真机加好 widget 手动截图，注入引擎的预留 slide（`app-store-screenshots.json` 中 screenshot 留空的 widget 卖点页）。
**教训**：涉及 SpringBoard / 系统 UI 的自动化，若无法在本地验证每一环，先做闭环论证再落码，不要堆 if/guard 兜底让用户反复跑整轮 raw_screenshots（一轮 10+ 分钟，重试代价极高）。

## 坑 13：snapshot 默认每次 run 全量构建（重复 Copy/Link 的根源）
**现象**：日志里同一文件反复 `Copying Localizable.strings` / `Linking *.debug.dylib` + 正式二进制，用户以为有重复动作；且 2 设备 × 5 语言 = 10 次 run 每次都完整重编 6 个 target（iOS App + Watch App + 两个 Widget extension + SPM 包 + UI 测试），单轮 Build 段耗时 30s+。
**根因**：
1. **多 target × 多语言 × 双架构**：工程含 6 个 target，每个都要 copy 自己的 Localizable.strings（5 语言 → 95 次 CopyStringsFile 属正常）；watchOS 构建是 **universal 双架构**（arm64 + x86_64 各编一次再 lipo 合并，日志中 `Objects-normal/arm64` 与 `x86_64` 各 64 次）。这些是构建系统正常行为，不是 bug。
2. **Xcode 16+ Eager Linking**：每个 target 先链接 `.debug.dylib`（供预览/调试快速加载）再链接正式可执行文件——同一个 target `Linking X.debug.dylib` 与 `Linking X` 各一次，属设计如此。
3. **真正的性能问题**：fastlane snapshot **默认每次 run 创建全新临时 derived data**（`/var/folders/.../snapshot_derived*`），10 次 run = 10 次全量构建，毫无增量缓存。
**解法**：Snapfile 固定 derived data 路径，让第 1 次全量、后续增量：
```ruby
derived_data_path("./fastlane/DerivedData")
```
并在 `.gitignore` 追加 `fastlane/DerivedData`。注意：若跑前刚改过源码且依赖旧缓存，先删该目录再跑，避免陈旧产物。

## 坑 14：首屏按「今天」筛照片 ⇒ 截图当天没照片就是空屏，用例静默空转

App 首屏若按 `(月, 日)` 比对相册，而演示照片的 EXIF 日期是准备那天写死的，那么**过了那天第一格就是空的**。
症状不是报错，是超时：实测一个区在一个 AX 查询里从 `t=38.97s` 直接跳到 `t=792.60s`，日志零 error。

修：给 App 一个启动参数钉死首屏日期（如 `-DisplayDate 2026-10-23`），`displayDate` 优先读它。
截图只是静态展示，不需要日期与真实当天一致；真正使用 App 时会自然按当天过滤。

## 坑 15：最后一格进详情/信息态后 App 永不静默 ⇒ `snapshot()` 卡死在 wait-for-idle

`snapshot()` 内部会 `Wait for app to idle`。最后一格通常要停在「信息态」（带正文、地图、动效），
这类页面持续重绘，App 永不静默，用例就永远不返回。表现和"模拟器卡了"一模一样。

修：**分两次启动**——一次拍前 N-1 格，一次只拍最后一格。并且：

- 用例按**方法名字母序**执行，`testShot06…` 会排在 `testShotAllFive` 前面先把状态搞脏；
  最后一格要改名成排在后面的名字（如 `testShotLastPhotoDetail`）。
- 最后一格的断言失败后**不要解引用 frame**（`XCTFail` 已让元素无匹配，再读 `.frame` 会抛出并终止整条用例）；
  先 `waitForExistence` 判到位，再读几何，最后无论成败都拍一张并关掉详情。

## 坑 16：`.accessibilityElement(children: .combine)` 吞掉内层 identifier

给一段文字挂的 `accessibilityIdentifier`，如果它的祖先声明了 `children: .combine`，
会被合并进那个更大的元素里，查询 `app.staticTexts[...]` **恒为空**——元素存在，但不在你以为的层级。

修：identifier 挂在**合并后的那个元素**上，查询用 `app.descendants(matching: .any)`，不要限定 `staticTexts`。

## 坑 17：`.presentationSizing` 在某些运行时退化成一条 90pt 竖条

自定义 sizing（含 `.form.fitted`）在个别运行时不为 sheet 采纳 `proposedSize`，而按内容的理想尺寸量；
内容根若是竖向 `ScrollView`，理想宽就是最小值 ⇒ 面板变成一条窄竖条，看起来像"宽度没生效"。

修：**用系统默认 sizing**。要改宽度就去改内容自己的 `frame(maxWidth:)`，别在 sheet 上叠 sizing。
遇到"面板宽度改不动"，先 `git log -- <文件>` 看是不是已经有人踩过并回滚过。
