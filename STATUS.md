# AI Pixel Copilot — 当前进度与交接

给下次继续的自己/agent：先读这一页，再动手。

## v0.6.1：算子参数变成契约（ops.manifest），插件侧 P1b 落地

**为什么**：`dsh-plugin-aseprite`（DSH 插件，独立项目在 `D:\PraticleTool\dsh-plugin-aseprite`）
需要「算子叫什么、吃什么参数、默认值多少」的机器可读清单。以前只有 10 个名字 + 一句描述，
参数只活在实现里；插件面板要跑默认参数、对话要给模型填参数，都没有真源。

**改了什么**（`docs/RELEASE-v0.6.1.md` 有完整说明）：

1. `extension/lib/ops.lua`：OPS 表每项新增 `params`（10 算子 / 27 参数，
   字段 `name/type/required/default/desc`），并新增 `ops.manifest()`；
   `ops.describe()` 带出参数摘要（系统提示立刻变准）。**OPS 表是唯一真源。**
2. `ops_test` **97 → 104**：manifest 条数、每参数有 name+type+desc、必填项与默认值、
   region 覆盖 10 算子、describe 带摘要。
3. 插件侧 P1b 完成：vendor 了 `ops.lua`+`util.lua` 并用 `ops.manifest()` 生成清单、
   覆盖前自动备份（同源 10 份 / 失败即中止）、GUI 冲突提示、7 个工具、
   `test/config.mjs` 22 + `test/manifest.mjs` 14 + `test/smoke.mjs` 18 全绿。
   **插件从此不依赖本仓库的路径**。

**验证**：`tests/verify-v1.0.ps1` → **Lua 2004 通过 / 0 失败**（21 文件），
桥 **636 通过 / 3 失败**（仍是那 3 条施工前就有的 selftest 隔离失败）。
上游 **v0.6.1** 已推远程并打 tag（commit `71bbdf1`）。插件侧已同步进 desktop profile，**重启 DSH 生效**。

**下一步**：桥侧 `tools.mjs` 的 enum 也可以从 `ops.manifest()` 生成（现在仍是手写，第二份名单）。

## v1.0：架构重做为「三明治内核」+ UI 重做为工作台（未发版）

**一句话**：内核压到永不改动的小体积，能力全部推出内核成为可热装载/可自测/可回滚的**能力包**；
模型可以在**声明层修改自己**（提议 → 子进程验证 → 激活 → 回滚），并且这条链路的每一步都有护栏与断言。

设计契约（先冻结再施工，三路并行才成立）：`docs/arch-v1.0.md`、`docs/ui-v1.0.md`；交付说明 `docs/v1.0-delivery.md`。

**终值**：Lua **1601 通过 / 0 失败**（16 文件，含迭代二新增的 panel_contract_test 与 workbench_click_test）；桥 **636 通过 / 3 失败**（那 3 条是 v0.5.9 就有、纯净 worktree 同样失败的
测试隔离问题）。基线是 Lua 960/0、桥 470/3。

**迭代二（用户实测「面板点不动」）**：agent 的 panel 从未接到工作台（25 个方法只实现 6 个），已由 lib/panel_adapter.lua 补齐；
点击激活从 onmousedown 改回旧面板验证过的 onmouseup 语义。详见 docs/v1.0-delivery.md 第 8 节。

**真机 GUI 验收**：`tests/lua/gui_v1_{console,packs,offline}.png`，跑法 `tests/run_gui_v1.ps1`。
这一环抓到两个无头测不出的宿主陷阱，已固化成 kit_test 的不变式：
1. onpaint 里探测 userdata 上不存在的字段（`gc.flush`）是**抛错**不是返回 nil → 错误穿出事件处理器 → 进程消失（0xC000001D）；
2. `string.upper` 对中文做字节级大写会切出非法 UTF-8 → `gc:fillText` 崩。

**跑批**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\verify-v1.0.ps1`（显式清单，纯 ASCII ——
PS 5.1 读 UTF-8 无 BOM 脚本时中文正则会变乱码，这个坑踩过）。

**已知缺口（诚实清单，全在 docs/v1.0-delivery.md 第 6 节）**：C 层阻塞挡不住、Lua 侧 `out.ok` 无消费点、
纯 Lua 包无完整 verify 路径、授权框多一个、`resolveCels` 去重是有意的行为修正。

## 一句话状态（v0.5.9）


**v0.5.9：修掉二进制通道的根因（上传 / get_canvas 全死，正是 gaps.md #1 那条）+ 超时放宽且可调（180s/600s）+ 新增 sharpen / contrast 两个算子 + 小窗默认贴右下角。**
`docs/plan-v0.5.9-timeouts-ops-corner.md` 是这轮的计划与结论；`docs/plan-v0.5.8-conversations.md` 是上一轮。

**v0.5.8：对话一个对话一个文件、可以新建/切换/改名/删除；关面板或重启 Aseprite 后屏幕上那段记录会回放回来；压缩改成"留档"不再真删。**
GUI 端到端已在真实 Aseprite 里跑通并留下截图证据；中文像素字体（方舟 10px）已装好。
面板已重做成【终端式】（PowerShell / git-bash 观感）：回显 + 彩色输出 + 命令表 + 内建命令 +
贴边小面板，中英双语（默认中文），都已在真 Aseprite 里验证并截图。**
扩展已安装到 `%APPDATA%\Aseprite\extensions\ai-pixel-copilot`。
只差：填 API Key → 重启 Aseprite → 首次实跑。

**v0.5.7：最小化小窗补上输入行 —— 收起来以后照样能打字、而且看得见自己打了什么（gaps.md #2 的兑现）。**

### 本轮（未发版：apply_ops 图层语义 —— 「说了整张图，却只动了一层」）

用户实测后的原话是「我总觉得还是不能用啊」。翻 21:31–21:50 那轮真机对话
（`bridge/data/conversations/c-20261016-xt53.json`）定位到三条具体堵点，本轮先修最要命的一条：

1. **`apply_ops` 只作用于活动图层**（`ops.run` 拿 `app.activeCel`），而模型**无从知道**要传层：
   用户说"整体加对比度"，模型改的是当时活动的那一层，其余 4 层没动；甚至 `outline`
   改了 **0 像素**却回 `ok:true`，模型只好自己重新 `draw_art` 画一遍。现在：
   - `apply_ops` 新增 `layer`（单层）/ `layers`（`"all"` 或层名数组）；**都不给 = 活动层，老行为一字不变**。
   - Lua 侧新增 `ops.resolveCels(sprite, frame, spec)`：`"all"` = 当前帧所有有 cel 的层；
     层名写错时**报错并列出本文档的层名**（模型下一轮能自己纠正，不用猜）。
   - `ops.run(list, label, targets)` 接受 cel 列表：**一个事务 = 一步撤销**，逐层报告
     `perLayer`，总数放 `changed`。
   - **0 改动时回 `hint`**：列出别的层各有多少不透明像素，直接说"改错层了，重试用
     `layers:\"all\"`" —— 这是本轮最省事的自愈机制。
   - **多层 `quantize` 用并集直方图**：调色板是全图共享的，逐层各算一份会互相踩
     （后一层覆盖前一层的色表），所以 `op_quantize` 新增 `ctx` 参数、直方图数**所有目标层**。
   - 系统提示新增**规则 12d**（`bridge/config.example.json` 与本地 `config.json` 同步写入，
     改前已备份）；`apply_ops` 工具描述改写（默认活动层 / 整图要 `layers:"all"` /
     0 改动必须看 hint 再重试）。
2. **测试 +23**：`ops_test` 82 → **97**（四种规格的 resolveCels、层名报错、perLayer 汇总、
   0 改动 hint、并集直方图 3 色 → 2 色）；`workspace_test` **+8**（走真消息入口 `feed`
   打通 `msg.layers → 真画布`：两层都真的被改、层名写错报错、省 layers 时只动活动层）；
   `selftest` 152 → **155**（`layers:"all"` 原样下发 / `layer:"base"` 归一化成单层名 /
   不给就不下发 `layers`）。

**测试**：Lua **924** + 桥 **473** = **1397** 项全绿（`workspace_test` 的断言数会随工作区里的残留
测试产物逐次上涨，实测 229 → 235 → 239，全程 0 失败；`git status` 保持干净）。

### 本轮（v0.5.9：二进制通道 / 超时 / 锐化与对比 / 小窗贴角）

用户一口气提了四件事（原话在 plan 文档里）。**先查再动手**，查出两件事和说法不一样：

1. **"锐化/对比做不到"不是模型偷懒 —— 是根本没有这两个算子。** `ops.lua` 的 OPS 表只有 8 个，
   工具 schema 的 enum 也只有 8 个，模型连"能锐化"这件事都看不见。这就是"它说做不到"的机制。
2. **"超时太严格"是真的，而且两层都紧**：单次 120s、整轮 180s。后者尤其离谱 ——
   一轮最多 24 步、每步一次 HTTP，180s 连正常的多步作业都跑不完；而且撞上时抛的是 fetch 的
   `AbortError`，用户看到的是 `This operation was aborted`。

顺手挖出一个**比上面都严重**的真 bug（和这四条都无关）：

3. **`ws.lua` 的 `sendBinary` 把头部帧的语义 `type` 覆盖成了 `"binary_header"`**，
   桥认不出这个 type → **上传和 `get_canvas` 两条路全死**。这就是 `gaps.md` #1
   "perfect_pixel 读不到画布、连续三次超时"的根因。修法：`type` 原样保留，只用
   `binary = true` 标出"后面还跟着一个二进制帧"；桥侧 `sendImport` 同步改。
   新测试 `tests/lua/ws_test.lua`（20 项）钉住帧形状；**selftest 的假 Aseprite 以前说的是
   桥的方言（所以从没测出这个 bug），现在改成真客户端的方言**。

具体改动：

1. **超时**：`llm.mjs` 新增 `RequestTimeout`（只翻译"自己计时器踢的那一脚"，用户中断
   照旧走 `TurnAborted`）；单次默认 120s → **180s**，整轮 180s → **600s**；
   两条超时都给本地化文案（带秒数、指向设置窗）；设置窗新增两个字段（界面按秒填、桥收毫秒，
   单次夹 10–1800s、整轮夹 30–3600s）。
2. **`i18n.render(key, args, fallback)`**：带 `%d` 的文案按实参格式化；认不出键 / 缺实参 /
   格式化失败一律退回原文 —— **绝不把 `%d` 显示给用户**。回放行也带 `i18nArgs`
   （`pushLog` 第 4 个参数），重连回放时数字还在。
3. **两个新算子**（`sharpen` / `contrast`，逐通道、**alpha 一律不动**）：
   - `sharpen` = 3x3 非锐化掩模。**均值只统计不透明邻居** —— 把透明邻居当黑色算进去，
     剪影边缘会被整体提亮一圈，在透明背景上就是一圈脏边（像素画里最显眼的毛病）。
     另有 `threshold` 忽略带（保护平色与抖动网点）。
   - `contrast` = 以 `pivot`（默认 128）为轴乘开，`amount<1` 是压平。
   - 三处必须一致：`ops.names`（发给桥、进 `can.edit_ops`）、`tools.mjs` 的 enum、工具说明。
     由 `ops_test` 的"算子名单 == 契约"和 `tools_test` 的 P15 段**两头钉住**。
   - 系统提示加规则 **12c**（"边缘发虚 → sharpen；发灰发平 → contrast"）。
4. **小窗贴右下角**：贴位算式抽成纯函数 `panel.anchorFor(mode, W, H, bw, bh)`（好单测），
   `small` 从"贴右侧垂直居中"改成"贴右下角"；并且**只在真的换形态时才贴位**（`mode ~= prev`）
   —— 重连 / 保存设置都会重复 `setMode(同一形态)`，那不该把用户拖走的窗口拽回来。
   "可拖动"不用做：小窗本来就是带标题栏的独立浮动对话框，拖标题栏即可。

**测试**：Lua **871** + 桥 **470** = **1341** 项全绿。
`ops_test` 52 → 82；`settings_test` 36 → 44（超时秒/毫秒换算）；`panel_test` 242 → 254
（`anchorFor` 四分支 + `i18nArgs` 回放 + `render` 退化路径）；`tools_test` 180 → 188（P15 算子名单契约）；
`selftest` 140 → 152（场景 8b 断言带秒数 + 新场景 8d：单次请求超时给 `llmTimeout` + warn 级 +
文案里没有 aborted + `set_config` 越界夹取）；新增 `ws_test.lua` 20 项。
版本 0.5.9 已打包并本地安装。

### 本轮（v0.5.8：对话持久化 + 多对话）

用户的说法是"记忆和上下文不随窗口和软件关闭而消失，同时实现多对话管理"。**先查现状**，
结果和说法不完全一样（这一步很重要，省得白做）：

| 东西 | 存在哪 | 关面板 | 重启 Aseprite |
|---|---|---|---|
| 对话上下文（消息+摘要） | 桥 `data/history.json` | 在 | **在**（selftest 场景 13 早实证过） |
| 长期记忆 | 桥 `data/memory.json` | 在 | 在 |
| **面板滚回区（屏幕上那些字）** | **Lua 内存 `panel.lines`** | 在 | **没了** |
| 多对话 | 不存在（全桥一个文件，多开窗口还共用） | — | — |

所以"它忘了"其实是**打开面板一片空白**。另外查到第二个真缺口：**压缩会真删老消息**
（`compact()` 里 `messages = keep` 后落盘，被摘要掉的原文从磁盘上消失）。

1. **一个对话一个文件**：`data/conversations/<id>.json`，装 `messages + summary + archive + log`
   （`log` = 面板回放行）。活动对话 id 落 `config.json` 的 `activeConversation`。
   新建 `bridge/src/conversations.mjs`（`ConversationStore`），**`current` 是稳定引用** ——
   切对话只换 `file` 再 `load()`，所以 server 里所有 `history.xxx` 调用一行都没改。
2. **压缩留档**：`compact()` 两个分支都先 `archive.push(...drop)`（上限 2000 条）再 `messages = keep`。
   **摘要 = 不再发给模型，不等于删除。**
3. **连上就回放**：`hello` **先**发 `replay` 再发握手提示（反了的话提示会被回放清屏冲掉）；
   面板 `replayLines()` 是**替换**不是追加（桥是唯一真相来源）。带 `i18n` 键的行按当前语言重渲染。
   握手那几句连接噪声传 `record=false`，不进记录 —— 否则重连几次记录就被刷满。
4. **多对话用命令表那套交互**（用户选的）：`会话`/`chats` 列出对话表（编号、标题、条数、
   token，当前那条有标记），敲编号切换；表尾 `n` 新对话 / `r` 改名 / `d` 删除。
   为此把 `_printMenuTable` 抽成通用的 `Panel:openTable(rows, title, kind)`，
   并修掉"重打时写死重打命令表"（从对话表挑一行会把命令表顶上来）。
5. **改名/删除要参数 → `Panel:setPendingInput`**：下一行输入当参数。
   **故意不做"命令+空格+参数"的前缀匹配** —— 那会把"帮我打开 这张图"这种聊天文本误判成命令。
6. **删除是移进 `conversations/trash/`**，只剩一个时拒绝删；删当前那个要自动切走，
   且切换时**不能 save**（文件已经移走，save 会把它原地复活 —— 这条有专门测试）。
7. **迁移**：老的 `data/history.json` 自动变成第一个对话（标题从老消息派生，按
   `[User request]` 标记抠掉画布上下文那段），原文件改名 `history.json.migrated` 留底；幂等。
8. **AI 不能切对话**（不加工具，仍 25 个）：系统提示加规则 17c，告诉它这是用户侧命令，
   遇到"开个新对话"要如实指路 —— 否则它会去 `log_gap` 记一条假缺口。

**测试**：Lua **793** + 桥 **450** = **1243** 项全绿。
新增 `conversations_test.mjs` 23 项；`history_test` 19 → 24（留档 / 元数据往返 / reset 保留 id）；
`selftest` 100 → 140（场景 13 改读对话文件 + 新增场景 16：两个对话互不串味、重启桥还认、
删进回收站、删最后一个被拒、本地产的行也进回放、迁移）；`panel_test` 204 → 242；
`artop_test` 72 → 103；`gui_agent_probe` 加一步"喂 replay 真面板画出记录"（实跑通过）。
版本 0.5.8 已打包并本地安装。

### 本轮（v0.5.7：小窗补输入行 —— 第一条"做不到"被兑现）

v0.5.6 建好闭环后，`bridge/data/gaps.md` 里立刻躺着一条待处理（#2）：
"最小化成小窗之后还想直接打字下指令"。这轮就是**照那份文档干活**，闭环走通一遍：

1. **根因不是"没做输入框"，是"输入框没画出来"**。面板一直是 `原生 Entry 当输入点 +
   画布画正文` 的分工（中文在 `ui::Entry` 里上下会被切掉一半，实测截图
   `tests/lua/entry_cjk_zoom.png`）。小窗形态当初只画了「状态行 + 控件行」，
   于是打字时 **Entry 收到了键、画布什么都不显示** —— 看着像打不进去。
2. **小窗改成两行**：`360x56`（原 320x44）。第一行 = 状态 + 那串控件（右对齐），
   第二行 = 输入行（提示符 + 正文 + 光标，整幅宽）。空输入时显示
   `已最小化 —— 直接打字下指令`（这条 `smallHint` 以前是死文案，现在用上了）。
3. **命中区顺序是个坑**：`_barHitAt` 取**第一个**命中，而"点状态行还原"是整行热区 ——
   先登记它就会把控件点击全吞掉。现在**先画控件、先登记控件**，还原带只铺到控件左边
   （`x ∈ [0, clusterX-2]`），点输入行则落到 `_onCanvasMouseDown` 的兜底分支 → 焦点给输入框。
   无头 + 真 GUI 都有断言守着"还原带不压控件"。
4. **窗口高度的下限是 Aseprite 给的**：对话框 chrome（原生 Entry 行 + ⏎/… 按钮行）固定 47px，
   所以小窗窗口是 372x103 —— 比底边栏（952x107）**窄得多**但一样高。要更矮只能不要输入行，
   那就回到"打字看不见"，不做。
5. **`self.lineH` 现在三种形态都写**（以前只有面板路径写），探针靠它断言"画布够两行高"。
6. 收尾用 `node bridge/src/gaps.mjs done 2 --note "v0.5.7 做了…"` 关掉这条 ——
   待处理归零，已处理段里留下结论。**闭环（记录 → 我读 → 我补 → 回填）至此完整走过一遍。**

**测试**：Lua **718** + 桥 **382** = **1100** 项全绿（panel_test 193 → 204：新增
"输入正文真的画出来了 / 光标在状态行下方 / 空输入画提示语 / 还原带不压控件 / 窄到 120 也画正文"；
`gui_agent_probe.lua` 加了小窗两行高与还原带不重叠两条真 GUI 断言，实跑通过）。
版本 0.5.7 已打包并本地安装。

### 本轮（v0.5.6：做不到的请求自动落盘，开发者读了去补）

用户要"助手遇到做不到的请求时写进一份专门文档，然后你（开发者）再去修改更新"。做成闭环：

1. **`bridge/src/gaps.mjs`（新）**：记录 + 生成给人看的那份 markdown。
   - 记什么：原话 / 为什么做不到 / 给了什么变通 / 哪个工具 / 当时的模型 / 首次与最近时间
   - **同一条重复提只加计数**（归一化去掉标点大小写空白），超长截断，上限 200 条
     （满了淘汰"最久没被提到"的那条）
   - 写两份：`data/gaps.md`（人看）+ `data/gaps.md.json`（机器读，重启桥不丢）
   - **"已处理"段是手写区，重写文档时原样保留** —— 否则我写的结论会被下一次记录冲掉
     （这条专门有回归测试 G11）
2. **两条路都往里记**：
   - 模型主动调新工具 **`log_gap(request, why, workaround)`**；系统提示加了规则 17b
     （"做不到就要 (1) 记一笔 (2) 诚实告诉用户，别默默丢掉，也别把做成的事记进去"）
   - **桥自动兜底**：`makeDispatcher` 外面包了一层，工具结果里出现
     `unknown op / not supported / 只能 32 位 / cannot …` 这类词就自动记一笔，
     并把 `logged: true` 放回结果里告诉模型"已经记下了，不用补"
3. **面板能看到**：敲 `做不到` / `gaps` / `backlog`（命令表 `K` 键）→ 报条数、文件路径、
   最近一条；握手时若已有记录也会提一句。
4. **我这一侧的命令**：`node src/gaps.mjs list | done <id> --note "结论" | path`。
   已经用它关掉了第一条（状态栏按钮 → 做不到，附探针证据）。

**测试**：Lua **701** + 桥 **392** = **1093** 项全绿（新增 gaps_test 13 条 + selftest 场景 15
共 10 条断言：模型记录 / 重复只加计数 / 自动兜底 / gaps_info 查询）。
版本 0.5.6 已打包并本地安装。

### 本轮（v0.5.5：最小化小窗 + 控件几何重做「先量后画」）

1. **新增最小化小窗**（第 4 种形态 `small`，320x44 画布）：上面一行状态（带转圈/文件名），
   下面一行就是那串控件。**点状态行或末尾那颗「还原」方块都能回去**，任何宽度下都至少保留
   一个还原入口（不会变成死胡同 —— 专门有测试：窗口窄到 120px 也能点回去）。
   还原回**最小化之前**的形态（记住了 `lastMode`）。`B` 键的三态循环现在是四态
   （面板 -> 贴底 -> 贴侧边 -> 小窗）。
2. **控件几何重做：先量后画。** 用户说"按钮不够对称、有超越框的问题"，查下来是两个真 bug：
   - **宽度预算拍脑袋**：电量条的 `8.2k/16k` 标签按 48px 硬算，中文实际 ~90px；滑杆那一格
     还**漏算了它自己的文字标签**（"思考 medium" ~72px）。预算算小 → 整串控件往右溢出画到
     框外/画布外（实测差 42px+）。
     现在只有一处算尺寸（`_clusterCells` 用 `_textWidth` 实测），绘制照同一份数据走
     （`_drawCluster`），并在右侧留 4px 边距。
   - **方块不等高、滑块出框**：缩略图 16、贴边按钮 14x12，滑杆的滑块（半径 3）会顶到格子
     右边 4px 之外。现在**所有方块统一 16x16**、间距统一 6px、同一条中线对齐；滑杆的档位
     位置内缩 (半径+1)，滑块含半径永远在框内；文字一律按实测宽高居中（真字体下也不越框）。
   测试：四种形态都断言"方块等高 / 间距一致 / 不出画布"，无头和真 GUI 各一遍。
3. 顺带：控件串末尾多了「最小化/还原」方块；`_clusterPlan` 改成三级降级
   （全都要 -> 去文字标签 -> 去「＋」方块 -> 整体不画），侧边栏用更小的文字预留（60px）。

**测试**：Lua **689** + 桥 **356** = **1045** 项全绿（panel 187）；真 GUI 探针新增两条：
四形态几何检查、最小化真的变小窗口并还原。

### 本轮（v0.5.4：修「切形态控件就没了」+ 贴边切换按钮）

用户报的 bug + 一个新按钮要求，两条都做完。

1. **严重 BUG：切形态后上下文电量条 / 思考滑杆不见了。** 根因是这三件控件我只画在
   `_paintBar` 里 —— 切回**面板**形态（用户截图里那条黑条）就整套消失。
   现在把控件区抽成面板与栏**共用**的一段（`_clusterPlan` 算宽度预算 + `_drawCluster`
   画一串），三种形态都在**输入行**上（和光标同一行、右对齐）。
   鼠标命中也不再限定栏模式（`_onBarMouseDown` 以前被 `if self:isBar()` 挡在面板模式外）。
   顺带加固：窗口矮到放不下状态行+输入行时，宁可重叠也不能把输入行和控件画到画布外
   （`inputY` 夹进画布；面板模式的 `inputTop` 同样夹一下）。测试覆盖栏高 60/40/28/20
   与面板高 420/120/60，控件都在画布内。
2. **贴边切换按钮**：在控件串末尾加了一个图标按钮（画的是「小窗口 + 贴住底边/右边的高亮」，
   不依赖字体字形），点一下在 **贴底 与 贴侧边** 之间切（面板模式下点它 = 去贴底）。
   两态切换，不会绕回面板 —— 三态循环仍归 `bar` 命令 / `B` 键。
3. **做不成的那部分说清楚**：用户想把按钮放进 Aseprite 自己的**米色状态栏**（和它现有的
   输入框、回车、… 按钮并排）。探针实测 `app` 只暴露
   `command fs os params pixelColor preferences theme` 七个成员 —— **没有 `app.ui`、
   `app.window`（-b 下为 nil）、`app.menus`，`app.command` 里也没有状态栏相关命令**，
   所以脚本**没有**任何途径往 Aseprite 的状态栏加控件。按钮只能做在我们自己的面板/栏里
   （也就是黑条那一行），这也正是它现在的位置。探针：`tests/lua/_statusbar_api_probe.lua`。

**测试**：Lua **667** + 桥 **356** = **1023** 项全绿（panel 从 153 涨到 171）；真 GUI 探针新增两条：三种形态都必须有五个控件、
点贴边按钮真的切换（含真窗口 bounds 变化）。版本 0.5.4 已打包并本地安装。

### 本轮（v0.5.3：自动减色 + 输入行上的三件控件）

用户实测后提了 5 条，全部做完。

1. **"这个任务都做不到？要支持"** —— 截图里它答"我做不到自动量化"。**根因是工具表里确实没有**：
   只有 `replace_color` / `palette_map`（都要显式映射表）。新增算子 **`quantize(colors)`**：
   在 Lua 侧做**中位切分**（按像素数中位切、盒子按用量排序），把用色数压到 N 以内、
   同步重写调色板，保留 alpha、透明像素不参与也不改；颜色数本来就 ≤N 时返回 0 改动并说明原因。
   - 桥侧：`apply_ops` 的 enum/描述加上它，系统提示加规则 12b（"配色太杂/合并到 N 色 → quantize"）。
   - 测试 21 条：64 色 → 8 色真的只剩 ≤8 色、调色板大小=合并后色数、四色图的色系没被并错、
     区域限定、全透明图、参数校验、`colors=1/999` 被拒。
2. **底边栏三件控件**（一开始做成了占满右侧一大块，用户说"太大了，不能放在和输入框同一行吗"，
   于是**改成和输入框同一行、右对齐、16px 高**，不额外占高度）：
   - **工作图片缩略图 + `＋`**：当前文档实时缩略图（自己按层合成 —— `sprite:flatten()`
     是**破坏性的**，实测 2 层真被合成 1 层，绝不能用），点图或点 `＋` 换新图。
   - **上下文电量条**：**20 格** + `8.2k/16k` 短标签（窄了自动去掉），绿/琥珀/红三档；点击报用量。
     数据来自桥的新 `context` 消息（每个 status 都推一次，握手/压缩/改预算也推）。
   - **思考强度滑杆**：4 档，点/拖都行。**松手才提交**（拖拽中只动视觉，否则一次拖动写 4 次配置）。
     踩过的坑：提交的判据必须是"和已写回桥的那一档不同"，跟当前显示值比永远不会提交。
3. **selftest 的隔离 bug（顺带发现的真问题）**：selftest 的桥没配 `paths.history`，
   于是写到**真的** `bridge/data/history.json` —— 场景之间互相"记得"，而且**自动压缩会偷吃
   mock LLM 的脚本步**，导致 11 项断言莫名失败。修：测试配置里加 `history: test/.tmp/...`，
   并删掉那份 52KB 的污染文件。

**测试**：Lua **637** + 桥 **353** = **990** 项全绿。
（Lua: menu 89 / ops 52 / versions 20 / sizelib 23 / artlib 40 / artop 72 / path 5 / panel 153 /
workspace 147 / settings 36；桥: selftest 90 / tools 177 / styles 47 / memory 23 / history 19。）
途中还发现 mock Aseprite 把 ops 结果平铺着回（真实 Lua 是包在 `report` 里），等于以前的
`run_ops` 回传内容从来没被校验过 —— 改对之后场景 14 才真的能断言"减色前后色数回到了模型上下文"。
真 GUI 探针 `run_gui_agent.sh` 追加三条断言：四个控件都画出来、缩略图采到的是画布真色
（中心 `0xFFBDE0FF` 奶油 / 角落 `0xFFDE862E` 蓝，注意 getPixel 是 0xAABBGGRR）、真鼠标点滑杆能改档。
版本 0.5.3 已打包并本地安装。

### 本轮（v0.5.2：4 条实测问题的修复 + 上下文管理）

用户实测后提了 4 条，全部做完。**这一轮的核心是"上下文管理"**（用户原话：
"AI 似乎现在没有记忆和上下文"）。

1. **0 像素却报成功**（最严重）：`artlib.lua` 的 `stampGrid` 用 `str:sub()` 按**字节**切行，
   而 .aseprite-keys / 视觉行宽都按**字符** —— 一个中文像素字符 3 字节，宽高全对不上，
   于是一行都画不出来，却一路报"已画 0 像素"直到撞上 8 步上限。
   改成 `utf8.codes` 逐字符切行；`painted == 0` 现在一律当**失败**上报，并带上透明字符统计
   （`.` / 空格各多少个）——"什么都没画"再也不算成功。桥侧行宽也改成按码点算（`[...str].length`）。
   复现探针 `tests/lua/_draw_probe.lua` 留在仓库里。
2. **上下文管理（新模块 `bridge/src/history.mjs`）**：
   - **落盘**：对话写 `bridge/data/history.json`，重启桥 / 重启 Aseprite 都接得上；
     握手时会提示"已恢复上次会话的上下文"。
   - **压缩**：按 **token 预算**（默认 16000，估算 2.5 字符 ≈ 1 token）而不是条数；
     超了就把最老的一段交给 LLM 摘要，摘要常驻系统提示（`buildSystemPrompt` 每步重取）。
     摘要失败/为空时**不压缩**——宁可涨 token，也不把上下文弄丢。
   - **安全**：落盘前剪掉半截的工具调用组（中断时会出现），否则下一轮 API 直接 400。
   - **清空**：内建命令 `forget` / `清空上下文`（命令表 M 键）。
3. **窗口一输入文字就撑大**：`dlg:modify` 触发的重排会按内容自然尺寸把窗口拉回去；
   新增 `Panel:_preserveBounds` 包住每一次 `modify`，改完把 bounds 还原。
4. **图层/文件命名强制英文**（路径安全）：桥侧加 `isAsciiName` 校验（`draw_art` / `add_layer` /
   风格名），内置风格的图层名改成英文（`Body` / `Outline`），中文只走 `label` 显示名。

**顺带把三个"写死"的值变成可配**（用户问："上下文要不要设上限？八步会不会不够？可以放在底部调？"）：

- **步数上限**：8 → **24**（它才是"画不完"的直接原因），设置窗里 1–200 可调；
  撞上限的文案改成"已达本轮步数上限，说『继续』我就接着做"（有上下文记忆后，"继续"真的能接上）。
- **上下文上限**：默认 16000 token，设置窗里 1000–200000 可调，改完**立刻生效**（不用重启桥）。
- **温度 / 思考强度**：设置窗里可填；思考强度只在选了 auto 以外的值时才发 `reasoning_effort`，
  端点不认（400/422）时**自动去掉重试一次**并提示用户，绝不因此连不上。
- 放哪：**设置窗**，不是底边栏 —— 底边栏只有 60px 高、输入区就占满了，塞不下输入框。
  顺带修了设置窗的一个数据丢失：工作区 / 栏底色以前不会回填，一按保存就把它们清空。

**测试**：Lua **542** + 桥 **351** = **893** 项全绿。
（Lua: menu 89 / ops 31 / versions 20 / sizelib 23 / artlib 40 / artop 72 / path 5 / panel 97 /
workspace 129 / settings 36；桥: selftest 85 / tools 177 / styles 47 / memory 23 / history 19。）
版本 0.5.2 已打包并本地安装。

### 收尾一轮（v0.5.1：4 条追加需求的缺口）

用户把"打开文档 / 缩成栏并融入 / 上传进工作区 / 能力边界要诚实"又提了一遍并要求
"先做计划再执行"。计划在 `docs/plan-v0.5.1-gaps.md`，做法是**先验证这 4 条已经实现**
（跑对应测试拿证据），再只补查出来的 7 个缺口（G1~G7）：

- **G1 桥侧测试盲区**（最高优先级）：`open_document` / `list_workspace` 在桥侧几乎没覆盖
  （tools_test 只有工具名、selftest 零覆盖）——正是 v0.4.0 踩过的"字段名对不上但两边全绿"。
  补了转发断言 + 端到端场景（含打开失败的错误回传）。
- **G2 底边栏看不到"正在执行的指令"**：栏高 44 只够 2 行，`rows >= 3` 的条件把最后一行输出
  挡掉了。改成 60（3 行），真 GUI 截图确认：`\ 正在执行 draw_art… ｜ hero.ase` +
  最后一行日志 + 输入行。
- **G3 形态不持久**：存进 `config.json` 的 `ui.mode`，启动按它恢复（quiet 模式，不刷日志）。
- **G5 "完美融入"**：先把"主题色读不到"从猜变成证 ——
  `app.theme.color["window_face"]` 和 `["zzzz"]` **都返回 0,0,0**（真名假名一样 = 兜底对象）。
  所以给设置里加了「Bar colour」，用户填自己主题的十六进制底色。
- **G4** 面板加「打开文件…」（O 键，原生选择器，只打开不矫正；P 键才是按路径打开）。
- **G6** `capabilities` 带上 `workspace{enabled,root}`、`ui_mode`、`openable_extensions`
  —— 模型回答"能不能备份/能不能开这个"时不再含糊。
- **G7** `list_workspace` 每项带 `size`（`app.fs.fileSize`）。

**测试**：Lua 463 + 桥 290 = 753 项全绿。版本 0.5.1 已打包并本地安装。

### 上一轮（交互修正 + 工作区，v0.5.0）

用户实测 v0.4.0 后提了 10 条 + 追加 4 条，全部做完。策划案在
`docs/plan-v0.5.0-ux-workflow.md`（**照着它做的话，先读它的"已验证事实"和"禁止事项"**）。

**这一轮最有价值的三个发现（都是探针跑出来的，不是猜的）**：

1. **窗口"点一下跳回原大小"的根因**（P4）：每次点画布都会 `dlg:modify{id="input",focus=true}`，
   而 `modify` 触发一次重新布局，Aseprite 会把窗口**按内容自然尺寸撑回去** ——
   实测 320×220 点一下就变回 672×467。修法：记下第一次绘制时的"自然尺寸"，
   只有当焦点确实不在输入框**且**窗口还是自然尺寸时才 modify（`panel.lua` 的
   `_windowIsNatural`）。**顺序也很关键**：`setMode` 里必须先 modify 再设 bounds，
   反过来 bounds 会被那次布局冲掉。
2. **"已矫正过的图还被再次矫正"的根因**（P8）：Perfect Pixel 的自动网格检测只找
   **≥4 倍**的上采样因子（`detectGridScale` 的 `minSize=4`），1px 一格的真像素画
   梯度峰值间距太小 → 判定"无网格"。所以用户看到的是"检测失败 → 模型重试 gridSize →
   开出一个和输入一模一样的文档"。修法：桥侧明确说"这是 1:1 真像素画、不用处理、
   **别重试**"，并且同一轮内同一来源重复调用直接挡掉。
3. **`saveCopyAs` 失败时**只打印错误、**不抛异常**（实测写不存在的盘符时 pcall 仍然成功）。
   工作区备份如果不额外校验，就会"备份失败照样改"—— 这是这一项最不能接受的失败方式。
   现在写完立刻 `fileExists()` 读回来确认（`workspace.lua`）。

**这一轮新增的东西**：
- `lib/workspace.lua`（P10/P13）：备份 → 副本 → 打开副本 → 交付四分支；上传图先复制进
  工作区；`listFiles` 走原生 `app.fs.listFiles`；相对路径按工作区根解析（P11）。
  **开副本之后 `app.activeSprite` 就是副本，所有算子代码一行没改** —— 这是设计的关键。
- **选项式提问**（P7）：`ask_user` 工具 + 协议 `ask`/`answer` + 面板**双通道**
  （终端敲数字/字母、原生按钮窗点选），关窗 = 取消，连来两个 ask 自动取消前一个。
- **中断**（P3）：`abort` 帧 + 桥侧 `AbortController`（手动/超时给不同提示）+
  轮级 `maxTurnMs`(默认 180s) + Lua 侧「停止/Esc」。
- **状态指示**（P2）：`Timer` 驱动的转圈（只在忙时转）+ 状态栏四色 + 断联红字提示行 +
  动态状态文案本地化（`working (step 3)...` → `正在处理（第 3 步）…`）。
- **能力清单**（P14）：`capabilities` 工具，内容**从真实注册表生成**，
  测试里和 `TOOLS` 交叉核对（防漂移），列了一份诚实的 `cannot`。
- **三种形态**（P12）：面板 / 底边栏 / 侧边栏，敲「栏 / bar」循环。

**Aseprite 的硬限制（查过了，别浪费时间再试）**：
- 没有"给对话框设最小尺寸"的 API；`autoscaling` 开或关都拦不住缩小（能缩到 40×30）。
  → 兜底：小于阈值时改画一行"窗口太小，请拖大一点"。
- `app.window` 只有 `width`/`height`（960×564），**没有** `bounds`/`x`/`y`；
  `app.workspace` 是 nil；`app.theme` 只暴露一个 `color` 成员。
  → 所以做不到真·停靠，"栏模式"是浮条；但按 `width`/`height` 能把栏贴到右下角。
- 脚本的 Security 授权框是**本体**的（英文），扩展改不了 → 写进 README 当作说明。

**测试**：Lua 416 项（新增 panel 75 / workspace 80）+ 桥 266 项（新增 ask/capabilities/
中断/幂等场景）。全部绿。`tests/lua/*_probe.lua` 是探针（只能靠真 Aseprite 问出答案的问题）。

### 上一轮（风格包 + 作画，v0.4.0）

让助手从"只能改图"变成"能自己画"：**风格约束 + 字符网格作画**。核心思路是用户要的
"约束 AI 写命令并执行"——**模型只输出结构化参数，像素由确定性 Lua 代码落下去**。

**风格库**（`bridge/src/styles.mjs`，工具 `style_list` / `style_use` / `style_save`）：
- 一个风格 = 调色板 + 推荐尺寸 + 图层结构 + 作画规矩
- 内置 `pixel-icon` / `stardew` / `flat-minimal`；自定义落在 `bridge/data/styles/*.json`
- **三层优先级：用户目录 > 仓库 `styles/` > 代码内置**（`all()` 里三次 Object.assign）
- **省 token 的关键**：`describe()` 只渲染**当前那一个**风格（实测 278 字符），
  不是把整库塞进 prompt。`styles_test.mjs` 里有条断言专门查"别的风格的颜色有没有漏进来"
- 当前风格名持久化在 `config.json` 的 `activeStyle`，重启桥还记得

**作画**（`extension/lib/artlib.lua`，工具 `new_sprite` / `add_layer` / `draw_art`）：
- `stampGrid(img, rows, palette, x, y)`：一个字符 = 一个像素，配 字符→颜色 表
- **省 token**：16×16 用字符网格约 100 token，坐标数组要几千；而且行宽写歪会被挡住
- **出界不是静默丢弃**：返回 `skippedOutOfBounds`，面板另起一行提示"有 N 像素落在画布外"
- `ensureLayer` 找不到就建，**并且把名字设上去**（这里踩过坑：`spr:newLayer()`
  出来的层叫 "Layer"，不改名的话后面按名字找图层全部落空 —— artlib_test 里 4 项就是这么挂的）
- 整个网格是**一个**撤销步骤（`app.transaction` 包住）
- 桥侧 `draw_art` 先校验一遍（空 rows / 行宽不一致 / 字符没进调色板），
  报错能指出是第几行，省一次 Lua 往返

**提示词**：`config.example.json` 的 `systemPrompt` 加 10~13 条（风格怎么用、
字符网格格式、分趟作画、新建文档流程）。`config.json` 同步更新了（不进版本库）。

**踩到的一个真 bug（值得记）**：`runTurn` 原本在**进循环之前**把 systemPrompt 定死，
于是模型在同一轮里 `style_use` 换的风格要到**下一轮**才生效 ——
"换个星露谷风格，画个 16×16 的小人"这种一句话指令，画出来的还是旧风格。
改成传函数（`systemPrompt` 可以是 `() => string`），循环里**每步重取**一次
（`messages[0] = {...}`）。内容没变时不多花 token。selftest 场景 7 专门钉住这条：
断言第 1 步没有风格段、`style_use` 之后的第 2 步就有。

**测试**：新增 artlib 30 + artop 40 + styles 41，tools 分发从 46 涨到 85（覆盖 20 个工具），
selftest 22 → 32（多了场景 7：style_use → new_sprite → draw_art 的端到端链路）。
合计 Lua 238 + 桥 181 = **419 项**全绿。

`artop_test.lua` 是这轮加的**协议层**测试，补的是前两轮留下的一个盲区：
`artlib_test` 只证明"函数调对了"，但桥发的字段名（`layer` / `palette` / `rows` / `x` / `y`）
和 `agent.lua` 读的 `msg.xxx` 一旦对不上，函数单测全绿也没用。
做法是构造**真的 Agent**（`agent.new` 在 `-b` 无头模式下能构造，已实测），
把 `send` / `panel` 换成假的，然后喂协议消息进去断言画布真的变了。
40 项覆盖：new_sprite / add_layer / draw_art 的字段名、行宽写歪时画布不动、
出界计数、crop / scale / canvas_size 的 size_result、未知消息不炸。

**另一个坑（install.ps1）**：扩展启动时优先用 `<扩展目录>/bridge/dist/bridge.mjs`，
而打包脚本正好把 bundle 生成在 `extension/bridge/`。于是"打过一次包"之后，
源码安装的副本会**静默跑到旧 bundle 上**，改 `bridge/src` 不生效。
install.ps1 现在复制完会删掉目标目录里的 `bridge/`，源码安装就跑源码。

### 上一轮（尺寸能力 + 通用记忆）

**新增三个文档级尺寸工具**，解决"AI 分不清裁剪和缩放"：
- `crop` —— 切画布，**像素原样保留**（去掉留白用这个）
- `scale` —— 整幅重采样到新尺寸（nearest / bilinear）
- `canvas_size` —— 只改画布，内容按锚点摆位、尺寸不变
- `canvas_info` 现在额外返回 `contentBounds` + 四边 `padding` + `contentRatio`，
  AI 据此判断"留白多 → 该裁剪，铺满 → 该缩放"

**重要实现细节（实测）**：`sprite:crop()` 和 `CanvasSize` **不重采样像素** ——
它们只改画布尺寸 + 挪 `cel.position`（crop 后 position 变成 -8,-8，`image` 内容原封不动）。
这就是"裁剪不重采样"的底层保证，`sizelib_test.lua` 就按这个断言。

**通用记忆库**（`bridge/src/memory.mjs`）：
- 工具 `remember` / `recall` / `forget`，分类 color / style / preference / project / note
- **省 token 的三条硬设计**：永不注入 prompt（只按需 recall）、单条截断 400 字、
  总量 500 条且超限时按 `usedCount` 淘汰
- 每次 recall 命中的条目 `usedCount` +1 → **越用越留得住**（这就是"进化"）
- 和旧色值库并存：`remember_color` / `search_colors` 保持可用

**测试**：新增 sizelib 23 + memory 23 + tools 分发 46 项；
加上原有的 menu 89 / ops 31 / versions 20 / path 5 / 桥自测 22，共 **259 项**全绿。

### 上一轮（单文件安装 + 跨平台）

- **能打成单文件 `.aseprite-extension` 了**（`tools/pack-extension.ps1`）。这个格式就是 zip，
  压缩包内路径 = 扩展目录的相对路径、`package.json` 必须在根
  （依据 Aseprite 自己的 `src/app/extensions_tests.cpp:98` 构造方式）。
  两个坑：`Compress-Archive` **只认 `.zip` 后缀**（先打 zip 再改名）；
  它生成的条目路径是正斜杠（实测合规）。
- **桥也 bundle 进包了**，所以单文件安装**只要系统有 Node.js，不用 clone、不用 npm install**：
  - `bridge/scripts/bundle-for-extension.mjs` 用 **esbuild 的 Node API**（不是 spawn npx：
    Windows 上 npx 实际是 `npx.cmd`，`execFileSync('npx', ...)` 找不到）。
  - `ws` 是 CJS，bundle 成 ESM 后它内部 `require('events')` 会报
    "Dynamic require of events is not supported" → 必须注入 `createRequire` banner。
  - `bufferutil` / `utf-8-validate` 是 ws 的可选 native 加速模块，`--external` 排除。
  - Perfect Pixel 核心是**运行时动态 import** 的（`perfectpixel.mjs` 里 `import(file://…)`），
    esbuild 打不进去 → 作为文件一起放（`bridge/vendor/perfectPixel.mjs`）。
  - bundle 放在 `extension/bridge/dist/bridge.mjs`，这样 `ROOT = HERE/..` 正好是 `bridge/`，
    config / vendor / data 的相对路径全部对上，不用传 `--config`。
- **扩展优先用自带的桥**：`bridgeEntry()` 先看 `<ext>/bridge/dist/bridge.mjs` 在不在，
  没有才回落到仓库的 `bridge/src/server.mjs`。两条装法共用一份代码。
- **跨平台**：起桥按 `package.config:sub(1,1)` 判断（`\` = Windows → `start /MIN`；
  否则 `nohup … &`）。Aseprite 用的是 **Lua 5.4，没有 `jit.os`**，别想着用 LuaJIT 那套。
- **桥缺失时不再静默失败**：面板里直接打出该做什么（换带桥的包 / 克隆仓库跑 install.ps1 /
  确认装了 Node）。
- 实测：把包解压到扩展目录、**删掉 `__project.lua`**（模拟纯单文件安装），
  桥能独立启动、自动从 `config.example.json` 生成配置、`/health` 返回 `{"ok":true}`。
- 版本号统一到 **0.2.0**（`extension/package.json`、`bridge/package.json`、`main.lua` 之前不一致）。

### 上一轮（输入修复 + 底部行 + 小面板位置 + 菜单瘦身）

- **退格只能删一个字 —— 已修**。根因：哨兵机制每次变化后把 Entry 重置成"一个空格"，
  而 `Entry::onSetText` **只把 caret 往下 clamp、不会挪到末尾**（entry.cpp:506），
  退格把 caret 留在 0；caret 在 0 时前面没字符，再按退格 Entry 内容不变 ->
  `onchange` 不再触发 -> 死住。修法：退格后让焦点绕一圈
  （`modify{ id="send", focus=true }` 再 `modify{ id="input", focus=true }`），
  触发 `kFocusEnterMessage -> selectAllText() -> setCaretPos(lastCaretPos())`
  把 caret 送到末尾（entry.cpp:283-295）。**只在退格时绕**，打字时不绕，
  免得频繁关开输入法打断 IME。
  验证：`bash tests/run_key_test.sh`（真键盘 SendKeys 发 3 次退格，预填 abc 被删空）。
- **底部那块黑画布撤掉了**。它只能占自己那一格，格子四周是对话框 grid 的主题 padding、
  涂不到，于是黑块被一圈米色框住，比原来的米色横条更突兀（用户实测反馈）。
  grid padding 没暴露给 Lua，想让整条底边变黑只能改主题（会波及整个 Aseprite）。
- **菜单只留一条**：`main.lua` 原先给 6 个命令都写了 `group = "file_scripts"`，
  于是 `File > Scripts` 里冒出 6 条 `AI: ...`（用户投诉"打开 Aseprite 有很多插件"）。
  现在只给 `ai_pixel_copilot_open` 留 group，其余命令**不写 group** ——
  Aseprite 只在 group 非空时才建菜单项（`plugin_class.cpp:Plugin_newCommand`
  "Add a new menu option if the group is defined"），但命令照常注册，
  `keys.aseprite-keys` 的快捷键（Ctrl+Shift+M / Ctrl+Shift+P）仍然可用。
- **第三方扩展 `paletton-color-wheel` 已移出**（10/1 装的色轮，不是本项目的；
  它的 `__pref.lua` 还是全默认值，说明只试装没用起来；且它和我们的 Ctrl+Shift+P 撞键）。
  移到了 `%APPDATA%\Aseprite\extensions.disabled\paletton-color-wheel`，**没删**，想恢复移回去即可。
- **别去动 Aseprite 安装目录自带的 14 个扩展**：`<Aseprite 安装目录>\data\extensions\`
  下那 14 个（`*-palettes` / `aseprite-theme` / `bayer-matrices`）是官方资源包，
  `contributes` 里只有 `palettes`/`themes`/`ditheringMatrices`、**没有 `scripts`**，
  所以**不注册命令、不占 `File > Scripts` 菜单**；删了会丢 pico8 / dawnbringer / endesga
  等调色板和 Bayer 抖动矩阵。它们只在 `Edit > Preferences > Extensions` 和调色板列表里出现。
- **哨兵字符从 NBSP 改成普通空格**：NBSP 字体缺字形，Aseprite 画成一条**红条**（实测截图）。
  现在 `local SENTINEL = " "`，`gsub(SENTINEL, "", 1)` 只吃一个哨兵（用户自己敲的空格留得住）。
- **小面板改贴"对话窗"右下角**：`Mini:show(anchor)` 接一个 Rectangle，
  由 `Panel:_anchorBounds()` 把 `self.dlg.bounds` 传下去（只在 shown 时读，避免
  `Dialog_get_bounds` 的 autoRemap 副作用），读不到才退回主窗口右下角。
- **Entry 里不能显示正文**：中文在原生 `ui::Entry` 里上下会被切掉一半（`tests/lua/entry_cjk_zoom.png`），
  所以"entry 当输入点 + canvas 画输入内容"这个分工不能改回"entry 直接显示全文"。
- **已知硬限制（别再试）**：原生按钮尺寸 = max(文本, 主题最小尺寸)，Lua 无法设尺寸
  （`Dialog:modify` 无 setMinSize）；回车磁吸按钮**必须可见**才吃 ENTER
  （`button.cpp:95`）；`ui::Entry` 只暴露 `onchange`（没有 onkeydown）。
  → "按钮刚好和符号一样大" 与 "回车提交" 在原生控件下**不可兼得**，
  想做到只能把按钮改成 canvas 自绘，代价是丢掉回车提交（或改用别的触发键）。

## 已完成且已验证

| 部分 | 文件 | 验证方式 | 结果 |
|---|---|---|---|
| 安全算子 | `extension/lib/ops.lua` | 无头测试 `tests/lua/ops_test.lua` | 31/31 |
| 快照/回滚/版本栈 | `extension/lib/versions.lua` | 无头测试 `tests/lua/versions_test.lua` | 20/20 |
| 桥 + 工具链 + 色值库 | `bridge/src/*.mjs` | 端到端 `bridge/test/selftest.mjs`（mock LLM + mock Aseprite） | 22/22 |
| Perfect Pixel 接入 | `bridge/vendor/perfectPixel.mjs` | 合成伪像素画 64x64 | 精确还原 16x16 |
| **面板 GUI + WebSocket + 算子回路** | 整个扩展 | **真 Aseprite + 真桥 + mock LLM**，`tests/run_gui_visual.sh` | **通过，见 `tests/lua/gui_panel_e2e.png`** |
| **终端式面板（回显/内建命令/命令表/小面板）** | `extension/lib/{panel,menu,miniwindow,i18n}.lua` + `agent.lua` | GUI `bash tests/run_gui_visual.sh --term`（+ `--term-en`） + 无头 `tests/lua/menu_test.lua` | **通过：`gui_term_menu.png`/`gui_term_palette.png`/`gui_term_en_menu.png`；89/89** |
| 中文像素字体 | `<Aseprite 安装目录>\data\fonts\` | A/B 像素比对 + 截图 | 中文墨高 18px vs 拉丁 14px，比例协调 |

## 复现测试

```bash
# 无头 Lua 套件：11 个文件，2026-10-16 实测 924 项全绿
aseprite.exe -b --script tests/lua/ops_test.lua        # 104（算子 + 目标层 layers + manifest 契约）
aseprite.exe -b --script tests/lua/artop_test.lua      # 103（协议层：桥的消息 -> 真动画布）
aseprite.exe -b --script tests/lua/workspace_test.lua  # 229+（工作区；需要 ASE_PROJ=<repo 根>；断言数随残留产物漂移）
aseprite.exe -b --script tests/lua/panel_test.lua      # 254
aseprite.exe -b --script tests/lua/menu_test.lua       # 89
aseprite.exe -b --script tests/lua/settings_test.lua   # 44
aseprite.exe -b --script tests/lua/artlib_test.lua     # 40
aseprite.exe -b --script tests/lua/sizelib_test.lua    # 23
aseprite.exe -b --script tests/lua/versions_test.lua   # 20
aseprite.exe -b --script tests/lua/ws_test.lua         # 20
aseprite.exe -b --script tests/lua/path_test.lua       # 5

# 桥套件：7 个文件，实测 473 项全绿
cd bridge && npm test

# GUI 可视化验证（会短暂弹 Aseprite 窗口，探针跑完自动截图）
bash tests/run_gui_agent.sh tests/lua/gui_agent_shot.png   # 末尾应见 RESULT=DONE + extension restored
bash tests/run_gui_bar.sh   tests/lua/gui_bar_shot.png
```

⚠️ **`tests/run_gui_visual.sh` 已过期，别用**：它给探针写的 `[script_access]` 清单漏了
`__project.lua`，Aseprite 会弹**原生安全授权框**把探针挡在门外（截到的只有弹框，
`%TEMP%\gui_visual.log` 是 0 字节）；它第 94 行还 `cd "$PROJ/bridge"`，相对 `-Out`
会落到错误目录。改用 `run_gui_agent.sh` / `run_gui_bar.sh`。

⚠️ 截图 `-Out` **必须传绝对路径**；`.sh` 脚本要用 **Git Bash**
（`C:\Program Files\Git\bin\bash.exe`）—— PATH 里的 `bash` 是 WSL，`/D:/...` 路径会直接失败。

⚠️ 无环境（`env` 为空）的自动化 runner 直接跑 `aseprite.exe -b` 会崩：
`Error creating directory`（找不到 `%APPDATA%`）并留下 `memory.dmp`。
至少要补 `APPDATA` / `USERPROFILE` / `TEMP` 三个变量。

GUI 截图里能看到完整证据链：
`Connected to local bridge` → `Bridge ready. Aseprite 1.3.18.6-dev, 7 ops available.` →
AI 回复 → `Auto-backed up v1 "before: 红色换蓝色"` → `Applied 1 op(s) ... replace_color: 256 px`
→ `PROBE: RESULT=OK`（画布像素真的从红变蓝）。

截图用 `tests/shot_window.ps1`：默认走 **PrintWindow**（抓窗口自身内容，**不抢前台**、
不会拍到同屏幕位置上别的程序）；`-Method foreground` 是旧的前台方案，会校验前台窗口确实是
Aseprite，不是就**拒绝截图**（防隐私泄露）。

`run_gui_agent.sh` / `run_gui_bar.sh` 在探针期间把**已安装的扩展目录**挪到
`%APPDATA%\Aseprite\_extensions_parked_ai-pixel-copilot`（`extensions/` 之外），
这样 `__project.lua` 不会被读、也就不会弹原生授权框；跑完**无条件还原**扩展目录与
`aseprite.ini`（`scripts.show_run_script_alert=false` 等）。

## 关键实现约束（踩过的坑，别重复踩）

### 撤销与像素
1. **`Image:putPixel` / `image.bytes =` 不记录撤销信息**。只有 `clear/drawImage` 这类走 `Tx`+`cmd::`
   的 API 才可撤销。算子一律"在游离 Image 上算完 → `drawImage(..., BlendMode.SRC)` 一次性写回"。
2. **`image.bytes`** 是整块连续缓冲（RGBA 字节序），可读可写 → 无逐像素性能问题，也无需 PNG 编解码，
   像素直接走 WebSocket 二进制帧。
3. **回滚用 `cel.image = 新图像` 会让旧 image 变量失效**，之后必须重新取 `cel.image`。

### 对话框与输入
4. **中文输入必须用 `dlg:entry`**：只有 `ui::Entry`/`ui::TextEdit` 会开 IME（`src/ui/entry.cpp:170`）。
5. **回车提交靠"磁吸按钮"**：`focus=true` 的按钮会捕获 ENTER（`src/ui/button.cpp:106`）。
   `focus=true` 放 Send 按钮，输入框另用 `dlg:modify{id="input", focus=true}` 拿焦点。
6. `dlg` 没有多行文本控件；日志区用 canvas 自绘（`gc:fillText`/`measureText`/`onwheel`）。

### 模块与权限
7. **`require` 只在 `init()` 作用域内可用**（`extensions.cpp:902`）→ 所有模块在 init 里加载完、存 upvalue。
8. **扩展只在启动时加载**；`Rescan Scripts Folder`（`cmd_refresh.cpp:45`）不重载扩展 → 改扩展必须重启。
9. **权限授权**（`security.cpp`）：`io.open/popen`、`os.execute/remove/rename`、`WebSocket` 首次调用弹授权框。
   键 = **脚本"源文件名"的 sha1**（小写 hex，`security.cpp:79` + `convert_to.cpp`），值 = 权限位掩码