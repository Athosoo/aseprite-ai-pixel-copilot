# dsh-plugin-aseprite — 当前进度（交接）

> **2026-10-19：项目关闭，仓库归档（read-only）。** 本机已卸载插件。
> 下面保留最后状态，供以后想捡起来时看。恢复方式：clone 仓库 → `node test/sync.mjs`
> → 按 README「装载方式」登记到 profile → 重启 DSH。

给下次继续的自己：先读 `DESIGN.md`（行为契约），再读这一页（做到哪了）。

## 2026-10-19 · 收尾（关闭前的真实状态）

- **代码**：P1b（7 个工具 / 备份 / 清单生成）与 P2（三块面板 + 路由 + 回显）都已提交；
  测试 `config 24 + manifest 14 + api 24 + client-load 4 + inject-wiring 8 + smoke 25 = 99` +
  `ops_test 104`，全部在本地跑绿。
- **唯一未验证的一步**：`f1e83cf` 的 405 修复（服务注入竞态 → `ctx.inject` 延迟挂路由）
  只经过单测（`test/inject-wiring.mjs` 模拟 cordis 时序），**没有真实重启一次确认面板可用**。
  下次捡起来时，第一件事就是重启 DSH 看面板是否还报 405，然后读
  `%TEMP%\dsh-plugin-aseprite.log` 里的 `panel routes registered: 2` / `NOT wired after 8s`。
- **卸载**：profile 的 `dependencies` 与 `dsh.profile.bundles` 已移除，`node_modules/dsh-plugin-aseprite`
  与 `~/.dsh/dsh-plugin-aseprite`（配置/工作区）已删除。代码本体仍在仓库里。

## 2026-10-18 · v0.1.1 修面板 405（cordis 服务注入竞态）

**症状**：面板渲染出来但红字 `HTTP 405`、文件列表空、点不动。

**根因（日志实锤）**：`webServer` / `connection` / `agents` 都是**后注册**的 cordis 服务。
插件可能先于它们挂载 —— 实测两次启动，一次 `panel routes registered: 2`，一次
`cannot get property "webServer" without inject`。我们的 `service()` 先 `ctx.get()`（返回 undefined）
再退到属性访问（未 inject 的 ctx 上属性访问**会抛**），于是路由一条都没注册，DSH 自己的
handler 对 `/aseprite/api/state` 回 405。

**修法**：
1. `lib/index.js`：路由挂载改成 `ctx.inject(['webServer','connection'], wire)` —— 等服务就绪再挂；
   `agents` 单独 `ctx.inject(['agents'], …)`，回显拿不到就保持诚实降级。
2. `lib/routes.js` 的 `service()`：`ctx.get` 与属性访问**两条路都包 try/catch**，任何一条都不许抛。
3. `client/client.js`：错误显示带 HTTP 状态 + 正文摘要，405/404 时直接提示看
   `%TEMP%\dsh-plugin-aseprite.log`。
4. 新增 `test/inject-wiring.mjs`（8 条）：模拟"服务未就绪 → 注入回调 → 挂上 2 条路由"的完整时序，
   并断言 apply 在没有服务、属性访问会抛的情况下也不炸。

**测试**：`config 24 + manifest 14 + api 24 + client-load 4 + inject-wiring 8 + smoke 25 = 99` + `ops_test 104`。

## 2026-10-18 · P2 面板完成（三块 + 回显）

**这一版做了什么**

1. **宿主路由**（`lib/routes.js`）：`POST /aseprite/api/<method>` 与 `GET /aseprite/media?path=…`。
   同源/鉴权闸门走 `ctx.connection.requestRejection`；媒体**白名单**只放行工作区与导出区（越界 403）。
   方法派发只认自有属性（`constructor` 之类返回 404）。
2. **面板 API**（`lib/api.js`）：`state / ls / preview / apply / export / open`。
   `preview` 把 .ase 导出到 `<workspace>/_preview/<stem>-<hash>.png`（不污染导出区）；
   `apply` 复用覆盖前备份、失败即中止。
3. **回显**：成功后 `agent.inject(createUserMessage({ source: { kind: 'plugin:dsh-plugin-aseprite' } }))`
   —— 不唤醒驱动、不触发新一轮。会话定位：客户端先试 `ctx.sidebarRight.mounted`，
   宿主退回"唯一活动 Agent"，都拿不到就如实 `echoed:false`（不伪造）。
4. **UI**（`client/client.js`）：文件列表 / 画布预览 / 算子台 + 顶部刷新·打开·导出 + 底部操作日志；
   预览棋盘底、`image-rendering: pixelated`；算子按钮跑 manifest 默认参数。

**测试**：`config 24 + manifest 14 + api 24 + client-load 4 + smoke 25 = 91`（smoke 需真机）+
`ops_test 104`。`client-load` 用 vm + react stub 验证外层壳、工厂导出、两个插槽注册与首屏渲染树。

**已验证 / 未验证**：路由、白名单、信封、回显降级、真机 preview/apply 都有测试；
**浏览器里的实际观感与真实点击尚未验证**（重启 DSH 后要人眼确认）。

## 2026-10-18 · 仓库合并 + P1b 完成

**这一版做了什么**

1. **仓库合并**：本仓库（原 `aseprite-ai-pixel-copilot`，扩展 + Node 桥）**整体换成插件**；
   旧版本留在 Git 历史里 —— tag `v0.6.1`、分支 `archive/extension`，需要时 `git show` 即可。
2. **领域层搬到本仓库**：`lib/ops.lua`（10 算子 / 27 参数 / `ops.manifest()`）+ `lib/util.lua`
   + `test/lua/ops_test.lua`（104 条）。**不再有 vendor / UPSTREAM / 任何外部 checkout 依赖。**
3. **清单生成**：`test/gen-manifest.mjs` 跑真 Aseprite 的 `ops.manifest()` 生成
   `lib/ops.manifest.json`（`--check` 只校验）。`test/smoke.mjs` 会重跑一遍对比，**清单过期即红**。
4. **备份**：`aseprite_apply` 覆盖前备份到 `<workspace>/_backup/<源相对路径>/<时间戳>_<原名>`，
   同源只留最新 10 份；复制失败 / 大小不符**中止操作**。
5. **GUI 冲突提示**：写入成功后固定带 `File > Revert` 提示（DESIGN §5 的决策 R5-A）。
6. **7 个工具**：config / status / ops / ls / apply / export / open；`aseprite_apply` 的说明
   内嵌全部算子与参数（R1-C）。
7. **测试隔离**：`config.mjs` 用 `DSH_ASEPRITE_HOME` 临时目录，不污染真配置。
8. **配置键迁移**：`extensionDir` → `luaRoot`（旧配置自动迁移；`luaRoot` 默认就是仓库根）。

**测试**：`config 24 + manifest 14 + smoke 19 = 57`（smoke 需真 Aseprite）+ 领域层 `ops_test 104`。
`register-check` 用临时 `@deepseek-ai/dsh-tools` stub 验证过：7 个工具、说明非空、apply 内嵌算子清单。

**安装状态**：profile 的依赖已改成 `file:D:/PraticleTool/Aseprite-AI`，并已 `node test/sync.mjs`
复制进 `~/.dsh/profiles/desktop/node_modules/dsh-plugin-aseprite` ——**重启 DSH 才生效**。

## 下一步

| 优先级 | 事项 | 备注 |
|---|---|---|
| P3 | 薄扩展 + ws 实时通道（P3 才需要从 `archive/extension` 取回旧扩展代码） | 先解决 GUI stale / Ctrl+S 覆盖问题 |

## 遗留风险

- 只测了 RGB、单帧、`saveAs`；indexed / grayscale / 多帧 / `--save-as` 路径未覆盖。
- 并发两次 apply 未处理（临时目录隔离了，但源文件会互踩）。
- GUI 里 Ctrl+S 是否真会覆盖 batch 改动：**仍未实测**（DESIGN §11）。
- 仓库名仍是 `aseprite-ai-pixel-copilot`，包名是 `dsh-plugin-aseprite` —— 改名是 GitHub 侧的事，未做。
