-- lib/miniwindow.lua -- 左上角小按钮唤出的「贴边小面板」
--
-- 形态：一个无标题栏的独立小窗，默认贴在主窗口左上角（dlg.bounds 是相对
-- 主窗口内容区原点的坐标 —— 见 src/app/script/dialog_class.cpp:238-266），
-- 大小只有主面板的一半左右，可拖动（按住标题区拖）。
--
-- 里面是自绘的图形按钮（canvas 画图标 + 文字，鼠标悬浮变蓝、按下有反馈，
-- 见 Aseprite canvas 的 onmousemove/onmousedown/onmouseup 绑定：
-- src/app/script/canvas_widget.cpp:118-159），点一下就是原来面板上那颗按钮的功能。
-- 这样面板本身既能保持紧凑，又能有一个"图形操作台"。

local i18n = require("lib.i18n")

local miniwindow = {}

local Mini = {}
Mini.__index = Mini

local COLS    = 2
local CELL_W  = 104
local CELL_H  = 34
local GAP     = 4
local PAD     = 5
local HDR_H   = 13

local COL = {
  face     = Color(30, 34, 41),
  cell     = Color(38, 43, 52),
  cellHot  = Color(46, 134, 222),   -- 悬浮：蓝
  cellDown = Color(28, 92, 156),
  border   = Color(58, 66, 78),
  text     = Color(230, 235, 242),
  textHot  = Color(255, 255, 255),
  glyph    = Color(150, 200, 245),
  glyphHot = Color(255, 255, 255),
  hdrText  = Color(150, 158, 172),
}

----------------------------------------------------------------------
-- 8x8 图标（每行一个字符串，'#' = 一个像素）
----------------------------------------------------------------------

local ICONS = {
  snapshot = {
    "..#####.",
    ".##...##",
    "##.....#",
    "##.....#",   -- 相机：镜头 + 闪光
    "##.....#",
    ".##...##",
    "..#####.",
    "........",
  },
  rollback = {
    "....##..",
    "...###..",
    "..####..",
    ".#####..",
    "..####..",
    "...###..",
    "....##..",
    "........",   -- 向左的箭头（回滚）
  },
  versions = {
    "..#####.",
    ".##.....",
    "##......",
    "##......",
    "##......",
    "##......",
    "..#####.",
    "........",   -- "C"：堆叠的版本
  },
  fix = {
    "......##",
    ".....##.",
    "....##..",
    "...##...",
    "..##....",
    ".##.....",
    "##......",
    "........",   -- 斜杠：重采样
  },
  upload = {
    "...#....",
    "..###...",
    ".#####..",
    "##.#.##.",
    "...#....",
    "...#....",
    ".......#",
    "########",   -- 向上箭头 + 底座
  },
  settings = {
    "...#....",
    "..###...",
    ".#####..",
    "#######.",
    ".#####..",
    "..###...",
    "...#....",
    "........",   -- 菱形/齿轮示意
  },
  reconnect = {
    "..#####.",
    ".##...##",
    "##......",
    "##......",
    "##......",
    ".##...##",
    "..#####.",
    "...##...",   -- 环 + 尾巴
  },
  clear = {
    "#.......",
    ".#.#....",
    "..#..#..",
    ".#.#..#.",
    "#...#.#.",
    "....#...",
    "...#....",
    "........",   -- 叉/橡皮示意
  },
}

local ICON_W, ICON_H = 8, 8

----------------------------------------------------------------------

function miniwindow.new(opts)
  return setmetatable({
    opts = opts or {},
    dlg = nil,
    shown = false,
    hot = -1,          -- 悬浮的按钮下标
    down = -1,         -- 按下的按钮下标
    pressed = false,
    drag = nil,        -- 拖动状态 {sx, sy, bx, by}
    version = 0,       -- 缓存失效计数
  }, Mini)
end

function Mini:items()
  if self._items and self._itemsVersion == self.version then return self._items end
  local list = {}
  if self.opts.items then
    local ok, res = pcall(self.opts.items)
    if ok and res then list = res end
  end
  self._items = list
  self._itemsVersion = self.version
  return list
end

function Mini:isShown() return self.shown end

function Mini:invalidate()
  self.version = self.version + 1
  self:repaint()
end

function Mini:repaint()
  if self.shown and self.dlg then
    pcall(function() self.dlg:repaint() end)
  end
end

----------------------------------------------------------------------
-- 布局与绘制
----------------------------------------------------------------------

function Mini:_metrics()
  local n = #self:items()
  local rows = math.max(1, math.ceil(n / COLS))
  local w = PAD * 2 + COLS * CELL_W + (COLS - 1) * GAP
  local h = PAD * 2 + HDR_H + rows * CELL_H + (rows - 1) * GAP
  return w, h, rows
end

function Mini:cellAt(x, y)
  for i = 1, #self:items() do
    local c = (i - 1) % COLS
    local r = math.floor((i - 1) / COLS)
    local cx = PAD + c * (CELL_W + GAP)
    local cy = PAD + HDR_H + r * (CELL_H + GAP)
    if x >= cx and x < cx + CELL_W and y >= cy and y < cy + CELL_H then
      return i
    end
  end
  return -1
end

function Mini:_inHeader(x, y) return y < PAD + HDR_H end

function Mini:_paint(gc)
  local w, h = self:_metrics()
  local items = self:items()

  gc.color = COL.face
  gc:fillRect(Rectangle(0, 0, w, h))

  -- 顶部把手：显示 "AI" + 抓纹，鼠标按住这里可以拖动整个小窗
  gc.color = COL.hdrText
  gc:fillText("AI", PAD, 1)
  local grip = "::::  ::::"
  local gsz = gc:measureText(grip)
  gc:fillText(grip, w - PAD - (gsz and gsz.width or 0), 1)
  gc.color = COL.border
  gc:fillRect(Rectangle(0, PAD + HDR_H - 3, w, 1))

  for i, item in ipairs(items) do
    local c = (i - 1) % COLS
    local r = math.floor((i - 1) / COLS)
    local cx = PAD + c * (CELL_W + GAP)
    local cy = PAD + HDR_H + r * (CELL_H + GAP)

    local hot = (self.hot == i)
    local down = (self.down == i and self.pressed)

    if down then
      gc.color = COL.cellDown
    elseif hot then
      gc.color = COL.cellHot
    else
      gc.color = COL.cell
    end
    gc:fillRect(Rectangle(cx, cy, CELL_W, CELL_H))
    gc.color = COL.border
    gc:fillRect(Rectangle(cx, cy, CELL_W, 1))
    gc:fillRect(Rectangle(cx, cy + CELL_H - 1, CELL_W, 1))
    gc:fillRect(Rectangle(cx, cy, 1, CELL_H))
    gc:fillRect(Rectangle(cx + CELL_W - 1, cy, 1, CELL_H))

    local glyph = ICONS[item.icon] or ICONS.settings
    gc.color = hot and COL.glyphHot or COL.glyph
    for gy = 1, ICON_H do
      local line = glyph[gy] or ""
      for gx = 1, ICON_W do
        if line:sub(gx, gx) == "#" then
          gc:fillRect(Rectangle(cx + 3 + (gx - 1) * 2, cy + 9 + (gy - 1) * 2, 2, 2))
        end
      end
    end

    gc.color = hot and COL.textHot or COL.text
    gc:fillText(tostring(item.label or item.id or ""), cx + 22, cy + 11)
  end
end

----------------------------------------------------------------------
-- 事件
----------------------------------------------------------------------

function Mini:_onMove(ev)
  local x, y = ev.x or 0, ev.y or 0

  -- 拖动中
  if self.drag then
    local dx = x - self.drag.sx
    local dy = y - self.drag.sy
    if dx ~= 0 or dy ~= 0 then
      local dlgW = self.dlg.bounds
      if dlgW then
        self.dlg.bounds = Rectangle(dlgW.x + dx, dlgW.y + dy, dlgW.w, dlgW.h)
      end
    end
    return
  end

  local hit = self:cellAt(x, y)
  if hit ~= self.hot then
    self.hot = hit
    self:repaint()
  end
end

function Mini:_onDown(ev)
  local x, y = ev.x or 0, ev.y or 0
  if self:_inHeader(x, y) then
    local b = self.dlg and self.dlg.bounds
    if b then self.drag = { sx = x, sy = y, bx = b.x, by = b.y } end
    return
  end
  self.down = self:cellAt(x, y)
  if self.down > 0 then
    self.pressed = true
    self:repaint()
  end
end

function Mini:_onUp(ev)
  if self.drag then
    self.drag = nil
    return
  end
  local was = self.down
  self.down = -1
  self.pressed = false
  self:repaint()

  if was > 0 then
    local hit = self:cellAt(ev.x or 0, ev.y or 0)
    if hit == was then
      local item = self:items()[was]
      if item and self.opts.onAction then
        pcall(function() self.opts.onAction(item.id) end)
      end
    end
  end
end

----------------------------------------------------------------------
-- 显隐
----------------------------------------------------------------------

function Mini:_build()
  if self.dlg then return self.dlg end

  local w, h = self:_metrics()
  local dlg = Dialog{
    title = "AI Copilot",
    notitlebar = true,
    resizeable = false,
    onclose = function() self.shown = false; self:_notify() end,
  }

  dlg:canvas{
    id = "mini",
    width = w,
    height = h,
    vexpand = false,
    autoscaling = true,
    onpaint = function(ev) self:_paint(ev.context) end,
    onmousemove = function(ev) self:_onMove(ev) end,
    onmousedown = function(ev) self:_onDown(ev) end,
    onmouseup = function(ev) self:_onUp(ev) end,
  }

  self.dlg = dlg
  return dlg
end

function Mini:_notify()
  if self.opts.onVisibilityChanged then
    pcall(function() self.opts.onVisibilityChanged(self.shown) end)
  end
end

-- anchor：对话窗（主面板）的 bounds（Rectangle，与 dlg.bounds 同一坐标系）。
-- 传了就把小面板贴在【对话窗】的右下角；没传（或面板还没建出来）退回主窗口右下角。
function Mini:show(anchor)
  local dlg = self:_build()
  if self.shown then
    dlg:repaint()
    return
  end

  local w, h = self:_metrics()
  local margin = 8
  local x, y

  if anchor and (anchor.w or 0) > w + margin * 2 and (anchor.h or 0) > h + margin * 2 then
    -- 贴"对话窗"右下角（面板拖动/缩放后重开会跟着走）
    x = anchor.x + anchor.w - w - margin
    y = anchor.y + anchor.h - h - margin
  else
    -- 兜底：主窗口右下角。app.window 就是主窗口（app_object.cpp:App_get_window），
    -- 宽高与 dlg.bounds 同一坐标系。
    local W, H = 0, 0
    pcall(function() W = app.window.width or 0 end)
    pcall(function() H = app.window.height or 0 end)
    x, y = margin, margin
    if W > 6 and H > 6 then
      x = math.max(margin, W - w - margin)
      y = math.max(margin, H - h - margin)
    end
  end

  dlg.bounds = Rectangle(x, y, w, h)
  dlg:show{ wait = false }
  self.shown = true
  self.hot = -1
  self.down = -1
  self:repaint()
  self:_notify()
end

function Mini:hide()
  if self.dlg then pcall(function() self.dlg:close() end) end
  self.shown = false
  self.drag = nil
  self:_notify()
end

function Mini:toggle(anchor)
  if self.shown then self:hide() else self:show(anchor) end
  return self.shown
end

function Mini:destroy()
  self:hide()
  self.dlg = nil
end

return miniwindow
