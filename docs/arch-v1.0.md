# AI Pixel Copilot · 架构 v1.0（三明治内核）

> 状态：**契约已冻结**。本文件是 v0.6.0 的施工图 —— 四个并行子任务的接口在此之前定死，
> 任何人不得单方面改签名；要改先改本文件并通知调度者。
> 决策基线：D1 声明层自扩展 · D2 工作台式 UI · D3 设计+可运行骨架 · D4 数据与快捷键全兼容 · D5 延迟优先。

---

## 1. 设计意图

v0.5.x 的能力是真的，但结构是**长出来的**，不是**设计出来的**：

| 症状 | 证据 | 后果 |
|---|---|---|
| 算子名单硬编码两处 | `ops.lua` 的 OPS 表 8 项、`tools.mjs` 的 enum 8 项 | STATUS.md 自证：模型"连能锐化这件事都看不见"，只能回"做不到" |
| 工具箱是一个静态数组 | `tools.mjs` 的 `TOOLS = [...]` + 单 `makeDispatcher` | 加一个工具要改桥源码、重新打包、重启 |
| 视图是手绘的一整块 | `panel.lua` 1700 行单体 | 换布局=重写；加一屏=在一千七百行里找位置 |
| 缺陷只记不修 | `gaps.md` 有账本，无闭环 | 同一个坑会再踩一次 |
| 扩展不能热更新 | Aseprite 只在启动加载扩展 | 任何"自我改进"都被重启卡死 |

**v1.0 的一句话**：把「内核」压到尽可能小且永不改动，把「能力」全部推出内核之外，
变成**可热装载、可自测、可回滚的能力包**；内核只负责总线、注册表、宿主适配、
视图原语、沙箱与账本。

> 判据：**新增一项能力，是否需要改内核？** 若需要，说明分层错了。

---

## 2. 三层结构

```
┌──────────────────────────── Aseprite（Lua 5.4） ────────────────────────────┐
│                                                                          │
│  KERNEL  —— 永不被模型修改，约 900 行，六个模块                             │
│   ┌────────┬──────────┬────────┬────────┬────────┬────────┐              │
│   │  bus   │ registry │  host  │  kit   │  dsl   │ ledger │              │
│   │ 事件   │ 能力表   │ 宿主   │ 视图   │ 沙箱   │ 账本   │              │
│   └────────┴──────────┴────────┴────────┴────────┴────────┘              │
│   ─────────────────────────────────────────────────────────────────────  │
│  WORKBENCH —— 通用渲染壳（三区布局），只认 registry，不认具体视图           │
│   ─────────────────────────────────────────────────────────────────────  │
│  PACKS  —— 可自扩展，模型可写                                             │
│   builtin/  ops · size · styles · memory · console · gallery · packs     │
│   user/     %APPDATA%\Aseprite\ai-pixel-copilot\packs\<id>\  ← 模型生成   │
└──────────────────────────────────────────────────────────────────────────┘
                                   │ WebSocket（帧协议向后兼容，只增不改）
┌──────────────────────────── Node 桥 ─────────────────────────────────────┐
│  KERNEL   server.mjs（薄）· bus · registry · journal                     │
│  SERVICES llm · memory · styles · conversations · perfectpixel            │
│  PACKS    bridge/packs/<id>/{manifest.json,tools.mjs,tests.mjs}           │
│  EVOLUTION propose → sandbox → verify → activate → rollback               │
└──────────────────────────────────────────────────────────────────────────┘
```

三层的依赖方向**严格单向**：`packs → workbench → kernel`，反向 import 一律视为 bug。

---

## 3. Lua 内核契约（已冻结）

### 3.1 `kernel/bus.lua`
```lua
Bus.new()                      -> bus
bus:on(name, fn)               -> id
bus:off(id)
bus:emit(name, payload)        -- 同步派发；handler 抛错被捕获并记入 journal，不影响其它 handler
bus:drain()                    -- 处理队列中由 ws 回调推入的事件（GUI 定时器里调）
```
固定事件名：`ws.open` `ws.close` `ws.error` `msg` `binary` `ui.invalidate`
`pack.changed` `pack.error` `log` `ask` `turn.start` `turn.end`

### 3.2 `kernel/registry.lua`
```lua
Registry.new()                 -> reg
reg:define(kind, spec)         -> ok, err      -- 同 kind+id 重复注册 = 覆盖（用于热重载）
reg:get(kind, id)              -> spec | nil
reg:list(kind)                 -> spec[]       -- 已按 spec.order 稳定排序
reg:remove(kind, id)
reg:kinds()                    -> string[]
reg:fingerprint()              -> string       -- 任何变更后变化；UI 据此失效缓存
```
`kind` 只有五种，规格形状**冻结**：

| kind | 规格字段 |
|---|---|
| `view` | `id, title, icon, order, params?, mount(ctx)->view, refresh(view,ctx), unmount?(view)` |
| `command` | `id, title, keys?, hint?, run(ctx, arg)` |
| `op` | `name, label, params, run(host, params)->{changed,elided,detail}` |
| `action` | `id, run(ctx, arg)` |
| `tool` | `name, description, inputSchema, run(ctx, input)` —— 仅桥侧权威，Lua 仅缓存用于展示 |

`spec.order` 缺省 100；`icon` 是单字形或短串（工作台左轨用）。

### 3.3 `kernel/host.lua` —— 唯一允许调用 `app.*` / `Sprite` / `Image` 的地方
```lua
Host.new(app)                  -> host
host:active()                  -> { document, sprite, layer, frame, cel, image, name } | nil
host:resolveCels(sprite, frame, spec) -> cels | nil, err
      -- spec: nil=活动cel | "all"=当前帧全部有cel的层 | {names...} | name
      -- 语义与 v0.5.9 完全一致（含"层名写错要报错并列出层名"）
host:apply(label, fn)          -> ok, err     -- 事务包裹：fn 内改动 = 一步撤销
host:drawCells(cels, imageFn)  -> changed     -- 游离 Image 算完 → drawImage(SRC) 一次写回
host:openDocument(path)        -> doc | nil, err
host:alert(text), host:notify(msg, tone), host:filePicker(cb)
host:versions()                -> 版本栈对象（平移 lib/versions.lua，接口不变）
```
**铁律**：算子与视图里**不得**出现 `app.`、`Sprite{`、`Image{` 字面量；一律走 host。
这条是让 Lua 侧可被无头单测的唯一前提（v0.5.x 已经靠 `feed` 消息入口做到一半）。

### 3.4 `kernel/kit.lua` —— 视图原语（无 aseprite 依赖，纯 GC + 命中测试）
```lua
Kit.new(gc, theme)             -> kit
kit:measure(text, style)       -> w, h
kit:text(xy, text, style)      -> rect
kit:field(rect, label, value)  -> rect        -- 键值行
kit:list(rect, items, state)   -> layout      -- items: {text,tone,badge?,cmd?}
kit:button(rect, label, opts)  -> rect
kit:badge(rect, text, tone)    -> rect
kit:hit(rect, x, y)            -> bool
kit:tone(name)                 -> color       -- ok/warn/err/dim/accent
kit:theme()                    -> theme
```
`kit` **不做布局决策**（没有 flex）；布局归视图。这样样式可测：给定 rect 集合与状态，
输出绘制调用序列 —— 单测断言调用序列即可。

### 3.5 `kernel/dsl.lua`
```lua
Dsl.load(src, name, perms)     -> fn | nil, err
Dsl.loadFile(path, name, perms)-> fn | nil, err
Dsl.env(perms)                 -> env        -- 白名单：io / os / net（debug 永不开放）
```
`Dsl.load` = `load(src, "@"..name, "t", env)`。已验证：Aseprite 1.3.18.6-dev 的 Lua 5.4
支持该调用且 env 隔离生效（`tests/lua/_kernel_probe.lua`）。
无 `perms` 时 `io/os/net` 全部不可见；**沙箱抛错一律转成 `nil, err`，绝不冒泡到 UI**。

### 3.6 `kernel/ledger.lua`
```lua
Ledger.new(dir)                -> l
l:scan()                       -> packs[]     -- 发现 packs/*/manifest.json
l:install(srcDir)              -> ok, err
l:enable(id), l:disable(id), l:rollback(id)
l:health()                     -> { [id] = {calls, fails, lastErr, msAvg} }
l:journal(event)               -- 追加 JSONL，环形上限 2000 行
```

---

## 4. 能力包格式（已冻结）

```
packs/<id>/
  manifest.json     # 必填，声明式，模型唯一必须写对的文件
  main.lua          # 必填：return function(ctx) end，ctx = {registry, host, kit, dsl, log}
  tests.lua         # 建议：return { {name=..., run=function(t) end} }
  bridge/
    tools.mjs       # 可选：export default { tools: [ {name,description,inputSchema,run} ] }
    tests.mjs       # 可选
```

`manifest.json` 冻结形状：
```json
{
  "id": "sharpen-pack",
  "name": "锐化与对比",
  "version": "1.0.0",
  "api": 1,
  "permissions": ["io"],
  "views":    [{ "id": "packs.sharp", "title": "锐化", "icon": "◈", "order": 40 }],
  "commands": [{ "id": "sharp.run", "title": "锐化边缘" }],
  "ops":      [{ "name": "sharpen" }, { "name": "contrast" }],
  "requires": ["core"]
}
```
约束：
- `api` 必须等于内核支持的版本（当前 `1`），不等则**拒装并给出可读理由**。
- `permissions` 是闭集 `["io","os"]`；声明 `io` 才能读写工作区。
- `ops[].name` 与桥侧工具 `name` 必须同名 —— 这是"模型看得见 = 能调用 = 真能跑"的同一条线。
- 一个包加载失败**不得**影响其它包：失败写入 `ledger.health()[id].lastErr`，UI「扩展」页标红。

**加载顺序**：`builtin/` 先，`user/` 后；同 id 时 user 覆盖 builtin（便于模型"改进"内置能力而不动内核）。

---

## 5. 桥侧契约（已冻结）

### 5.1 `bridge/src/registry.mjs`
```js
createRegistry({ journal }) -> { define(spec), list(), get(name), remove(name), fingerprint() }
// spec: { name, description, inputSchema, run(ctx, input), pack, meta: {since, evolved} }
```
`tools.mjs` 的静态 `TOOLS` 数组**保留为** `builtin/tools/*.mjs` 的聚合结果 —— 对外形状不变，
旧测试（`tools_test.mjs` 的 P15 段、`selftest` 的交叉核对）必须继续绿。

### 5.2 `bridge/src/packs.mjs`
```js
loadPacks({ dirs, registry, journal }) -> { loaded: PackInfo[], errors: {id,err}[] }
// PackInfo: { id, name, version, dir, tools: string[] }
```
每个 pack 的 `tools.mjs` 用**动态 import + cache-busting query**（`?v=<mtime>`）实现热重载 ——
这是 Node 侧"自我扩展"的关键，避免进程重启。

### 5.3 `bridge/src/evolution.mjs` —— 自扩展闭环
```js
journal(event)                              // JSONL，环形 5000 行
propose({ id, files, rationale })  -> { staged, digest }
verify({ staged })                 -> { ok, results:[{name,ok,ms,err}] }   // 子进程跑 tests.mjs，硬超时
activate({ staged })               -> { id, previous }
rollback({ id })                   -> { ok, restoredTo }
health()                           -> { [id]: {calls, fails, msAvg} }
```

### 5.4 新增 WS 帧（旧 type 一个不动）
| type | 方向 | 载荷 |
|---|---|---|
| `cap.list` / `cap.result` | Lua ⇄ 桥 | 能力清单（按 query 过滤，**不常驻 prompt**） |
| `pack.propose` / `pack.verify` / `pack.activate` / `pack.rollback` | Lua → 桥 | 见 evolution |
| `pack.changed` | 桥 → Lua | {id, action} → Lua 侧热装载 |
| `view.invalidate` | 双向 | 视图脏标记 |

### 5.5 模型可见的新工具（**只增不减**）
`list_capabilities(query)` `propose_pack` `verify_pack` `activate_pack` `rollback_pack` `pack_health`

---

## 6. 自扩展闭环（"允许接入的模型修改自己"）

```
 观察                      提议                    验证                  启用/回退
journal/gaps  ──▶  propose_pack(files)  ──▶  verify_pack  ──▶  activate_pack
（工具失败/unknown op/      （写进 staging/，     （node 子进程跑       （写 packs/<id>/，
  用户纠正/慢调用/           不碰 active）         tests.mjs，硬超时）    Lua 热装载）
  "做不到" 自述）                                                          │
       ▲                                                                    ▼
       └──────────────── pack_health：失败率超阈值 → 自动 rollback ◀───── 现网表现
```

五条护栏（任何一条不满足就不许 activate）：
1. **不可写内核**：staging 目录之外的文件写入由桥侧路径白名单拒绝。
2. **必须自测**：`tests.mjs` 不存在或 0 断言 → `verify` 直接不通过。
3. **必须同名**：`manifest.ops[].name` 必须在桥侧注册表里真实存在且可调用。
4. **必须可回滚**：activate 前自动快照上一版；失败自动回退（保留最近 3 个版本）。
5. **预算**：单轮会话最多 3 次 propose；单包源码 ≤ 200 行 / 32KB；超出即拒。

**保持快速**的三条硬手段：
- 能力包**不进常驻 prompt**；模型用 `list_capabilities(query)` 按需检索（tool-search 模式）。
- 工具 schema 懒构造：`fingerprint()` 未变则不重算、不重发。
- Lua 侧视图**脏区重绘**：只有 `ui.invalidate` 命中的那块重画，不做整屏重绘。

---

## 7. 兼容性（D4 硬要求）

| 资产 | 处理 |
|---|---|
| `bridge/config.json` | 原键全读；新增键一律有默认值 |
| `bridge/data/*`（conversations/styles/memory/gaps/colors） | 格式不变，直接读 |
| 8 个算子 | 全部保留，签名不变；sharpen / contrast 平移入 builtin 包 |
| 快捷键 Ctrl+Shift+A / +M / +P | 不变；keys.aseprite-keys 不改 |
| main.lua 的 6 个命令 id | 全部保留（菜单仍只挂 1 条） |
| 旧 WS 帧 | 一个不改，只增新 type |

---

## 8. 风险与验证

| 风险 | 证伪方式 |
|---|---|
| Lua `load` 在 GUI 下与 `-b` 行为不同 | GUI 探针：装载一个测试包并截图（T4） |
| 动态 `import()` 的 cache-busting 在 Node 24 上失效 | `packs_test.mjs` 断言改文件后 fingerprint 变化 |
| 三区自绘在中文字体下测量漂移 | golden-layout 单测 + GUI 截图比对 |
| 并行四路合流时接口漂移 | 本文件第 3/5 节的冻结签名；合流只允许"填空" |
| 性能回退 | `tests/bench/` 基准：首屏 <150ms、输入回显 <30ms、本地工具开销 <50ms |

---

## 9. 不做的事（YAGNI）

- 不做插件市场、不做依赖解析、不做沙箱内多语言（只 Lua + JS）。
- 不做模型的强类型代码生成；能力包是**声明 + 少量片段**，不是"让模型写一个大项目"。
- 不改 Aseprite 源码，不重编译。
- 不为 GUI 引入第三方 UI 库（Aseprite 的 Lua 沙箱里没有）。
