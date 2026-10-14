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

local KIND_COLOR = {
  user  = USER,
  ai    = AI,
  think = THINK,
  tool  = TOOL,
  info  = DIM,
  error = ERROR,
  menu  = MENU_TX,
}

local KIND_PREFIX = {
  user  = "▸ ",
  think = "│ ",
  tool  = "· ",
  error = "! ",
}

local ROW_FACTOR = 1.55

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
    -- 图片矫正队列
    fixQueue = {},
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

function Panel:setStatus(text, kind)
  self.status = i18n.statusText(text)
  self.statusKind = kind or ""
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
  pcall(function()
    self.dlg:modify{ id = "input", text = SENTINEL }
    if restoreCaret then
      self.dlg:modify{ id = "send", focus = true }
      self.dlg:modify{ id = "input", focus = true }
    end
  end)
  self.entrySyncing = false
end

function Panel:_inputBackspace()
  local s = self.input or ""
  if s == "" then return end
  local i = utf8.offset(s, -1)
  self.input = i and s:sub(1, i - 1) or ""
end

-- ↑ / ↓ 翻历史（控制台 / 终端习惯）
function Panel:_onKeyDown(ev)
  if ev.code == "ArrowUp" then
    self:_history(-1)
    if ev.stopPropagation then ev.stopPropagation() end
    self:repaint()
  elseif ev.code == "ArrowDown" then
    self:_history(1)
    if ev.stopPropagation then ev.stopPropagation() end
    self:repaint()
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
  if self.dlg then pcall(function() self.dlg:modify{ id = "input", focus = true } end) end
  self:repaint()
end

----------------------------------------------------------------------
-- 提交
----------------------------------------------------------------------

function Panel:_submit()
  local text = tostring(self.input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  self:fillInput("")
  if text == "" then return end

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
-- 小面板（6 个图标按钮，贴主窗口右下角）
----------------------------------------------------------------------

function Panel:_miniItems()
  local ids = { "snapshot", "rollback", "versions", "fix", "settings", "close" }
  local icons = {
    snapshot = "snapshot", rollback = "rollback", versions = "versions",
    fix = "fix", settings = "settings", close = "clear",
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
    onmousemove = function(ev)
      local idx = self:_menuIndexAt(ev.x or 0, ev.y or 0)
      if (idx or 0) ~= (self.menuHover or 0) then
        self.menuHover = idx or 0
        self:repaint()          -- 悬浮高亮必须重绘，否则屏幕上什么都看不到
      end
    end,
    onmousedown = function(ev)
      -- 点空白处 = 把焦点还给输入点（终端习惯：点了就能接着打字）
      if ev.button == MouseButton.LEFT and not self:_menuIndexAt(ev.x or 0, ev.y or 0) then
        pcall(function() dlg:modify{ id = "input", focus = true } end)
      end
    end,
    onmouseup = function(ev)
      if ev.button == MouseButton.LEFT and self.menuOpen then
        local idx = self:_menuIndexAt(ev.x or 0, ev.y or 0)
        if idx then self:_runMenuIndex(idx) end
      end
    end,
    onwheel = function(ev)
      local dy = ev.deltaY or 0
      self.scroll = math.max(0, self.scroll + (dy > 0 and 1 or -1) * 3)
      self:repaint()
    end,
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

  gc.color = BG
  gc:fillRect(Rectangle(0, 0, w, h))

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
  local availW = w - 18 - markW

  local inputRows
  if tostring(self.input or "") == "" then
    inputRows = { { text = i18n.t("inputHint"), hint = true } }
  else
    inputRows = self:_wrapTo(gc, self.input, availW, "user", nil)
  end
  while #inputRows > INPUT_MAX_ROWS do table.remove(inputRows, 1) end   -- 太长只留尾部

  local inputH = #inputRows * rowH
  local inputTop = h - 6 - inputH
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
  self.dbg = string.format("w=%d h=%d lh=%d rowH=%d rows=%d markW=%d availW=%d inputTop=%d caret=(%s,%s) textLen=%d textW=%d",
    w, h, lh, rowH, #inputRows, markW, availW, inputTop, tostring(caretX), tostring(caretY),
    #(self.input or ""), caretX and (caretX - 6 - markW) or -1)

  ----------------------------------------------------------------------
  -- 2) 状态行（最上面）
  ----------------------------------------------------------------------
  local statusY = 4
  gc.color = STATUS
  local extra = ""
  if self.miniShown then extra = extra .. "  ▣" end
  if self.scroll > 0 then extra = extra .. "  ↕" end
  gc:fillText(string.format(i18n.t("statusBar"), self.status) .. extra, 6, statusY)

  local ruleY = statusY + lh + 2
  gc.color = RULE
  gc:fillRect(Rectangle(0, ruleY, w, 1))

  ----------------------------------------------------------------------
  -- 3) 中间：滚回输出（打印出来的命令表也在里面，可悬浮 / 可点击）
  ----------------------------------------------------------------------
  local logTop = ruleY + 3
  local logBottom = inputTop - 6
  gc.color = RULE
  gc:fillRect(Rectangle(0, logBottom + 2, w, 1))

  local rows = self:_wrap(gc, w - 12)
  local visible = math.max(0, math.floor((logBottom - logTop) / rowH))
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
    return
  end
  dlg:show{ wait = false }
  self.shown = true
  pcall(function() dlg:modify{ id = "input", focus = true } end)
  self:repaint()
end

function Panel:hide()
  if self.dlg then pcall(function() self.dlg:close() end) end
  if self.fixDlg then pcall(function() self.fixDlg:close() end); self.fixDlg = nil end
  self.shown = false
  if self.mini then self.mini:hide() end
end

function Panel:destroy()
  self:hide()
  if self.mini then self.mini:destroy() end
  self.dlg = nil
end

return panel
