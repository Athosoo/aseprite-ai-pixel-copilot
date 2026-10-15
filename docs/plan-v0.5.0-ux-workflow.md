# v0.5.0 策划案：交互修正 + 状态/中断 + 工作区交付流

> **给执行者（DeepSeek-flash）**：这份文档就是完整任务书。每条工作项都给了
> 定位（文件:行）、方案、验收标准和测试命令。**先读第 1、2 节再动手**，
> 按 M1 → M5 的顺序做，每个里程碑做完跑对应的测试，全部绿了再进下一个。
> 不确定的地方先写探针脚本验证，**禁止靠猜改代码**。

---

## 0. 背景（一段话）

这是 Aseprite 的 AI 对话扩展「AI Pixel Copilot」。结构：
`extension/`（Lua，跑在 Aseprite 里，自绘终端式面板）
↔ WebSocket ↔ `bridge/`（Node，本地桥，调 OpenAI 兼容 LLM）。
AI 只输出结构化参数，像素由确定性 Lua 代码落下去。用户实测 v0.4.0 后提了 10 条反馈，
本策划案把它们变成 10 个工作项（P1~P10）。

用户提到"可参考开源 harness 如 DSH 和 ZCode"。相关模式**已吸收进本文档的具体设计**，
执行时**不需要联网读外部仓库**：

- 工具调用循环里的**中断标志 + 每步检查**（→ P3）
- **AskUserQuestion 式选项工具**：模型发问 → UI 弹选项 → 用户点选 → 答案作为工具结果回传（→ P7）
- **超时分级**：单次 HTTP 超时 < 单轮对话总超时（→ P3）

---

## 1. 先读清单（动手前必读，都在仓库里）

| 文件 | 为什么要读 |
|---|---|
| `STATUS.md` | 进度交接 + 所有踩过的坑（控件限制、Lua 坑、BOM/LF）。**先读这一页** |
| `README.md` 的"能力""限制"两节 | 知道现有功能边界，别重复造 |
| `extension/lib/panel.lua` | 终端面板（P1/P2/P4/P7 都改这里） |
| `extension/lib/agent.lua` | 消息分发（P3/P7/P10 改这里） |
| `bridge/src/server.mjs` `bridge/src/llm.mjs` `bridge/src/tools.mjs` | 桥侧（P3/P7/P8 改这里） |

### 硬约束（改回去就会坏，全部有测试钉着）

1. **`.lua` 必须 LF 行尾**，**`.ps1` 必须 UTF-8 带 BOM**（PowerShell 5 按 GBK 读无 BOM 的
   中文注释会搞坏引号配对）。`.gitattributes` 已锁，别动它。
2. **Aseprite 是 Lua 5.4，没有 `jit.os`**。平台判断用 `package.config:sub(1,1)`。
3. **对话框控件限制**（都实测过，STATUS.md 有细节）：
   - 按钮尺寸在**创建时**定死，之后改不了；同行按钮要 `samerow` 挂到 entry 后面才不会被拉满行。
   - canvas 只能占自己的格子，格子外的 padding 涂不到颜色。
   - `Entry` 只有 `onchange`，没有光标 API；输入框靠**空格哨兵 + 焦点往返**维持光标在末尾
     （`panel.lua` 的 `SENTINEL` 和 `_resetEntry`，**别拆**）。
   - `dlg.bounds` **只在窗口可见时读**——不可见时读会触发 autoRemap 把窗口重新居中
     （`panel.lua:518` 的 `_anchorBounds` 有注释）。
   - `dlg.bounds = Rectangle(...)` 可以写（miniwindow 用它挪位置），但没有 onResize 事件。
4. **`bridge/config.json` 含 API Key，永不提交**；只提交 `config.example.json`。
5. **源码里不写绝对路径**。测试脚本用 `$ASE_PROJ` 环境变量（缺省当前目录）。
6. git 提交作者必须是 `Athosoo <226670423+Athosoo@users.noreply.github.com>`
   （仓库 local config 已配好，别改）。
7. **不要 push、不要做 Release**。本机 push 需要 GH_TOKEN + 7890 代理的特定环境，
   策划案只做代码和本地验证。commit 可以打，推送留给主会话。

### 跑测试（都在仓库根执行）

```bash
# Lua 无头单测（"-b" 是 Aseprite 批处理模式，不弹窗）
ASE_PROJ="$PWD" "D:/PraticleTool/Aseprite/aseprite.exe" -b --script tests/lua/<名字>.lua

# 桥的全部单测（不联网、不花 token）
cd bridge && npm test

# 全量 Lua 回归（当前 7 个文件，238 项）
for t in menu ops versions sizelib artlib artop path; do
  ASE_PROJ="$PWD" "D:/PraticleTool/Aseprite/aseprite.exe" -b --script tests/lua/${t}_test.lua | tail -1
done
```

**两个已验证的、可以依赖的事实**（本轮刚探过，写进策划案免得再探）：

- **Lua 有定时器**：`Timer{ interval = 0.1, ontick = function() end }`，
  方法 `start()` / `stop()`，属性 `isRunning`。`-b` 无头模式下 ontick 不触发（没有 UI 循环），
  GUI 下正常。**P2 的转圈动画就靠它**。
- **`agent.new{...}` 在 `-b` 无头模式下能构造**（`tests/lua/artop_test.lua` 就是这么做的），
  所以协议层测试可以不弹窗地构造真 Agent、把 `send`/`panel` 换成假的喂消息。

---

## 2. 里程碑总览

| 里程碑 | 内容 | 依赖 | 风险 |
|---|---|---|---|
| **M1 快修包** | P1 滚轮、P2 状态指示、P3 中断+超时、P8 完美像素幂等、P5a 状态栏显示当前文件 | 无 | 低 |
| **M2 窗口行为** | P4 窗口跳变 + 最小尺寸 | 无 | 中（要先探针） |
| **M3 选项弹窗** | P7 ask_user 工具 + 终端点选 + 原生对话框 | 无 | 中 |
| **M4 工作区交付流** | P10 备份/副本/打开/交付 + P5b 打开正在编辑的画 | **依赖 M3** | 高 |
| **M5 收尾** | P6 授权框排查+文档、P9 完美像素诊断、全量回归 + 打包 | M1~M4 | 低 |

每个 P 项下面都有「验收」一栏——**验收过不了就是没做完**。

---

## 3. 工作项

### P1 滚轮方向反了

**现象**：终端面板里滚轮方向和直觉相反。

**定位**：`extension/lib/panel.lua:577-581`

```lua
onwheel = function(ev)
  local dy = ev.deltaY or 0
  self.scroll = math.max(0, self.scroll + (dy > 0 and 1 or -1) * 3)
  self:repaint()
end,
```

`self.scroll` 越大越往历史翻（`panel.lua:760` 的 `first = #rows - visible + 1 - self.scroll`）。
现在 `dy > 0`（滚轮向下）反而往历史翻 = 反了。

**方案**：把 `(dy > 0 and 1 or -1)` 改成 `(dy > 0 and -1 or 1)`。
终端惯例：滚轮向上 = 翻历史（scroll 增大），滚轮向下 = 回最新（scroll 减小到 0）。

**顺手修**（同一函数内）：`self.scroll` 现在只钳下界（`math.max(0, ...)`），
往上翻没有上界，翻过顶后 `first` 被钳到 1 所以显示没错，但 scroll 会无限涨。
把它存成"最多翻到顶"即可——**注意**：此处拿不到行数，行数在 `_wrap` 里。
方案：不在这里钳，在 `_paint` 里算 `visible` 之后顺手
`self.scroll = math.min(self.scroll, math.max(0, #rows - visible))`（`_paint` 在 `panel.lua:758` 附近）。

**验收**：GUI 里滚轮上 = 翻历史、滚轮下 = 回最新；翻过顶停住。
无头测不了滚轮事件，验收方式 = 在 `tests/lua/gui_panel_probe.lua` 风格的探针里
直接调用面板对象的 `onwheel` 处理器模拟（传 `{ deltaY = ±120 }`）断言 `self.scroll` 增减方向。

---

### P2 没有状态指示（思考/执行/断联要看得见）

**现象**：用户分不清 AI 是在思考、在改图、还是断联了。

**定位**：
- 桥**已经在发**状态文本：`llm.mjs` 的 `runTurn` 里 `onStatus('thinking...' / 'working (step N)...' / 'running X...' / 'ready')`；
  断联时 `agent.lua:154` 的 onClose 发 `disconnected`。
- 面板**已经在收**：`agent.lua:450` → `panel:setStatus(text)` → 状态栏渲染在 `panel.lua:739-746`。
- **缺的是"动"**：静态一行灰字不起眼，思考时没有活动感。

**方案**：
1. **转圈动画**：Panel 加一个 spinner（字符序列 `| / - \`）。
   - 新增 `self.spinTimer = Timer{ interval = 0.12, ontick = fn }`（构造 Panel 时建一次，
     注意：**Timer 对象要被长期持有防 GC**，存 `self` 上即可）。
   - ontick 里只推进帧序号，帧变了才 `self:repaint()`（不变不重绘，省电）。
   - **忙时才转**：`setStatus` 里判断，status 文本属于 `ready / error / disconnected / connected`
     之一 = 闲，停表；其余 = 忙，开表。判断逻辑放在 `Panel:setStatus`（`panel.lua:150`），
     在 `i18n.statusText` 翻译**之前**用原文判断（翻译后的文本不该参与逻辑）。
2. **状态栏上色**：`_paint` 里按 `self.statusKind` 上色——思考/执行 = 黄/青，
   error = 红，ready/connected = 绿。现在全是一种颜色。`setStatus(text, kind)` 的 kind
   参数已存在但调用方没传，让桥侧的 say/status 带上即可（见 P3 的状态文本统一）。
3. **断联要醒目**：`disconnected` / `connError` 状态时状态栏显示红色 + 提示
   "桥断了：面板里敲 menu → 设置 确认配置，或手动起桥"（i18n 已有 `connectingLong`，复用）。

**验收**：
- GUI 里问 AI 一个问题，状态栏出现转圈 + "思考中…"；工具执行时变 "执行 crop…"；
  完成后转圈停、变绿 "就绪"。
- 杀掉桥进程，1~5 秒内状态栏变红提示断联。
- 测试：协议层（参考 `artop_test.lua` 的做法）喂 `{type='status', text='thinking...'}`
  断言 `panel.spinTimer.isRunning == true`；喂 `ready` 断言停了。
  **注意** `-b` 无头模式下 Timer ontick 不触发，测的是"表有没有被启动"，不是动画本身。

---

### P3 紧急中断 + 超时中断

**现象**：AI 跑飞了（工具循环停不下来、请求卡死）时用户没有任何办法。

**定位**：
- `llm.mjs:19-29`：每次 HTTP 请求有自己的 `AbortController`（只管超时，外部够不着）。
- `runTurn` 的工具循环没有"停下来"的概念，只能等 `maxSteps`（默认 8）耗尽或 HTTP 超时。
- `server.mjs:121` 的 `request()` 已有单请求超时（默认 60s），这个保留。

**方案（桥侧）**：
1. `chatCompletion(cfg, messages, tools, extraSignal)` 加第 4 参：
   外部 signal 触发时 `ctrl.abort()`。
   ```js
   const onAbort = () => ctrl.abort();
   extraSignal?.addEventListener('abort', onAbort, { once: true });
   // finally 里 removeEventListener
   ```
2. `runTurn` 的 opts 加 `abortSignal`：循环每步开头检查 `abortSignal?.aborted`，
   是 → `onSay('error', ...)` + `onStatus('ready')` + return。
   fetch 被 abort 会抛 `AbortError`（`e.name === 'AbortError'`），
   在 handleChat 的 catch 里把它和真正的错误区分开（中断不算错误，提示"已中断"即可）。
3. `server.mjs` Session 加 `this.turnAbort`：
   - `handleChat` 开头 `this.turnAbort = new AbortController()`，结束（finally）置 null。
   - `onMessage` 加 `case 'abort'`：`this.turnAbort?.abort()`，并 `say('info', '已中断当前任务')`。
   - **轮级超时**：config `llm.maxTurnMs`（默认 180000，3 分钟）。handleChat 开头起一个
     `setTimeout(() => this.turnAbort?.abort(), maxTurnMs)`，finally 里 clearTimeout。
     超时中断的提示要和手动中断区分开（"超时自动中断"vs"已中断"）——给 abort 带原因：
     自己包一层 `{ signal, reason }` 或 abort 前记下 `this.abortReason = 'timeout' | 'user'`。

**方案（Lua 侧）**：
4. `agent.lua` 的 `onMessage` 不需要新增 case（中断是 Lua→桥方向）。
   新增 `Agent:abort()`：`self:send{ type = "abort" }`。
5. 面板入口三处（用户习惯都要照顾）：
   - 内建命令：`停止` / `stop`（i18n 的 builtins 表加映射 → action id `abort`）。
   - 命令表加一行「中断当前任务」（menu 的 rows 数据来源里加，`agent:action("abort")` 接到）。
   - **Esc 键**：`panel.lua` 的 `_onKeyDown` 里，Esc 优先级：
     菜单开着 → 关菜单（现状保留）；否则若状态为"忙"（P2 的判断逻辑复用）→ 调 `opts.onAction("abort")`；
     否则不做事。

**验收**：
- selftest 加场景：mock LLM 第一步返回一个工具调用、之后**永不回复**（sleep 卡住），
  发 chat 后立刻发 `{type:'abort'}`，断言面板收到"已中断"且 status 回 ready。
  再验超时版：把 maxTurnMs 配成 500，断言 1 秒内自动中断。
- artop 风格 Lua 测试：菜单/命令 `停止` → 断言发出了 `{type:'abort'}`。
- 手动 GUI：问一个长任务，按 Esc，AI 立刻停。

---

### P4 窗口跳变 + 没有最小尺寸

**现象**：缩小窗口后，点窗口内部又跳回原大小；且能缩到所有元素消失。

**定位与假设（两个症状分开治，都要先探针验证，禁止直接改）**：

**症状 A：点一下跳回**。最大嫌疑是 `panel.lua:565-570`：

```lua
onmousedown = function(ev)
  if ev.button == MouseButton.LEFT and not self:_menuIndexAt(...) then
    pcall(function() dlg:modify{ id = "input", focus = true } end)   -- ← 每次点击都调 modify
  end
end,
```

`dlg:modify` 会触发重新布局，Aseprite 自动布局时内容最小尺寸会把窗口撑回去。
**探针**：写一个 GUI 探针（照 `tests/lua/gui_panel_probe.lua` 的写法）：
打开面板 → 记录 `dlg.bounds` → 模拟点击 → 再读 bounds，对比确认是 modify 触发的。
**修复**：只在输入框**没有**焦点时才 modify。焦点状态没有 API 可读，自己维护：
`onfocus`/canvas 的 onkeydown 时记下"焦点在输入框"，点击 canvas 前判一下。
（如果探针发现不是 modify 引起的，下一步嫌疑是 miniwindow 的锚定逻辑 `_anchorBounds`，同样探针确认。）

**症状 B：能缩到元素消失**。canvas 是 `autoscaling = true`（`panel.lua:551-556`），
窗口缩小时画布跟着缩，缩到很小就"消失"。
**探针**：`autoscaling = false` 后窗口是否还能缩得比内容小？（Aseprite 通常会用
内容最小尺寸钳住对话框，需要实测。）
**修复**（按探针结果二选一）：
- 若 `autoscaling = false` 能钳住：用它，canvas 尺寸保持 CANVAS_W×CANVAS_H。
  副作用：窗口拉得比画布大时，右边/下边留白。接受（比"消失"好）；或者留白区涂底色。
- 若钳不住：保留 autoscaling，在 `_paint` 里加下限——`w` 或 `h` 小于阈值
  （比如 w<360 或 h<240）就不画内容，改画一行"⤢ 窗口太小，请放大"，让用户明白不是坏了。
  这是兜底提示，不是真最小尺寸，**在 PR 描述里注明这是 Aseprite 没暴露最小尺寸 API 的限制**。

**验收**：GUI 里把窗口拖到最小 → 内容要么被钳住、要么显示"窗口太小"提示；
点击窗口内部不再跳变。两个探针脚本留在 `tests/lua/` 里（命名 `gui_resize_probe.lua`）。

---

### P5 AI 操作时：状态栏显示当前文件 + 正在执行的指令；工作区模式下自动打开副本

**现象**：AI 改图/作画时，窗口里看不到"正在对哪个文件做什么"。

**方案**（拆两半）：
- **P5a（M1，纯状态栏）**：状态栏格式升级为 `spinner + 状态文本 + 当前文件名`。
  文件名从 `agent:context()` 能拿到（`app.activeSprite.filename` / title），
  但状态栏在 Panel 层——让 Agent 在 `onMessage` 的 `status` 分支里把当前文档名
  附加传给 panel（`setStatus(text, kind, docName)`），Panel 存在 `self.docName` 随状态栏画。
  "正在执行的指令"已经有了：桥发 `status('running crop...')`，P2 让它动起来后自然可见。
  另外每次工具**完成**时面板已有日志（`i18n.t("applied")` / `artDrawn` 等），保持。
- **P5b（M4，跟 P10 一起）**：工作区模式下，编辑发生在副本文件上，
  副本会被**自动打开**（见 P10 步骤 3），用户能实时看到成果。这条不单独做。

**验收**：问 AI 改个颜色，状态栏显示"执行 replace_color… ｜ xxx.ase"。

---

### P6 授权索取框是英文

**现象**：首次装扩展时 Aseprite 弹的"脚本请求权限"框是英文的。

**定位**：那是 **Aseprite 本体的安全对话框**（脚本沙箱授权），文案跟随 Aseprite 的
界面语言包，**扩展改不了**。扩展自己的对话框已全部走 `i18n.lua`（已核对：
panel / menu / settings / fix 对话框都是 `i18n.t(...)`，默认中文）。

**方案**：
1. 先确认用户说的是哪个框：截图对照——Aseprite 原生授权框（标题通常是
   "Aseprite" + 钥匙/警告图标）还是扩展自己的窗口。
2. 原生框 → **不改代码**。在 `README.md` 的安装一节加一小段"授权框说明"：
   每个框在要什么权限（读文件/写文件/执行进程/网络），为什么需要，配一句
   "勾选 Remember / 不再提示"。如果 Aseprite 本体语言设为中文后这些框仍英文，
   注明"这是 Aseprite 本体翻译未覆盖，与本扩展无关"。
3. 如果发现**扩展自己的**哪个框硬编码了英文（全面 grep 一遍 `extension/` 里
   `text = "`、`title = "`、`label{` 不带 i18n 的），全部接进 `i18n.lua`。

**验收**：README 有授权框说明段；扩展内零硬编码英文 UI 文本（grep 结果为证）。

---

### P7 选项式提问：弹窗点选

**现象**：AI 问"你想要 A 还是 B？"时，用户希望能点选而不是打字。

**方案**（新工具 + 新协议，参照 ZCode 的 AskUserQuestion）：

1. **工具** `ask_user`（`bridge/src/tools.mjs`）：
   ```
   question: string
   options: string[]（2~4 个，每个 ≤30 字）
   ```
   description 写明：**只在真正需要用户拍板时用**（覆盖原图还是保留副本这种），
   不要拿它问日常琐事；每个 option 要短。
2. **分发**：`session.request('ask', { question, options }, 300000)`（5 分钟超时，
   用户要点。`request()` 的第三参已有，直接用）。
3. **桥侧**：`server.mjs` 的 onMessage 加 `case 'answer'`：`resolvePending(msg.id, { choice: msg.choice, index: msg.index })`。
4. **Lua 侧**（`agent.lua` onMessage 加 `case 'ask'`）：**双通道**——
   - 终端里把问题和编号选项打印出来（复用命令表的行样式），用户**敲数字**也能答
     （输入框输入 "1"/"2" 时优先判定为对当前 ask 的回答——Panel 加一个
     `pendingAsk` 状态，有 pendingAsk 时纯数字输入不走聊天）。
   - 同时弹一个原生小对话框（照 `panel.lua:430-468` fix 对话框的写法）：
     标题 = 问题，每个 option 一个 button，onclick →
     `self:send{ type = "answer", id = msg.id, index = i, choice = options[i] }`，
     并关掉对话框、清 pendingAsk。
   - 防重：已有 pendingAsk 时再来 ask，先把旧的答一个 `{ cancelled: true }`（别让桥挂死）。
   - 用户关掉对话框（onclose）也回 `{ cancelled: true }`。
5. **i18n**：选项按钮文字直接用模型给的（模型会按用户语言出选项），
   对话框的固定文案（如"取消"）进 i18n.lua。

**验收**：
- selftest 场景：mock LLM 调 `ask_user`，mock Aseprite 收到 `ask` 后回
  `{type:'answer', ...}`，断言工具结果带着 choice 回到模型上下文。
- artop 风格 Lua 测试：喂 `{type='ask', ...}`，断言发出了 answer 帧；
  喂两个连续 ask 断言第一个被取消。
- GUI：让 AI 问一个二选一，弹窗点选 + 敲数字两种都通。

---

### P8 已矫正过的图还会被再次矫正

**现象**：已经用完美像素处理过的图片，AI 还认为要再处理。

**定位**：`bridge/src/tools.mjs` 的 `perfect_pixel` 分发（约 470-514 行）。
核心算法对**真像素画**的检测结果应该是：网格 == 图片尺寸（每格 1px），
即 `res.gridW === width && res.gridH === height`，此时输出和输入逐字节相同，
再"矫正"一次纯属浪费，还会新开一个一模一样的文档。

**方案**：
1. 桥侧幂等：检测成功后判断 `res.gridW === w && res.gridH === h`
   （`w,h` 是输入尺寸），是 → **不 import**，返回
   ```js
   { detected: true, alreadyPerfect: true, grid: `${w}x${h}`,
     note: 'This image is already true pixel art (every grid cell is exactly 1px). Nothing to fix. Do NOT retry with gridSize.' }
   ```
2. prompt 补一条（`config.example.json` 的 systemPrompt，追加为规则 14）：
   "perfect_pixel returns alreadyPerfect=true when the image is already true pixel art — tell the user it needs no processing and move on; do not retry with a manual gridSize."
   （`config.json` 本地那份同步加，不进版本库。）
3. 模型侧防复读：同一轮里 perfect_pixel 已经成功导入过一次，模型又调第二次时，
   桥侧记一下"本轮已处理过 source X"，重复调直接回 `{ note: 'already processed in this turn' }`
   （Session 上加个 `turnProcessed` 集合，handleChat 结束清空）。

**验收**：
- selftest 场景：造一张 16x16 真像素画当 active_canvas，调 perfect_pixel，
  断言**没有**收到 import_image，返回 alreadyPerfect=true。
- tools_test 补一项：同样的分发断言。
- 现状的 selftest 场景 3（64x64 伪像素画 → 16x16）必须保持绿。

---

### P9 "完美像素功能似乎有问题？"

**现象**：用户一句话描述，没有复现案例。**禁止在没有复现案例时重写算法**。

**方案（诊断 + 复现 harness，修复等案例）**：
1. **加诊断输出**：`perfect_pixel` 成功时把
   `input/grid/refined/output` 四组尺寸 + sampleMethod 以 `say('info', ...)` 推到面板
   （现在只有工具结果回给模型，用户看不见）。这样用户下次觉得结果不对时，
   面板里就有可截图的数据。
2. **加真机探针**：`tests/lua/gui_fix_probe.lua`（新）：打开一张已知图 →
   跑 import 链路 → 截图结果文档。留作用户报 bug 时的复现模板。
3. 文档：README 的排错一节已经有"矫正结果糊"条目，补一句
   "觉得矫正结果不对时，把面板里 `detected grid=… refined=…` 那行截给开发者"。
4. **真正的修复等用户给出**：什么图 + 期望结果 + 实际结果，三样齐了才动算法。

**验收**：诊断行能在面板显示；探针脚本可运行；README 更新。算法代码零改动。

---

### P10 工作文件夹：备份 → 副本编辑 → 打开副本 → 交付

**现象**（用户原话整理）：希望能选定一个**工作文件夹**。在 `gift/001.ase` 里打开助手要求修改时，
助手应：把当前文件备份到 `工作区/backups/gift_back/001.ase`；复制出
`<时间戳>_001_copy.ase`；**修改副本**；在 Aseprite 里**打开副本**；
之后弹窗让用户选：继续修改 / 用它覆盖原文件 / 其他操作。

**设计**：

1. **配置**：`config.json` 加 `workspace: { root: "" }`。
   - 空 = 工作区模式**关**（现状：直接改当前文档）。
   - 非空 = 开。设置入口：面板设置对话框加第 4 个输入框"工作区路径"
     （`extension/lib/settings.lua`，照现有三个框的写法），
     桥的 `set_config` / `configPayload` 相应扩展（`server.mjs`，照 llm 段的写法）。
   - `config.example.json` 同步加示例（`"workspace": { "root": "" }`）。

2. **编辑前准备**（Lua 侧，新文件 `extension/lib/workspace.lua`）：
   工作区模式开启时，任何**会改画布**的请求（`run_ops` / `crop` / `scale` / `canvas_size` /
   `draw_art`）落到"非副本"文档上前，先执行一次 prepare：
   - 备份：`<root>/backups/<原文件父目录名>_back/<原名去扩展名>-<yyyymmdd-hhmmss>.ase`
     （时间戳命名、只增不覆盖，比用户示例的固定名更安全）。
     用 `sprite:saveCopyAs(path)`；目录用 `app.fs.makeAllDirectories` 建。
     （`saveCopyAs` 和 `app.command.OpenFile` **先写探针确认可用**，不可用就换
     `app.command.SaveFileCopyAs` / 读文档后自行拼。）
   - 副本：放在**原文件同目录**，`<yyyymmdd-hhmmss>_<原名去扩展名>_copy.ase`，
     `sprite:saveCopyAs(copyPath)`。
   - 打开副本：pcall `app.command.OpenFile{ filename = copyPath }`（ui 参数探针确认）。
     打开后 `app.activeSprite` 就是副本，后续所有算子自然落在副本上——
     **不需要改任何 op 代码**，这是本设计的关键。
   - 记录：`self.managed = { original = 原路径, copy = 副本路径, backup = 备份路径 }`，
     面板日志打一行"已备份 → …，正在编辑副本 …"。
   - 无文件名的新文档（从未保存）：跳过备份，但仍可做副本（或提示先保存——
     选择：**提示先保存**，因为交付时的"覆盖"需要原路径）。
   - 已经是副本（managed 且 activeSprite 就是 copy）：不再重复 prepare。

3. **交付**（依赖 P7 的 ask 机制，或直接复用 fix 对话框写法自建四按钮对话框）：
   入口：内建命令 `交付` / `deliver` + 命令表一行 + 状态栏提示
   （managed 非空时状态栏文件名后缀 ` [副本]`，提示"交付请敲 交付"）。
   四个选项：
   - **覆盖原文件**：`sprite:saveAs(originalPath)`（副本存回原路径）→
     询问是否关闭副本标签页（默认关）→ 清 managed。
   - **保留副本，不覆盖**：什么都不动，只清 managed 标记（副本文件留在磁盘上）。
   - **丢弃副本**：关闭副本标签页（不保存）+ 删副本文件（`os.remove`）+ 清 managed。
     备份留着（那是安全网）。
   - **继续修改**：关掉对话框，什么都不变。

4. **状态显示**（和 P5a 汇合）：managed 非空时状态栏显示
   `副本：<副本文件名>` 而不是原文件名。

**验收**：
- Lua 无头测试（artop 风格）：配好 workspace root（临时目录），
  打开一个已保存的 .ase → 喂一个 `run_ops` 消息 → 断言：
  备份文件存在、副本文件存在、`app.activeSprite.filename` 是副本。
  再喂一次 op → 断言没有二次备份（managed 已建立）。
  交付四分支各断言行為正确（用临时文件，别碰真文件）。
- selftest 不需要改（桥不感知工作区，纯 Lua 侧）。
- GUI 全流程：真改一张图 → 看副本自动打开 → 敲 交付 → 覆盖 → 原文件内容更新。

**风险**：这是改动最大的一项。**备份逻辑出错会毁用户文件**，所以：
- 备份/副本用 `saveCopyAs`（不影响当前文档），绝不用 `saveAs` 做备份。
- "覆盖原文件"是唯一的写原路径操作，且必须经过用户点选。
- 所有文件操作 pcall 包住，失败时**中止本次编辑并明确报错**，不许"备份失败照样改"。

---

## 4. 验收总表（M5 时全绿才算完）

| # | 验收点 | 方式 |
|---|---|---|
| P1 | 滚轮上=历史，下=最新 | 探针模拟 onwheel |
| P2 | 忙时转圈、闲时停、断联红字 | 协议测试 + GUI 目检 |
| P3 | Esc/命令可中断；超时自动中断 | selftest 2 场景 + GUI |
| P4 | 点击不跳变；缩到极限有钳制或提示 | GUI 探针 + 目检 |
| P5 | 状态栏可见当前文件 + 执行中的指令 | GUI 目检 |
| P6 | README 授权框说明；扩展零硬编码英文 | grep + 文档 |
| P7 | ask_user 弹窗点选 + 敲数字双通道 | selftest + artop 风格 + GUI |
| P8 | 真像素画返回 alreadyPerfect，不再开新文档 | selftest + tools_test |
| P9 | 诊断行上屏；探针模板；算法零改动 | 目检 + 文档 |
| P10 | 备份/副本/打开/交付四分支 | Lua 测试 + GUI 全流程 |
| 回归 | Lua 238 项 + 桥 181 项 + 新增全部 | 见第 1 节命令 |

**打包**：M5 跑 `powershell -ExecutionPolicy Bypass -File tools/pack-extension.ps1`
生成 `dist/ai-pixel-copilot-0.5.0.aseprite-extension` 即可，**不推仓库、不发 Release**。
版本号：`extension/package.json` 和 `bridge/package.json` 都升 0.5.0。

---

## 5. 禁止事项（再强调一遍）

1. 禁止提交 `bridge/config.json`、`bridge/data/`、`dist/`、`extension/bridge/`。
2. 禁止写死任何本机绝对路径（测试用 `$ASE_PROJ`）。
3. 禁止拆 `SENTINEL` / `_resetEntry` / 焦点往返逻辑。
4. 禁止在 `-b` 无头模式期待 Timer ontick / Dialog 可用（Dialog 无头返回 nil 是正常）。
5. 禁止动 perfect pixel 核心算法（P9 只加诊断）。
6. 禁止改 `.gitattributes`、git 作者配置。
7. 禁止 push 和 Release。
8. 新增 Lua 文件注意 LF；改 `.ps1` 注意保留 BOM。

---

## 6. 追加需求（用户在接受本策划案后补充，同样按 P 项做）

> 这四条是用户在本案执行期间新提的，编号接在后面。M 顺序：P7/P14 一起做（都在 M3），
> P11/P13 并进 M4（和 P10 是同一个"工作区"主题），P12 单独一个 M6。

### P11 从助手这里打开文档

**需求**（用户原话）：「我希望能从AI助手那里打开文档」。

**设计**：新工具 `open_document`：

```
path: string      -- 绝对路径，或工作区内的相对路径
```

- 桥侧：`session.request('open_doc', { path })`。
- Lua 侧 `agent.lua` 新增 `case 'open_doc'`：
  - 路径先归一化：相对路径按**工作区根**（P10 的 `workspace.root`）拼；
    没有工作区就用当前文档所在目录；都没有就报错让用户给绝对路径。
  - `Sprite{ fromFile = path }` 先试读——读不了就直接报错（**不要**让 Aseprite
    弹一个"文件不存在"的原生框）。
  - 用 `app.command.OpenFile{ filename = path }` 真正打开（`ui=false`，
    避免弹原生文件选择器）。打开后 `app.activeSprite` 就是它。
  - 回 `{ ok = true, name, width, height }`；失败回 `{ error }`。
- 安全：只允许打开图片/文档后缀（`.ase` `.aseprite` `.png` `.jpg` `.jpeg` `.gif` `.webp` `.bmp`）；
  其他后缀直接拒绝（这是防止模型被诱导去"打开"任意文件）。
- 提示词补一条：模型不知道路径时用 `ask_user` 问，或先用工作区列表工具（见 P13）。

### P12 缩成底边栏 / 侧边栏，「完美融入」

**需求**（用户原话）：「AI助手能够缩成底边栏或侧边栏，完美融入」。

**现状**：已有一个「贴边小面板」（`lib/miniwindow.lua`，2×3 个图标按钮），
但它是个**浮动小窗**，不是"栏"。

**设计（先把技术上限说清楚）**：Aseprite 的 Lua 没有"把对话框停靠进主窗口布局"的 API
（没有 dock/tab 接口，`Dialog` 只能是非模态浮动窗）。所以"完美融入"能做到的是：

1. **条形窗口**：新增「栏模式」——窗口变成**一条贴边的窄条**：
   - 底边栏：贴主窗口内容区底边，宽 = 主窗口内容区宽，高 ≈ 1 行输入 + 1 行状态；
   - 侧边栏：贴右侧，宽 ≈ 320，高 = 主窗口内容区高。
   - 位置用 `dlg.bounds = Rectangle(...)`（miniwindow 已经在用，可行）。
     主窗口尺寸从 `app.window`/`app.workspace` 取——**先写探针确认能拿到**
     （`app.window.bounds` 或 `app.workspace.bounds`；拿不到就用用户上次拖到的位置）。
   - 无标题栏：`Dialog{ title = "" }` 仍然有边框，Aseprite 没暴露去边框的开关，
     所以"完美融入"只能做到**配色与 Aseprite 主题一致**（面板配色已经是自绘的深色，
     把 BG/RULE 换成 `app.theme` 的颜色即可）。
2. **切换入口**：命令 `栏` / `bar`，以及小面板加一个图标按钮；三种形态循环
   （面板 → 底边栏 → 侧边栏 → 面板）。
3. **栏模式下画什么**：状态栏（P2 的转圈 + 文件 + 状态文本）+ 单行输入 + 最后一行输出。
   Esc/停止仍然可用。

**验收**：GUI 里切到栏模式，窗口贴住底边/右侧；再切回面板尺寸恢复；
截图留证（`tests/lua/gui_bar_*.png`）。**如果探针发现拿不到主窗口尺寸**，
退化成"记住上次位置 + 让用户自己拖"，并在 README 里写明这是 Aseprite 的限制。

### P13 上传图片 -> 复制进工作区

**需求**（用户原话）：「我希望能够上传图片给它，可以采用复制到工作区的方案也行」。

**设计**：并入 P10 的工作区流程。
- 工作区开启时：`upload` 选中的文件**先复制到** `<root>/uploads/<yyyymmdd-hhmmss>_<原名>`，
  再按复制件的路径读像素送给桥。原文件一个字都不动。
- 工作区关闭时：保持现状（直接读原文件）。
- 面板日志说明"已复制到工作区：…"。
- 「工作区里有哪些图」：新工具 `list_workspace`（列 `<root>` 下的图片/文档，
  带相对路径），让模型能回答"我上次处理的图在哪"。P11 的 `open_document` 配合它用。

### P14 明确能力边界，做不到就诚实说

**需求**（用户原话）：「我希望它能够明确自己的能力边界，做不到的时候要诚实」。

**设计**（三件事，都是加法）：

1. **新工具 `capabilities`**：返回一份**从真实注册表生成**的能力清单——
   - `can.edit`: 现有算子名（`ops.names`），每个一句话说明；
   - `can.draw`: 字符网格作画、图层、调色板；
   - `can.image`: 打开/矫正图片、完美像素、导出；
   - `can.files`: 工作区下的打开/列出/备份/交付（P10）；
   - `cannot`: 明确列出做不到的事——**不能**画画以外的创作（不能生成位图以外的
     音频/矢量/字体）、不能联网搜索、不能读写工作区以外的任意文件（除非绝对路径且后缀合法）、
     不能在没有工具的情况下"撤销"（只能靠快照回滚）、不能停靠进主窗口（P12 的限制）、
     不能改变 Aseprite 本体的授权对话框语言（P6）。
   - 这份清单**必须**在测试里和 `TOOLS` 注册表交叉核对（`can.*` 里提到的工具名
     必须真的存在），否则清单会随代码漂移变成谎言——那就违背了"诚实"这条需求本身。
2. **提示词补规则**（16/17）：不知道就说不知道；工具返回 error 时把**原因**转述给用户，
   不许编造成功；不确定路径/尺寸/风格时用 `ask_user` 问；不确定自己能不能做时先调
   `capabilities` 再回答；**永远不要承诺清单里没有的能力**。
3. **README 加一节「能力边界」**：把 `cannot` 那几条写成人话给用户看。

**验收**：`capabilities` 与 `TOOLS` 交叉核对的测试通过；README 有该节；
GUI 里问"你能做什么/能不能帮我做 XXX"时回答与清单一致（人工目检）。
