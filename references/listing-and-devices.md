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
      "name": "MYAPP-ASC-6.9", "simType": "…iPhone-16-Pro-Max", "runtime": "…iOS-18-0",
      "udidFile": "fastlane/.simulator-udid",
      "ascType": "IPHONE_67", "pixels": ["1320x2868"],
      "editorDevice": "iphone", "exportSize": "1320x2868",
      "shotsDir": "fastlane/screenshots", "beautifiedDir": "fastlane/screenshots-beautified",
      "seedDir": "~/asc-seeds/demo", "foldable": false
    },
    "iphone-duo": {
      "name": "MYAPP-ASC-DUO", "simType": "…iPhone-Duo", "runtime": "…iOS-27-1",
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

### `name` 必须带项目前缀

`simctl` 的设备名是**全机共用的命名空间**。两台不同项目都叫 `ASC-DUO` 时，
`init_simulator.sh` 按名字会命中别人的设备并 `erase` 它——别人的演示数据全没了。

前缀（`MYAPP-ASC-6.9`）是唯一的分家手段，不要省。同一台机器上实际会并存
`MYAPP-ASC-DUO`、`OTHER-ASC-DUO` 这类多项目设备，它们靠前缀区分。

### 设备只创建一次

`xcrun simctl create` 不查重。绑定靠 `name` + `udidFile` 两样，由
`scripts/init_simulator.sh` 保证：

| 层 | 判据 | 结果 |
|---|---|---|
| L1 | `udidFile` 里的 UDID 仍 `available` | 直接复用（主路径，跑多少轮都是同一台） |
| L2 | 按 `name` + `runtime` 精确命中 | 复用，把 UDID 写回文件 |
| L3 | 按 `name` 命中但 runtime 不符 | 复用，并提示 `--prune` 清旧档 |
| L4 | 都没有 | 新建一台，此后永远走 L1 |

细节、`--prune` 的删除范围、以及"同类型同 runtime 已有别的名字设备"的告警，见
`setup-guide.md` 的"设备只创建一次"一节。

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
