# 发布到 App Store Connect

两件独立的推送：**截图**和**文案**。两件都是**版本作用域**的，推错版本不会报错，只是商店页没变。

## 一、截图

### 槽位与尺寸（写错就是"商店页还是旧图"）

| 设备 | ASC 显示类型 | 像素 | 备注 |
|---|---|---|---|
| iPhone 6.9" | `IPHONE_67` | 1320×2868 | 常规 iPhone 套 |
| iPhone Duo（内屏展开） | `IPHONE_DUO` | 2007×2853（或横 2853×2007） | **独立槽，不替代**常规 iPhone 套 |
| iPad Pro 13" | `IPAD_PRO_3GEN_129` | 2064×2752 | |

把 6.9" 的图写进 `IPHONE_65` 会让真机商店页继续显示旧套装——这是真实事故，不是假设。

### 三步

```bash
# 1. 整理 + 逐区像素门 + 逐区 asc validate
bash scripts/stage_beautified.sh <导出目录> \
  --asc-type IPHONE_67 --size-dir 1320x2868 --per-locale 6 \
  --app-id "$APP" --version "$VER"

# 2. 干跑：只看会删什么、会加什么
bash scripts/stage_beautified.sh … --upload

# 3. 真跑（--replace 只作用于 --device-type 指定的那一个槽）
bash scripts/stage_beautified.sh … --upload --confirm
```

`--replace` 的执行顺序是**先删后传**，所以永远先 `--dry-run` 看删除清单。
它也只删指定 `--device-type` 的槽，因此"只补 Duo"是完全安全的操作。

### 验收

```bash
asc screenshots list --app "$APP" --version "$VER"
```
每个区每个槽的张数必须一致，且状态全为 `COMPLETE`（`UPLOAD_COMPLETE` 是还在处理，等一分钟再看）。

### 上传时的三个坑

1. **单张 checksum 结算超时**（`context deadline exceeded`，状态停在 `UPLOAD_COMPLETE`）。
   不是失败，是慢。加大超时并**续传**：
   ```bash
   ASC_TIMEOUT=180s asc screenshots upload --resume .asc/reports/screenshots-upload/failures-*.json
   ```
2. **单区模式不接受 `--confirm`**。`--confirm` 只服务于 `--replace`；单区补传带上它会直接打帮助文本，
   而 `| tail` 会把报错行截掉，看起来像"命令没输出"。排查时先看 `head`。
3. **逐区批跑 + `set -e` ⇒ 首区失败，后面几个区一张没传**（实测：ja 第 6 张超时，ko/pt/zh 三区全空）。
   补传要**单区来**，不要整批重跑：
   ```bash
   for loc in ko pt-BR zh-Hans zh-Hant; do
     asc screenshots upload --app "$APP" --version "$VER" --locale "$loc" \
       --path "fastlane/screenshots-beautified/$loc" --device-type IPHONE_DUO
   done
   ```

## 二、文案

### 五步，每步都停下来看

```bash
bash scripts/publish_asc.sh --app-id "$APP" --version "$VER" --dir asc-metadata/canonical
# 逐条读「更新」项的 from —— 名称/副标题被意外改动只有这里能发现
bash scripts/publish_asc.sh --app-id "$APP" --version "$VER" --dir asc-metadata/canonical --confirm
```

脚本内置三条硬约束：

- `--if-exists update` 必填（默认 `fail` 会中途中断，造成"推了一半"）；
- **绝不传 `--allow-deletes`**（它会删掉本地没覆盖的所有语言区）；
- `apply` 报 `plan drifted` **不等于没写入**（drift 校验跑在写入之后），
  所以脚本不重跑，直接 `pull` 回读逐字段比对——**这是唯一可信的验收**。

### 新建版本不会继承的字段

| 字段 | 新建版本时 | 后果 |
|---|---|---|
| `whatsNew` | 空 | 提交时被拦，必填 |
| `promotionalText` | 空 | 白丢一个 170 字符的营销位（可随时改，不需审核） |
| `description` / `keywords` | 继承上一版 | 与上一版逐字相同，属正常 |

所以每新建一个版本，至少要把 `whatsNew` 和 `promotionalText` 补上。

### 更新说明怎么写

一句话说清这版**用户能看见什么**，然后两条以内的具体变化，末尾一句修复。够了。

⛔ **不要写实现细节**：列数、像素、内部组件名、"某某表头改为实色"这类都属实现层。
用户看更新说明只关心"打开会看到什么"。反面实例（真实被驳回的一版）六条 bullet 里五条是内部改动：

```
✗ - Half folded, the photo grid switches to an even number of columns, so the crease
    falls between two photos instead of cutting one in half.
✓ - Unfolded, the wide screen gets a layout of its own: more photos per row.
```

### 语言码两套，别混

工程内部用 `en` / `de` / `pt`，ASC 用 `en-US` / `de-DE` / `pt-BR`（中日韩相同）。
fan-out 上传按**同名目录**找图，名字不对就静默少传；元数据目录名同样必须是 ASC 码。

## 三、不可自动的部分（明确不做）

素材库 Asset Library、产品页面优化 PPO、自定产品页面 CPP 目前只能走 ASC 网页后台或 API。
本流水线产出的是它们的**上游原料**，不代建、不代提审。
