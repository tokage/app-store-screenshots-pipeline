# 折叠设备与一次启动多格

这一份只讲两件在普通手机上不会遇到的事：**折叠设备的姿态**，以及**把多格压进一次启动**。

## 一、折叠设备：姿态必须自动化，且旋转后要等画面

折叠屏模拟器每次重启都回到外屏（折叠态），而 ASC 的 `IPHONE_DUO` 槽只认**内屏展开态**。
不摆姿态的后果是：脚本一切正常，图的尺寸却是外屏 1398×2034，收货门报尺寸不符。

### 工具

`simctl` / `devicectl` / `XCUIDevice.shared.orientation` **都报成功但不生效**。可用的是厂商自定义 HID：

```bash
brew install skarol/tap/duoctl
# duoctl 通过 simctl spawn 起 helper，发 usage page 0xFF61 / 0x5B 的铰链滑块事件（0–180°），
# 由 locationd 折算成铰链角度。
```

### 顺序（顺序错了就是白等）

```bash
duoctl open                       # 展开内屏
sleep "$POSE_SETTLE"              # 等 4s；state 先于画面就报新姿态
duoctl rotate portrait            # 内屏转竖
sleep "$POSE_SETTLE"              # 再等；⛔ 不要在 rotate 后立刻判定
duoctl state                      # 校验 inner + portrait，不满足最多重试三轮
# 兜底判据：拍一张探针图，比像素是否落在 profile 的 pixels 集合里
```

**⛔ 最常见的坑**：`state` 已经报 `inner + portrait`，画面还在旧姿态上。判定必须以**图像像素**为准，
不以 `state` 为准。

### 半折（有折痕）时的布局约束

折痕落在内容里就会把一张卡片切成两半。列表类布局要满足：

- 折痕激活时列数取**偶数**（`n - (n % 2)`），让分界落在列间；
- 判据取"折痕是否激活"（`isActive`），**不要拿屏宽当门**——同一块宽屏在展开与半折下宽度可能相同；
- 只有一列时不做偶数化（两列会比目标宽度还窄，此时折痕只能落在内容内）。

## 二、一次启动多格：省掉 N 份启动开销

### 能压就压

区级整批（一次 `xcodebuild` 跑完该区全部格）已是标配；格级也能压：前 N-1 格在同一用例里顺序拍完，
避免每格一次冷启（实测一个区从 6 次启动压到 2 次，单区省 2–3 分钟）。

### 但有一格必须单独启动

最后一格若停在「信息态」（正文 + 地图 + 动效），App 会持续重绘、永不静默，`snapshot()` 内部的
`Wait for app to idle` 会永久挂住——和"模拟器卡死"长得一模一样。详见 `gotchas-deadlock.md` 坑 15。

拆分原则：

```swift
// 一次启动拍前五格，中间任何一格失败都不中断，保证能收回尽可能多的图
func testShotAllFive() { continueAfterFailure = true; … }

// 最后一格独立启动；名字要排在字母序**之后**（testShot06 会先跑并把状态搞脏）
func testShotLastPhotoDetail() { continueAfterFailure = false; … }
```

- 用例按**方法名字母序**执行，不是书写顺序。
- 最后一格无论断言成败都要拍一张再关详情；断言失败后不要读 `.frame`（元素已无匹配，会抛异常终止整条用例）。

### 首屏日期要钉死

按"今天"筛照片的 App，演示照片的 EXIF 日期是准备那天写死的，**过了那天第一格就是空的**。
症状是超时而不是报错（一次实测在一个 AX 查询里从 38.97s 直接跳到 792.60s，日志零 error）。

```swift
// 启动参数钉死首屏日期；截图不需要"真的是今天"
private static let pinnedDisplayDate: Date? = {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "-ODMDisplayDate"), i + 1 < args.count else { return nil }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
    return f.date(from: args[i + 1])
}()
var displayDate: Date = Self.pinnedDisplayDate ?? Date()
```

抓图脚本每区都要把这个值写进 ephemeral 的 `display-date.txt`，和 `language.txt` 一样是运行期输入。

## 三、区级批量：一门一区

```bash
for loc in $LOCALES; do
  terminate_app                                  # 先把残留进程收掉，否则上一区状态污染下一区
  use_store    "$loc"   || { echo "✗ $loc 种子库"; exit 1; }
  shoot_locale "$loc"   || { echo "✗ $loc 出图";   exit 1; }
  verify_shots --root "$SHOTS" --locales "$loc" || { echo "✗ $loc 收货门"; exit 1; }
done
```

无门链式（`for l in …; do shoot $l; done`）会把一次失败放大成 N 次排查——
这也是"跑了九区只收到三区图"的唯一成因。

### 长批次的后台收口

后台跑时 `xcodebuild` 可能卡在 AX 会话上不退出，批次永远不结束。给每区设**墙钟上限**，
超时先 `SIGTERM`，15s 后补 `SIGKILL`；并且**只在收到足够张数后才允许宽限**，否则宽限会把失败拖成静默通过。

### 别在运行中改脚本

正在跑的批次读的是启动那一刻的脚本。中途编辑会得到 `syntax error`，而产物已经被拷走一半——
比"跑失败"更难收拾。要改就先停批次。
