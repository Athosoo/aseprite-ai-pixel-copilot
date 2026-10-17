-- lib/views/styles.lua -- 风格页（v1 骨架）
--
-- 骨架的判据是"能显示真实数据"：卡片上的色块条来自当前风格的真实调色板，
-- 规矩摘要来自真实 rules 字段。没有数据时给引导文案，不是"暂无数据"。

local i18n = require("lib.i18n")

local styles = {}
local View = {}
View.__index = View

local function zh() return i18n.isZh() end

function styles.mount(ctx) return setmetatable({ ctx = ctx, hits = {}, sel = 1, scroll = 0 }, View) end
function View:title() return zh() and "风格" or "STYLES" end
function View:actions() return { { id = "new", label = zh() and "新建" or "New" } } end

-- 风格来源：ctx.styles（宿主注入）优先，其次 agent.styles()。都拿不到就是空。
function View:list()
  if self.ctx and type(self.ctx.styles) == "table" then return self.ctx.styles end
  local a = self.ctx and self.ctx.agent
  if a and type(a.styles) == "function" then
    local ok, res = pcall(a.styles, a)
    if ok and type(res) == "table" then return res end
  end
  return {}
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")
  local list = self:list()
  if #list == 0 then
    local y = r.y + m.viewPad
    kit:text({ x = r.x + m.viewPad, y = y }, kit:pick("还没有风格。", "No styles yet."), { tone = "dim" })
    y = y + m.lineH + 8
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("风格 = 调色板 + 图层结构 + 作画规矩，打包成一个可切换的集合。",
                      "A style packs palette + layer structure + drawing rules into one switchable set."),
             { tone = "faint" })
    return self
  end
  local y = r.y + m.viewPad
  local x = r.x + m.viewPad
  local innerW = r.w - m.viewPad * 2
  for i, st in ipairs(list) do
    if y + m.rowH * 3 > r.y + r.h then break end
    local name = tostring(st.name or st.id or ("style" .. i))
    local header = { x = x, y = y, w = innerW, h = m.lineH + 8 }
    if self.sel == i then kit:fill({ x = x - 4, y = y, w = innerW + 8, h = m.lineH + 8 }, "surface2") end
    kit:text({ x = x, y = y }, (self.sel == i and "▸ " or "  ") .. name, { bold = self.sel == i, tone = "text" })
    y = y + m.lineH + 6
    -- 色块条：每格 12x12，直接来自 palette
    local pal = st.palette or st.colors or {}
    local sw = 0
    for k = 1, math.min(#pal, 24) do
      local c = pal[k]
      local hex = type(c) == "string" and c or (type(c) == "table" and c.hex) or nil
      local col = hex and kit.hexToColor(hex) or nil
      if col then
        if kit.gc then kit.gc.color = col; kit.gc:fillRect(kit.toRect({ x = x + sw, y = y, w = 12, h = 12 })) end
        kit:pushCall("swatch", { x = x + sw, y = y, w = 12, h = 12 }, {})
        sw = sw + 13
      end
    end
    y = y + 16
    if st.rules then
      kit:text({ x = x, y = y }, kit.u8sub(tostring(st.rules), 1, 120), { tone = "dim" })
      y = y + m.lineH + 4
    end
    if st.layers then
      kit:text({ x = x, y = y }, string.format("%s %d", zh() and "图层" or "layers", #st.layers), { tone = "faint", mono = true })
      y = y + m.lineH + 4
    end
    y = y + m.gap + 4
    kit:rule({ x = x, y = y, w = innerW, h = m.hair }, "line")
    y = y + m.gap + 4
    self.hits[#self.hits + 1] = { rect = header, kind = "style", index = i, id = st.id or name }
  end
  return self
end

-- 标题行右侧「新建」：v1 只读骨架，交回壳记 noop（带理由并打一行）
function View:action(id, state)
  if id == "new" then return false end
  return false
end

function View:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then return h end
  end
  return nil
end

function View:nav(delta)
  local n = #self:list()
  if n == 0 then return false end
  self.sel = math.max(1, math.min((self.sel or 1) + delta, n))
  return true
end

function View:wheel(dy) self.scroll = math.max(0, self.scroll + (dy > 0 and 1 or -1)); return true end

return styles
