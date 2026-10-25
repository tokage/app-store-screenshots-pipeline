# 配置与凭据

只列这条流水线真正需要的东西。小节标题里的英文就是 `skill-dependencies.json` 的依赖 id，
缺哪项就跳到哪一节，已配好的不重复讲。

先跑一次体检，它会告诉你缺的是哪几项：

```bash
python3 scripts/check_environment.py --app-root .
```

| 返回 | 含义 | 接下来的动作 |
|---|---|---|
| `ready` | 必需项齐全 | 直接进主流程，本文件不用读 |
| `partial` | 必需齐、可选缺 | 只跑可用部分，并明确标注哪一步被跳过（例如没装 asc 就只出图不传） |
| `needs_setup` | 缺必需项 | 只看下面缺的那一节，不要通读 |
| `unavailable` | 装了但坏了 | 按报错给恢复步骤（版本不支持 / 认证失效 / 权限） |

凭据类检查只输出"有无"，不回显任何值。

---

## 一、macos-xcode —— Xcode 与 iOS 模拟器（必需）

官方：<https://developer.apple.com/xcode/> · 文档：<https://developer.apple.com/documentation/xcode>

抓图必须有真机外的模拟器，收货门的尺寸校验依赖 `sips`。

1. App Store 安装 Xcode，然后指定命令行工具路径：
   ```bash
   sudo xcode-select -s /Applications/Xcode.app
   xcodebuild -version
   ```
2. Xcode → Settings → Components → 下载一个 iOS runtime。
   折叠设备要用对应版本的 runtime，具体版本看设备档案的 `runtime` 字段。
3. 验证：
   ```bash
   xcrun simctl list runtimes
   xcrun simctl list devices available | head
   ```
   两件事要确认：目标 runtime 在列表里；对应 simType 的设备状态为 `available`。

**安全**：上述命令只读，不启动模拟器。真正启动模拟器由抓图阶段的 lane 负责，
不要在体检阶段 `simctl boot`——首次启动会触发数据迁移与索引，机器会被吃满。

## 二、fastlane —— 抓图编排（必需）

官方：<https://fastlane.tools> · 文档：<https://docs.fastlane.tools>

```bash
gem install fastlane        # 或项目里 bundle install
fastlane --version
```

`bundle exec fastlane …` 需要仓库里有 `Gemfile`。**没有 Gemfile 时用裸 `fastlane`**，
先 `ls Gemfile*` 判断，不要无条件加 `bundle exec`——它会报"找不到 Gemfile"，
看起来像 fastlane 没装，是常见的误判来源。

抓图用 snapshot（`fastlane snapshot` / `Snapfile` 的 `language` × `locale` 矩阵），
配置写法见 [references/snapfile-fastfile.md](snapfile-fastfile.md)。

## 三、bun-node —— 美化工程运行时（必需）

官方：<https://bun.sh> · 文档：<https://bun.sh/docs>

```bash
curl -fsSL https://bun.sh/install | bash
bun --version
```

没有 bun 就退回 Node 20+ 用 `npm run dev`。两者任一可用即算通过。
只查询版本，不要在体检阶段 `bun install`——依赖安装属于构建阶段，不是环境检查。

## 四、asc-cli —— App Store Connect 命令行（可选，上传阶段需要）

官方：<https://github.com/rorkai/asc> · 文档：<https://github.com/rorkai/asc#readme>

```bash
brew install asc
asc --version
```

`/opt/homebrew/bin` 不在 PATH 里时，要么补 PATH，要么在脚本里用绝对路径调它。
没装 asc 不影响出图，只影响自动上传——此时停在 staging 产物，按手动步骤上传。

## 五、app-store-connect —— ASC 凭据（可选，写入阶段需要）

官方：<https://developer.apple.com/app-store-connect/>
API 文档：<https://developer.apple.com/documentation/appstoreconnectapi>
登录：<https://appstoreconnect.apple.com/login>
生成密钥：<https://appstoreconnect.apple.com/access/integrations/api>

1. 看权限：页面路径 **Users and Access → Integrations → App Store Connect API**，
   需要 **App Manager** 或 **Admin** 角色。团队里角色不够时，密钥页面不会让你生成密钥，
   这一步必须由管理员完成。
2. 生成密钥：在 Integrations 页点生成，`.p8` **只能下载一次**，丢了只能 Revoke 重来。
3. 存放：仓库外，权限 0600。
   ```bash
   mkdir -p ~/.private_keys && chmod 700 ~/.private_keys
   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.private_keys/
   chmod 600 ~/.private_keys/AuthKey_XXXXXXXXXX.p8
   ```
   凭据进的是系统钥匙串，由 asc 自己管理。**不要**把 `.p8` 放进仓库，
   也不要写进任何 skill 文件或在对话里回显。
4. 登录并验证：
   ```bash
   asc auth login --name "<项目名>" \
     --key-id "KEY_ID" --issuer-id "ISSUER_ID" \
     --private-key ~/.private_keys/AuthKey_XXXXXXXXXX.p8
   asc auth doctor        # 应显示凭据 OK、无 issue
   asc status --app <APP_ID>   # 能返回版本与构建才算真的通
   ```
5. **不要设置 `ASC_BYPASS_KEYCHAIN=1`**。它让 CLI 完全跳过钥匙串，于是即便早就登录过，
   `auth status` 也返回 `credentials: []`、`auth doctor` 打印 "No stored credentials found"——
   症状和"从未登录"一模一样，极易误判成凭据丢了。
   判据：看 `auth doctor` 的 `Storage:` 段里有没有 `Keychain is bypassed via ASC_BYPASS_KEYCHAIN`。
6. 轮换与撤销：在同一个 Integrations 页面 Revoke 旧密钥、生成新密钥，重新 `asc auth login`。
   撤销**立即生效**，正在跑的长任务会中途失效（JWT 有效期 20 分钟），
   所以批量上传尽量一次跑完，别跨小时分批。

## 六、duoctl —— 折叠设备姿态（可选，只有折叠屏才要）

官方：<https://github.com/skarol/duoctl> · 文档：<https://github.com/skarol/duoctl#readme>

```bash
brew install skarol/tap/duoctl
duoctl state        # 能读出铰链角度才算可用
```

没有它就只能手动摆姿态，或者跳过该设备——其它设备不受影响。
姿态切换的正确时序（rotate 之后必须等画面真的转过去再判定）见
[references/foldable-and-multishot.md](foldable-and-multishot.md)。

**判定姿态不要拿屏幕宽度当门**，宽度会随旋转时序漂移；只看 `duoctl` 报的
展开态与外屏/内屏状态。

---

## 缺少某项时的降级

`check_environment.py` 判 `partial` 时，按能力而不是按工具决定跳过什么：

| 缺的东西 | 影响的阶段 | 降级做法 |
|---|---|---|
| Xcode / runtime | 抓图 | 用手工无框截图继续注入与美化，但要标注"截图来源未验证" |
| fastlane | 抓图 | 改直调 `xcodebuild test`，自行准备 language/locale 输入文件 |
| bun 与 Node | 美化 | 交付已注入的工程，附启动命令，由用户自备运行时 |
| asc | 上传 | 停在 staging，输出上传树与逐条手动步骤 |
| ASC 凭据 | 上传 / 文案 | 只做离线 validate 与 plan，交付可复制的命令 |
| duoctl | 折叠设备抓图 | 跳过该设备，或由用户手动摆好姿态后再跑 |

降级不是失败，但要如实标注：跳过的门一律写"未验证"，不要用"应该没问题"顶上。
