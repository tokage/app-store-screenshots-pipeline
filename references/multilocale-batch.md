# 多语言批量出图：门禁、锚点与无视觉验收

一次真实事故的沉淀：9 语言 × 6 格 = 54 张图，从下午做到第二天下午，**其中大部分时间不是花在截图上，而是花在四个可预防的错误上**。本文按「下次遇到同样场景该怎么做」组织，不按事故时间线。

---

## 0 一句话总纲

> **一个语言区 = 一个事务。要么 6 格全绿进下一区，要么停在原地修。**
> 任何「跑失败了就继续跑下一个」的批处理，都会把一次失败放大成 N 次排查。

---

## 1 批处理：按区整批，但每区必须有门

### 1.1 为什么按区整批，不按帧逐格

每次 `xcodebuild test` 有固定启动开销（编译检查、安装 runner、启动模拟器、权限门）。**6 格分 6 次调用 ≈ 6 份开销**；一次调用跑 6 条用例只付一份。

```bash
# ✅ 一次 xcodebuild 跑完一个语言区的全部帧，再统一收货
xcodebuild test \
  -scheme OneDayMemory \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath fastlane/build \
  -only-testing:OneDayMemoryUITests/ASCShotTests/testShot01OnThisDay \
  -only-testing:OneDayMemoryUITests/ASCShotTests/testShot02JourneyMap \
  -only-testing:OneDayMemoryUITests/ASCShotTests/testShot03JourneyHome \
  -only-testing:OneDayMemoryUITests/ASCShotTests/testShot04Memory \
  -only-testing:OneDayMemoryUITests/ASCShotTests/testShot05Poster \
  -only-testing:OneDayMemoryUITests/ASCShotTests/testShot06PhotoDetail
```

### 1.2 但绝不允许无门链式循环

```bash
# ❌ 事故写法：de 区 02/03/05 全失败，循环照样继续跑 es/fr/ja...
for l in de es fr ja ko; do
  use_store.sh $l
  shoot_locale.sh $l
done

# ✅ 每区一门：失败即停，本区修好再进下一区
for l in de es fr ja ko; do
  use_store.sh "$l" || exit 1
  shoot_locale.sh "$l" || { echo "❌ $l 出图失败，停在此处，不进入下一区"; exit 1; }
  verify_locale.py "$l" || { echo "❌ $l 体检不合格，停"; exit 1; }
done
```

**「门」= 三件事同时成立**，缺一不可：

| 判据 | 检查方式 | 不合格意味着 |
|---|---|---|
| 用例真的跑了并通过 | 日志里该 locale 的 `** TEST SUCCEEDED **`，且 6 条 `Test Case ... passed` | 有断言失败被 `tail` 截掉 |
| 文件数对得上 | `ls fastlane/screenshots/$l/*.png \| wc -l` == 帧数 | 静默跳过（见 §2.3） |
| 文件是新的 | mtime 晚于本次开跑时间 | 拍到了上一轮的残留 |

**每一区跑完立刻体检，不要等 9 区跑完再查**。等 9 区跑完才发现 de 缺 3 张，那 3 张的成本已经乘了 9。

### 1.3 后台跑长批次时的收口

多区串行跑（一区 3–5 分钟）必须用后台任务，但**后台任务失败不会自动停下**。要求：

- 每个区把关键行同时写进 `fastlane/logs/<locale>.log`，而不是只回显在 `tail -8` 里。
- 批次结束**必须逐区 grep 断言**，不能只看最后一行 exit code（`| tail -8` 会把 `** TEST FAILED **` 之后的报错整段吞掉）。
- 事故实例：后台批次报 `failed`，但日/韩/葡三区其实 6/6 全出，失败的是收尾的钥匙串写入 —— 如果只看状态就重跑，会白烧一轮。

```bash
# 收口：逐区判定，而不是看批次状态
for l in de es fr ja ko pt zh-Hans zh-Hant; do
  n=$(ls fastlane/screenshots/$l/*.png 2>/dev/null | wc -l | tr -d ' ')
  printf "%-9s %s/6\n" "$l" "$n"
done
```

---

## 2 锚点：本地化文案不能当锚点

### 2.1 事故

用例里用 `journeyName = "Highlands, Early Summer"` 匹配旅程卡片。种子库是**逐区各造一份**的，所以德语区里它叫 `Highlands, Frühsommer`、日语区 `ハイランド、初夏`、中文区 `高地，初夏`。结果德语区 **02/03/05 三格直接断言失败**，而 01/04/06 通过 —— 看起来像"随机失败"，实际是最稳定的失败。

### 2.2 铁律

> **任何跨语言复用的 UI 锚点，都不能是用户可见文案。**

按可靠性排序：

| 优先级 | 锚点类型 | 说明 |
|---|---|---|
| 1 | `accessibilityIdentifier` | 唯一正解。与语言、SF Symbol 名、数据内容都无关 |
| 2 | 结构特征（`app.images.firstMatch`、`cell` 下标、`element(boundBy:)`） | 可用，但对界面结构调整脆弱 |
| 3 | 多语言谓词集合 | 退路。仅在无法加 identifier 时使用 |

```swift
// ✅ 退路写法：九语任一命中
private let journeyNames = [
    "Highlands, Early Summer", "Highlands, Frühsommer", "Highlands, début d'été",
    "Highlands, primavera", "ハイランド、初夏", "하이랜드, 초여름",
    "Highlands, início do verão", "高地，初夏",
]
private var journeyPredicate: NSPredicate {
    NSCompoundPredicate(orPredicateWithSubpredicates:
        journeyNames.map { NSPredicate(format: "label CONTAINS[c] %@", $0) })
}
```

### 2.3 静默跳过：最贵的一种"通过"

```swift
// ❌ 出事写法：等不到就算了，测试照样绿
_ = memoryBody.waitForExistence(timeout: 8)
snapshot("06-photo-detail")

// ✅ 等不到就失败，把问题暴露在这一区
XCTAssertTrue(memoryBody.waitForExistence(timeout: 8),
              "记忆正文未出现——遮罩/面板/语言任一环节有问题")
```

同一文件里出现 `_ = ...waitForExistence(...)` 就是**缺陷信号**，一律改成 `XCTAssertTrue`。快照函数本身不该无条件执行。

---

## 3 点不到：先读码，再决定点哪里

### 3.1 事故

按界面观感估算坐标去点（例如"右上角第三个图标"），`tap()` 返回成功但**什么都没发生** —— XCUITest 的坐标点击不校验命中，落在空白处也是成功。后续断言失败时，现象是"界面没变"，很容易被误判成"功能坏了"。

### 3.2 铁律

> **写点击之前，先在源码里找到那个控件的 `accessibilityIdentifier` 或它所在的 View 结构；找不到就不许写坐标。**

排查顺序：

1. `grep -rn "accessibilityIdentifier" <ViewName>` —— 有就直接用（最稳）。
2. 没有 identifier 时，找控件的 `Label`/`Image` 的 SF Symbol 名，用 `app.buttons["<label>"]`（注意 SF Symbol 名**不会**进入 a11y，只有 `Label("文字", systemImage:)` 的文字会）。
3. 都没有，才用结构定位：`app.buttons.matching(identifier:)`、`app.cells.element(boundBy:)`。
4. 坐标是最后手段，且必须**紧跟一条断言证明落点正确**：

```swift
// 坐标只能作为"手势路径"，不能作为"控件定位"
let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
start.press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)),
           withVelocity: .slow, thenHoldForDuration: 0.3)
XCTAssertTrue(memoryBody.waitForExistence(timeout: 8))   // 证明手势真的生效了
```

### 3.3 相关坑：元素存在但不可点

`exists == true` 而 `isHittable == false` 的常见原因，按出现频率排：

1. 系统权限弹窗盖在上面（SpringBoard 窗口，不归 App 管）。
2. 一个 Button 套 Button，或叠了 `.onLongPressGesture(minimumDuration: .infinity)` 抢走触摸序列。
3. 目标在 `ScrollView` 之外的可视区（`ScrollView` 会吞掉下层的 tap）。

判断方式：`element.isHittable` 单独断言一次，别把它和 `exists` 混在一起查。

---

## 4 改动是否真的生效：必须是二进制判据

### 4.1 事故（本次最贵的一个）

改了 App 源码 → 直接跑出图脚本 → 截图与改前**逐像素相同** → 判定"修复无效"，于是换方向重做。真相是：出图脚本只跑 UI 用例，**不构建 App**，拍的是模拟器上**已安装的旧包**。两次误判，白烧数小时。

### 4.2 铁律

> **出图脚本 ≠ 构建脚本。改 App 源码后必须显式重装，并用可核对的证据确认。**

```bash
fastlane install_and_grant config:Release    # 构建 + 安装（唯一正确前置）
bash fastlane/scripts/use_store.sh "$L"      # 换该区种子库
bash fastlane/scripts/shoot_locale.sh "$L"   # 出图
```

**两条证据缺一不可**：

| 证据 | 命令 | 合格标准 |
|---|---|---|
| 产物二进制是新的 | `ls -la fastlane/build/Build/Products/Release-iphonesimulator/<App>.app/<App>` | mtime 晚于改码时间 |
| 该文件真的被编译 | `grep -c "Compiling <File>.swift" "$TMPDIR"/asc-*.log` | ≥ 1 |

### 4.3 像素 diff 的正确用法

改动确实进了二进制时，**逐像素 diff 是判定"改到了哪片区域"的最强证据**：

```python
d = np.abs(a.astype(np.int16) - b.astype(np.int16)).sum(axis=2)
print("差异像素:", int((d > 8).sum()))
ys, xs = np.where(d > 8)
print("差异区域 y[%d,%d] x[%d,%d]" % (ys.min(), ys.max(), xs.min(), xs.max()))
```

- `差异像素 == 0` ⇒ 要么没进二进制（查 §4.2），要么改的代码在当前界面**根本没被执行**（查调用链）。
- 差异只落在预期区域 ⇒ 修复精准，无夹带。
- 差异落在意外区域 ⇒ 副作用，必须解释清楚再继续。

---

## 5 无视觉能力时怎么"看"图

模型读不到 PNG 像素（`Read` 返回不支持图像）时，**不要试图用全局启发式去"看图"**。

### 5.1 事故

用「饱和度 > 阈值」「非黑连通域」去分割照片区域，结果把照片自身的色带切成好几块、把文字卡片并进照片，反复得出互相矛盾的结论（"有第二个矩形" / "只有一个 blob"），每一轮都要重新解释一次。

### 5.2 正确姿势：先由代码推出应然几何，再做定向带测量

```
① 从代码算出「应当成立」的数字
   容器 440×361pt；照片 600×400（3:2）；scaledToFit ⇒ 440×293
   ⇒ 照片应占 y ∈ [top, top+293]，两侧各 0 留白
② 只测那条该空/该满的带
   取 y ∈ [照片上沿-20, 照片上沿) 与 x ∈ [内容区左右边界]，统计非白占比
③ 给出单一数字判据
   「下沿带非白占比应为 0.0%」——不解释、不猜、不画 ASCII 图
```

一条可复现的数字断言，胜过十张 ASCII 示意图：

```python
# 判据：照片下沿之下那条带必须是纯白（双绘会在这里露出方形副本）
band = (lum < 250)[1170:1268, 118:1202]
print("下沿残留 %.1f%%" % (band.mean() * 100))   # 期望 0.0
```

需要人工确认观感的内容（构图、文案、配色），**交给用户看**，不要用像素统计去替代审美判断。

---

## 6 根因定位：形状就是指纹

### 6.1 事故

"同一张照片出现两次"。先怀疑转场动画、再怀疑 chrome 层、再怀疑 overlay，逐个排除，花掉一整天。真相是渐进加载的第二层（低清图）**在最终图到达后从不卸载**，而低清图取自缩略图缓存，是 **350×350 正方形**。

### 6.2 方法

**先量 artifact 的比例，再去反推哪段代码会产出这个比例。**

| 观测量 | 反推 |
|---|---|
| 边长 361pt 的正方形，居中在 440 宽容器里 | `min(440, 361) = 361` ⇒ 一张 1:1 的图被 `scaledToFit` 进 440×361 |
| x 起点 39.5pt | `(440 − 361) / 2` ⇒ 水平居中，印证 1:1 |
| 全 App 里唯一产出 1:1 的图片来源 | 缩略图缓存请求（`350×350` + `.aspectFill` + `resizeMode .exact`） |

比"猜交互机制 → 逐个排除"快一个数量级。**比例 + 位置 + 全仓 grep 该比例的生产者**，三件套定位。

### 6.3 改码前先看它是不是"已修过"

```bash
git log --oneline -10 -- <可疑文件>
git log --oneline --all --grep="重复\|重影\|双绘\|duplicate"
```

用户说"这个问题以前解决过，又出现了"时，**先找那次修复**，读它改了什么、为什么现在失效。自创第二套修法 = 让代码里同时存在两套互相不认识的约定。

---

## 7 演示数据（种子库）不可重跑

### 7.1 事故

`fastlane seed` 中途失败后想"重跑一次就好了"，但 `photos-prepared/` 素材目录已被清空，重跑直接报缺 `manifest.json`；而一旦去补素材，`prepare_photos.py` 会**重新导入照片**，`simctl addmedia` 会重新分配 `localIdentifier`，种子里写的照片 id 全部失效 —— 整段旅程的照片全变空白。

### 7.2 铁律

> **`prepare`（导入照片）与 `seed`（造 store）只做一次。产物要归档，不是现场重造。**

- 九语种子库归档在仓库外（如 `~/asc-seeds/<locale>/ASCDemo.store*`），换库用 `simctl` 直接替换容器内文件，**比跑 fastlane lane 快一个量级**。
- 归档前先 `md5` 确认九区**互不相同**（每个区一份本地化文案）。九区 md5 全同 = 你其实只造了一份。
- 重跑 `seed` 前先确认 `fastlane/photos-prepared/<set>/manifest.json` 存在；不存在就别跑，去用归档。

```bash
# 换库（免 fastlane 开销）
C=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
D="$C/Library/Application Support"
rm -f "$D"/default.store*                    # 先清 -wal / -shm，残留的旧库会把内容盖回去
for f in ~/asc-seeds/"$L"/ASCDemo.store*; do
  cp "$f" "$D/default.store${f##*ASCDemo.store}"   # 后缀原样带过去：'' / -wal / -shm
done
```

注意末尾那行不是一次 `cp 通配 目标文件`：SQLite 的 `-wal` / `-shm` 必须与主库成对替换，
把三个文件拷成同一个文件名只会报错。

### 7.3 语言注入：直调 xcodebuild 时必须自己写

`fastlane snapshot` 的语言轮询是靠写两个缓存文件实现的；绕过 fastlane 直调 `xcodebuild` 时**不会自动发生**：

```bash
echo "$LANG_CODE"   > ~/Library/Caches/tools.fastlane/language.txt
echo "$LOCALE_CODE" > ~/Library/Caches/tools.fastlane/locale.txt
```

不写这两个文件 ⇒ 9 个语言区拍出来全是同一种语言，而且**不会报错**。判据：九区同帧的 `md5` 必须各不相同（§1.2 的第三道门）。

---

## 8 收口清单

出图全部完成后，逐项核对，**任一项不过不许进入美化/上传**：

- [ ] 9 区 × 帧数，文件数齐全（`ls | wc -l`）
- [ ] 每张尺寸 = 目标槽位（`sips -g pixelWidth -g pixelHeight`，6.9" = 1320×2868）
- [ ] 同一帧跨 9 区的 `md5` 各不相同（证明本地化真的生效）
- [ ] 截图里无付费墙、加载态、空态、调试悬浮球
- [ ] 状态栏固定（9:41 / 满格 / 满电）
- [ ] 废弃帧归档而不是删除（`screenshots/_obsolete/`）
- [ ] 单一语言目录口径（`en/` 与 `en-US/` 并存会导致后续上传取错图）
