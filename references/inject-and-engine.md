# 注入与美化工程加设备

## 一、注入：四道门都在拷贝之前

```bash
python3 scripts/inject_screenshots.py \
  --scaffold app-store-screenshots \
  --src fastlane/screenshots-duo \
  --device iphone-duo \
  --slugs 01-on-this-day,02-journey-map,03-journey-home,04-memory,05-poster,06-photo-detail \
  --src-pattern "ASC-DUO-{slug}.png" \
  --expect-size 2007x2853 \
  --dry-run
```

四道门：**张数**（幻灯片数 = slug 数，每区都真拷到）、**尺寸**（`--expect-size`，抓错设备第一症状）、
**跨区一致**（同一格在各区的像素尺寸必须相同，防"一半内屏一半外屏"）、**覆盖保护**
（目标已存在且内容不同，必须 `--force` 才覆盖）。

手工 `cp` 的真实失败模式是"某区少一张"或"某张其实是上一轮旧图"，两者都不报错，
只在商店页上表现为少一格或图文不符。所以这四道门不能省。

**给 `--expect-size` 是硬要求**，不给就少了唯一能抓住"抓错设备"的那道门。

## 二、给美化工程加一台新设备：六处，一处都不能少

`resources/template/app-store-screenshots/` 的 device 是**类型收窄的联合体**，加一个设备要同时改六处，
漏一处就是 `tsc` 报错（这算好的）或运行时无声回落到默认设备（这算差的）。

| # | 文件 | 改什么 |
|---|---|---|
| 1 | `src/lib/types.ts` | `Device` 联合体加成员 |
| 2 | `src/lib/constants.ts` | `CANVAS`、`EXPORT_SIZES`、`DEVICE_LABEL` 三个 Record 都要加（少一个 `tsc` 直接报缺 key） |
| 3 | `src/lib/constants.ts` | 机身比例常量 + 宽度系数函数（见下） |
| 4 | `src/components/editor/device-frames.tsx` | 新设备外框组件 |
| 5 | `src/components/editor/slide-canvas.tsx` | `getFrameAspect` 与 `getFrameForDevice` 两个 switch |
| 6 | `src/components/editor/toolbar.tsx` | 设备下拉项；`src/lib/defaults.ts` 的 `slidesByDevice` 与 `detectPlatform` |

### ⛔ 不能把新尺寸塞进现有设备的 EXPORT_SIZES

Duo 的 2007×2853 是 1.42:1，iPhone 的 1320×2868 是 2.17:1。塞进同一个设备的导出尺寸列表里，
导出时会按同一套画布等比缩放 ⇒ **整体变形或加黑边**，而且编辑器里看不出来（画布是新的那个）。

判据很简单：**长宽比差超过 10% 就必须是独立 device 档**，不是同一 device 的第二个尺寸档。

### 机身材质：能画就别复用 PNG

现有 `mockup.png` 是 0.49 比例的直板机、带灵动岛。折叠内屏约 0.70，把它拉到 0.70 会把边框和灵动岛一起拉歪。
所以新设备用 CSS 画（外框渐变 + `inset` 描边 + 内层 `overflow: hidden` 收屏幕），
侧键放在 wrapper 上（它凸出机身，会被机身的 `overflow` 裁掉）。

### 宽度系数：由"标题底 ↔ 设备顶"的间隙反解

手机用的高度占比（0.72）在宽屏上会把设备顶推穿标题。做法不是猜一个更小的数，而是：

1. 先按 0.72 导出三张不同版式（hero / device-top / device-bottom）；
2. 逐张扫像素，量「最后一行文字底」到「设备顶」的间隙；
3. 系数调到每张都留出 ≥100px 的安全间隙为止。

实测 0.68 时三种版式最小间隙 135px；0.72 时 `device-bottom` 为负（重叠）。

```ts
export const DUO_RATIO = 2007 / 2853;
export function duoW(cW: number, cH: number, clamp = 0.78) {
  return Math.min(clamp, 0.68 * (cH / cW) * DUO_RATIO);
}
```

## 三、出图之后必须逐张查内容，不只查尺寸

尺寸对、张数对，仍然可能标题压到设备、或末页少了关闭按钮。用**像素扫描**代替肉眼看：

```python
# 对每张图：从"设备顶"往上找最后一行暗像素，得到文字底；间隙 = 设备顶 - 文字底
# 间隙 < 40px 判为重叠；分版式分别算（hero / device-bottom 从下往上，device-top 从上往下）
```

同一批图必须**全部**过，不能抽样：重叠只发生在某一版式上，抽样极容易正好错过。

## 四、常见误判

- **"编辑器里换了设备但图没变"**：`slidesByDevice` 里新设备是空数组或缺失 ⇒ 引擎会回落默认 starter，
  指向不存在的图。注入脚本的"幻灯片数 ≠ slug 数"就是拦这个的。
- **"导出的尺寸目录名不对"**：导出树根名随引擎版本是 `apple/` 或 `ios/`，
  整理脚本要按 `--size-dir` 反查目录，而不是硬编码根名。
- **"改了工程但导出还是旧图"**：`next dev` 有缓存，导出前重开一次页面。
