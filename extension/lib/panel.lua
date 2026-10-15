-- lib/panel.lua -- 终端式控制台（PowerShell / git-bash 观感）
--
-- 布局（整个面板只有两块）：
--     ┌──────────────────────────────┐
--     │  canvas：整台终端              │   ← 状态行 / 滚回输出 / 打印出来的命令表 /
--     │                                 │      输入行（含块光标）
--     ├──────────────────────────────┤
--     │ [隐形输入点] [⏎] [ … ]         │   ← 极简底部：没有别的按钮了
--     └──────────────────────────────┘
--
-- 关键实现（都对过 Aseprite 源码，别重复踩）：
--   * 输入为什么画在 canvas 上：原生 ui::Entry 的行高装不下中文字形（实测裁切），
--     而"开 IME"的开关没暴露给 Lua（只有 C++ 能调 setTextInput），所以自绘输入行又打不了中文。
--     折中：Entry 收成一个小方块当"输入法输入点"（视觉上不显眼），
--     画布负责显示输入内容（多行折行 + 块光标 + 中文字形完整）。
--     Entry 里常驻一个不可见字符（NBSP 哨兵），靠 onchange 的文本差算出
--     "插入/退格"，再同步回来 —— 所以只能末尾编辑（←/→ 不生效），这是已知取舍。
--   * 回车提交靠"磁吸按钮"：focus=true 的按钮吃 ENTER（button.cpp:108），
--     而且它必须可见（isEnabled() && isVisible()），所以底部保留一颗小 [⏎]。
--   * 命令表是打印出来的文字行，带 meta.menuIndex；绘制时记录命中框，
--     鼠标悬浮/点击就作用在那些行上（canvas 的 onmousemove/onmouseup）。
--     悬浮高亮必须自己 repaint —— 改了状态不重绘就是"看起来没生效"。

local util = require("lib.util")
local i18n = require("lib.i18n")
local menu = require("lib.menu")
local miniwindow = require("lib.miniwindow")

local panel = {}

local Panel = {}
Panel.__index = Panel

-- 默认尺寸（UI 单位；窗口可拖大拖小，theme screenscaling=2 时屏幕上是 2 倍）
-- 注意别按"屏幕像素"来定：这台机器 UI 缩放 2x，写 880 就是 1760px，几乎占满屏。
local CANVAS_W, CANVAS_H = 660, 420
local MAX_LINES = 800
local INPUT_MAX_ROWS = 6                 -- 输入区最多显示几行，超出只显示尾部
-- 画布小于这个尺寸就不再画内容，改画一行"窗口太小"（P4：Aseprite 没暴露最小尺寸 API）
local MIN_CANVAS_W, MIN_CANVAS_H = 240, 120

-- 栏模式（P12）。Aseprite 没有"把对话框停靠进主窗口布局"的 API，也**读不到主窗口
-- 的几何**（实测 app.window / app.workspace 在 -b 下是 nil，GUI 下也没有 bounds 字段），
-- 所以做不到真的贴边停靠。能做的是一键把窗口**缩成一条**，位置沿用当前的 x/y：
--   底边栏：很宽很矮（一行输出 + 一行输入），用户自己拖到底边就很像状态条
--   侧边栏：窄而高（日志 + 输入），拖到右侧就是侧栏
-- 窗口尺寸 = 画布尺寸 + 实测的边框余量（672x467 的窗口对应 660x420 的画布）。
local CHROME_W, CHROME_H = 12, 47
-- 底边栏要 3 行才够（状态 / 最后一行输出 / 输入）：行高约 18，3 行 54，取 60 留点余量。
-- 只有 2 行的话"正在执行的指令"那行画不出来，而用户要的正是看得见它在干什么。
local MODE_CANVAS = {
  panel      = { w = CANVAS_W, h = CANVAS_H },
  bar_bottom = { w = 1000, h = 60 },
  bar_side   = { w = 320, h = 420 },
}
local MODE_ORDER = { "panel", "bar_bottom", "bar_side" }

-- 哨兵：一个普通空格。
--   * 必须"渲染出来看不见"——NBSP 不行：字体缺该字形，Aseprite 画成红条（实测）；
--   * 每次变化只吃【一个】哨兵，别把用户输入的空格一起吞掉。
local SENTINEL = " "

-- 终端配色
local BG      = Color(16, 18, 22)
local TEXT    = Color(222, 226, 232)
local DIM     = Color(118, 126, 138)
local USER    = Color(126, 226, 168)
local AI      = Color(240, 244, 250)
local THINK   = Color(152, 158, 168)
local TOOL    = Color(128, 178, 200)
local ERROR   = Color(255, 122, 122)
local RULE    = Color(44, 48, 56)
local STATUS  = Color(130, 190, 255)
local MENU_TX = Color(214, 220, 230)
local MENU_HL = Color(46, 134, 222)      -- 悬浮：蓝
local MENU_HLT= Color(255, 255, 255)
-- 栏内控件的"空槽"底色（电量条空格子 / 缩略图外框 / 滑杆轨道）
local FRAME   = Color(58, 64, 74)

-- 状态栏配色（P2）：忙 = 黄、执行算子 = 青、闲 = 绿、出错/断联 = 红
local STATUS_OK    = Color(126, 226, 168)
local STATUS_BUSY  = Color(255, 206, 92)
local STATUS_TOOL  = Color(128, 200, 220)
local STATUS_ERROR = Color(255, 122, 122)
local STATUS_WARN  = Color(255, 196, 110)

local STATUS_COLORS = {
  ok = STATUS_OK, busy = STATUS_BUSY, tool = STATUS_TOOL, error = STATUS_ERROR,
  warn = STATUS_WARN,
}

-- 桥侧 / 面板侧给的 kind -> 四类之一
local STATUS_KIND_ALIAS = {
  ok = "ok", ready = "ok", connected = "ok", done = "ok",
  busy = "busy", thinking = "busy", working = "busy", connecting = "busy", waiting = "busy",
  tool = "tool", running = "tool", op = "tool",
  warn = "warn", warning = "warn", limited = "warn",
  error = "error", disconnected = "error", failed = "error",
}

-- 转圈帧（P2）：思考/执行时状态栏第一个字符在动
local SPIN_FRAMES = { "|", "/", "-", "\\" }
local SPIN_INTERVAL = 0.12

-- 哪些状态算"闲"（停转圈）。判断用【原文】—— 桥发的英文和面板本地化后的中文都要认。
-- 前缀匹配：只要以这些开头就算闲（"connected, waiting for input" 也算闲）。
local IDLE_STATUS_PREFIX = {
  "ready", "connected", "disconnected", "error", "missing api key",
  "就绪", "已连接", "已断开", "出错", "连接出错", "缺少",
}

-- 断联/连接出错：状态栏下面再补一行红字提示（P2 第 3 点）
local ALERT_STATUS_PREFIX = { "disconnected", "connection error", "已断开", "连接出错" }

-- 红色状态（比 alert 宽：普通的 error / 缺 key 也红，但不弹提示行）
local ERROR_STATUS_PREFIX = {
  "error", "出错", "missing api key", "缺少",
  "disconnected", "connection error", "已断开", "连接出错",
}

local WARN = Color(255, 196, 110)

local KIND_COLOR = {
  user  = USER,
  ai    = AI,
  think = THINK,
  tool  = TOOL,
  info  = DIM,
  warn  = WARN,
  error = ERROR,
  menu  = MENU_TX,
}

local KIND_PREFIX = {
  user  = "▸ ",
  think = "│ ",
  tool  = "· ",
  warn  = "! ",
  error = "! ",
}

local ROW_FACTOR = 1.55

----------------------------------------------------------------------
-- 栏里的小控件（v0.5.3）：上下文电量条 / 思考强度滑杆 / 工作图片缩略图
--
-- 为什么做在【栏】里：这三个都是"随时看一眼、顺手调一下"的东西。
-- 上下文电量条用 20 格表示 已用 / 预算；思考强度是 4 档（auto/low/medium/high）
-- 的分档滑杆 —— 点一下或拖着走都能改，改完立刻写回桥的配置。
----------------------------------------------------------------------

local CTX_CELLS = 20          -- 电量条格子数（用户要的 20 格）
local CTX_CELL_W, CTX_CELL_H, CTX_CELL_GAP = 3, 6, 0
local CTX_CELL_H_LINE = 16    -- 控件在输入行里占的高度
local THINK_STEPS = { "auto", "low", "medium", "high" }
local THINK_TRACK_W, THINK_KNOB_R = 44, 3
local THUMB_BOX = 16          -- 缩略图外框：和输入行一样高，才塞得进去
local DOCK_BOX_W, DOCK_BOX_H = 14, 12   -- 贴边切换按钮（贴底 / 贴侧边）

----------------------------------------------------------------------

function panel.new(opts)
  local self = setmetatable({
    opts = opts or {},
    lines = {},
    scroll = 0,
    status = "--",
    hint = "",
    dirty = true,
    wrapWidth = -1,
    wrapped = {},
    charW = {},
    dlg = nil,
    shown = false,
    miniShown = false,
    -- 输入
    input = "",
    entrySyncing = false,
    -- 历史
    history = {},
    historyPos = 0,
    inHistory = false,
    draft = "",
    -- 命令表
    menuOpen = false,
    menuRows = nil,
    menuHover = 0,
    hitRows = {},
    -- 状态栏（P2/P5a）：busy 决定转圈，docName 显示当前文件
    statusRaw = "",
    statusKind = "ok",
    docName = "",
    alert = "",
    busy = false,
    spinIdx = 1,
    spinTimer = nil,
    -- P7 选项式提问
    pendingAsk = nil,
    askDlg = nil,
    askClosing = false,
    askShownOptions = nil,
    inputFocused = false,
    -- P12 形态
    mode = "panel",
    -- 图片矫正队列
    fixQueue = {},
    -- 栏内控件（v0.5.3）
    ctx = { used = 0, budget = 0 },
    thinking = "auto",
    thinkCommitted = "auto",     -- 已经写回桥的那一档（松手时按它判断要不要提交）
    barHit = {},
    thinkDrag = false,
    thinkTrack = nil,
  }, Panel)

  self.mini = miniwindow.new{
    items = function() return self:_miniItems() end,
    onAction = function(id) self:_miniAction(id) end,
    onVisibilityChanged = function(shown)
      self.miniShown = shown
      self:repaint()
    end,
  }
  return self
end

----------------------------------------------------------------------
-- 输出缓冲
----------------------------------------------------------------------

function Panel:log(text, kind, meta)
  kind = kind or "info"
  local prefix = KIND_PREFIX[kind] or ""
  local first = true
  for _, line in ipairs(util.splitLines(tostring(text))) do
    self.lines[#self.lines + 1] = {
      text = (first and prefix or "") .. line,
      kind = kind,
      menuIndex = meta and meta.menuIndex or nil,
    }
    first = false
  end
  while #self.lines > MAX_LINES do table.remove(self.lines, 1) end
  self.dirty = true
  self.scroll = 0
  self:repaint()
end

-- 终端风格：把用户敲的命令回显出来
function Panel:echo(text)
  self:log(text, "user")
end

-- 解析 "#RRGGBB" / "#RGB"（栏底色的用户配置）。认不出来返回 nil，调用方回落到默认底色。
function panel.parseHexColor(text)
  local s = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^#", "")
  if #s == 3 then
    s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2)
  end
  if #s ~= 6 or not s:find("^%x%x%x%x%x%x$") then return nil end
  return Color(tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16))
end

-- 状态文本的"闲/忙"判定。用【原文】判（翻译后的文本不该参与逻辑），
-- 前缀匹配，中英都认 —— 桥发英文，面板自己那几处发的是本地化后的中文。
local function startsWithAny(s, list)
  for _, p in ipairs(list) do
    if s:sub(1, #p) == p then return true end
  end
  return false
end

-- 只对纯 ASCII 做小写（string.lower 是字节级的，会改坏多字节字符）
local function asciiLower(s)
  if s:find("^[%z\1-\127]*$") then return s:lower() end
  return s
end

local function normalizeStatus(s)
  return asciiLower(tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Panel:_statusIsIdle(raw)
  local s = normalizeStatus(raw)
  if s == "" then return true end
  return startsWithAny(s, IDLE_STATUS_PREFIX)
end

function Panel:_statusIsError(raw)
  local s = normalizeStatus(raw)
  return startsWithAny(s, ERROR_STATUS_PREFIX)
end

function Panel:_statusNeedsAlert(raw)
  local s = normalizeStatus(raw)
  return startsWithAny(s, ALERT_STATUS_PREFIX)
end

----------------------------------------------------------------------
-- 转圈动画（P2）
----------------------------------------------------------------------

-- Timer 对象必须被长期持有（GC 掉 = 动画停），所以挂在 self 上。
-- 注意：`-b` 无头模式下 Timer 能构造、start/stop 也能改 isRunning，
-- 但 ontick 不会触发（没有 UI 循环）—— 测试只能断言"表有没有被启动"。
function Panel:_ensureSpinTimer()
  if self.spinTimer then return self.spinTimer end
  local ok, t = pcall(function()
    return Timer{ interval = SPIN_INTERVAL, ontick = function() self:_spinTick() end }
  end)
  if ok and t then self.spinTimer = t end
  return self.spinTimer
end

function Panel:_spinTick()
  self.spinIdx = (self.spinIdx or 1) % #SPIN_FRAMES + 1
  self:repaint()
end

function Panel:_startSpin()
  local t = self:_ensureSpinTimer()
  if t and not t.isRunning then
    pcall(function() t:start() end)
  end
end

function Panel:_stopSpin()
  local t = self.spinTimer
  if t and t.isRunning then
    pcall(function() t:stop() end)
  end
end

function Panel:isBusy() return self.busy == true end

function Panel:setStatus(text, kind, docName)
  local raw = tostring(text or "")
  self.statusRaw = raw
  self.status = i18n.statusText(raw)
  if docName ~= nil then self.docName = tostring(docName) end

  self.busy = not self:_statusIsIdle(raw)
  self.statusKind = STATUS_KIND_ALIAS[kind or ""]
    or (self.busy and "busy")
    or (self:_statusIsError(raw) and "error")
    or "ok"

  -- 断联/连接出错：状态栏下面补一行红字（P2 第 3 点）
  if self:_statusNeedsAlert(raw) then
    self.alert = i18n.t("bridgeDown")
  else
    self.alert = ""
  end

  if self.busy then self:_startSpin() else self:_stopSpin() end
  self:repaint()
end

function Panel:setHint(text)  self.hint = tostring(text); self:repaint() end

function Panel:clear()
  self.lines = {}
  self.dirty = true
  self.scroll = 0
  self.hitRows = {}
  self:repaint()
end

function Panel:repaint()
  if self.shown and self.dlg then
    pcall(function() self.dlg:repaint() end)
  end
end

----------------------------------------------------------------------
-- 输入（画布显示 + 隐形 Entry 收键盘/输入法）
----------------------------------------------------------------------

function Panel:inputValue()
  return tostring(self.input or "")
end

-- 程序化设置输入内容（测试 / 探针 / agent 用）
function Panel:fillInput(text)
  self.input = tostring(text or "")
  self:_resetEntry(true)      -- 顺便把光标送回末尾，接着敲字才是接在后面
  self:repaint()
end

-- Entry 的内容永远是 SENTINEL（一个空格）；每次变化都按"差"算成插入 / 退格
function Panel:_onEntryChange()
  if self.entrySyncing then return end
  local raw = tostring((self.dlg and self.dlg.data.input) or "")

  local wasBackspace = false
  if raw == SENTINEL then
    return                                    -- 没变（例如只是移动了光标）
  elseif raw == "" then
    self:_inputBackspace()                    -- 哨兵被删掉 = 用户按了退格
    wasBackspace = true
  else
    local inserted = raw:gsub(SENTINEL, "", 1)   -- 只吃一个哨兵（用户输入的空格要留住）
    if inserted ~= "" then
      self.input = (self.input or "") .. inserted
    end
  end

  self:_resetEntry(wasBackspace)
  self:repaint()
end

-- 把 Entry 恢复成"只有一个哨兵"。
--
-- restoreCaret：退格之后【必须】把光标送回末尾，否则下一次退格删不动 ——
--   Entry::onSetText 只把 caret 往下 clamp、不会挪到末尾（entry.cpp:506），
--   而退格会把 caret 留在 0；caret 在 0 时前面没字符，再按退格 Entry 内容不变，
--   onchange 就不再触发 —— 表现就是"只能删一个字，删不掉前面的"（用户实测）。
--
-- 送 caret 的唯一 Lua 途径是让焦点绕一圈：先让给别的控件再抢回来，
-- 这会触发 kFocusEnterMessage -> selectAllText() -> setCaretPos(lastCaretPos())，
-- 即把 caret 放到末尾（entry.cpp:283-295）。只在退格时做，打字时不绕，
-- 免得频繁关开输入法（setTextInput）打断 IME 组合。
function Panel:_resetEntry(restoreCaret)
  if not self.dlg then return end
  self.entrySyncing = true
  self:_preserveBounds(function()
    self.dlg:modify{ id = "input", text = SENTINEL }
    if restoreCaret then
      self.dlg:modify{ id = "send", focus = true }
      self.dlg:modify{ id = "input", focus = true }
    end
  end)
  self.entrySyncing = false
  self.inputFocused = true          -- 绕完一圈，焦点回到输入框
end

function Panel:_inputBackspace()
  local s = self.input or ""
  if s == "" then return end
  local i = utf8.offset(s, -1)
  self.input = i and s:sub(1, i - 1) or ""
end

-- ↑ / ↓ 翻历史（控制台 / 终端习惯）；Esc = 关菜单 / 中断当前任务（P3）
function Panel:_onKeyDown(ev)
  if ev.code == "ArrowUp" then
    self:_history(-1)
    if ev.stopPropagation then ev.stopPropagation() end
    self:repaint()
  elseif ev.code == "ArrowDown" then
    self:_history(1)
    if ev.stopPropagation then ev.stopPropagation() end
    self:repaint()
  elseif ev.code == "Escape" then
    if self.menuOpen then
      self:closeMenu()
      self:repaint()
    elseif self.busy then
      if self.opts.onAction then self.opts.onAction("abort") end
    end
    if ev.stopPropagation then ev.stopPropagation() end
  end
end

-- pos: 0 = 草稿行；1 = 最近一条历史，n = 最早一条
function Panel:_history(delta)
  local n = #self.history
  if n == 0 then return end

  local pos = self.historyPos or 0
  if delta < 0 and not self.inHistory then
    self.inHistory = true
    self.draft = self.input or ""
    pos = 1
  elseif self.inHistory then
    pos = pos - delta
    if pos < 0 then pos = 0 end
    if pos > n then pos = n end
    if pos == 0 then self.inHistory = false end
  end
  self.historyPos = pos

  local text = (pos == 0) and (self.draft or "") or self.history[n - pos + 1]
  self:fillInput(text)
  if self.dlg then
    self:_preserveBounds(function() self.dlg:modify{ id = "input", focus = true } end)
    self.inputFocused = true
  end
  self:repaint()
end

----------------------------------------------------------------------
-- 提交
----------------------------------------------------------------------

function Panel:_submit()
  local text = tostring(self.input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  self:fillInput("")
  if text == "" then return end

  -- 有正在等回答的提问：数字/字母先当成回答（这是阻塞式问题，优先级最高）
  if self.pendingAsk then
    local ans = self:_interpretAskInput(text)
    if ans ~= nil then
      self:echo(text)
      if self.opts.onAskAnswer then self.opts.onAskAnswer(ans) end
      return
    end
  end

  -- 命令表开着：编号 / 键位 / x 关闭
  if self.menuOpen then
    if i18n.isMenuClose(text) then
      self.menuOpen = false
      self.menuHover = 0
      self:log(i18n.t("menuClosed"), "info")
      return
    end
    local idx = menu.resolveInput(self.menuRows, text)
    if idx then
      self:_runMenuIndex(idx)
      return
    end
  end

  -- 历史
  if self.history[#self.history] ~= text then
    self.history[#self.history + 1] = text
    while #self.history > 100 do table.remove(self.history, 1) end
  end
  self.historyPos = 0
  self.inHistory = false

  -- 内建命令（中英都能敲）
  local bi = i18n.builtinAction(text)
  if bi == "menu" then
    self:openMenu()
    return
  elseif bi == "clear" then
    self:clear()
    self:log(i18n.t("clearDone"), "info")
    return
  elseif bi == "help" then
    self:echo(text)
    self:log(i18n.helpText(), "ai")
    return
  elseif bi == "@exit" then
    self:echo(text)
    self:log(i18n.t("bye"), "info")
    self:hide()
    return
  elseif bi and bi ~= "" then
    self:echo(i18n.miniLabel(bi))
    if self.opts.onAction then self.opts.onAction(bi) end
    return
  end

  -- 其余原样发给 AI
  self:echo(text)
  if self.opts.onSend then self.opts.onSend(text) end
end

-- 滚轮翻历史。
-- 终端惯例：滚轮【上】= 往历史翻（scroll 增大），滚轮【下】= 回最新（scroll 归 0）。
-- deltaY > 0 是滚轮向下，所以这里是 -1。上界在 _paint 里钳（那里才知道行数）。
-- 抽成方法是为了无头测试能直接调（闭包里的处理器在 -b 模式下拿不到）。
function Panel:_onWheel(ev)
  local dy = (ev and ev.deltaY) or 0
  if dy == 0 then return end          -- 水平滚动 / 空事件：别白翻一页
  self.scroll = math.max(0, self.scroll + (dy > 0 and -1 or 1) * 3)
  self:repaint()
end

function Panel:_onCanvasMouseMove(ev)
  if self:_onBarMouseMove(ev) then return end
  local idx = self:_menuIndexAt(ev.x or 0, ev.y or 0)
  if (idx or 0) ~= (self.menuHover or 0) then
    self.menuHover = idx or 0
    self:repaint()          -- 悬浮高亮必须重绘，否则屏幕上什么都看不到
  end
end

-- 点画布空白处 = 把焦点还给输入点（终端习惯：点了就能接着打字）。
--
-- 这里有两个坑（都实测过，见 tests/lua/gui_resize_probe.lua 的输出）：
--   1) `dlg:modify` 会触发一次重新布局，而 Aseprite 的布局会把窗口**按内容撑回
--      自然尺寸** —— 用户手动把窗口缩小后，点一下内部就"跳回原大小"，就是这么来的。
--      实测：设成 320x220 -> 点一下 -> 变回 672x467。
--   2) 焦点状态没有 API 可读，只能自己记（self.inputFocused）。
-- 所以：焦点已经在输入框 -> 什么都不做；窗口已经不是自然尺寸（用户拖过）-> 也不动，
-- 免得把用户调好的尺寸冲掉。自然尺寸在第一次绘制时（_paint）记下来。
-- 所有 dlg:modify 都要包在这里面。
--
-- 原因（实测）：`modify` 会触发一次重新布局，Aseprite 顺手把窗口**按内容自然尺寸
-- 撑开**。用户手动缩小窗口之后，每敲一个字（输入要重置哨兵 = 一次 modify）、
-- 每点一下画布（改焦点 = 一次 modify）都会"跳回原大小"。
-- 所以这里在 modify 前后各读一次 bounds，变了就放回去 —— 比"猜什么时候不该 modify"
-- 可靠得多，也不会牺牲点一下就能接着打字的手感。
function Panel:_preserveBounds(fn)
  local before = nil
  if self.dlg and self.shown then
    local ok, b = pcall(function() return self.dlg.bounds end)
    if ok and b and (b.width or 0) > 0 and (b.height or 0) > 0 then
      before = { x = b.x, y = b.y, w = b.width, h = b.height }
    end
  end

  local ok, err = pcall(fn)

  if before and self.dlg then
    local ok2, b2 = pcall(function() return self.dlg.bounds end)
    if ok2 and b2 and ((b2.width or 0) ~= before.w or (b2.height or 0) ~= before.h) then
      pcall(function()
        self.dlg.bounds = Rectangle(before.x, before.y, before.w, before.h)
      end)
    end
  end

  if not ok then error(err) end
end

function Panel:_onCanvasMouseDown(ev, dlg)
  if ev.button ~= MouseButton.LEFT then return end
  if self:_onBarMouseDown(ev) then return end
  if self:_menuIndexAt(ev.x or 0, ev.y or 0) then return end
  if self.inputFocused then return end
  dlg = dlg or self.dlg
  if not dlg then return end
  self:_preserveBounds(function() dlg:modify{ id = "input", focus = true } end)
  self.inputFocused = true
end

function Panel:_onCanvasMouseUp(ev)
  if ev.button == MouseButton.LEFT then self:_onBarMouseUp() end
  if ev.button == MouseButton.LEFT and self.menuOpen then
    local idx = self:_menuIndexAt(ev.x or 0, ev.y or 0)
    if idx then self:_runMenuIndex(idx) end
  end
end

----------------------------------------------------------------------
-- 选项式提问（P7）
--
-- AI 问"要 A 还是 B"时：终端里列出编号选项（敲数字也能答），
-- 同时由 agent 弹一个原生按钮窗（点选）。两条通道都通到同一个回调。
----------------------------------------------------------------------

-- 取消词（大小写不敏感，仅 ASCII 才做小写）
local ASK_CANCEL = {
  x = true, q = true, esc = true, cancel = true, skip = true, none = true,
  ["取消"] = true, ["放弃"] = true, ["算了"] = true, ["不了"] = true, ["关闭"] = true,
}

function Panel:setAsk(ask, silent)
  self.pendingAsk = ask
  if ask and not silent then
    self:log(tostring(ask.question or ""), "ai")
    for i, opt in ipairs(ask.options or {}) do
      self:log(string.format(i18n.t("askOption"), i, tostring(opt)), "menu")
    end
    self:log(i18n.t("askHint"), "info")
  end
  self:repaint()
end

function Panel:askIsPending() return self.pendingAsk ~= nil end

-- 把一行输入解释成"对当前提问的回答"：返回 1..n、或 "cancel"、或 nil（不是回答）
function Panel:_interpretAskInput(text)
  if not self.pendingAsk then return nil end
  local s = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  local n = #(self.pendingAsk.options or {})

  local num = tonumber(s)
  if num and num == math.floor(num) and num >= 1 and num <= n then return num end

  if #s == 1 and s:find("^[%z\1-\127]+$") then
    local idx = s:lower():byte() - string.byte("a") + 1
    if idx >= 1 and idx <= n then return idx end
  end

  local key = s:find("^[%z\1-\127]+$") and s:lower() or s
  if ASK_CANCEL[key] then return "cancel" end
  return nil
end

----------------------------------------------------------------------
-- 形态：面板 / 底边栏 / 侧边栏（P12）
--
-- 极限说清楚：Aseprite 没给脚本"停靠进主窗口"的接口，也读不到主窗口几何，
-- 所以这里做的是"把窗口缩成一条 + 布局换成栏的形态"，位置沿用当前 x/y，
-- 用户拖到底边/右边就得到想要的效果。配色用自绘的深色（和面板一致）：
-- app.theme 只暴露一个 color 成员（实测），拿不到整套主题色。
----------------------------------------------------------------------

function Panel:layoutMode() return self.mode or "panel" end

-- 栏底色（G5）。传空/"#" = 恢复默认
function Panel:setBarColor(text)
  self.barBg = panel.parseHexColor(text)
  self:repaint()
  return self.barBg ~= nil
end

-- 形态名（状态栏用）
function Panel:modeLabel(mode)
  mode = mode or self:layoutMode()
  if mode == "bar_bottom" then return i18n.t("modeBarBottom") end
  if mode == "bar_side" then return i18n.t("modeBarSide") end
  return i18n.t("modePanel")
end

-- 栏形态贴哪儿：app.window.width/height 和 dlg.bounds 同一坐标系（miniwindow 也是这么用的）。
-- 拿不到就返回 nil，调用方沿用它原来的位置。
function Panel:_barAnchor(mode)
  local W, H = 0, 0
  pcall(function() W = app.window.width or 0 end)
  pcall(function() H = app.window.height or 0 end)
  if W <= 0 or H <= 0 then return nil end

  local bw, bh = self:_modeSize(mode)
  if mode == "bar_bottom" then
    -- 底边栏：水平居中，贴底
    return math.max(0, math.floor((W - bw) / 2)), math.max(0, H - bh)
  end
  -- 侧边栏：贴右，垂直居中
  return math.max(0, W - bw), math.max(0, math.floor((H - bh) / 2))
end

-- 形态的窗口尺寸（含边框余量）。主窗口比目标还小的时候按主窗口收缩 ——
-- 否则底边栏会宽过主窗口，看着像跑出去了。
function Panel:_modeSize(mode)
  local c = MODE_CANVAS[mode] or MODE_CANVAS.panel
  local ww, wh = c.w + CHROME_W, c.h + CHROME_H
  if mode ~= "panel" then
    local W, H = 0, 0
    pcall(function() W = app.window.width or 0 end)
    pcall(function() H = app.window.height or 0 end)
    if W > 0 then ww = math.min(ww, W - 8) end
    if H > 0 then wh = math.min(wh, H - 8) end
  end
  return ww, wh
end

-- 返回实际生效的形态名
function Panel:setMode(mode, quiet)
  local valid = false
  for _, m in ipairs(MODE_ORDER) do if m == mode then valid = true end end
  if not valid then mode = "panel" end
  self.mode = mode

  if self.dlg and self.shown then
    local ww, wh = self:_modeSize(mode)

    -- 顺序很重要：modify 会触发一次重新布局，把窗口按内容撑回自然尺寸。
    -- 先 modify（改焦点），**最后**才设 bounds —— 反过来的话 bounds 会被那次布局冲掉
    -- （实测：先设 bounds 再 modify，读回来还是旧尺寸）。
    self.inputFocused = false
    pcall(function() self.dlg:modify{ id = "input", focus = true } end)
    self.inputFocused = true

    local x, y = nil, nil
    if mode ~= "panel" then
      x, y = self:_barAnchor(mode)
    end
    if not x then
      local ok, b = pcall(function() return self.dlg.bounds end)
      if ok and b then x, y = b.x, b.y end
    end
    if x and y then
      pcall(function() self.dlg.bounds = Rectangle(x, y, ww, wh) end)
    end
  end

  if not quiet then self:log(string.format(i18n.t("modeChanged"), self:modeLabel()), "info") end
  if self.opts.onModeChange then
    local ok, err = pcall(self.opts.onModeChange, self.mode)
    if not ok then self:log(tostring(err), "error") end
  end
  self:repaint()
  return self.mode
end

function Panel:cycleMode()
  local cur = self:layoutMode()
  for i, m in ipairs(MODE_ORDER) do
    if m == cur then
      return self:setMode(MODE_ORDER[i % #MODE_ORDER + 1])
    end
  end
  return self:setMode("panel")
end

function Panel:isBar() return self:layoutMode() ~= "panel" end

-- 把一行文本裁到宽度 maxW 以内。keepTail=true 保留尾部（输入行长、要看到光标附近）
function Panel:_clipToWidth(gc, text, maxW, keepTail)
  text = tostring(text or "")
  if maxW <= 0 then return "" end
  if self:_textWidth(gc, text) <= maxW then return text end

  local chars = {}
  for _, code in utf8.codes(text) do chars[#chars + 1] = utf8.char(code) end
  if keepTail then
    local out = {}
    for i = #chars, 1, -1 do
      table.insert(out, 1, chars[i])
      if self:_textWidth(gc, table.concat(out)) > maxW - 12 then
        table.remove(out, 1)
        break
      end
    end
    return "…" .. table.concat(out)
  end
  local out = {}
  for i = 1, #chars do
    out[#out + 1] = chars[i]
    if self:_textWidth(gc, table.concat(out)) > maxW - 12 then
      table.remove(out)
      break
    end
  end
  return table.concat(out) .. "…"
end

----------------------------------------------------------------------
----------------------------------------------------------------------
-- 栏内控件：设置 / 绘制 / 命中
--
-- 尺寸是"塞进输入行"的尺寸：整条栏只有 60px 高、输入行 ~18px，
-- 所以缩略图 16px、电量条 20 格每格 3px、滑杆 44px —— 全部和输入框同一行，
-- 不额外占高度、不额外占一块地方。文字标签只在放得下的时候才画。
----------------------------------------------------------------------

-- 桥每步都会推一次用量（{type="context"}），面板只管显示
function Panel:setContext(used, budget)
  used = tonumber(used) or 0
  budget = tonumber(budget) or 0
  if used == self.ctx.used and budget == self.ctx.budget then return end
  self.ctx.used, self.ctx.budget = used, budget
  self:repaint()
end

function Panel:contextUsage() return self.ctx.used, self.ctx.budget end

-- 用了几格（0..CTX_CELLS）。预算未知时按 0 格算。
function Panel:ctxFilled()
  local used, budget = self.ctx.used, self.ctx.budget
  if budget <= 0 then return 0 end
  local n = math.floor(used / budget * CTX_CELLS + 0.5)
  if n < 0 then n = 0 end
  if n > CTX_CELLS then n = CTX_CELLS end
  return n
end

function Panel:ctxColor()
  local used, budget = self.ctx.used, self.ctx.budget
  local ratio = (budget > 0) and (used / budget) or 0
  if ratio >= 0.85 then return STATUS_ERROR end
  if ratio >= 0.6 then return STATUS_WARN end
  return STATUS_OK
end

-- "8.2k/16k" 这种短标签（栏里寸土寸金）
function Panel:ctxLabel()
  local function short(n)
    n = math.floor(n)
    if n >= 1000 then
      if n % 1000 == 0 then return string.format("%dk", n / 1000) end
      return string.format("%.1fk", n / 1000)
    end
    return tostring(n)
  end
  if self.ctx.budget <= 0 then return "-" end
  return short(self.ctx.used) .. "/" .. short(self.ctx.budget)
end

-- 桥发来的权威值（配置回推 / 启动恢复）：连"已提交"一起对齐
function Panel:setThinking(value)
  value = tostring(value or "auto"):lower()
  local ok = false
  for _, v in ipairs(THINK_STEPS) do if v == value then ok = true end end
  if not ok then value = "auto" end
  self.thinkCommitted = value
  if value == self.thinking then return end
  self.thinking = value
  self:repaint()
end

function Panel:thinkIndex()
  for i, v in ipairs(THINK_STEPS) do if v == self.thinking then return i end end
  return 1
end

-- 按档位设置。commit=true 才回调（= 真的写回桥）。
-- 拖拽过程中只改视觉，松手才提交 —— 否则拖一次滑杆会写 4 次配置、刷 4 条日志。
function Panel:setThinkIndex(i, commit)
  if i < 1 then i = 1 end
  if i > #THINK_STEPS then i = #THINK_STEPS end
  local v = THINK_STEPS[i]
  local changed = (v ~= self.thinking)
  self.thinking = v
  -- 提交的判据是"和已写回桥的那一档不同"，不是"和当前显示的不同" ——
  -- 拖到 low 再松手时当前值早就是 low 了，按当前值比就永远不会提交（实测踩过）。
  if commit and v ~= self.thinkCommitted and self.opts.onThinkingChange then
    self.thinkCommitted = v
    local ok, err = pcall(self.opts.onThinkingChange, v)
    if not ok then self:log(tostring(err), "error") end
  end
  if changed then self:repaint() end
  return v
end

function Panel:thinkLabel()
  return tostring(i18n.t("thinkPrefix")) .. self.thinking
end

-- 缩略图：把 agent 给的整幅合成图按最近邻缩到外框里（保持长宽比）。
-- 一次 16x16 ≈ 256 次字节取，几乎不花时间，所以不做缓存 —— 每帧重采样，
-- 画布一改缩略图立刻跟着变，不会出现"缩略图比画布旧"的怪现象。
function Panel:thumbImage(boxW, boxH)
  if not self.opts.frameImage then return nil end
  local ok, src = pcall(self.opts.frameImage)
  if not ok or not src then return nil end
  local sw, sh = src.width or 0, src.height or 0
  if sw <= 0 or sh <= 0 or src.bytesPerPixel ~= 4 then return nil end

  local scale = math.min(boxW / sw, boxH / sh)
  local tw = math.max(1, math.floor(sw * scale + 0.5))
  local th = math.max(1, math.floor(sh * scale + 0.5))
  local dst = Image(tw, th, ColorMode.RGB)
  local sb = src.bytes
  local sstride = src.rowStride
  local rows = {}
  for y = 0, th - 1 do
    local sy = math.min(sh - 1, math.floor(y * sh / th))
    local row = {}
    for x = 0, tw - 1 do
      local sx = math.min(sw - 1, math.floor(x * sw / tw))
      local p = sy * sstride + sx * 4 + 1
      row[#row + 1] = sb:sub(p, p + 3)
    end
    rows[#rows + 1] = table.concat(row)
  end
  dst.bytes = table.concat(rows)
  return dst
end

-- 控件区宽度预算（面板模式与栏模式共用同一套算法，保证切形态不会"少东西"）。
-- 放不下就先丢文字标签，再放不下就整体不画 —— 绝不挤掉输入框。
function Panel:_clusterPlan(w, minTextW)
  minTextW = minTextW or 130
  local base = THUMB_BOX + 2 + THUMB_BOX + 6
    + (CTX_CELLS * (CTX_CELL_W + CTX_CELL_GAP)) + 8 + THINK_TRACK_W + 6 + DOCK_BOX_W + 6
  local withLabel = (base + 4 + 48) <= (w - minTextW)
  local cw = withLabel and (base + 4 + 48) or base
  if cw > w - minTextW then return 0, false end
  return cw, withLabel
end

-- 贴边切换按钮：图标画成"一个小窗口 + 贴住底边/右边的高亮"，不依赖字体字形。
function Panel:_drawDock(gc, x, y)
  local w, h = DOCK_BOX_W, DOCK_BOX_H
  local mode = self:layoutMode()
  gc.color = FRAME
  gc:fillRect(Rectangle(x, y, w, h))
  gc.color = DIM
  gc:fillRect(Rectangle(x + 1, y + 1, w - 2, h - 2))
  gc.color = (mode == "panel") and TEXT or STATUS_TOOL
  if mode == "bar_side" then
    gc:fillRect(Rectangle(x + w - 4, y + 1, 3, h - 2))       -- 贴右边
  else
    gc:fillRect(Rectangle(x + 1, y + h - 4, w - 2, 3))       -- 贴底边（面板模式也画这个＝点一下去贴底）
  end
  self.barHit[#self.barHit + 1] = { kind = "dock", x = x, y = y, w = w, h = h }
  return w
end

-- 整串控件：工作图片 / 电量条 / 思考滑杆 / 贴边切换。在 x..x+clusterW 内右对齐摆好。
function Panel:_drawCluster(gc, x, y, clusterW, ctxLabel)
  local cy = y + math.floor((CTX_CELL_H_LINE - THUMB_BOX) / 2)
  x = x + self:_drawWork(gc, x, cy, THUMB_BOX) + 6
  x = x + self:_drawCtx(gc, x, y, ctxLabel) + 8
  x = x + self:_drawThink(gc, x, y) + 6
  self:_drawDock(gc, x, y + math.floor((CTX_CELL_H_LINE - DOCK_BOX_H) / 2))
end

-- 贴底 / 贴侧边 两态切换（"面板"模式下点一下 = 去贴底）。
function Panel:toggleDock()
  local cur = self:layoutMode()
  local next_ = (cur == "bar_side") and "bar_bottom" or (cur == "bar_bottom" and "bar_side" or "bar_bottom")
  return self:setMode(next_)
end

-- 工作图片缩略图 + "＋"（打开一张新的）。返回占用的宽度。
function Panel:_drawWork(gc, x, y, box)
  gc.color = FRAME
  gc:fillRect(Rectangle(x, y, box, box))
  local img = self:thumbImage(box - 2, box - 2)
  if img then
    local ox = x + math.floor((box - img.width) / 2)
    local oy = y + math.floor((box - img.height) / 2)
    pcall(function() gc:drawImage(img, ox, oy) end)
  end

  local bw = box
  local bx = x + box + 2
  gc.color = FRAME
  gc:fillRect(Rectangle(bx, y, bw, box))
  gc.color = TEXT
  gc:fillText("+", bx + math.max(2, math.floor(bw / 2) - 2), y + math.max(0, math.floor(box / 2) - 7))

  self.barHit[#self.barHit + 1] = { kind = "work", x = x, y = y, w = box, h = box }
  self.barHit[#self.barHit + 1] = { kind = "open", x = bx, y = y, w = bw, h = box }
  return box + 2 + bw
end

-- 上下文电量条：20 格（单行）。withLabel 时在后面跟一个 "8.2k/16k"。
function Panel:_drawCtx(gc, x, y, withLabel)
  local cellW, gap = CTX_CELL_W, CTX_CELL_GAP
  local filled = self:ctxFilled()
  local cy = y + math.floor((CTX_CELL_H_LINE - CTX_CELL_H) / 2)
  for i = 1, CTX_CELLS do
    if i <= filled then gc.color = self:ctxColor() else gc.color = FRAME end
    gc:fillRect(Rectangle(x + (i - 1) * (cellW + gap), cy, cellW, CTX_CELL_H))
  end
  local w = CTX_CELLS * (cellW + gap) - gap
  if withLabel then
    gc.color = DIM
    local label = self:ctxLabel()
    gc:fillText(label, x + w + 4, y)
    local lblW = self:_textWidth(gc, label)
    w = w + 4 + lblW
  end
  self.barHit[#self.barHit + 1] = { kind = "ctx", x = x, y = y, w = w, h = CTX_CELL_H_LINE }
  return w
end

-- 思考强度滑杆：4 档，点一下或拖着走都行（单行）。
function Panel:_drawThink(gc, x, y)
  local ty = y + math.floor(CTX_CELL_H_LINE / 2)
  gc.color = FRAME
  gc:fillRect(Rectangle(x, ty - 1, THINK_TRACK_W, 3))

  local idx = self:thinkIndex()
  for i = 1, #THINK_STEPS do
    local kx = x + math.floor((i - 1) * (THINK_TRACK_W - 1) / (#THINK_STEPS - 1))
    gc.color = (i <= idx) and STATUS_TOOL or DIM
    gc:fillRect(Rectangle(kx, ty - 5, 2, 11))
  end
  local kx = x + math.floor((idx - 1) * (THINK_TRACK_W - 1) / (#THINK_STEPS - 1))
  gc.color = STATUS_BUSY
  gc:fillRect(Rectangle(kx - THINK_KNOB_R, ty - THINK_KNOB_R, THINK_KNOB_R * 2 + 2, THINK_KNOB_R * 2))

  self.thinkTrack = { x = x, y = ty - 8, w = THINK_TRACK_W, h = 16 }
  self.barHit[#self.barHit + 1] = { kind = "think", x = x, y = ty - 8, w = THINK_TRACK_W, h = 16 }
  return THINK_TRACK_W
end

-- 命中查询（只有栏模式会填 barHit）
function Panel:_barHitAt(x, y)
  for _, b in ipairs(self.barHit or {}) do
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return b end
  end
  return nil
end

-- 滑杆：把画布 x 映射成档位
function Panel:_thinkIndexAt(x)
  local t = self.thinkTrack
  if not t or t.w <= 1 then return self:thinkIndex() end
  local frac = (x - t.x) / (t.w - 1)
  if frac < 0 then frac = 0 end
  if frac > 1 then frac = 1 end
  return math.floor(frac * (#THINK_STEPS - 1) + 0.5) + 1
end

function Panel:_onBarMouseDown(ev)
  local hit = self:_barHitAt(ev.x or 0, ev.y or 0)
  if not hit then return false end
  if hit.kind == "think" then
    self.thinkDrag = true
    self:setThinkIndex(self:_thinkIndexAt(ev.x or 0), true)   -- 单击也算一次提交
  elseif hit.kind == "open" or hit.kind == "work" then
    if self.opts.onAction then self.opts.onAction("open_file") end
  elseif hit.kind == "ctx" then
    if self.opts.onAction then self.opts.onAction("ctx_info") end
  elseif hit.kind == "dock" then
    self:toggleDock()
  end
  return true          -- 命中控件 = 不要再把焦点抢给输入框
end

function Panel:_onBarMouseMove(ev)
  if not self.thinkDrag then return false end
  self:setThinkIndex(self:_thinkIndexAt(ev.x or 0))          -- 拖着走：只动视觉
  return true
end

function Panel:_onBarMouseUp()
  if self.thinkDrag then
    self.thinkDrag = false
    self:setThinkIndex(self:thinkIndex(), true)              -- 松手才写回桥
  end
end


-- 栏形态的绘制：状态行（上）+ 最后一行输出（中，够高才画）+ 输入行（下）
function Panel:_paintBar(gc)
  local w, h = gc.width, gc.height
  local szC = gc:measureText("中")
  local szL = gc:measureText("Ag")
  local lh = math.max(10, (szL and szL.height or 12), (szC and szC.height or 12))
  local rowH = math.max(lh, math.floor(lh * ROW_FACTOR + 0.5))

  local rows = math.max(1, math.floor(h / rowH))
  local y = 2

  -- 控件都摆在【输入行】上（和输入框同一行、右对齐），不额外占高度。
  -- 预算算法和面板模式共用（_clusterPlan），保证切形态不会"少东西"。
  local clusterW, ctxLabel = self:_clusterPlan(w, 130)

  -- 1) 状态行
  gc.color = STATUS_COLORS[self.statusKind or "ok"] or STATUS
  local spin = ""
  if self.busy then spin = SPIN_FRAMES[self.spinIdx or 1] .. " " end
  local extras = ""
  if self.miniShown then extras = extras .. "  ▣" end
  if self.scroll > 0 then extras = extras .. "  ↕" end
  local docSuffix = ""
  if self.docName and self.docName ~= "" then docSuffix = "   ｜ " .. tostring(self.docName) end
  local statusText = spin .. string.format(i18n.t("statusBar"), self.status) .. docSuffix .. extras
  gc:fillText(self:_clipToWidth(gc, statusText, w - 12, false), 6, y)
  y = y + rowH

  -- 2) 最后一行输出（高度够才画）
  if rows >= 3 then
    local last = nil
    for i = #self.lines, 1, -1 do
      if self.lines[i].text ~= "" then last = self.lines[i] break end
    end
    if last then
      gc.color = KIND_COLOR[last.kind] or TEXT
      gc:fillText(self:_clipToWidth(gc, last.text, w - 12, false), 6, y)
    end
    y = y + rowH
  end

  -- 3) 输入行（贴底）
  local mark = i18n.promptMark()
  local markW = self:_textWidth(gc, mark)
  local inputY = math.max(y, h - rowH)
  -- 窗口矮到放不下状态行+输入行时，宁可让它们重叠，也不能把输入行（和它上面的控件）
  -- 画到画布外 —— 用户看到的会是"控件不见了"。
  if inputY + rowH > h then inputY = math.max(0, h - rowH) end
  gc.color = USER
  gc:fillText(mark, 6, inputY)
  local shown = tostring(self.input or "")
  local inputMaxW = w - 18 - markW - clusterW
  if shown == "" then
    gc.color = DIM
    gc:fillText(self:_clipToWidth(gc, i18n.t("inputHint"), inputMaxW, false), 6 + markW, inputY)
  else
    shown = self:_clipToWidth(gc, shown, inputMaxW, true)
    gc.color = USER
    gc:fillText(shown, 6 + markW, inputY)
    gc:fillRect(Rectangle(6 + markW + self:_textWidth(gc, shown) + 1, inputY, 5, lh))
  end

  -- 4) 控件：就和输入行同高、右对齐（"和输入框一个地方"）
  if clusterW > 0 then
    self:_drawCluster(gc, w - clusterW + 2,
      inputY + math.floor((rowH - CTX_CELL_H_LINE) / 2), clusterW, ctxLabel)
  end

  self.dbg = string.format("bar mode=%s w=%d h=%d rows=%d ctx=%d/%d think=%s",
    self:layoutMode(), w, h, rows, self.ctx.used, self.ctx.budget, tostring(self.thinking))
  self.hitRows = {}
end

----------------------------------------------------------------------
-- 命令表（打印出来的文字表）
----------------------------------------------------------------------

function Panel:_menuRowData()
  if self.opts.menuCommands then
    local ok, res = pcall(self.opts.menuCommands)
    if ok and res then return res end
  end
  return {}
end

-- 打印一份新的命令表到滚回缓冲
function Panel:_printMenuTable()
  self.menuRows = self:_menuRowData()
  self:log(menu.titleLine(i18n), "info")
  local lines = menu.tableLines(self.menuRows)
  if #lines == 0 then
    self:log(i18n.t("noCommands"), "info")
    return
  end
  for _, l in ipairs(lines) do
    self:log(l.text, "menu", { menuIndex = l.index })
  end
end

function Panel:openMenu()
  self:show()
  self.menuOpen = true
  self.menuHover = 0
  self:_printMenuTable()
  self:repaint()
end

function Panel:closeMenu()
  if not self.menuOpen then return end
  self.menuOpen = false
  self.menuHover = 0
  self:log(i18n.t("menuClosed"), "info")
end

function Panel:menuIsOpen() return self.menuOpen and true or false end

function Panel:_runMenuIndex(idx)
  local row = self.menuRows and self.menuRows[idx]
  if not row then return end
  self.menuHover = 0

  local id = row.id
  if id == "clear" then
    self:clear()
    self:log(i18n.t("clearDone"), "info")
  elseif id == "help" then
    self:log(i18n.helpText(), "ai")
  else
    self:echo(string.format("%d:%s  %s", idx, tostring(row.keys or ""), tostring(row.label or id)))
    if self.opts.onAction then self.opts.onAction(id) end
  end

  -- 执行后自动重打一份（旧的往上滚）
  if self.menuOpen then self:_printMenuTable() end
end

-- 鼠标命中：返回命中行的菜单序号
function Panel:_menuIndexAt(x, y)
  for _, b in ipairs(self.hitRows) do
    if y >= b.y and y < b.y + b.h and x >= b.x and x < b.x + b.w then
      return b.index
    end
  end
  return nil
end

----------------------------------------------------------------------
-- 图片矫正：队列 + 小确认窗（两段式）
----------------------------------------------------------------------

function Panel:fixQueueSize() return #(self.fixQueue or {}) end

function Panel:addFixFile(path)
  self.fixQueue = self.fixQueue or {}
  path = tostring(path or "")
  if path == "" then return end
  for _, p in ipairs(self.fixQueue) do
    if p == path then return end              -- 去重
  end
  self.fixQueue[#self.fixQueue + 1] = path
  self:_showFixDialog()
end

function Panel:_showFixDialog()
  if not self.dlg then return end

  local d = self.fixDlg
  if not d then
    d = Dialog{ title = i18n.t("fixTitle"), resizeable = false }
    if not d then return end

    d:label{ id = "fixIntro", text = i18n.t("fixIntro") }
    d:newrow()
    for i = 1, 5 do                     -- 最多列 5 条
      d:label{ id = "fixRow" .. i, text = "" }
      d:newrow()
    end
    d:label{ id = "fixCount", text = "" }
    d:newrow()
    d:button{ id = "fixAdd", text = i18n.t("fixAdd"), hexpand = false,
              onclick = function() self:_fixAddMore() end }
    d:button{ id = "fixRun", text = i18n.t("fixRun"), focus = true, hexpand = false,
              onclick = function() self:_fixStart() end }
    d:button{ id = "fixCancel", text = i18n.t("fixCancel"), hexpand = false,
              onclick = function() self:_fixClose() end }

    self.fixDlg = d
  end

  -- 刷新列表
  local q = self.fixQueue or {}
  for i = 1, 5 do
    local text = ""
    if q[i] then
      text = "   " .. app.fs.fileName(q[i])
      if i == 5 and #q > 5 then text = text .. string.format(i18n.t("fixMore"), #q - 5) end
    end
    pcall(function() d:modify{ id = "fixRow" .. i, text = text } end)
  end
  pcall(function()
    d:modify{ id = "fixCount", text = string.format(i18n.t("fixCount"), #q) }
  end)

  pcall(function() d:show{ wait = false } end)
end

function Panel:_fixAddMore()
  if self.opts.onAction then self.opts.onAction("fixadd") end
end

function Panel:_fixStart()
  local q = self.fixQueue or {}
  if #q == 0 then return end
  self.fixQueue = {}
  self:_fixClose()
  if self.opts.onFixRun then self.opts.onFixRun(q) end
end

function Panel:_fixClose()
  if self.fixDlg then pcall(function() self.fixDlg:close() end) end
  self.fixDlg = nil
end

function Panel:fixDialogIsOpen() return self.fixDlg ~= nil end

----------------------------------------------------------------------
-- 选项窗（P7）：把 ask 的选项做成一排原生按钮，点一下就答
--
-- 复用 fix 对话框的写法：按钮在【创建时】定死尺寸，之后只能改 text/visible。
-- 所以固定建 4 个按钮位，按选项个数显示前 n 个、把多余的 visible=false。
-- 问题文本放 label（Aseprite 的 label 不自动折行，所以先手工折一下）。
----------------------------------------------------------------------

local ASK_WRAP = 46      -- 问题文本每行大致字符数（中英混排的折中）

local function wrapText(s, width)
  s = tostring(s or "")
  if #s <= width then return s end
  local out, line, n = {}, {}, 0
  for _, code in utf8.codes(s) do
    local ch = utf8.char(code)
    if ch == "\n" then
      out[#out + 1] = table.concat(line)
      line, n = {}, 0
    else
      table.insert(line, ch)
      n = n + 1
      if n >= width then
        out[#out + 1] = table.concat(line)
        line, n = {}, 0
      end
    end
  end
  if #line > 0 then out[#out + 1] = table.concat(line) end
  return table.concat(out, "\n")
end

-- 通用"选一个"对话框：ask（P7）和交付（P10）都用它。
-- question 是问题正文，options 是最多 4 个按钮文字，onPick(index) / onPick("cancel")。
function Panel:_showChoiceDialog(question, options, onPick, title)
  if not self.dlg then return end
  local d = self.askDlg
  if not d then
    d = Dialog{ title = title or i18n.t("askTitle"), resizeable = false,
                onclose = function() self:_onAskDialogClosed() end }
    if not d then return end

    d:label{ id = "askQ", text = "" }
    d:newrow()
    for i = 1, 4 do
      d:button{ id = "askOpt" .. i, text = "", hexpand = false,
                onclick = function() self:_answerFromDialog(i) end }
    end
    self.askDlg = d
  else
    pcall(function() d:modify{ id = "askQ", text = "" } end)
  end

  self.askPick = onPick
  pcall(function() d:modify{ id = "askQ", text = wrapText(question, ASK_WRAP) } end)
  local opts = options or {}
  for i = 1, 4 do
    pcall(function()
      if opts[i] then
        d:modify{ id = "askOpt" .. i, text = tostring(opts[i]), visible = true }
      else
        d:modify{ id = "askOpt" .. i, text = " ", visible = false }
      end
    end)
  end
  self.askShownOptions = opts
  pcall(function() d:show{ wait = false } end)
end

function Panel:_showAskDialog(ask)
  self:_showChoiceDialog(ask.question, ask.options, function(i) 
    if self.opts.onAskAnswer then self.opts.onAskAnswer(i) end
  end, i18n.t("askTitle"))
end

-- 交付对话框（P10）：四个选项
function Panel:showDeliverDialog(labels, onPick)
  self:_showChoiceDialog(i18n.t("wsQuestion"), labels, onPick, i18n.t("wsTitle"))
end

function Panel:_answerFromDialog(i)
  local pick = self.askPick
  self:_closeAskDialog()
  if pick then pick(i) end
end

-- 用户自己关掉选项窗 = 取消（别让桥那边挂着等 5 分钟）。
-- 我们自己 close 的时候会置 askClosing，避免"点选项"被当成"取消"。
function Panel:_onAskDialogClosed()
  if self.askClosing then return end
  local pick = self.askPick
  self.askDlg = nil
  self.askShownOptions = nil
  self.askPick = nil
  if pick then pick("cancel") end
end

function Panel:_closeAskDialog()
  if self.askDlg then
    self.askClosing = true
    pcall(function() self.askDlg:close() end)
    self.askClosing = false
  end
  self.askDlg = nil
  self.askShownOptions = nil
  self.askPick = nil
end

function Panel:askDialogIsOpen() return self.askDlg ~= nil end

----------------------------------------------------------------------
-- 小面板（6 个图标按钮，贴主窗口右下角）
----------------------------------------------------------------------

function Panel:_miniItems()
  -- 小面板：形态切换也放进去了（P12），图标复用现有的（resize 形状的没有，用 fix 的方块）
  local ids = { "snapshot", "rollback", "versions", "fix", "bar", "settings", "close" }
  local icons = {
    snapshot = "snapshot", rollback = "rollback", versions = "versions",
    fix = "fix", bar = "versions", settings = "settings", close = "clear",
  }
  local out = {}
  for _, id in ipairs(ids) do
    out[#out + 1] = { id = id, icon = icons[id], label = i18n.miniLabel(id) }
  end
  return out
end

function Panel:_miniAction(id)
  if self.opts.onMiniAction then
    local ok, handled = pcall(self.opts.onMiniAction, id)
    if ok and handled then return end
  end
  if self.opts.onAction then self.opts.onAction(id) end
end

-- 对话窗自己的 bounds（小面板要贴着它的右下角）。
-- 注意：dlg.bounds 只在窗口可见时读才安全 —— 不可见时读会触发 autoRemap 把它重新居中
-- （dialog_class.cpp:2020 Dialog_get_bounds 的副作用）。
function Panel:_anchorBounds()
  if not (self.shown and self.dlg) then return nil end
  local ok, b = pcall(function() return self.dlg.bounds end)
  if ok and b and (b.w or 0) > 0 then return b end
  return nil
end

function Panel:_toggleMini()
  local shown = self.mini:toggle(self:_anchorBounds())
  self.miniShown = shown
  self:repaint()
end

function Panel:showMini()
  self.mini:show(self:_anchorBounds())
  self.miniShown = self.mini:isShown()
end

function Panel:hideMini()
  self.mini:hide()
  self.miniShown = false
end

----------------------------------------------------------------------
-- 对话框
----------------------------------------------------------------------

function Panel:_build()
  if self.dlg then return self.dlg end

  local dlg = Dialog{ title = "AI Pixel Copilot", onclose = function() self.shown = false end }
  if not dlg then return nil end   -- 无头（-b）时 Dialog 构造返回 nil

  dlg:canvas{
    id = "screen",
    width = CANVAS_W,
    height = CANVAS_H,
    autoscaling = true,
    onpaint = function(ev) self:_paint(ev.context) end,
    onkeydown = function(ev) self:_onKeyDown(ev) end,
    onmousemove = function(ev) self:_onCanvasMouseMove(ev) end,
    onmousedown = function(ev) self:_onCanvasMouseDown(ev, dlg) end,
    onmouseup = function(ev) self:_onCanvasMouseUp(ev) end,
    onwheel = function(ev) self:_onWheel(ev) end,
  }

  -- 底部只有三样：输入框、回车磁吸按钮、小面板开关。
  --   * 必须 samerow：Aseprite 的对话框把"同一行里的按钮"放进 HOMOGENEOUS 的 hbox，
  --     一撑就是满行（实测两个按钮各占半屏）。先放 entry 建出普通 hbox，再 samerow 挂按钮，
  --     它们才保持各自的小尺寸。
  --   * 这里【曾经】在按钮后面挂过一块 hexpand 的黑画布，想把右侧涂成终端底色。去掉了：
  --     画布只能占自己那一格，格子四周的间距是对话框 grid 的主题 padding，涂不到；
  --     于是黑块被一圈米色框住，比原来的米色横条更突兀（用户实测反馈）。
  --     grid padding 没暴露给 Lua，想让整条底边变黑只能改主题（会波及整个 Aseprite）。
  --   * 按钮尺寸改不了：ui::Button 尺寸 = max(文本, 主题最小尺寸)，而 Lua 的 Dialog:modify
  --     只认 enabled/visible/text/label/focus（dialog_class.cpp:1528），没有 setMinSize；
  --     且磁吸按钮【必须可见】才吃 ENTER（button.cpp:95 isEnabled() && isVisible()）。
  --     所以这里保留原生按钮，不自绘。
  dlg:newrow()
  dlg:entry{
    id = "input",
    text = SENTINEL,
    hexpand = false,
    placeholder = "",
    onchange = function() self:_onEntryChange() end,
  }
  dlg:samerow()
  dlg:button{ id = "send", text = "⏎", hexpand = false, focus = true,
              onclick = function() self:_submit() end }
  dlg:samerow()
  dlg:button{ id = "more", text = "…", hexpand = false,
              onclick = function() self:_toggleMini() end }

  self.dlg = dlg
  return dlg
end

----------------------------------------------------------------------
-- 绘制
----------------------------------------------------------------------

function Panel:_charWidth(gc, ch)
  local w = self.charW[ch]
  if w == nil then
    local sz = gc:measureText(ch)
    w = sz and sz.width or 0
    if w <= 0 then w = 1 end
    self.charW[ch] = w
  end
  return w
end

-- 整串宽度：**必须整串量**。
-- 逐字 measureText 拿到的是单字"墨迹"宽，比排版推进宽度小（中文约差 10%），
-- 累加起来会让光标落在一行文字中间（实测踩过）。逐字累加只当兜底。
function Panel:_textWidth(gc, text)
  if text == "" then return 0 end
  local sz = gc:measureText(text)
  if sz and sz.width and sz.width > 0 then return sz.width end
  local w = 0
  for _, code in utf8.codes(text) do
    w = w + self:_charWidth(gc, utf8.char(code))
  end
  return w
end

-- 按宽度折行（保留 menuIndex，让折出来的续行也能点）
function Panel:_wrapTo(gc, text, maxW, kind, menuIndex)
  local rows = {}
  if text == "" then
    return { { text = "", kind = kind, menuIndex = menuIndex } }
  end
  local cur, curW = {}, 0
  for _, code in utf8.codes(text) do
    local s = utf8.char(code)
    local cw = self:_charWidth(gc, s)
    if curW + cw > maxW and #cur > 0 then
      rows[#rows + 1] = { text = table.concat(cur), kind = kind, menuIndex = menuIndex }
      cur, curW = {}, 0
    end
    cur[#cur + 1] = s
    curW = curW + cw
  end
  if #cur > 0 then
    rows[#rows + 1] = { text = table.concat(cur), kind = kind, menuIndex = menuIndex }
  end
  return rows
end

function Panel:_wrap(gc, maxW)
  if self.wrapWidth == maxW and not self.dirty then
    return self.wrapped
  end
  local rows = {}
  for _, line in ipairs(self.lines) do
    local sub = self:_wrapTo(gc, line.text, maxW, line.kind, line.menuIndex)
    for _, r in ipairs(sub) do rows[#rows + 1] = r end
  end
  self.wrapped = rows
  self.wrapWidth = maxW
  self.dirty = false
  return rows
end

function Panel:_paint(gc)
  local w, h = gc.width, gc.height
  self.canvasW, self.canvasH = w, h
  self.barHit = {}
  self.thinkTrack = nil

  -- 栏模式下底色可配置（G5）：Aseprite 读不到主题色（实测真名假名都返回 0,0,0），
  -- 所以给用户一个填色口来贴合自己的主题；没填就用面板默认深色。
  local bg = self:isBar() and self.barBg or BG
  gc.color = bg or BG
  gc:fillRect(Rectangle(0, 0, w, h))

  -- 栏形态走另一套布局（P12）
  if self:isBar() then
    self:_paintBar(gc)
    return
  end

  -- 窗口太小：画什么都看不清，只给一行明确的提示（P4 症状 B）。
  -- Aseprite 没暴露"给对话框设最小尺寸"的 API（Lua 的 Dialog:modify 只认
  -- enabled/visible/text/label/focus），而且【实测】canvas 的 autoscaling 设成
  -- true 或 false 都拦不住缩小（40x30 都设得进去，见 gui_resize_probe 输出），
  -- 所以只能这样兜底：让用户知道"不是坏了，是窗口太小"。
  if w < MIN_CANVAS_W or h < MIN_CANVAS_H then
    local sz = gc:measureText("Ag")
    local lh = math.max(10, sz and sz.height or 12)
    gc.color = STATUS_BUSY
    local msg = i18n.t("tooSmall")
    local okW = self:_textWidth(gc, msg)
    gc:fillText(msg, math.max(4, math.floor((w - okW) / 2)), math.max(4, math.floor((h - lh) / 2)))
    self.dbg = string.format("too small: %dx%d", w, h)
    self.hitRows = {}
    return
  end

  -- 行高要同时量拉丁与 CJK（中文字形更高，只按 "Ag" 算会让中文行互相压住）
  local szL = gc:measureText("Ag")
  local szC = gc:measureText("中")
  local lh = math.max(10, (szL and szL.height or 12), (szC and szC.height or 12))
  self.lineH = lh
  local rowH = math.max(lh, math.floor(lh * ROW_FACTOR + 0.5))

  ----------------------------------------------------------------------
  -- 1) 输入区：画在最下面，向上长（多行折行 + 块光标）
  ----------------------------------------------------------------------
  local mark = i18n.promptMark()
  local markW = self:_textWidth(gc, mark)
  -- 输入行右侧要留出控件区（工作图片 / 电量条 / 思考滑杆 / 贴边切换）——
  -- 这三种形态（面板、底边栏、侧边栏）都得有，否则"切形态就少东西"。
  local clusterW, ctxLabel = self:_clusterPlan(w, 150)
  local availW = w - 18 - markW - clusterW

  local inputRows
  if tostring(self.input or "") == "" then
    inputRows = { { text = i18n.t("inputHint"), hint = true } }
  else
    inputRows = self:_wrapTo(gc, self.input, availW, "user", nil)
  end
  while #inputRows > INPUT_MAX_ROWS do table.remove(inputRows, 1) end   -- 太长只留尾部

  local inputH = #inputRows * rowH
  local inputTop = math.max(2, h - 6 - inputH)
  local caretX, caretY = nil, nil

  for i, r in ipairs(inputRows) do
    local y = inputTop + (i - 1) * rowH
    if i == 1 then
      gc.color = USER
      gc:fillText(mark, 6, y)
    end
    gc.color = r.hint and DIM or USER
    gc:fillText(r.text, 6 + markW, y)
    if i == #inputRows then
      caretX = 6 + markW + self:_textWidth(gc, r.text)
      caretY = y
    end
  end
  if caretX then
    gc.color = USER
    gc:fillRect(Rectangle(caretX + 1, caretY, 5, lh))
  end

  -- 控件就摆在输入行这一行（和光标同一行，右对齐）
  if clusterW > 0 and caretY then
    local lineY = caretY - math.floor((CTX_CELL_H_LINE - lh) / 2)
    self:_drawCluster(gc, w - clusterW + 2, lineY, clusterW, ctxLabel)
  end

  self.dbg = string.format("w=%d h=%d lh=%d rowH=%d rows=%d markW=%d availW=%d inputTop=%d caret=(%s,%s) textLen=%d textW=%d cls=%d",
    w, h, lh, rowH, #inputRows, markW, availW, inputTop, tostring(caretX), tostring(caretY),
    #(self.input or ""), caretX and (caretX - 6 - markW) or -1, clusterW)

  ----------------------------------------------------------------------
  -- 2) 状态行（最上面）：转圈 + 状态文本 + 当前文件 + 小面板/滚动标记
  ----------------------------------------------------------------------
  local statusY = 4
  gc.color = STATUS_COLORS[self.statusKind or "ok"] or STATUS
  local extra = ""
  if self.busy then extra = extra .. SPIN_FRAMES[self.spinIdx or 1] .. " " end
  if self.miniShown then extra = extra .. "  ▣" end
  if self.scroll > 0 then extra = extra .. "  ↕" end
  local docSuffix = ""
  if self.docName and self.docName ~= "" then
    docSuffix = "   ｜ " .. tostring(self.docName)
  end
  gc:fillText(string.format(i18n.t("statusBar"), self.status) .. docSuffix .. extra, 6, statusY)

  local ruleY = statusY + lh + 2
  gc.color = RULE
  gc:fillRect(Rectangle(0, ruleY, w, 1))

  -- 断联红字（有就占一行，把滚回区往下推）
  local alertH = 0
  if self.alert and self.alert ~= "" then
    gc.color = STATUS_ERROR
    gc:fillText(self.alert, 6, ruleY + 3)
    alertH = rowH
  end

  ----------------------------------------------------------------------
  -- 3) 中间：滚回输出（打印出来的命令表也在里面，可悬浮 / 可点击）
  ----------------------------------------------------------------------
  local logTop = ruleY + 3 + alertH
  local logBottom = inputTop - 6
  gc.color = RULE
  gc:fillRect(Rectangle(0, logBottom + 2, w, 1))

  local rows = self:_wrap(gc, w - 12)
  local visible = math.max(0, math.floor((logBottom - logTop) / rowH))
  -- scroll 上界：最多翻到顶（再多也没有内容了）。滚轮处理里拿不到行数，只能在这儿钳。
  local maxScroll = math.max(0, #rows - visible)
  if self.scroll > maxScroll then self.scroll = maxScroll end
  local first = #rows - visible + 1 - self.scroll
  if first < 1 then first = 1 end

  self.hitRows = {}
  for i = 0, visible - 1 do
    local row = rows[first + i]
    if not row then break end
    local y = logTop + i * rowH
    local hot = (row.menuIndex and self.menuHover == row.menuIndex)
    if hot then
      gc.color = MENU_HL
      gc:fillRect(Rectangle(2, y - 1, w - 4, rowH))
      gc.color = MENU_HLT
    else
      gc.color = KIND_COLOR[row.kind] or TEXT
    end
    gc:fillText(row.text, 6, y)
    if row.menuIndex then
      self.hitRows[#self.hitRows + 1] = { x = 0, y = y - 1, w = w, h = rowH, index = row.menuIndex }
    end
  end

  -- 提示行（hint）画在输入区上方
  if self.hint ~= "" then
    gc.color = DIM
    gc:fillText(self.hint, 6, logBottom - 1 - lh)
  end
end

----------------------------------------------------------------------

function Panel:isShown() return self.shown end

function Panel:show()
  local dlg = self:_build()
  if not dlg then
    self.shown = true
    return
  end
  if self.shown then
    pcall(function() dlg:modify{ id = "input", focus = true } end)
    self.inputFocused = true
    return
  end
  dlg:show{ wait = false }
  self.shown = true
  pcall(function() dlg:modify{ id = "input", focus = true } end)
  self.inputFocused = true
  if self.busy then self:_startSpin() end     -- 关窗时停过表，重开要接着转
  self:repaint()
end

function Panel:hide()
  if self.dlg then pcall(function() self.dlg:close() end) end
  if self.fixDlg then pcall(function() self.fixDlg:close() end); self.fixDlg = nil end
  if self.askDlg then pcall(function() self.askDlg:close() end); self.askDlg = nil end
  self.shown = false
  if self.mini then self.mini:hide() end
  self:_stopSpin()          -- 窗口不在就别转（Timer 在 GUI 里是活的，会一直 repaint）
end

function Panel:destroy()
  self:hide()
  if self.spinTimer then pcall(function() self.spinTimer:stop() end); self.spinTimer = nil end
  if self.mini then self.mini:destroy() end
  self.dlg = nil
end

return panel
