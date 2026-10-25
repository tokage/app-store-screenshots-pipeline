# 清单与设备档案

两个文件，两个职责：`listing.json` 说"要出什么"，`fastlane/device-profiles.json` 说"在哪台设备上出"。

## listing.json（应用级，git 跟踪）

```json
{
  "appName": "OneDay Memory",
  "bundleId": "com.3523128.OneDayMemory",
  "platforms": ["ios"],
  "locales": ["en", "de", "es", "fr", "ja", "ko", "pt", "zh-Hans", "zh-Hant"],
  "devices": ["iphone", "iphone-duo"],
  "tagline": "…",
  "valueProposition": "…",
  "features": ["On this day", "Journeys", "Memories", "Posters"],
  "screenshotSpec": { "countPerDevice": 6 },
  "sources": {
    "locales": "OneDayMemory/Localizable.xcstrings",
    "bundleId": "fastlane/Fastfile",
    "features": "docs/PRD.md"
  }
}
```

- `sources` 不是装饰：每个字段都要能指回它被读出来的那个文件。用户问"这个语言区哪来的"时，答案必须是一个路径，不是"我推断的"。
- `locales` 一律从本地化资源派生（`.xcstrings` 的 `localizations`，或 pbxproj 的 `knownRegions`），**不要凭经验写 `en-US`**：`en-US` 是 ASC 码，工程内部码是 `en`，两者在这一步就要分清，混用到上传那步才会炸（见 `publish-asc.md`）。
- `devices` 是**本轮要出的设备**，不是支持的全部设备。出第二台就多一条，不复用第一台的管线。

## fastlane/device-profiles.json（设备身份唯一出口）

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
      "name": "ASC-6.9", "simType": "...iPhone-16-Pro-Max", "runtime": "...iOS-18-0",
      "udidFile": "fastlane/.simulator-udid",
      "ascType": "IPHONE_67", "pixels": ["1320x2868"],
      "editorDevice": "iphone", "exportSize": "1320x2868",
      "shotsDir": "fastlane/screenshots", "beautifiedDir": "fastlane/screenshots-beautified",
      "seedDir": "~/asc-seeds/demo", "foldable": false
    },
    "iphone-duo": {
      "name": "ASC-DUO", "simType": "...iPhone-Duo", "runtime": "...iOS-27-1",
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
写任何机器专属的绝对路径。

取值一律走脚本，不要手抄：

```bash
bash scripts/device_profile.sh --list
bash scripts/device_profile.sh --get ascType iphone-duo
eval "$(bash scripts/device_profile.sh --export iphone-duo)"   # 得到 DEV_* 变量
```

### 为什么必须是唯一出口

一台设备不只是"一个名字"。它同时决定：模拟器类型、runtime、ASC 显示槽、允许像素、抓图目录、种子库目录、
美化工程 device 键、导出尺寸目录、是否折叠。这九个值原先分散在 `init_simulator` / `shoot_one` / `use_store` /
`Snapfile` / `Fastfile` / 上传脚本里各写一遍，加第二台设备时必然漏改一处。

**漏改的表现不是报错，是静默抓错设备**，或静默抓到外屏尺寸（1398×2034 而不是内屏 2007×2853），
要等到商店页上才发现。

### 多设备的四条硬约定

1. **产物目录按设备分家**（`shotsDir` / `beautifiedDir`），两台设备共用目录 = 互相覆盖 + 收货门比错像素。
2. **种子库按设备分家**（`seedDir`），store 里存的是 PHAsset 的 `localIdentifier`，跨设备必然失效。
3. **管线按设备分家**：设备 A 的脚本不许出现设备 B 的字节。加设备时新建 profile，不要给旧脚本加 `if`。
4. **每轮只跑一台**。两台并行跑同一份 seed/DerivedData 会互相抢锁，排查成本远高于串行等。
