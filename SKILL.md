---
name: app-store-screenshots-pipeline
description: End-to-end App Store screenshot and listing pipeline for iOS projects. Reads the listing from the project's own docs, captures frameless screenshots with fastlane across every locale and device (foldables included), gates the output by count, size, mtime and cross-locale pixels, injects them into the bundled Next.js beautify editor, proves the running editor in a real browser, exports, stages the upload tree, then pushes screenshots and metadata to App Store Connect and verifies by read-back. Absorbs the retired ios-fastlane-screenshots skill. 触发：跑截图流水线、给这个 App 出商店图、准备 App Store 截图、配 fastlane 多语言多设备截图、snapshot 抓图加框、更新商店页文案与更新说明。
version: 2.0.0
agent_created: true
---

# App Store 截图文案流水线（端到端）

从「项目代码」到「App Store 上真的换了图、换了文案」的一条链路。六个阶段，
每个阶段末尾有一道门；门不过就停，不进下一阶段。

| 阶段 | 干什么 | 门 |
|---|---|---|
| 0 | 读依赖与设备档案 | `check_environment.py` 不是 `needs_setup`；设备档案齐全 |
| 1 | 抓无框截图（每语言 × 每设备） | `verify_shots.py` 四门全过 |
| 2 | 注入 + 起美化工程 | `inject_screenshots.py` 四门全过 |
| 3 | 编辑器可用（真的能渲染） | 真浏览器 DOM 里无运行时错误、有真实文案 |
| 4 | 导出并整理成 ASC 上传树 | `stage_beautified.sh` 四门全过 |
| 5 | 推截图 + 推文案 | `asc` 回读逐张/逐字段一致 |

> **贯穿全程的不变量：一个语言区是一笔事务。** 跑完一个区的所有格 → 验这个区 →
> 再进下一个区。批量循环在某个区失败后继续往下跑，会把一次失败变成 N 次排查——
> 这是九语实测里最贵的错误。

## 何时用

「准备 App Store 截图」「跑截图流水线」「给这个 App 出商店图」「更新商店页文案」，
以及任何需要「改完 UI → 商店页看到变化」的场合。

技能装在用户级，任何项目都能调；每个项目自己生成 `<app-root>/app-store-screenshots/`。

## 阶段 0 — 依赖与设备档案

先体检，不要凭记忆判断环境：

```bash
python3 scripts/check_environment.py --app-root .
```

四态路由（`ready` / `partial` / `needs_setup` / `unavailable`）与逐项配置见
[references/setup-guide.md](references/setup-guide.md)。只读体检，不启动模拟器。

然后确认设备档案存在（没有就从 `resources/device-profiles.example.json` 拷一份到
`fastlane/device-profiles.json` 再改值）：

```bash
bash scripts/device_profile.sh --list
```

**设备身份只有一个出口。** 一台设备同时决定九个值：模拟器类型、runtime、ASC 槽、
允许像素、原始截图目录、种子库目录、美化工程的 device 键、导出尺寸目录、是否折叠。
这九个值散落在 init / shoot / use_store / Snapfile / Fastfile / 上传脚本里各写一遍时，
加第二台设备必然漏改一处——**而漏改的表现不是报错，是静默抓错设备或静默抓到外屏尺寸**，
要等商店页上线才发现。所以任何脚本、配置都不许再写死设备名，一律：

```bash
eval "$(bash scripts/device_profile.sh --export <profile>)"
# DEV_ASC_TYPE / DEV_PIXELS / DEV_SHOTS_DIR / DEV_EDITOR_DEVICE / DEV_EXPORT_SIZE / DEV_FOLDABLE …
```

档案格式、字段含义、多设备四条硬约定见
[references/listing-and-devices.md](references/listing-and-devices.md)。

**门**：体检结果能支撑「抓图 + 美化」；`device_profile.sh --list` 能列出目标设备。
不满足就先修环境或降级（缺什么跳什么，跳过的门必须标「未验证」）。

## 阶段 1 — 抓无框截图

1. 先读 `listing.json`（若还没有，按 [references/listing-contract.md](references/listing-contract.md)
   从 README / PRD / `*.xcstrings` / Fastfile / Snapfile 抽取，并让用户确认）。
2. 抓图走项目的 snapshot lane（**不要** frameit——机身由美化工程画）：

   ```sh
   # Fastfile 里的关键三项，缺一项就会抓到不确定的东西
   capture_languages(...)      # 语言来自档案/配置，不要手抄
   capture_devices(...)        # 来自 DEV_*，不要手抄
   # 并发必须关：Xcode 会复用同一个模拟器，两个语言区同时跑会互相污染
   sh "xcodebuild test ... -parallel-testing-enabled NO ..."
   ```

   `Snapfile` / `Fastfile` 的写法、`clear_previous_screenshots` 的坑、部分重跑
   （`ODM_SHOT_MODE` 那类逃生开关）、九语种子库准备，见
   [references/snapfile-fastfile.md](references/snapfile-fastfile.md) 与
   [references/multilocale-batch.md](references/multilocale-batch.md)。

3. 折叠设备要摆姿态：`duoctl` 展开内屏 → **等画面真的转过去** → 再判定 →
   然后再启动 UI 测试。`rotate` 返回成功但画面没转是常态，此时抓到的整批都是外屏尺寸。
   完整时序见 [references/foldable-and-multishot.md](references/foldable-and-multishot.md)。

4. **门：收货门。**

   ```bash
   python3 scripts/verify_shots.py \
     --root "$DEV_SHOTS_DIR" --pattern "<前缀>-*.png" \
     --expect-size "${DEV_PIXELS%% *}" --expect-count 6 \
     --since "$RUN_STARTED_AT"
   ```

   四类判据一次判死，不需要人眼看图：**张数**（少一张 = 某个分支没进）、
   **尺寸**（抓错设备的唯一症状）、**mtime**（同尺寸的旧文件）、
   **跨区 md5 互异**（切了语言但没真生效，九区一模一样）。
   有区不合格就停，不要"先跑完再一起看"。

抓图阶段的硬故障（xcodebuild 残留锁 / 模拟器 Invalid state / 系统权限弹窗挡住点击 /
按本地化文案定位控件导致某区静默少图 / 拿旧二进制验收改动）逐条写在
[references/gotchas-deadlock.md](references/gotchas-deadlock.md)，
遇到"跑不动"或"少图"先查那里，不要重新设计流程。

## 阶段 2 — 注入与美化工程

1. 目标 `<app-root>/app-store-screenshots/`。不存在就从
   `resources/template/app-store-screenshots/` 拷一份进去，并写 `.gitignore`
   （边界见 [references/git-boundary.md](references/git-boundary.md)）。
2. `listing.json` → `app-store-screenshots/app-store-screenshots.json`。
   **非目标设备要显式写成 `[]`**，不要省略：引擎是 `{...defaults, ...yours}` 合并，
   省略的设备会带着 starter 幻灯片回来，指向不存在的图片。
3. 注入（不要用 `cp`）：

   ```bash
   python3 scripts/inject_screenshots.py \
     --scaffold app-store-screenshots \
     --src "$DEV_SHOTS_DIR" --device "$DEV_EDITOR_DEVICE" \
     --slugs 01-on-today,02-journey-map,03-journey-home,04-memory,05-poster,06-photo-detail \
     --src-pattern "<前缀>-{slug}.png" \
     --expect-size "${DEV_PIXELS%% *}" --dry-run
   ```

   四道门：**张数**、**尺寸**、**跨区同格尺寸一致**（防"一半内屏一半外屏"）、
   **覆盖保护**（目标已存在且像素不同，必须显式 `--force`）。
   幻灯片文案必须来自项目自己的分镜文档，不要临场编——图和文案会各走各的，
   等上传完才发现对不上。

4. **非破坏性重入**：`app-store-screenshots.json` 已存在时**绝不覆盖**。
   只有用户明确说"只刷新图"时才只重拷图片，手工排版全部保留。

## 阶段 3 — 编辑器跑起来

```bash
cd app-store-screenshots && bun install && bun run dev
# 没有 bun：npm install && npm run dev
```

**`curl` 返回 200 不是证据。** 渲染发生在客户端，水合阶段崩掉的页面照样回 200。
必须用真浏览器看 DOM：

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --virtual-time-budget=8000 --dump-dom \
  http://127.0.0.1:3000/ > "$TMPDIR/dom.html"
grep -cEi "Unhandled Runtime Error|TypeError|Application error" "$TMPDIR/dom.html"  # 必须 0
grep -c "<某一格的真实文案>" "$TMPDIR/dom.html"                                    # 必须 >0
```

DOM 几十 MB 属正常：画布把每张 PNG 内联成 `data:` URI。

起不来 / 白屏 / 整页报错这三类占了全部故障，都在
[references/editor-runtime.md](references/editor-runtime.md)：`next dev` 被沙箱拦住
删除 `.next` 而 2 秒退出、`raw.startsWith is not a function` 这类跨脚手架共享
localStorage 导致的水合崩溃、以及"验证服务器活着"的正确姿势。

**门**：真浏览器 DOM 里运行时错误 0 且真实文案 >0。这两条都过了才交给人微调。
微调是反复的，交出去之后用户随时可以重开地址，改动持久化在 JSON 里。

## 阶段 4 — 导出与 staging

编辑器导出后得到一棵按尺寸分的树。整理成 ASC 能直接吃的形状，靠一个脚本而不是手工搬：

```bash
bash scripts/stage_beautified.sh <导出目录或 zip> \
  --asc-type "$DEV_ASC_TYPE" --size-dir "$DEV_EXPORT_SIZE" --per-locale 6 \
  --app-id "$APP_ID" --version "$VERSION" \
  --project <App>.xcodeproj --bundle-id <bundle id> \
  --out "$DEV_BEAUTIFIED_DIR"
```

它做四件事，每一件都是真实踩过的：

1. **语言码映射**：ASC 用的是 `en-US` / `de-DE` / `pt-BR` 这套，工程里常写 `en` / `de` / `pt`。
   目录名不对，ASC 的 fan-out 上传会**静默少传**，不报错。
2. **槽位与尺寸硬门**：`--asc-type` 与 `--size-dir` 必须与档案一致；写错槽位则商店页
   继续显示旧套装。
3. **张数硬门**：每区张数必须等于 `--per-locale`。
4. **版本号认领**：给了 `--project` + `--bundle-id` 时从 pbxproj 里按 bundle id 精确取版本，
   避免拿错版本去推。

槽位与像素的对应关系、以及"为什么 Duo 是独立槽而不是塞进 6.9 寸"，见
[references/publish-asc.md](references/publish-asc.md) 与
[references/inject-and-engine.md](references/inject-and-engine.md)。

## 阶段 5 — 推截图与推文案

### 5a. 截图

```bash
# 先看清单（--replace 是先删后传，必须先读删除清单）
asc screenshots upload --app "$APP_ID" --version "$VERSION" \
  --device-type "$DEV_ASC_TYPE" --path "$DEV_BEAUTIFIED_DIR" --replace --dry-run

# 确认后真跑；或直接交给 stage_beautified.sh --upload [--confirm]
```

三个实测坑，都可能让你以为"上传失败"其实只是姿势不对：

- **单张 checksum 结算超时**：`context deadline exceeded`。
  `ASC_TIMEOUT=180s` 重跑，并用 `--resume <failures-*.json>` 只补失败那张，
  不要整批重来。
- **单区模式不接受 `--confirm`**：`--locale` 单区补传时报
  `--confirm only applies to --replace`。单区就是不带 `--confirm`。
- **别用 `set -e` 逐区跑**：首区失败会让后面所有区一区未传，看起来像"全失败"，
  实际是"全没跑"。要么一次跑完，要么单区单独跑并逐区记账。

**验收只有一件事**：`asc screenshots list` 回读，每区张数一致、槽位正确。

### 5b. 文案

有 `asc-metadata/` 三目录（`metadata/` 编辑源 → `canonical/` 推送物 → `live/` 只读快照）
就按五步走，一个脚本跑完并当场回读：

```bash
# 只看计划：新增/更新/删除各几条，逐条读 from
bash scripts/publish_asc.sh --app-id "$APP_ID" --version "$VERSION" --dir asc-metadata/canonical

# 确认后真推：validate → plan → approve → apply → pull 回读逐字段比对
bash scripts/publish_asc.sh --app-id "$APP_ID" --version "$VERSION" \
  --dir asc-metadata/canonical --confirm
```

三条不可违反：`--if-exists update` 必填（默认 `fail` 会让整批中断，一半推了一半没推）；
**绝不传 `--allow-deletes`**（会删掉本地没覆盖的所有语言区）；
`apply` 报 `plan drifted` **不等于没写入**（drift 校验跑在写入之后），
不去重跑，直接 `pull` 回读——**回读逐字段比对是唯一可信的验收**。

**新建版本不继承 `whatsNew` 与 `promotionalText`**（继承的是 `description` / `keywords`）。
所以新版本必须显式写这两个字段，否则提交会被"缺少更新说明"拦下。

`whatsNew` 只写用户看得见的结果：展开后排版不同、旋转后重排；不写列数、像素、
组件名、内部修复项。三句话封顶：一句说改了什么，两条说能感受到什么，一句兜底。

## 硬性禁止

- 不在非 macOS 上假装能抓图。
- 不用 `cp` 代替注入脚本，不用 `--allow-deletes`，不省略 `--if-exists update`。
- 不覆盖用户已经手工调过的 `app-store-screenshots.json`。
- 不因为 `curl` 200 就宣称编辑器可用。
- 不在抓图循环里用 `set -e` 逐区跑。
- 不拿屏幕宽度当折叠姿态的判据。
- 不把"跳过的门"写成"通过"。

## 文件索引

| 文件 | 讲什么 |
|---|---|
| `scripts/check_environment.py` | 四态体检 |
| `scripts/device_profile.sh` | 设备身份唯一出口 |
| `scripts/verify_shots.py` | 抓图收货门（四判据） |
| `scripts/inject_screenshots.py` | 注入四门 |
| `scripts/stage_beautified.sh` | 导出树 → ASC 上传树 + 硬门 |
| `scripts/publish_asc.sh` | 文案五步 + 回读验收 |
| `scripts/probe_environment.py` | 环境探针（被体检调用） |
| `resources/device-profiles.example.json` | 设备档案样例，拷到项目里改值 |
| `resources/template/app-store-screenshots/` | 美化工程模板（Next.js + 设备机身 + 版式） |

references 里按问题域分，遇到具体问题再翻，不要顺序通读：

- 契约与设备：[listing-contract.md](references/listing-contract.md) ·
  [listing-and-devices.md](references/listing-and-devices.md)
- 抓图：[snapfile-fastfile.md](references/snapfile-fastfile.md) ·
  [multilocale-batch.md](references/multilocale-batch.md) ·
  [foldable-and-multishot.md](references/foldable-and-multishot.md) ·
  [demo-data-builder.md](references/demo-data-builder.md)
- 美化：[inject-and-engine.md](references/inject-and-engine.md) ·
  [editor-runtime.md](references/editor-runtime.md)
- 上传：[publish-asc.md](references/publish-asc.md)
- 排障：[gotchas-deadlock.md](references/gotchas-deadlock.md)
- 环境与边界：[setup-guide.md](references/setup-guide.md) ·
  [git-boundary.md](references/git-boundary.md)
