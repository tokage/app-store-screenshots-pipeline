# 清单与设备档案

两个文件，两个职责：`listing.json` 说"要出什么"（含每格的场景与文案），
`fastlane/device-profiles.json` 说"在哪台设备上出"。

`listing.json` 写在 App 项目根，纳入 git；它是抓图（fastlane）与美化（web 引擎）之间唯一的解耦点。
**两份配置都必须留在项目里，不要放进技能目录**——技能对所有项目通用，项目差异只能落在项目自己的文件里。

## 一、listing.json

```jsonc
{
  "schemaVersion": "1.0",
  "appName": "示例 App",
  "bundleId": "com.example.app",
  "platforms": ["ios"],
  "locales": ["en", "de", "es", "fr", "ja", "ko", "pt", "zh-Hans", "zh-Hant"],
  "devices": ["iphone", "iphone-duo"],

  "tagline": "…",
  "valueProposition": "…",
  "features": ["On this day", "Journeys", "Memories", "Posters"],

  "screenshotSpec": { "countPerDevice": 6, "perLocale": true },

  // 截图场景清单：拍什么、每格配什么文案。抓图前就必须定稿。
  "slides": [
    { "index": 1, "slug": "01-on-today",  "scene": "首页-当天",   "title": "…", "caption": "…" },
    { "index": 2, "slug": "02-journey",   "scene": "旅程-地图",   "title": "…", "caption": "…" }
  ],

  "sources": {
    "locales": "App/Resources/Localizable.xcstrings",
    "bundleId": "fastlane/Fastfile",
    "features": "docs/PRD.md"
  },
  "capturedBy": "fastlane@raw_screenshots",
  "generatedAt": "2026-10-25T18:00:00+08:00"
}
```

### 字段约定

- `sources` 不是装饰：每个字段都要能指回它被读出来的那个文件。用户问"这个语言区哪来的"时，
  答案必须是一个路径，不是"我推断的"。
- `locales` 一律从本地化资源派生（`.xcstrings` 的 `localizations`，或 pbxproj 的 `knownRegions`），
  **不要凭经验写 `en-US`**：`en-US` 是 ASC 码，工程内部码是 `en`，两者在这一步就要分清，
  混用到上传那步才会炸（见 `publish-asc.md`）。
- `devices` 用引擎的 device 键（`iphone` / `iphone-duo` / `ipad` / `watch-45mm` / `android`），
  不是营销名。它表示**本轮要出的设备**，不是支持的全部设备。
- `slides[].slug` 是文件名的中段（`<前缀>-01-on-today.png`），必须与
  `inject_screenshots.py --slugs` 一字不差，否则注入时静默少格。
- `slides[].title` / `caption` 是美化稿上真正显示的文案，**不是内部说明**。
  这一层必须在抓图前定稿：图按 slug 走、文案按 index 走，两边不一致时，
  直到上传完在商店页上才会被发现。

### 抓图前必须做的一步：对照线上现状

先看 App Store 上现在是什么，再决定这轮拍什么。不然很容易拍完才发现线上本来就有 6 张、
只是有一张想换，结果整批重传。

```bash
# 全区概览：哪些槽、每槽几张、有没有卡在 FAILED
asc screenshots list --app "$APP_ID" --version "$VERSION" --output table

# 单区细看（推荐：一次只处理一个区）
asc screenshots list --app "$APP_ID" --version "$VERSION" --locale zh-Hans --output table
```

输出是 `Set ID / Display Type / Screenshot ID / File Name / File Size / State`。
要拿 JSON（做逐张校验）就去掉 `--output table`。

对照之后才写 `slides`：每格对应哪个场景、文案是谁，写进 `listing.json` 再开拍。

## 二、fastlane/device-profiles.json（设备身份唯一出口）

从 `resources/device-profiles.example.json` 拷一份到项目里再改值：

```bash
mkdir -p fastlane && cp resources/device-profiles.example.json fastlane/device-profiles.json
```

字段形状：

```json
{
  "default": "iphone-69",
  "profiles": {
    "iphone-69": {
      "name": "ASC-6.9", "simType": "…iPhone-16-Pro-Max", "runtime": "…iOS-18-0",
      "udidFile": "fastlane/.simulator-udid",
      "ascType": "IPHONE_67", "pixels": ["1320x2868"],
      "editorDevice": "iphone", "exportSize": "1320x2868",
      "shotsDir": "fastlane/screenshots", "beautifiedDir": "fastlane/screenshots-beautified",
      "seedDir": "~/asc-seeds/demo", "foldable": false
    },
    "iphone-duo": {
      "name": "ASC-DUO", "simType": "…iPhone-Duo", "runtime": "…iOS-27-1",
      "udidFile": "fastlane/.simulator-udid-duo",
      "ascType": "IPHONE_DUO", "pixels": ["2007x2853", "2853x2007"],
      "editorDevice": "iphone-duo", "exportSize": "2007x2853",
      "shotsDir": "fastlane/screenshots-duo", "beautifiedDir": "fastlane/screenshots-beautified-duo",
      "seedDir": "~/asc-seeds/duo", "foldable": true
    }
  }
}
```

`seedDir` 可以写 `~`，`device_profile.sh` 取值时会展开成 `$HOME`，所以档案文件本身不必
写任何机器专属的绝对路径。`foldable` 会被序列化成 `1` / `0`，下游一律
`[ "$DEV_FOLDABLE" = "1" ]` 判断。

取值一律走脚本，不要手抄：

```bash
bash scripts/device_profile.sh --list
bash scripts/device_profile.sh --get ascType iphone-duo
eval "$(bash scripts/device_profile.sh --export iphone-duo)"   # 得到 DEV_* 变量
```

### 为什么必须是唯一出口

一台设备不只是"一个名字"。它同时决定：模拟器类型、runtime、ASC 显示槽、允许像素、抓图目录、
种子库目录、美化工程 device 键、导出尺寸目录、是否折叠。这九个值原先分散在
`init_simulator` / `shoot_one` / `use_store` / `Snapfile` / `Fastfile` / 上传脚本里各写一遍，
加第二台设备时必然漏改一处。

**漏改的表现不是报错，是静默抓错设备**，或静默抓到外屏尺寸（1398×2034 而不是内屏 2007×2853），
要等到商店页上才发现。

### `name` 只是标签，查重按规格

一台设备的物理规格只有两个维度：`simType`（机型）与 `runtime`（系统版本）。
`name` 是给人看的显示标签，`simctl` 允许同规格存在任意多台不同名字的设备。

所以 **不要按名字查重**。按名字查重的直接后果是「每个项目一套」：10 个项目 ×
2 档机型 = 20 台同规格设备，每台 1–3 GB，`CoreSimulator` 会越跑越慢。

按规格查重则是「全机每种规格一台」，多个项目共用，**项目数增加不产生新设备**。
冲突不在名字上，在**同一时刻只能有一个使用者**上——模拟器的 AX 会话同时只能被
一个 UI 测试接管，两个项目并行争同一台会有一个卡死。

什么时候才需要加项目前缀：**要长期独享时**。比如两个项目必须用不同 iOS 版本、
或种子库不能互相覆盖，那就得两台不同规格/不同名字的设备，前缀用来分辨归属。
名字里带上 app 标识（`MYAPP-ASC-DUO`）比 `ASC-DUO` 更容易在 `--prune` 时判断归属。

### 共享一台设备的四个真实代价

| 代价 | 机制 | 表现 |
|---|---|---|
| 数据串味 | 相册、SwiftData 容器都是设备级的 | A 写进相册的种子照片出现在 B 的截图里，**张数尺寸全对，收货门查不出来** |
| `erase` 互踩 | `simctl erase` 抹整个设备容器 | A 正在跑抓图，B 的脚本 erase → A 的 app 容器消失、测试崩在随机位置 |
| 不能并行 | AX 会话是设备级独占 | 两个 XCUITest 同时跑，一个必然超时 |
| 不可复现 | 首次启动标记、TCC 授权、状态栏覆盖都是设备级 | 同一份代码两次跑出不同结果，且找不到原因 |

**不冲突的三件事**：语言与区域（走 launchArguments `-AppleLanguages`，不是设备级）、
相册权限（`privacy grant` 按 bundle id 各授一份）、App 数据本身（`erase` 就是干净的起点）。

所以共享的成立条件是：**串行 + 每次 erase + 重铺种子库**。前两条脚本负责
（`init_simulator.sh` 默认 erase，`duo_pose.sh` 摆姿态前也要求干净设备），
第三条是调用方的事。要并行就 `xcrun simctl clone` 克隆一台、跑完即删，
不要长期建独立设备。

### 设备只创建一次

`xcrun simctl create` 不查重。绑定靠 `udidFile` + 规格查重，由
`scripts/init_simulator.sh` 保证：

| 层 | 判据 | 结果 |
|---|---|---|
| L1 | `udidFile` 里的 UDID 仍 `available` | 直接复用（主路径，跑多少轮都是同一台） |
| L2 | 同 `simType` + 同 `runtime`（同名优先） | 复用，把 UDID 写回文件 |
| L3 | 同 `simType` + 同主版本 runtime（`iOS-18-0` vs `18-1`） | 复用，提示改档案的 runtime |
| L4 | 同 `simType` 但大版本不符，或完全没有 | 建一台，旧档交给 `--prune` |

**接管保护**：L2/L3 命中的若是**别人名字**的设备且当前 `Booted`，脚本 `exit 3`
拒绝接管——它可能正被另一个项目跑着。确认要接管加 `--take-over`。

`--prune` 只删**精确属于本档案**的：同名重复档（含 runtime 换代留下的旧档）与
`<name> Clone N` / `Clone N of <name>` 克隆体。**判据必须是精确匹配不能是子串**
——档案叫 `ASC-DUO` 时，`VR-ASC-DUO` 与 `ODM-ASC-DUO` 都包含这个子串，按子串删
就是删别人的设备。同规格但名字不同的设备只报不删，列在"属其他项目，本脚本不碰"下。

细节见 `setup-guide.md` 的"设备只创建一次"一节。

### 多设备的四条硬约定

1. **产物目录按设备分家**（`shotsDir` / `beautifiedDir`），两台设备共用目录 = 互相覆盖 + 收货门比错像素。
2. **种子库按设备分家**（`seedDir`），store 里存的是 PHAsset 的 `localIdentifier`，跨设备必然失效。
3. **管线按设备分家**：设备 A 的脚本不许出现设备 B 的字节。加设备时新建 profile，不要给旧脚本加 `if`。
4. **每轮只跑一台**。两台并行跑同一份 seed/DerivedData 会互相抢锁，排查成本远高于串行等。

## 三、目录约定

抓图产物（git 忽略）：

```
fastlane/screenshots/<locale>/<device>-<NN>.png
```

注入美化工程后（派生，git 忽略）：

```
app-store-screenshots/public/screenshots/<platform>/<device>/<locale>/<NN>.png
```

`<NN>` 是补零序号。引擎读第二处；第一处是像素的唯一来源。
美化从不依赖截图是怎么产生的——换抓图工具不需要改引擎，反之亦然。
