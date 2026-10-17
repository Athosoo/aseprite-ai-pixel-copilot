-- kernel/kit.lua -- 视图原语（arch §3.4）
--
-- 只认 GraphicsContext + 命中测试，**不做布局决策**（没有 flex）。布局归视图。
-- 为什么这样切：给定 rect 集合与状态，输出就确定成一整条绘制调用序列 ——
-- 于是样式可被无头单测（golden layout 只比 rect 与调用名，不比字体位图）。
--
-- 五个脏区（titlebar / rail / context / main / composer）的失效标记也落在这里：
-- begin() 开一帧、region() 切区、end() 收帧。整屏重绘没有入口可走。

local kit = {}
local Kit = {}
kit.Kit = Kit

kit.REGIONS = { "titlebar", "rail", "context", "main", "composer" }
kit.CACHE_MAX = 2000

-- 无 gc 时的兜底宽度：只用于"没有渲染上下文"的纯逻辑测量（如断连态单测）。
-- 有 gc 时一律实测 —— 中文像素字体的推进宽只有 measureText 知道。
local FALLBACK_ASCII_W, FALLBACK_CJK_W = 5, 10

-- kit 属于 kernel，不得 require 上层模块（依赖方向 packs -> workbench -> kernel）。
-- 所以 theme 缺省时用这张内置底座，而不是回头去要 lib.theme。
local BUILTIN = {
  name = "dark",
  locale = "zh",     -- 缺省中文（产品默认）；theme.new 会按 i18n 的真实语言覆盖
  colors = {
    bg = "#111318", surface = "#171a20", surface2 = "#1d2129",
    line = "#2a2f39", lineHi = "#3a414e",
    text = "#dfe3ea", dim = "#79818f", faint = "#4d5461",
    accent = "#6ea8fe",
    ok = "#5ec98a", warn = "#e0b34a", err = "#e2657a", busy = "#7f9cf5",
  },
  metrics = {
    lineH = 14, rowH = 18, gap = 4, pad = 8, viewPad = 12,
    titleH = 30, railW = 56, ctxW = 240, composerH = 40,
    hair = 1, accentBar = 2,
  },
}

local function hexToColor(hex)
  local s = tostring(hex or ""):gsub("^#", "")
  if #s ~= 6 then return Color(255, 255, 255) end
  local r = tonumber(s:sub(1, 2), 16) or 0
  local g = tonumber(s:sub(3, 4), 16) or 0
  local b = tonumber(s:sub(5, 6), 16) or 0
  return Color(r, g, b)
end
kit.hexToColor = hexToColor

-- Rectangle 只在真要画的时候才构造：纯逻辑测量阶段不该产生图形对象。
local function toRect(r)
  if Rectangle then return Rectangle(r.x, r.y, r.w, r.h) end
  return r
end
kit.toRect = toRect

local function rect(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end
kit.rect = rect

-- 按【字符】切串，不是按字节：string.sub 会从多字节序列中间切断，切出来的
-- 非法 UTF-8 送进 gc:fillText 会让 Aseprite 直接崩（实测 0xC000001D）。
-- i/j 与 string.sub 同义，负数表示从尾部数。
function kit.u8sub(s, i, j)
  s = tostring(s or "")
  if s == "" then return s end
  local len = utf8.len(s) or 0
  if len == 0 then return s end
  if i < 0 then i = len + i + 1 end
  if j == nil then j = -1 end
  if j < 0 then j = len + j + 1 end
  if i < 1 then i = 1 end
  if j > len then j = len end
  if j < i then return "" end
  local from = utf8.offset(s, i)
  if not from then return "" end
  local to = utf8.offset(s, j + 1)
  local tail = to and (to - 1) or #s
  return s:sub(from, tail)
end

local function defaultTheme()
  local th = { name = BUILTIN.name, colors = {}, metrics = {} }
  for k, v in pairs(BUILTIN.colors) do th.colors[k] = hexToColor(v) end
  for k, v in pairs(BUILTIN.metrics) do th.metrics[k] = v end
  th.space = { 4, 8, 12, 16 }
  return th
end

function kit.new(gc, theme, opts)
  opts = opts or {}
  local th = theme or defaultTheme()
  if not th.metrics then th.metrics = defaultTheme().metrics end
  if not th.colors then th.colors = defaultTheme().colors end
  if not th.locale then th.locale = "zh" end
  local self = setmetatable({
    gc = gc,
    th = th,
    record = opts.record ~= false,
    calls = {},
    cache = {},            -- styleKey -> { [text] = {w=, h=} }
    cacheSeq = {},         -- 近似 LRU：淘汰时丢最老的一半
    cacheN = 0,
    regionName = "main",
    regionRect = rect(0, 0, 0, 0),
    frameRegions = {},
    stats = { frames = 0, calls = 0, ms = 0, regions = {} },
    marks = {},            -- 五个区的失效标记（不叫 dirty：会和同名的 kit:dirty() 冲突）
    frameDirty = {},
  }, { __index = Kit })
  for _, name in ipairs(kit.REGIONS) do
    self.marks[name] = true
    self.stats.regions[name] = 0
  end
  return self
end

----------------------------------------------------------------------
-- 帧与脏区
----------------------------------------------------------------------

function Kit:theme() return self.th end

-- 只有被标记的区会被绘制；标记在 end() 收帧时统一清除（ui §7 flush 语义）。
function Kit:invalidate(name)
  if name == nil then
    for _, n in ipairs(kit.REGIONS) do self.marks[n] = true end
    return
  end
  self.marks[name] = true
end

function Kit:dirty(name) return self.marks[name] == true end

function Kit:dirtySet()
  local out = {}
  for _, n in ipairs(kit.REGIONS) do
    if self.marks[n] then out[#out + 1] = n end
  end
  return out
end

function Kit:region(name, r)
  self.regionName = name
  if r then self.regionRect = r end
  local fr = self.frameRegions
  if fr[#fr] ~= name then fr[#fr + 1] = name end
end

function Kit:frame() return self.regionRect end

function Kit:begin()
  self.calls = {}
  self.frameRegions = {}
  self.frameBegin = os.clock()
end

-- 收帧。名字不叫 end：end 是 Lua 关键字，kit:end() 根本没法写。
-- 想按规格字面调用的人可以 kit["end"](kit)（下面挂了别名）。
function Kit:finish()
  local ms = (os.clock() - (self.frameBegin or os.clock())) * 1000
  self.stats.frames = self.stats.frames + 1
  self.stats.ms = self.stats.ms + ms
  self.stats.calls = self.stats.calls + #self.calls
  for _, name in ipairs(self.frameRegions) do
    self.stats.regions[name] = (self.stats.regions[name] or 0) + 1
    self.marks[name] = false
  end
  -- 这里**不探测 gc 有没有 flush**：GraphicsContext 是 userdata，读一个不存在的字段
  -- 会抛 "Field flush does not exist"（不是返回 nil）。而这个错误发生在 onpaint 里，
  -- 会穿过 C++ 边界 —— 实测直接让 Aseprite 以 0xC000001D 退出（v1wb_step4/5 的根因）。
  -- 收帧语义本来就是"清掉本帧用掉的失效标记"，上面已经做完，不需要再通知谁。
  return { ms = ms, calls = #self.calls, regions = self.frameRegions }
end

Kit["end"] = Kit.finish

----------------------------------------------------------------------
-- 调用记录
----------------------------------------------------------------------

local function push(self, op, r, extra)
  if not self.record then return end
  local c = { op = op, region = self.regionName, x = r.x, y = r.y, w = r.w, h = r.h }
  if extra then
    for k, v in pairs(extra) do c[k] = v end
  end
  self.calls[#self.calls + 1] = c
end
kit.pushCall = push

----------------------------------------------------------------------
-- 色与量
----------------------------------------------------------------------

-- 语义色名直通：ok / warn / err / dim / accent / busy / text / faint / line / surface2
function Kit:tone(name)
  if name == nil then return self.th.colors.text end
  local col = self.th.colors[name]
  if col then return col end
  if self.th.tones and self.th.tones[name] then return self.th.tones[name] end
  return self.th.colors.text
end

function Kit:_styleKey(style)
  if style == nil then return "n" end
  if type(style) ~= "table" then return tostring(style) end
  return (style.size or 10) .. (style.bold and "B" or "") .. (style.mono and "M" or "")
end

function Kit:_trim()
  -- 严格 LRU 要每帧维护链表，收益不抵复杂度：一次丢最老的一半，摊还成本极低。
  local half = math.floor(#self.cacheSeq / 2)
  for i = 1, half do
    local e = self.cacheSeq[i]
    local bucket = self.cache[e.key]
    if bucket then bucket[e.text] = nil end
    self.cacheN = self.cacheN - 1
  end
  local keep = {}
  for i = half + 1, #self.cacheSeq do keep[#keep + 1] = self.cacheSeq[i] end
  self.cacheSeq = keep
end

-- 返回原始宽度：缺字时**如实返回 0**，让调用方按 i18n 退回英文（ui §3.2）。
-- 这里不替调用方猜一个宽度 —— 猜了就把"缺字"这个事实抹掉了。
function Kit:measure(text, style)
  text = tostring(text or "")
  local key = self:_styleKey(style)
  local bucket = self.cache[key]
  if not bucket then
    bucket = {}
    self.cache[key] = bucket
  end
  local hit = bucket[text]
  if hit then return hit.w, hit.h end

  local w, h = 0, self.th.metrics.lineH
  if self.gc and self.gc.measureText then
    local sz = self.gc:measureText(text)
    if sz then
      w = sz.width or 0
      h = (sz.height and sz.height > 0) and sz.height or h
    end
  end
  if w <= 0 and self.gc == nil and text ~= "" then
    -- 没有渲染上下文时按字符类别估：ASCII 半宽、其余全宽。
    for _, code in utf8.codes(text) do
      w = w + (code < 0x80 and FALLBACK_ASCII_W or FALLBACK_CJK_W)
    end
  end

  if self.cacheN < kit.CACHE_MAX then
    bucket[text] = { w = w, h = h }
    self.cacheN = self.cacheN + 1
    self.cacheSeq[#self.cacheSeq + 1] = { key = key, text = text }
  else
    self:_trim()
    bucket[text] = { w = w, h = h }
    self.cacheN = self.cacheN + 1
    self.cacheSeq[#self.cacheSeq + 1] = { key = key, text = text }
  end
  return w, h
end

-- 界面文案选择：**先按语言选，再按缺字回落**（ui §3.2）。
-- 为什么语言在 kit 里：标签宽度决定布局，而布局归 kit 记录；语言要是留给每个视图
-- 自己判断，同一段文案在七个视图里会有七份 if。
function Kit:pick(zh, en, style)
  if (self.th.locale or "zh") ~= "zh" then
    local we = self:measure(en or zh, style)
    return (we and we > 0) and (en or zh) or zh
  end
  local w = self:measure(zh, style)
  if w and w > 0 then return zh end
  return en or zh
end

----------------------------------------------------------------------
-- 原语
----------------------------------------------------------------------

local function styleOf(style, base)
  if style == nil then return base end
  if type(style) ~= "table" then return { tone = style } end
  return style
end

function Kit:fill(r, tone)
  push(self, "fill", r, { tone = tone })
  if self.gc then
    self.gc.color = self:tone(tone or "surface")
    self.gc:fillRect(toRect(r))
  end
  return r
end

-- 发丝线：1px，结构靠它表达（ui §1）
function Kit:rule(r, tone)
  push(self, "rule", r, { tone = tone })
  if self.gc then
    self.gc.color = self:tone(tone or "line")
    self.gc:fillRect(toRect(r))
  end
  return r
end

function Kit:frameRect(r, tone)
  push(self, "frame", r, { tone = tone })
  if self.gc then
    local col = self:tone(tone or "line")
    self.gc.color = col
    self.gc:fillRect(toRect(rect(r.x, r.y, r.w, 1)))
    self.gc:fillRect(toRect(rect(r.x, r.y + r.h - 1, r.w, 1)))
    self.gc:fillRect(toRect(rect(r.x, r.y, 1, r.h)))
    self.gc:fillRect(toRect(rect(r.x + r.w - 1, r.y, 1, r.h)))
  end
  return r
end

-- xy 接受 {x=,y=} / {x, y} / (x 数字, y 数字)
local function xyOf(xy)
  if type(xy) == "number" then return xy, 0 end
  if not xy then return 0, 0 end
  return xy.x or xy[1] or 0, xy.y or xy[2] or 0
end
kit.xyOf = xyOf

-- 纯 ASCII 才判定：偏移 1px 双次绘制（假粗）对拉丁字形是加法，对像素方块字是灾难。
local function isAsciiText(s)
  return type(s) == "string" and s:find("[\128-\255]") == nil
end
kit.isAsciiText = isAsciiText

function Kit:text(xy, text, style)
  local st = styleOf(style, nil)
  local str = tostring(text or "")
  local x, y = xyOf(xy)
  local w, h = self:measure(str, st)
  local r = rect(x, y, w, h)
  local tone = st and st.tone or nil
  -- double = 这一条真的做了偏移双画（只有纯 ASCII 的 bold 才会）
  local double = (st and st.bold and isAsciiText(str)) and true or false
  push(self, "text", r, { tone = tone, bold = st and st.bold or false, mono = st and st.mono or false,
                           text = str, double = double })
  if self.gc then
    self.gc.color = self:tone(tone or "text")
    self.gc:fillText(str, x, y)
    -- 字重：GC 没有真的 bold，只能用「同一串再画一遍、偏移 1px」模拟半粗。
    -- **只对纯 ASCII 做**：中文是方块字，笔画密集，偏移再画一遍会把笔画叠糊成一团
    -- （真机截图：画布页标题「加强明暗对比」糊得看不出字形）。
    -- 中文的层级表达交给 tone（accent/text/dim），不靠假粗。
    if double then self.gc:fillText(str, x + 1, y) end
  end
  return r
end

-- 键值行：label 左、value 右对齐成列。像素数/颜色值/耗时全靠它对齐（ui §1 第 2 条）。
-- opts：{ valueTone = "err" } —— 必填项没配时值用红色（"未设置"要一眼看见）
function Kit:field(r, label, value, opts)
  local lh = self.th.metrics.lineH
  local y = r.y + math.floor((r.h - lh) / 2)
  local lr = self:text({ x = r.x, y = y }, label, { tone = "dim" })
  local vw = self:measure(value, { mono = true })
  local vx = r.x + r.w - vw
  if vx < lr.x + lr.w + 8 then vx = lr.x + lr.w + 8 end
  self:text({ x = vx, y = y }, value, { tone = (opts and opts.valueTone) or "text", mono = true })
  push(self, "field", r, { tone = "text" })
  return r
end

function Kit:hit(r, x, y)
  if not r or not x or not y then return false end
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

function Kit:badge(xy, text, tone)
  local x, y = xyOf(xy)
  local m = self.th.metrics
  local tw, th = self:measure(text, { mono = true })
  local w = tw + 16          -- 4x8 内边距：左右各 8
  local h = math.max(m.lineH, th) + 8
  local r = rect(x, y, w, h)
  self:fill(r, "surface")
  self:frameRect(r, tone or "line")
  self:text({ x = x + 8, y = y + 4 }, text, { tone = tone or "dim", mono = true })
  push(self, "badge", r, { tone = tone })
  return r
end

function Kit:button(r, label, opts)
  opts = opts or {}
  local m = self.th.metrics
  local bg = opts.hover and "surface2" or "surface"
  self:fill(r, bg)
  self:frameRect(r, opts.focus and "lineHi" or "line")
  if opts.hover then
    -- hover 反色：底变 accent，字回 bg（没有阴影/渐变可用，只能靠色相反转表达"可按"）
    self:fill(r, "accent")
  end
  local tw, th = self:measure(label, {})
  local tx = r.x + math.floor((r.w - tw) / 2)
  if tx < r.x + 4 then tx = r.x + 4 end
  local ty = r.y + math.floor((r.h - math.max(th, m.lineH)) / 2)
  self:text({ x = tx, y = ty }, label, { tone = opts.hover and "bg" or (opts.enabled == false and "faint" or "text") })
  push(self, "button", r, { tone = opts.tone, focus = opts.focus and true or false })
  return r
end

-- 列表：Row = text + tone + 可选 badge，18px 高，悬浮 surface2，选中左侧 2px accent。
-- 返回 layout（含每行的命中矩形），视图据此做鼠标判定，不需要再算一遍布局。
function Kit:list(r, items, state)
  state = state or {}
  local m = self.th.metrics
  local rowH = state.rowH or m.rowH
  local scroll = state.scroll or 0
  local accentBar = m.accentBar
  local visible = math.floor(r.h / rowH)
  local layout = { x = r.x, y = r.y, w = r.w, h = r.h, rowH = rowH, rows = {},
                   count = #items, visible = visible, scroll = scroll }
  layout.maxScroll = math.max(0, #items - visible)
  local y = r.y
  for i = scroll + 1, #items do
    if #layout.rows >= visible then break end
    local item = items[i]
    local rr = rect(r.x, y, r.w, rowH)
    if state.sel == i then
      self:fill(rr, "surface2")
      self:fill(rect(r.x, y, accentBar, rowH), "accent")
    elseif state.hover == i then
      self:fill(rr, "surface2")
    end
    local tx = r.x + m.pad
    if state.sel == i then tx = tx + accentBar end
    local badgeW = 0
    if item.badge ~= nil and item.badge ~= "" then
      local bw = self:measure(tostring(item.badge), { mono = true }) + 16
      local br = self:badge({ x = r.x + r.w - m.pad - bw, y = y + math.floor((rowH - (m.lineH + 8)) / 2) },
                            tostring(item.badge), item.badgeTone or "dim")
      badgeW = br.w + m.gap
      layout.rows[#layout.rows + 1] = { index = i, rect = rr, item = item }
    else
      layout.rows[#layout.rows + 1] = { index = i, rect = rr, item = item }
    end
    local textMax = r.w - (tx - r.x) - m.pad - badgeW
    local text = tostring(item.text or "")
    local tw = self:measure(text, {})
    if tw > textMax and textMax > 0 then
      -- 截断而不是折行：列表行高固定，折行会打乱 18px 栅格。
      local cut = {}
      local acc = 0
      for _, code in utf8.codes(text) do
        local ch = utf8.char(code)
        local cw = self:measure(ch, {})
        if acc + cw > textMax - 12 then break end   -- 留出省略号位置
        cut[#cut + 1] = ch
        acc = acc + cw
      end
      text = table.concat(cut) .. "…"
    end
    self:text({ x = tx, y = y + math.floor((rowH - m.lineH) / 2) }, text, { tone = item.tone or "text" })
    y = y + rowH
  end
  push(self, "list", r, { count = #items })
  return layout
end

-- 图像：画廊缩略图是唯一需要 drawImage 的地方（ui §5 gallery）。
-- 不给缩放 —— 缩略图由调用方先做好尺寸，省得每次重绘都重采样。
function Kit:image(r, img)
  push(self, "image", r, {})
  if self.gc and img then self.gc:drawImage(img, r.x, r.y) end
  return r
end

-- 分隔块：1px 全宽 line
function Kit:divider(y, x, w)
  return self:rule(rect(x or self.regionRect.x, y, w or self.regionRect.w, self.th.metrics.hair))
end

-- 转圈：三帧 ·○◎ 轮换，只在 busy 时跑（ui §4 Spinner）
kit.SPINNER = { "·", "○", "◎" }

function Kit:spinner(xy, phase)
  local f = kit.SPINNER[(math.floor(phase or 0) % #kit.SPINNER) + 1]
  return self:text(xy, f, { tone = "busy" })
end

return kit
