# dsh-plugin-aseprite

> ## ⛔ 已停止维护（2026-10-19 归档）
>
> 本仓库不再更新，代码保持原样，供参考或自行取用。**不要期待 issue/PR 有回应。**
>
> **最后状态（诚实版）**
>
> - 对话侧 7 个工具、领域层 10 个算子（含参数元数据）、P2 三块面板都已实现；
> - 本地测试全绿：`config 24 + manifest 14 + api 24 + client-load 4 + inject-wiring 8 + smoke 25 = 99`
>   （smoke 需真机）+ 领域层 `ops_test 104`；
> - **面板 405 的修复（`f1e83cf`，cordis 服务注入竞态 → `ctx.inject` 延迟挂路由）只过了单测，
>   没有在真机重启后确认过一次。** 重装后第一件事就是看面板是否还报 405；
> - 本机已卸载：profile 依赖与 `dsh.profile.bundles` 登记、`node_modules` 副本、
>   `~/.dsh/dsh-plugin-aseprite` 数据目录、`pnpm-lock.yaml` 引用全部移除。
>
> **想重新装回**：`git clone` → `node test/sync.mjs` → 按下面「装载方式」一节登记到 profile → 重启 DSH。
>
> **旧产品**（Aseprite 扩展 + Node 桥，v0.5.x–v0.6.1）在 tag `v0.6.1` 与分支 `archive/extension`；
> 领域层 `lib/ops.lua` 就是从那边迁过来的。

把 Aseprite 的能力接进 DeepSeek Harness。**UI 全在 DSH，Aseprite 侧零安装**（batch 路线）。
设计契约见 `DESIGN.md`（改行为先改那里）。

> 这个仓库 2026-10-18 起以插件为主产品。之前的 Aseprite 扩展 + Node 桥（v0.5.x–v0.6.1）
> 保留在 Git 历史里：`git show v0.6.1` / 分支 `archive/extension`。领域层 `lib/ops.lua`
> 就是从那边迁过来的，现在是本仓库的真源。

## 现在能做什么（P1b + P2）

**对话侧：7 个工具**

| 工具 | 作用 |
|---|---|
| `aseprite_config` | 读/改工作区、导出区、allowOutside、aseprite 路径、Lua 模块根 |
| `aseprite_status` | 版本 + 算子数 + 工作区设置 |
| `aseprite_ops` | 10 个算子及其**参数 schema / 默认值**（来自 `ops.manifest()`，不写死） |
| `aseprite_ls` | 列工作区里的 .ase/.aseprite/.png |
| `aseprite_apply` | 跑算子并保存：**覆盖前自动备份**、失败即中止、结果里带 GUI 冲突提示 |
| `aseprite_export` | 导出 PNG 等格式（默认落导出区） |
| `aseprite_open` | 用 GUI 打开文件，改完直接看图 |

**UI 侧：Aseprite Workbench（侧边栏 → 主区面板）**

- **文件列表**：工作区里的 .ase/.aseprite/.png，点击选中
- **画布预览**：`aseprite_export` 出的 PNG（棋盘底、像素化渲染），算子跑完自动刷新
- **算子台**：10 个算子按钮，跑 `ops.manifest()` 里的默认参数
- 顶部：刷新 / 用 Aseprite 打开 / 导出 PNG
- 底部：操作日志；每次操作**回显一行到当前会话**（宿主 `agent.inject`，不唤醒新一轮）

面板数据走两条宿主路由：`POST /aseprite/api/<method>` 与 `GET /aseprite/media?path=…`（同源校验 +
媒体白名单，只放行工作区/导出区内的文件）。

执行方式：`aseprite -b --script`（每次一个新进程，约 0.37s），**不需要在 Aseprite 里装任何东西**。

**备份**：写到 `<workspace>/_backup/<源相对路径>/<时间戳>_<原名>`，同一源文件只留最新 10 份。
备份失败（复制出错 / 大小不符）会**中止**，不写入任何东西。

**GUI 冲突**：batch 写盘后 Aseprite 不会自动重载，所以 `aseprite_apply` 的结果里会明确提示
`File > Revert`；在那之前从旧窗口 Ctrl+S 会覆盖本次改动（DESIGN §5）。

## 目录

```
lib/index.js          插件入口：defineTool × 7 + ctx.tools.register
lib/opsinfo.js        算子清单文本化 / 工具说明 / 冲突提示（不依赖 dsh，可单测）
lib/config.js         工作区 / 路径判定 / 备份（零 dsh 依赖，可单测）
lib/runner.js         批处理执行器（零 dsh 依赖，可脱离宿主单测）
lib/api.js            面板 API 表：列文件 / 预览 / apply / export / open + 媒体白名单
lib/routes.js         宿主路由：POST /aseprite/api/*、GET /aseprite/media + 会话回显
lib/ops.lua           领域层：10 个算子 + params 元数据 + ops.manifest()（唯一真源）
lib/util.lua          ops.lua 的公共小工具
lib/ops.manifest.json 由 ops.manifest() 生成的机器可读清单（别手改）
client/client.js      客户端 bundle：三块面板 + 宿主路由调用 + 操作日志/回显
test/config.mjs       路径 / 配置 / 备份单测（不需要 Aseprite）
test/manifest.mjs     清单与 ops.lua 一致性 + 工具说明生成（不需要 Aseprite）
test/api.mjs          面板 API / 路由信封 / 媒体白名单 / 回显降级（不需要 Aseprite）
test/client-load.mjs  客户端 bundle 外壳与插槽注册（不需要浏览器）
test/smoke.mjs        对真 Aseprite 的冒烟：建图 / 导出 / 算子 / 备份 / 越界拒绝 / 清单新鲜度
test/gen-manifest.mjs 从 ops.lua 重生成清单（--check 只校验是否过期）
test/lua/ops_test.lua 领域层 104 条无头断言（和旧仓库同一份测试）
test/sync.mjs         把插件同步进 desktop profile
test/register-check.mjs  用假 ctx 验证注册（需要 dsh-tools stub，见下）
```

## 跑测试

```bash
node test/config.mjs     # 24：路径 / 配置 / 备份
node test/manifest.mjs   # 14：清单一致性 + 工具说明生成
node test/api.mjs        # 24：面板 API / 路由 / 回显降级
node test/client-load.mjs # 4：客户端 bundle 外壳与插槽注册
node test/smoke.mjs      # 25：需要本机装了 Aseprite（含面板 API 真机路径）
node test/gen-manifest.mjs            # 改了 ops.lua 之后：重生成清单
node test/gen-manifest.mjs --check    # 只校验，过期 exit 1
aseprite -b --script test/lua/ops_test.lua   # 104：领域层断言
node test/sync.mjs       # 改完代码后同步进 profile，然后重启 DSH
```

`test/register-check.mjs` 需要 `@deepseek-ai/dsh-tools` 能被解析（只有 DSH 自己的模块映射能提供它）。
本地验证注册的办法：临时在 profile 的 `node_modules/@deepseek-ai/` 下放一个 `dsh-tools` stub
（`export const defineTool = (x) => x`），跑完删掉。已用此法验证过 7 个工具与内嵌算子清单。

## 装载方式（DSH 的 desktop profile）

`dsh plugin --profile desktop ...` 被 CLI 拒绝（"managed exclusively by the Electron application"），所以直接改文件：

1. `~/.dsh/profiles/desktop/package.json`：`dsh.profile.bundles` 加 `dsh-plugin-aseprite`，
   `dependencies` 写 `"dsh-plugin-aseprite": "file:D:/PraticleTool/Aseprite-AI"`
2. 包必须存在于 `~/.dsh/profiles/desktop/node_modules/dsh-plugin-aseprite`（用 `node test/sync.mjs` 复制）
3. 重启 DSH

**注意**：`package.json` 必须是 **UTF-8 无 BOM**（PS 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，导致 `JSON.parse` 失败、DSH 起不来）。

**注意**：junction 不行。Node 会把 junction 解析成真实路径，于是 `@deepseek-ai/dsh-tools` 解析不到；必须**复制**进 profile 的 node_modules。

## 客户端插槽（挖自 app.asar，非文档）

```js
ctx.slots.inject("sidebar.panellist", () => ctx.slots.register(
  { name: "sidebar.panellist", id: PANEL_ID, order: 40, label: () => "Aseprite" }, 条目组件));
ctx.slots.register({ name: "main", key: PANEL_ID }, 页面组件);   // 点进去的主区页面
```

客户端 bundle 外壳必须是 `window.__ModuleLoader__.load({ id, factory: (require) => ... })`，`react` 通过 `require` 注入，导出 `{ name, apply, inject }`。

## 下一步

- P2：面板薄版三块（文件列表 / 画布预览 / 算子台）+ 操作回显到主会话
- P3：薄扩展 + ws 实时通道（改你正在编辑的未保存画布；先解决 stale/覆盖问题）
