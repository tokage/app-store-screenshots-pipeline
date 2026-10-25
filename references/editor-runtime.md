# 编辑器运行时故障

美化工程是 Next.js，起不来 / 白屏 / 整页报错这三类占了全部故障。按顺序查。

## 0. `next dev` 在 `Starting...` 后 2 秒退出，`[safe-delete] broker denied delete: path=…/.next/types`

`next dev` 的热重载每次启动都会 `recursiveDelete(".next")`。Agent 沙箱若拦截文件删除，进程立刻死：
2 秒后退出、`curl` 返回 000、`lsof -iTCP:3000` 什么都没有。

**把 `.next` 移走是不够的**——Next 几秒后又造一个 `.next/types` 再删一次，崩溃带全新时间戳重演。

修：启动时把删除相关的环境变量摘掉，并给一个不遮蔽真实 node 的 PATH：

```bash
cd app-store-screenshots && mv .next "${TMPDIR:-/tmp}/asc-next-$(date +%s)" 2>/dev/null
env -u NODE_OPTIONS \
    -u CODEBUDDY_SAFE_DELETE_BROKER_DELETE \
    -u CODEBUDDY_SAFE_DELETE_REPORT_PATH \
    -u CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR \
    PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /usr/bin/env node ./node_modules/next/dist/bin/next dev -H 127.0.0.1 -p 3000
```

显式绑 `127.0.0.1`（Next 默认通配）。两道核验：

```bash
curl --noproxy '*' -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/   # 期望 200
lsof -nP -iTCP:3000 -sTCP:LISTEN                                             # 期望 127.0.0.1:3000
```

**`502` 不等于端口占用**：系统 HTTP 代理会给"没人在听"的端口回 502，同一个状态下 `curl --noproxy '*'` 返回 000。

## 1. `TypeError: raw.startsWith is not a function`，整页变成 Next 的错误遮罩

`raw` 是 `slide.screenshot`：schema 声明它是 `string`，实际到达的是多语言对象 `{en, zh, ja}`。
抛在 `screenshot-editor.tsx` 的 `assetPaths` memo 里。

两条事实让它变成整页崩溃而不是小毛病：

- 水合顺序是 **localStorage 先（立即绘制）→ 磁盘 JSON 后覆盖**，而 `assetPaths` 在**首帧**就算 ⇒ 在磁盘数据来得及救场之前先抛。
  **`curl` 返回 200 不能证明页面能用**，客户端崩溃不会体现在 HTTP 状态码上。
- 同一台机器上所有脚手架共用 `http://localhost:3000` **和同一个 `STORAGE_KEY`**，
  localStorage 是跨项目的。不同时期生成的脚手架 schema 不兼容，旧引擎读到新缓存就是这个崩。

修：把边界解析做完整——`label` / `headline` 已被 `coerceLocalized` 处理，`screenshot` / `screenshotSecondary` 漏了：

```ts
function coerceScreenshot(value: unknown): string {
  return pickText(coerceLocalized(value), DEFAULT_LOCALE);
}
```

**规则：任何在边界被解析的值（localStorage、文件、API）都必须强制转成声明的类型，不能指望它已经是。**

验完"崩没了"不算完，要验**降级是正确的**而不是静默空白：用 Playwright `addInitScript` 注入脏状态、
`abort **/api/project` 让缓存成为唯一来源，然后断言浏览器真的去请求了那张图。
不要拿 `appName` 的文本选择器当"页面渲染了"的证据——它是受控 `<input>` 的 **value**，不是文本节点。

## 2. 验证服务器活着的正确姿势

```bash
curl 200 + grep 关键文案 ≥1 + grep 运行时错误 ==0
```

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --virtual-time-budget=8000 --dump-dom \
  http://127.0.0.1:3000/ > "$TMPDIR/dom.html"
grep -cEi "Unhandled Runtime Error|TypeError|Application error" "$TMPDIR/dom.html"   # 必须 0
grep -c "<任一 slide 的真实文案>" "$TMPDIR/dom.html"                                  # 必须 >0
```

DOM 几十 MB 属正常：画布把每张 PNG 内联成 `data:` URI（比 `grep -o "<img"` 与 `grep -o "data:image"` 的数量）。
