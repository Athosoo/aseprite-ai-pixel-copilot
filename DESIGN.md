# dsh-plugin-aseprite · 设计 v1.0（已定案）

> 三轮 grilling 的全部决策。每条都标了「为什么」，便于以后推翻时有据可依。
> 定案时间：2026-10-18。实现前必须与本文件一致；要改先改这里。

---

## 1. 定位

在 DSH 里用自然语言驱动 Aseprite 改图。**UI 全在 DSH，Aseprite 侧零安装**。
batch（`aseprite -b --script`）为基座；实时通道（薄扩展）排 P3，不是现在。

**为什么**：Aseprite 的宿主能力面太窄（4 个绘图原语、6 种控件、无事件模型、require 仅 init 作用域），
把 UI 放进去等于用最受限的画布做最复杂的界面。DSH 侧是浏览器，成本差一个数量级。

---

## 2. 分层

```
UI       client/client.js       侧边栏条目 + 工作台页面（文件列表 / 预览 / 算子键）
工具体   lib/index.js           7 个 defineTool
         lib/opsinfo.js         清单文本化 / 工具说明 / 冲突提示（纯函数，可单测）
边界体   lib/config.js          workspace / exportDir / allowOutside / 路径判定 / 备份
执行体   lib/runner.js          spawn aseprite -b --script，文本契约，超时
领域体   lib/ops.lua             10 个算子 + params 元数据 + ops.manifest()（本仓库真源）
         lib/util.lua           ops.lua 的公共小工具
         lib/ops.manifest.json  由 ops.manifest() 生成的机器可读清单
```
三层的依赖是单向的：UI → 工具 → （边界 / 执行 / 领域）。runner 与 config 零 dsh 依赖，可脱离宿主单测。

---

## 3. 工具面（7 个）

| 工具 | 作用 | 关键行为 |
|---|---|---|
| `aseprite_config` | 读/改工作区、导出区、allowOutside、aseprite 路径 | 落盘到 `~/.dsh/dsh-plugin-aseprite/config.json` |
| `aseprite_status` | 版本 + 算子数 + 当前工作区设置 | 出问题先查这个 |
| `aseprite_ops` | 算子清单（名字 + 描述 + 参数 schema） | 从 `ops.manifest()` **动态生成**，不写死 |
| `aseprite_ls` | 列工作区里的 .ase/.aseprite/.png | 让模型自己找文件，不用反问用户 |
| `aseprite_apply` | 跑算子并保存 | 覆盖前自动备份；备份失败即中止；返回冲突提示 |
| `aseprite_export` | 导出（默认落导出区） | 不传 out → `<exportDir>/<stem>.png` |
| `aseprite_open` | 用 GUI 打开文件 | `aseprite <file>`，改完看图的路径 |

**算子清单内嵌进 `aseprite_apply` 的描述**（决策 R1-C）：10 个算子塞进一个描述，比 10 个独立 tool 便宜得多；
`aseprite_ops` 保留作兜底。

---

## 4. 安全模型

| 规则 | 值 | 为什么 |
|---|---|---|
| 工作区根 | `~/.dsh/dsh-plugin-aseprite/workspace` | 相对路径按它解析 |
| 导出区 | `<workspace>/_export` | 自动建 |
| 工作区外访问 | **默认拒绝**，`allowOutside=true` 才放行 | 工具能写任意绝对路径 = 一次幻觉毁一个文件 |
| 覆盖前备份 | 复制到 `<workspace>/_backup/<相对路径>/<时间戳>_<原名>` | 默认行为必须可后悔 |
| 备份保留 | **按源文件各留 10 份** | 热点文件不挤掉冷门文件的备份 |
| 备份失败 | **中止操作，什么都不改** | 没有备份的写入等于没有后悔药 |

---

## 5. GUI 冲突（实测结论，非推断）

实测（Aseprite 1.3.18.6-dev）：GUI 打开同一 .ase 时 batch 写入**成功**（exit 0、磁盘确实变），
但 **GUI 不会自动重载**，界面仍是旧内容，也没有「文件已改变」提示。

**处理（决策 R5-A）：照常写，结果里强提示**——

> 文件已写入磁盘。Aseprite 里打开的那份需要 File > Revert 才会更新；
> 在此之前不要 Ctrl+S，否则会用旧内容覆盖本次改动。

**为什么不检测/GUI 拒绝**：Windows 上判断「某文件被某进程打开」需要 handle 扫描，不可靠；
而「Aseprite 在运行」并不等于「它开着这个文件」，误报会让人频繁被打断。

**未实测的高风险项**（单独立项验证）：用户在 GUI 里 Ctrl+S 是否真会覆盖 batch 改动。

---

## 6. 已知的执行坑（必须遵守）

1. **不能拿 exit code / stdout 判成功**：PowerShell 用 `&` 调 GUI 子系统程序会立刻返回，真实写入异步落盘。
   我们的 runner 用 `spawn` + 等 `exit` + 读结果文件，天然正确（冒烟 9/9 证）。
2. **Lua 脚本必须自己把结果写文件**，不依赖管道——避免捕获失败被误判为无输出。
3. 每次调用约 **0.37 秒**（一次调用里跑完一串算子，不要一个算子一次进程）。

---

## 7. UI 面板（薄版三块，一次做）

| 块 | 内容 |
|---|---|
| 文件列表 | 工作区里的 .ase/.aseprite/.png，点击选中并预览 |
| 画布预览 | 当前帧合成图（`aseprite_export` 出的 PNG），**算子跑完自动刷新** + 手动刷新按钮 |
| 算子台 | 10 个算子按钮，**跑默认参数**（contrast 1.5 / sharpen 1.0 / quantize 64…） |

**参数怎么给**（决策 R3-C）：按钮跑默认值；要精细调参就去对话里说一句让模型填。
面板负责快，对话负责准，两者不重复。

**回显**（决策 R4-B）：面板上的操作要在主会话里回显一行「已执行 contrast → 1024 px」。
否则你回对话时模型以为画布还是旧的，会基于错误前提继续改。

**不做的**：不在面板里实现对话（DSH 已有一流会话）。多帧切换、图层显隐不做（R4-A：只预览当前帧合成图）。

---

## 8. 里程碑与验收

| 阶段 | 内容 | 验收判据 |
|---|---|---|
| **P1b**（完成） | 领域层 + params 元数据；备份；冲突提示；算子清单动态生成；清单生成脚本 | `test/config.mjs` 24 + `test/manifest.mjs` 14 + `test/smoke.mjs` 19 + `test/lua/ops_test.lua` 104 全绿；备份真的生成；越界真的拒绝 |
| **P2** | 面板薄版三块 + 回显 | 侧边栏点进去能选文件、看预览、点按钮改图并看到变化 |
| **P3** | 薄扩展 + ws 实时通道（改你正在编辑的未保存画布） | 需重新走一遍安装与授权；**首个要解决的正是第 5 节的 stale/覆盖问题** |

---

## 9. 领域层归属（v0.6.1 之后的定案）

**背景变化**：v0.6.1 之前 ops.lua 在旧仓库（扩展产品），插件只是 vendored 副本；2026-10-18
仓库合并后，插件成为主产品，**旧仓库降级为 Git 历史**（tag `v0.6.1` / 分支 `archive/extension`）。

1. 上游先把 `params` 元数据加进 OPS 表并发布 **v0.6.1**（commit `71bbdf1`），ops 测试 97 → 104；
2. 合并时把 `ops.lua` + `util.lua` + `ops_test.lua` **搬进本仓库**（`lib/`、`test/lua/`），
   插件从此不依赖任何外部 checkout；
3. 清单由 `test/gen-manifest.mjs` 生成 `lib/ops.manifest.json`：跑真 Aseprite 的 `ops.manifest()`
   再序列化成 JSON，**不在 JS 里解析 Lua 源码**（OPS 表是唯一真源，解析源码等于造第二个真源）；
4. `test/manifest.mjs`（不需要 Aseprite）校验清单条数、名字集合与 `ops.lua` 一致；
   `test/smoke.mjs`（需要 Aseprite）重跑一遍 `ops.manifest()` 对比文件，**清单过期即红**。

**运行时**只读 `lib/ops.manifest.json`，不额外 spawn Aseprite。

---

## 10. 明确不做（YAGNI）

- 不做插件市场、不做多语言、不做图层合成预览、不在面板里重做对话
- 不做「检测文件是否被 GUI 占用」（不可靠）
- 不做 npm 发布（决策 R2-A：先本地私有，能用了再说）

---

## 11. 遗留风险登记

| 风险 | 状态 |
|---|---|
| GUI 里 Ctrl+S 覆盖 batch 改动 | **未实测**，高风险，P3 前必须验 |
| 只测了 RGB/单帧/saveAs；indexed、grayscale、多帧、`--save-as` 路径未测 | 未覆盖 |
| 并发：两次 apply 同时跑 | 未处理（临时目录已隔离，但源文件会互踩） |
