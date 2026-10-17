-- lib/views/gallery.lua -- 画廊页（v1 骨架）
--
-- 会话产出物的缩略图网格。缩略图由宿主注入**已经缩好的 Image**（视图里不做缩放：
-- 每次重绘都重采样会把滚动预算吃光）。

local i18n = require("lib.i18n")

local gallery = {}
local View = {}
View.__index = View

local function zh() return i18n.isZh() end

function gallery.mount(ctx) return setmetatable({ ctx = ctx, hits = {}, sel = 1, scroll = 0 }, View) end
function View:title() return zh() and "画廊" or "GALLERY" end

function View:items()
  if self.ctx and type(self.ctx.gallery) == "table" then return self.ctx.gallery end
  local a = self.ctx and self.ctx.agent
  if a and type(a.gallery) == "function" then
    local ok, res = pcall(a.gallery, a)
    if ok and type(res) == "table" then return res end
  end
  return {}
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")
  local list = self:items()
  if #list == 0 then
    local y = r.y + m.viewPad
    kit:text({ x = r.x + m.viewPad, y = y }, kit:pick("还没有产出物。", "Nothing produced yet."), { tone = "dim" })
    y = y + m.lineH + 8
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("每次落笔的图都会留一份缩略图在这里，方便找回上一步的结果。",
                      "Every drawing step leaves a thumbnail here so you can get back to it."),
             { tone = "faint" })
    return self
  end

  local cell = 72
  local gap = m.gap
  local cols = math.max(1, math.floor((r.w - m.viewPad * 2 + gap) / (cell + gap)))
  local x0 = r.x + m.viewPad
  local y0 = r.y + m.viewPad
  for i, it in ipairs(list) do
    local ci = (i - 1) % cols
    local ri = math.floor((i - 1) / cols)
    local cr = { x = x0 + ci * (cell + gap), y = y0 + ri * (cell + gap + m.lineH), w = cell, h = cell }
    if cr.y + cr.h > r.y + r.h then break end
    kit:fill(cr, "surface2")
    kit:frameRect(cr, self.sel == i and "accent" or "line")
    if it.image then
      kit:image({ x = cr.x + 2, y = cr.y + 2, w = cell - 4, h = cell - 4 }, it.image)
    else
      kit:text({ x = cr.x + 8, y = cr.y + math.floor(cell / 2) - 6 }, "▦", { tone = "faint" })
    end
    if it.label then
      kit:text({ x = cr.x, y = cr.y + cell + 2 }, kit.u8sub(tostring(it.label), 1, 12), { tone = "dim" })
    end
    self.hits[#self.hits + 1] = { rect = cr, kind = "thumb", index = i }
  end
  return self
end

function View:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then return h end
  end
  return nil
end

function View:nav(delta)
  local n = #self:items()
  if n == 0 then return false end
  self.sel = math.max(1, math.min((self.sel or 1) + delta, n))
  return true
end

function View:wheel(dy) self.scroll = math.max(0, self.scroll + (dy > 0 and 1 or -1)); return true end

return gallery
