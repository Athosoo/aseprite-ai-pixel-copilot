-- lib/views/console.lua -- 会话页（终端原样平移，ui §8）
--
-- 这个文件同时是**两处的唯一实现**：
--   1) 工作台的主视图（三区壳里的 console 页）
--   2) panel.lua 的滚回区（四形态里那块自绘 canvas）
-- 所以文案、配色语义、折行算法都只有一份 —— panel.lua 只转发，不复制。
--
-- 平移原则（D4）：配色语义与文案逐字保留。老用户的 /menu 命令表、回显颜色、
-- i18n 键一个都不改；变的只是它现在住在一个视图里，而不是拥有整个窗口。

local i18n = require("lib.i18n")
local menu = require("lib.menu")
local util = require("lib.util")

local console = {}

----------------------------------------------------------------------
-- 配色语义（与 v0.5.x panel.lua 逐字相同）
----------------------------------------------------------------------

console.BG      = Color(16, 18, 22)
console.TEXT    = Color(222, 226, 232)
console.DIM     = Color(118, 126, 138)
console.USER    = Color(126, 226, 168)
console.AI      = Color(240, 244, 250)
console.THINK   = Color(152, 158, 168)
console.TOOL    = Color(128, 178, 200)
console.ERROR   = Color(255, 122, 122)
console.RULE    = Color(44, 48, 56)
console.STATUS  = Color(130, 190, 255)
console.MENU_TX = Color(214, 220, 230)
console.MENU_HL = Color(46, 134, 222)
console.MENU_HLT= Color(255, 255, 255)
console.WARN    = Color(255, 196, 110)

console.KIND_COLOR = {
  user  = console.USER,
  ai    = console.AI,
  think = console.THINK,
  tool  = console.TOOL,
  info  = console.DIM,
  warn  = console.WARN,
  error = console.ERROR,
  menu  = console.MENU_TX,
}

console.KIND_PREFIX = {
  user  = "▸ ",
  think = "│ ",
  tool  = "· ",
  warn  = "! ",
  error = "! ",
}

-- 同一套语义给 kit 用的**色名**（kit 只认主题里的令牌名）。
-- 两套表必须同步：panel 走 KIND_COLOR，工作台走 KIND_TONE。
console.KIND_TONE = {
  user = "ok", ai = "text", think = "dim", tool = "busy",
  info = "dim", warn = "warn", error = "err", menu = "text",
}

console.ROW_FACTOR = 1.55

function console.kindColor(kind) return console.KIND_COLOR[kind] or console.TEXT end
function console.kindTone(kind) return console.KIND_TONE[kind] or "text" end
function console.kindPrefix(kind) return console.KIND_PREFIX[kind] or "" end

----------------------------------------------------------------------
-- 文本量算与折行（panel.lua 转发到这里）
----------------------------------------------------------------------

function console.charWidth(cache, gc, ch)
  local w = cache[ch]
  if w == nil then
    local sz = gc:measureText(ch)
    w = sz and sz.width or 0
    if w <= 0 then w = 1 end
    cache[ch] = w
  end
  return w
end

-- 整串宽度：**必须整串量**。逐字 measureText 拿到的是单字墨迹宽，比排版推进宽度小
-- （中文约差 10%），累加起来光标会落在一行文字中间（实测踩过）。逐字累加只当兜底。
function console.textWidth(cache, gc, text)
  if text == "" then return 0 end
  local sz = gc:measureText(text)
  if sz and sz.width and sz.width > 0 then return sz.width end
  local w = 0
  for _, code in utf8.codes(text) do
    w = w + console.charWidth(cache, gc, utf8.char(code))
  end
  return w
end

-- 按宽度折行；保留 menuIndex，让折出来的续行也能点（命令表的行会折）。
function console.wrapTo(cache, gc, text, maxW, kind, menuIndex)
  local rows = {}
  if text == "" then
    return { { text = "", kind = kind, menuIndex = menuIndex } }
  end
  local cur, curW = {}, 0
  for _, code in utf8.codes(text) do
    local s = utf8.char(code)
    local cw = console.charWidth(cache, gc, s)
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

----------------------------------------------------------------------
-- 命令表（数据在 lib/menu.lua，这里只负责落成可绘制的行）
----------------------------------------------------------------------

-- rows = { {id, keys, label, note}, ... } -> { title=, lines={ {text=, index=} } }
function console.printTable(rows, title)
  local lines = menu.tableLines(rows or {})
  local out = { title = title or menu.titleLine(i18n), lines = {} }
  for _, l in ipairs(lines) do
    out.lines[#out.lines + 1] = { text = l.text, index = l.index }
  end
  return out
end

-- 状态文本的语义色名：红 > 黄 > 蓝，其余灰。与 panel 的 STATUS_* 语义一致。
local ERR_PREFIX = { "error", "出错", "missing api key", "缺少", "disconnected", "connection error", "已断开", "连接出错" }
local WARN_PREFIX = { "interrupted", "timeout", "已中断", "超时", "pending", "待" }
local OK_PREFIX = { "ready", "connected", "就绪", "已连接", "done", "完成" }

local function hasPrefix(s, list)
  for _, p in ipairs(list) do
    if s:sub(1, #p) == p then return true end
  end
  return false
end

function console.statusTone(text)
  local s = tostring(text or "")
  if s == "" then return "dim" end
  if hasPrefix(s, ERR_PREFIX) then return "err" end
  if hasPrefix(s, WARN_PREFIX) then return "warn" end
  if hasPrefix(s, OK_PREFIX) then return "ok" end
  return "busy"
end

function console.fmtTime(ts)
  local t = tonumber(ts)
  if not t then return "" end
  -- 桥给的是毫秒；秒级时间戳（< 1e11）按秒处理，免得多对话迁移来的旧记录显示成 1970
  if t > 1e11 then t = math.floor(t / 1000) end
  local ok, d = pcall(os.date, "*t", t)
  if not ok or not d then return "" end
  return string.format("%02d:%02d", d.hour, d.min, d.sec)
end

----------------------------------------------------------------------
-- 会话页视图
----------------------------------------------------------------------

local EMPTY_EXAMPLES = {
  { zh = "把这层的红色换深一点", en = "make this layer's red darker" },
  { zh = "合并到 64 色以内",     en = "merge down to 64 colours" },
  { zh = "给主体描个边",         en = "outline the subject" },
}

local Console = {}
Console.__index = Console

-- opts: { lines=, i18nKey=, onExample=fn }
function console.new(opts)
  opts = opts or {}
  local self = setmetatable({
    lines = {},
    wrapped = {},
    wrapWidth = -1,
    scroll = 0,
    charW = {},
    hits = {},
    hover = nil,
    menuRows = {},
    menuOpen = false,
    menuHover = 0,
    maxLines = opts.maxLines or 800,
    empty = opts.empty or EMPTY_EXAMPLES,
    hint = "",
  }, Console)
  for _, l in ipairs(opts.lines or {}) do self:log(l.text, l.kind, l.meta) end
  return self
end
console.Console = Console

-- 视图挂载入口（arch §3.2 的 view 规格）：壳只认 mount(ctx) -> view
function console.mount(ctx)
  local v = console.new({})
  v.ctx = ctx
  return v
end

function Console:log(text, kind, meta)
  self.lines[#self.lines + 1] = {
    text = tostring(text or ""),
    kind = kind or "ai",
    ts = meta and meta.ts or nil,
    menuIndex = meta and meta.menuIndex or nil,
    card = meta and meta.card or nil,
  }
  local over = #self.lines - self.maxLines
  if over > 0 then
    local keep = {}
    for i = over + 1, #self.lines do keep[#keep + 1] = self.lines[i] end
    self.lines = keep
  end
  self.wrapWidth = -1
end

function Console:clear()
  self.lines = {}
  self.wrapped = {}
  self.wrapWidth = -1
  self.scroll = 0
end

function Console:count() return #self.lines end

-- 折行缓存按宽度失效：只有宽度变了才重排（滚动不重排）
function Console:rows(gc, maxW)
  if self.wrapWidth == maxW and #self.wrapped > 0 then return self.wrapped end
  local rows = {}
  for _, line in ipairs(self.lines) do
    local sub = console.wrapTo(self.charW, gc, line.text, maxW, line.kind, line.menuIndex)
    for _, r in ipairs(sub) do
      r.ts = line.ts
      r.card = line.card
      rows[#rows + 1] = r
    end
  end
  self.wrapped = rows
  self.wrapWidth = maxW
  return rows
end

function Console:rowCount(gc, maxW) return #self:rows(gc or {measureText = function() return { width = 0 } end}, maxW) end

function Console:scrollBy(n, viewH, rowH)
  self.scroll = util.clamp(self.scroll + n, 0, self:maxScroll(viewH, rowH))
end

function Console:maxScroll(viewH, rowH)
  rowH = rowH or 18
  local visible = viewH and math.floor(viewH / rowH) or 0
  return math.max(0, #self.wrapped - visible)
end

-- 命令表打印进滚回区（与 panel 的 _printTable 同一份数据/排版）
function Console:printTable(rows, title)
  self.menuRows = rows or {}
  self.menuOpen = true
  self.menuHover = 0
  local t = console.printTable(self.menuRows, title)
  self:log(t.title, "info")
  if #t.lines == 0 then
    self:log(i18n.t("noCommands"), "info")
    return
  end
  for _, l in ipairs(t.lines) do
    self:log(l.text, "menu", { menuIndex = l.index })
  end
end

----------------------------------------------------------------------
-- 绘制
----------------------------------------------------------------------

-- 视图内动作（右对齐在标题行上）。标题行由壳统一绘制 —— 七个视图各画一遍
-- 会把 30px 的高度与 12px 内边距散落到七处，改一次要改七次。
local TITLE = { zh = "会话", en = "CONSOLE" }
console.TITLE = TITLE

function Console:title() return i18n.isZh() and TITLE.zh or TITLE.en end

function Console:actions(state)
  -- 标题行左边已经写了「会话」（视图名），这里再写「会话 Chat」就是同一个词出现两次。
  -- 页签只负责"当前是哪条对话"，所以只写对话名。
  local name = state and state.session
  local sess = (name ~= nil and name ~= "") and (tostring(name) .. " ▾") or "Chat ▾"
  return {
    { id = "session", label = sess },
    { id = "new", label = "⊕" },
  }
end

-- 空状态是设计的一部分（ui §5）：一句话 + 三个可点的示例，不是"暂无数据"
function Console:renderEmpty(kit, r, state)
  local m = kit:theme().metrics
  local y = r.y + m.viewPad + 8
  local lead = kit:pick("说一句你想改的。比如「把这层的红色换深一点」",
                        "Say what you want changed. e.g. \"make this layer's red darker\"")
  kit:text({ x = r.x + m.viewPad, y = y }, lead, { tone = "dim" })
  y = y + m.lineH + 12
  local layout = {}
  for i, ex in ipairs(self.empty) do
    local text = kit:pick(ex.zh, ex.en)
    local tw = kit:measure(text, {})
    local er = { x = r.x + m.viewPad, y = y, w = tw + 16, h = m.lineH + 8 }
    kit:button(er, text, { hover = (state and state.hover == ("ex" .. i)) or false })
    -- 画的是紧凑按钮，命中区给宽一点：真机上偏几个像素就点空，用户只会说「点不动」。
    -- 横向多给到 240（点行内空白也算），纵向上下各 3px（行距 26，相邻命中区只擦 1px 边）。
    local hr = {
      x = er.x - 4,
      y = er.y - 3,
      w = math.max(er.w + 8, 240),
      h = er.h + 6,
    }
    self.hits[#self.hits + 1] = { rect = hr, kind = "example", index = i, text = text }
    layout[i] = er
    y = y + m.lineH + 12
  end
  return layout
end

function Console:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  local lh = m.lineH
  local rowH = m.rowH
  local inner = { x = r.x, y = r.y, w = r.w, h = r.h }
  kit:fill(inner, "surface")

  if self:count() == 0 then
    self:renderEmpty(kit, { x = inner.x, y = inner.y, w = inner.w, h = inner.h }, state)
    return self
  end

  local maxW = inner.w - m.viewPad * 2
  local rows = self:rows(kit.gc, maxW)
  local visible = math.floor((inner.h - 8) / rowH)
  local maxScroll = math.max(0, #rows - visible)
  if self.scroll > maxScroll then self.scroll = maxScroll end

  local y = inner.y + 4
  for i = self.scroll + 1, #rows do
    if i > self.scroll + visible then break end
    local row = rows[i]
    local x = inner.x + m.viewPad
    if row.menuIndex then
      local hot = (self.menuHover == row.menuIndex)
      if hot then kit:fill({ x = inner.x + 2, y = y - 1, w = inner.w - 4, h = rowH }, "accent") end
      local tone = hot and "bg" or "text"
      kit:text({ x = x, y = y }, row.text, { tone = tone, bold = hot })
      self.hits[#self.hits + 1] = { rect = { x = inner.x, y = y - 1, w = inner.w, h = rowH }, kind = "menu", index = row.menuIndex }
    else
      local prefix = console.kindPrefix(row.kind)
      local tx = x
      if row.ts then
        local ts = console.fmtTime(row.ts)
        local tr = kit:text({ x = x, y = y }, ts, { tone = "dim", mono = true })
        tx = tr.x + tr.w + 8
      end
      if prefix ~= "" then
        local pr = kit:text({ x = tx, y = y }, prefix, { tone = console.kindTone(row.kind) })
        tx = pr.x + pr.w
      end
      kit:text({ x = tx, y = y }, row.text, { tone = console.kindTone(row.kind), mono = row.kind == "tool" })
    end
    y = y + rowH
    if y > inner.y + inner.h - 8 then break end
  end

  -- 滚动指示：只有真的滚起来才画，不占常驻空间
  if self.scroll > 0 or maxScroll > 0 then
    local label = string.format("%d/%d", self.scroll, maxScroll)
    local lw = kit:measure(label, { mono = true })
    kit:text({ x = inner.x + inner.w - m.viewPad - lw, y = inner.y + inner.h - lh - 2 }, label, { tone = "faint", mono = true })
  end
  return self
end

----------------------------------------------------------------------
-- 交互
----------------------------------------------------------------------

-- 少数地方需要命中测试而手里没有 kit 实例，就地写一份等价判定
local function kitHit(r, x, y)
  return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
console.hit = kitHit

-- 标题行右侧两个动作：Chat▾ 切对话、⊕ 新建对话（都走 agent 既有通路）
function Console:action(id, state)
  local a = self.ctx and self.ctx.agent
  if id == "session" then
    if a and type(a.action) == "function" then return pcall(a.action, a, "conversations") end
    return false
  elseif id == "new" then
    if a and type(a.action) == "function" then return pcall(a.action, a, "conversation_new") end
    return false
  end
  return false
end

-- 空状态的三个示例是可点的：点一下等于把它填进 composer（不是直接发送）
function Console:click(hit)
  if not hit then return false end
  if hit.kind == "example" then
    local wb = self.ctx and self.ctx.workbench or nil
    if wb and hit.text then
      wb:setInput(hit.text)
      return true
    end
  elseif hit.kind == "menu" and hit.index then
    self.menuHover = hit.index
    return true
  elseif hit.kind == "session" then
    return true
  end
  return false
end

function Console:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if kitHit(h.rect, x, y) then return h end
  end
  return nil
end

function Console:wheel(dy)
  if self:count() == 0 then return false end
  -- 滚轮方向沿用 v0.5.x：向下滚 = 看更新的内容（scroll 增大）
  self:scrollBy(dy > 0 and 3 or -3)
  return true
end

return console
