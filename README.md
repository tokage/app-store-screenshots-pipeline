# app-store-screenshots-pipeline

一个 WorkBuddy 技能：把「iOS App 的截图与文案」从代码一路送到 App Store Connect，
中途每一站都有一道门。六个阶段：

| 阶段 | 干什么 | 门 |
|---|---|---|
| 0 | 环境体检 + 读设备档案 | 缺必需项就停，不猜 |
| 1 | 抓每语言 × 每设备的无框截图 | 张数 / 尺寸 / mtime / 跨区 md5 四项 |
| 2 | 注入美化工程 | 张数 / 尺寸 / 跨区同格一致 / 覆盖保护 |
| 3 | 起编辑器并证明它真的能渲染 | 真浏览器 DOM 无运行时错误 |
| 4 | 导出并整理成 ASC 上传树 | 语言码 / 槽位 / 张数 / 版本号 |
| 5 | 推截图 + 推文案 | `asc` 回读逐张、逐字段一致 |

设计取舍只有一条：**要么真的验过，要么明说没验过**。截图上线的失败几乎全是静默的
——文件名对、张数看着差不多、打开也像那么回事，但像素是旧的、尺寸是外屏的、
某区少一张、九区其实一模一样。所以每一道门都用机器判据，不靠肉眼看。

## 安装

技能按仓库软链到用户级目录，改完立刻生效，不必重新拷贝：

```bash
git clone https://github.com/tokage/app-store-screenshots-pipeline.git ~/Projects/app-store-screenshots-pipeline
ln -s ~/Projects/app-store-screenshots-pipeline ~/.workbuddy/skills/app-store-screenshots-pipeline
```

要分发给别人时再打包：`skill_ops.py package <dir> --output <zip> --risk-ack "<说明>" --write-confirmed`。

## 依赖

- **必须**：macOS + Xcode（含一个 iOS runtime）、fastlane、bun 或 Node 20+。
- **上传阶段需要**：`asc` CLI 与 App Store Connect API 密钥。
- **折叠设备需要**：`duoctl`。

缺哪项就跑哪部分，跳过的门标「未验证」。逐项配置见
[`references/setup-guide.md`](references/setup-guide.md)；先体检：

```bash
python3 scripts/check_environment.py --app-root .
```

## 合并来源

本仓库吸收并取代了 `ios-fastlane-screenshots`。合并的理由是两个技能**互相依赖却互不提及**：
这里的第一步要跑的抓图 lane 恰由另一个技能配置，而另一边的脚本清单里三个脚本在
本仓库里根本不存在。同一套知识写两遍的结果是两边都过期——ASC 章节写了两版、
抓图坑一个写 7 条一个写 13 条，且两份 `validate` 都不通过。

合并后：抓图、多语言批次、折叠姿态、ASC 上传与文案全部在这一个仓库里，
只有一份事实源。`ios-fastlane-screenshots` 留作指向页，不再维护正文。

## 目录

```
SKILL.md                     六阶段主流程，每阶段一道门
skill-dependencies.json      依赖清单（能力 / 检查 / 配置 / 降级）
references/                  按问题域分的细节，遇到问题再翻
scripts/
  check_environment.py       四态体检
  device_profile.sh          设备身份唯一出口
  verify_shots.py            抓图收货门
  inject_screenshots.py      注入四门
  stage_beautified.sh        导出树 → ASC 上传树
  publish_asc.sh             文案五步 + 回读验收
resources/
  device-profiles.example.json
  template/app-store-screenshots/   美化工程（Next.js）
```

## 版权

- 编排部分（`SKILL.md`、`references/`、`scripts/`、本 README、`LICENSE`）：
  MIT — Copyright (c) 2026 刘俊。
- `resources/template/app-store-screenshots/` 是
  [ParthJadhav/app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots)
  的修改副本（MIT，© 2026 Parth Jadhav），见 `NOTICE` 与引擎自带的 `LICENSE`。
