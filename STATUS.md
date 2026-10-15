# AI Pixel Copilot — 当前进度与交接

给下次继续的自己/agent：先读这一页，再动手。

## 一句话状态

**v0.5.1：用户实测反馈的 14 条 + 追加 4 条全部做完，Lua 463 + 桥 290 = 753 项测试全绿。**
`docs/plan-v0.5.0-ux-workflow.md` 是这轮的完整任务书与结论。
GUI 端到端已在真实 Aseprite 里跑通并留下截图证据；中文像素字体（方舟 10px）已装好。
面板已重做成【终端式】（PowerShell / git-bash 观感）：回显 + 彩色输出 + 命令表 + 内建命令 +
贴边小面板，中英双语（默认中文），都已在真 Aseprite 里验证并截图。**
扩展已安装到 `%APPDATA%\Aseprite\extensions\ai-pixel-copilot`。
只差：填 API Key → 重启 Aseprite → 首次实跑。

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
aseprite.exe -b --script tests/lua/ops_test.lua
aseprite.exe -b --script tests/lua/versions_test.lua
aseprite.exe -b --script tests/lua/menu_test.lua
cd bridge && node test/selftest.mjs

# GUI 可视化验证（会短暂弹 Aseprite 窗口，自动截图后杀进程）
bash tests/run_gui_visual.sh tests/lua/gui_panel_final.png
bash tests/run_gui_visual.sh --term        # 终端 + 命令表 + 小面板（中文），截两张
bash tests/run_gui_visual.sh --term-en     # 英文模式同上
```

GUI 截图里能看到完整证据链：
`Connected to local bridge` → `Bridge ready. Aseprite 1.3.18.6-dev, 7 ops available.` →
AI 回复 → `Auto-backed up v1 "before: 红色换蓝色"` → `Applied 1 op(s) ... replace_color: 256 px`
→ `PROBE: RESULT=OK`（画布像素真的从红变蓝）。

截图用 `tests/shot_window.ps1`：默认走 **PrintWindow**（抓窗口自身内容，**不抢前台**、
不会拍到同屏幕位置上别的程序）；`-Method foreground` 是旧的前台方案，会校验前台窗口确实是
Aseprite，不是就**拒绝截图**（防隐私泄露）。

`run_gui_visual.sh` 会临时改两处首选项并**无条件还原**：
`scripts.show_run_script_alert=false`（否则运行脚本弹确认框），
以及预置 `[script_access]` 授权（否则 io.open/WebSocket 弹授权框阻塞，见下）。

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
   （Read 4 / Write 2 / Execute 1 / OpenSocket 8 / LoadLib 16，Full=31）。授权一次即长期记住，
   **改代码不会重弹**（键取自文件名不是内容）。
   - 用户首次使用会看到 **3~4 个授权框**（`lib/ws.lua` 开 socket、`lib/versions.lua` 写文件/删文件、
     `lib/agent.lua` 读上传的图片、`main.lua` 执行命令拉起桥）。每个勾"不再提示"即可，一次性。
   - 写自动化测试时要预置这些键，键串是 **chunk source name**：`--script` 传入的路径会被
     `get_absolute_path` 规范成**反斜杠绝对路径**；而 `require` 的模块名走 `package.path` 模板，
     Lua 把 `lib.ws` 里的点换成 **Windows 分隔符 `\`**，所以会得到
     `<repo>/extension/lib\ws.lua` 这种**混合分隔符**。两种都要写上（见 `run_gui_visual.sh`）。
10. **`ask_access` 在无 UI 时直接放行**（`security.cpp:436`）→ 无头测试能读写文件。

### JSON 与消息
11. **`json.decode` 返回的是 `JsonObj` userdata，不是 Lua table**（`json_class.cpp`）。
    它支持 `obj.key` / `obj[i]` / `#obj`，但**这一版数组的 `ipairs/pairs` 迭代器有 bug**
    （`JsonObj_ipairs_next` 返回 0 而不是 2，循环立刻结束）→ 数组必须用 `#obj` + `obj[i]` 取。
    `lib/ws.lua` 里的 `fromJson()` 统一转成普通 table。
12. **无头（`-b`）模式下 WebSocket 回调不触发**（回调走 `os::queue_event`，批处理没有事件循环；
    33ms 的 Timer 只在 `isGui()` 时建）→ WS 链路只能在 GUI 下验证，但 Lua 逻辑可 `-b` 全量测。
13. `app.version` 是 userdata，`json.encode` 会变 null → 要 `tostring(app.version)`。

### Lua 语言层面（POSIX Lua 变体，坑最深）

29. **`|`（模式或运算）完全不生效！** Aseprite 内置的 Lua 是 POSIX 正则版：实测
    `("menu"):find("^%s*(menu|foo)%s*$") == nil`，而 `("menu"):find("^%s*menu%s*$") == 1`。
    凡是需要"或"的地方一律**查表匹配**或拆成多次匹配（`lib/i18n.lua` 的 MENU_WORDS 就是因此写成查表）。
30. **`string.lower()` 是字节级的**，会把多字节字符的尾巴改坏：`"menú":lower()` 的末字节
    `C3 BA` → `C3 9A`，表查不到；俄文 `МЕНЮ` 更是根本不会被降格。含非 ASCII 时**别调 lower**。
31. **`string.sub(2)` / `sub(-1)` 会切碎多字节字符**：`"menú":sub(2)` 得到 `en` + 残字节。
    取首/尾字符要用 `utf8.offset`（见 `i18n.lastChar`）；剥括号/标点必须按字符边界走。
32. **归一化要先洗 BOM 和 `\r`**：Lua 的 `%s` **不**匹配 `\r`，也不匹配 UTF-8 BOM，
    带 BOM 的输入会让 `^%s*matching$` 整条失效（这次真的踩到了）。
33. **无头（`-b`）下 `Dialog(...)` 返回 nil**（`dialog_class.cpp:Dialog_new` 里 `!isGui()` 直接 return 0），
    所以面板代码要对 nil 兜底，无头测试才能跑纯逻辑（`Panel:_build` / `Panel:show` 已处理）。
33b. **多行字符串字面量 + CRLF 文件 = 语法错误**。这个 Lua 的词法器只把 `\n` 当换行
    （POSIX/C89 分支），CRLF 文件里的多行字符串会报 `unfinished string`（实测：含 `\r\n`
    的多行字面量直接 loadfile 失败）。**测试脚本里的多行文本一律用 `\n` 转义**，别写真正的换行；
    行尾也可能被编辑器/工具改掉，改完跑一遍 `loadfile` 检查最稳。

### 终端化（IME 是硬约束）

33c. **输入行不能自绘**：Aseprite 里只有 `ui::Entry` / `ui::TextEdit` 会主动开输入法
    （`entry.cpp:170` 调 `os::System::setTextInput(true, caretPos)`），而**这个开关没有暴露给
    Lua**（`app.os` 里只有系统信息查询）。Windows 的 IME 由 `laf/os/win/window.cpp` 的
    `WM_IME_CHAR` 转成带 unicode 的 KeyDown 事件，但前提是控件先开了 text input。
    所以自绘输入行 = 中文完全打不了字（连退格都得自己实现）。做法：**canvas 当屏幕、
    原生 Entry 当提示行**（素边框 + 同底色），观感一致、中文能打。
33d. **桥发来的状态是英文硬编码**（`ready` / `missing API key` …）——面板侧用查表翻译
    （`i18n.statusText`），中文界面才不会漏出英文状态。

### 命令表 / 小面板（新交互，都对过源码）

34. **canvas 不只是画布**：`dlg:canvas` 支持 `onmousemove / onmousedown / onmouseup / onwheel /
    onkeydown / onkeyup`（`canvas_widget.cpp:118-159` + `dialog_class.cpp:1373-1405`）→
    "鼠标悬浮变蓝、点击执行"完全能自己实现，不需要主题也改不了 Aseprite 皮肤。
    鼠标消息字段：`x/y`（已减去 widget 原点）、`button`（`MouseButton.LEFT`）、`altKey` 等。
35. **键名走 `ev.code` 不是 `ev.key`**：`fill_keymessage_values` 里 `key` = unicode 字符，
    `code` = `vkcode_to_code` 的名字（`"ArrowUp"/"ArrowDown"/"KeyA"`）。吃了按键要调
    **`ev.stopPropagation()`**（消息表里的函数），不是 `app.canvas:…`。
36. **对话框定位**：`dlg.bounds = Rectangle(x, y, w, h)`（`Dialog_set_bounds`）或
    `dlg:show{ bounds = … }`；坐标是**相对主窗口内容区**的（`getWindowBounds()` 里减掉了
    mainOrigin），所以贴边小窗写 (6,6) 就贴在 Aseprite 自己窗口的左上角，跟主窗口一起移动。
37. **`dlg:modify{id=…, text=…}` 不会立刻刷新 `dlg.data`**（真人敲键会）——脚本/探针填进去的值
    读回来还是旧的。面板因此自己存一份输入值（`Panel:fillInput` / `Panel:inputValue`）。
38. **`app.command.OpenFile` 返回布尔值，不是文件名**（`app_command_object.cpp:Command_call`）；
    要拿选中的文件得事后读 `app.activeSprite.filename`。

### 字体（中文像素字体 + 关平滑）

14. **laf 只查第一层回退**：位图字体的 `<fallback>` 指向谁，缺字就用谁渲染；再往下的 fallback
    **不会被查**（那层缺字交给系统字体兜底）。中文字体必须挂在 `Aseprite` / `Aseprite Mini`
    的**第一层**回退上，挂中间层（如 `Unicode` 的 fallback）**完全没效果**——实测过，别再试。
15. **回退字号 = `size × guiscale()`**（`src/app/fonts/font_data.cpp:92`，`size` 默认 10）。
16. **`antialias` 默认 true**（`skin_theme.cpp:257`）、**`hinting` 默认 Normal** → 像素字体必须
    显式写 `antialias="false" hinting="false"`，否则会被抗锯齿糊掉、被自动微调挪位。
    转换出的 TTF 里也写了 `gasp` 表（只留 GASP_GRIDFIT，不含 DOGRAY）做双保险。
17. `<font>` 里 `<fallback font="X">` 的 X 必须**在前面声明**，否则启动报
    "Font named 'X' not found"。
18. **BDF 用不了**：`skin_theme.cpp` 里 `type=` 只认 `truetype` / `spritesheet` / `system`。
    用户给的 Fusion Pixel 是 BDF，所以写了转换器 `tools/bdf2ttf.py`
    （fontTools；每个点亮像素转成方形轮廓，同行连续像素合并成矩形、纵向再合并；
    UPEM=1000，1 设计像素=100 单位）。实测 7 个语言 BDF 的**字形集完全一致**（各 25314 个），
    只是区域字形变体不同，取 `zh_hans` 一个即可 → 25123 个码位、5.4MB、转换耗时 4.5 秒。
19. 当前 `fonts.xml`：`<font name="Fusion Pixel 10" file="fusion-pixel-10px.ttf"
    antialias="false" hinting="false" />`，`Aseprite` 与 `Aseprite Mini` 的第一层回退都指向它，
    `size="10"`。想换回方舟像素只改两处 `file=` 和 `name=`。
    **原始备份**：`data/fonts/fonts.xml.orig-backup`。

## 未完成 / 下一步

1. **重启 Aseprite** → `File > Scripts > AI Pixel Copilot (AI console)` 或 `Ctrl+Shift+A`
   → 首次点几次授权框（勾不再提示）。
2. **点面板上的 Settings**（或菜单 `AI: Settings`）填 Base URL / Model / API Key，
   点 **Test Connection** 应看到 `Connection OK in ... ms`。保存后**立即生效**，不用重启桥。
3. 试一句「把背景的 #FF0000 换成 #2E86DE」。
4. 新交互的快捷键（都写在 `extension/keys.aseprite-keys`，装完重启生效）：
   `Ctrl+Shift+A` 面板 / `Ctrl+Shift+M` 命令表 / `Ctrl+Shift+P` 贴边小面板。
5. 真 LLM 跑通后，可考虑：
   - 命令表增加"参数化命令"（如 `10: 换成颜色 [#RRGGBB]` 输入编号后追问参数）
   - 上传图片 → 矫正的实测（`Fix Image` 按钮链路目前只在代码层验证过，GUI 未实测；
     小面板的 Upload 走 `app.command.OpenFile`，选完自动进矫正流程）
   - 界面语言只做了中/英两套（`lib/i18n.lua`）；想加语言就往 LOCALES + BUILDER 加表
   - 输出区还不能选中复制（canvas 自绘）；要复制的需求真要满足只能走 C++

## 架构速览

```
Aseprite (Lua 扩展)  <--WebSocket(JSON + 二进制 RGBA)-->  本地 Node 桥  <--HTTPS-->  LLM
  lib/panel.lua      终端式控制台（canvas = 滚回缓冲/命令表；提示符行 = entry 输入）
  lib/menu.lua       命令表：纵向表格、悬浮变蓝、点击/编号/键位执行（画在 canvas 上）
  lib/miniwindow.lua 贴边小面板：自绘图标按钮的无标题栏小窗，可拖动
  lib/i18n.lua       中/英双语文案 + 终端内建命令词表 + 语言判定（默认中文，查表匹配）
  lib/agent.lua      编排：协议、画布上下文、导入新文档、待发队列
  lib/ops.lua        7 个安全算子（可撤销）
  lib/versions.lua   内存快照 + 磁盘 .aseprite 副本
  lib/ws.lua         WebSocket 封装（JsonObj→table、文本帧 + 二进制帧配对）
  bridge/src/*.mjs   会话 / 请求关联 / OpenAI 兼容工具循环 / 色值库
  bridge/vendor/     Perfect Pixel 核心（esbuild 从原仓库 src/core 打包，不动原仓库）
```

设计原则：**模型永远不产出像素**，只产出结构化算子；图像级工作交给 Perfect Pixel 的算法。
