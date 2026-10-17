-- lib/views/memory.lua -- 记忆页（v1 骨架）
--
-- 记忆不占常驻 token，所以这里就是**唯一的可见入口**：条目 + 检索框 + 标签。
-- 骨架也要求真数据：条目来自 agent.memory()（桥侧 memory.json 的形状）。

local i18n = require("lib.i18n")

local memory = {}
local View = {}
View.__index = View

local function zh() return i18n.isZh() end

function memory.mount(ctx)
  return setmetatable({ ctx = ctx, hits = {}, query = "", sel = 1, scroll = 0 }, View)
end

function View:title() return zh() and "记忆" or "MEMORY" end
function View:actions() return { { id = "search", label = zh() and "检索" or "Search" } } end

function View:entries()
  if self.ctx and type(self.ctx.memories) == "table" then return self.ctx.memories end
  local a = self.ctx and self.ctx.agent
  if a and type(a.memory) == "function" then
    local ok, res = pcall(a.memory, a, self.query)
    if ok and type(res) == "table" then return res end
  end
  return {}
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")

  -- 检索框（不是真 entry：语义上它只是"这里能搜"，真输入走 composer）
  local qr = { x = r.x + m.viewPad, y = r.y + m.viewPad, w = r.w - m.viewPad * 2, h = m.lineH + 8 }
  kit:fill(qr, "surface2")
  kit:frameRect(qr, state.focus == "main" and "lineHi" or "line")
  local qtext = self.query ~= "" and self.query or kit:pick("按关键词/标签检索…", "search by keyword or tag…")
  kit:text({ x = qr.x + 6, y = qr.y + 4 }, qtext, { tone = self.query ~= "" and "text" or "faint" })
  self.hits[#self.hits + 1] = { rect = qr, kind = "search" }

  local list = self:entries()
  local y = qr.y + qr.h + 8
  if #list == 0 then
    kit:text({ x = r.x + m.viewPad, y = y }, kit:pick("还没有记住任何东西。", "Nothing remembered yet."), { tone = "dim" })
    y = y + m.lineH + 8
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("让它记住：「记住 #2E86DE 是外壳蓝，标签: shell」", "Try: \"remember #2E86DE is my shell blue, tags: shell\""),
             { tone = "faint" })
    return self
  end

  local tags = {}
  local items = {}
  for i, e in ipairs(list) do
    local text = tostring(e.text or e.content or e.value or "")
    -- 按字符切，不按字节：切断多字节序列会让 fillText 崩宿主
    items[#items + 1] = { text = kit.u8sub(text, 1, 96), tone = "text", badge = e.tag or e.kind }
    for _, t in ipairs(e.tags or {}) do tags[tostring(t)] = (tags[tostring(t)] or 0) + 1 end
  end
  local layout = kit:list({ x = r.x, y = y, w = r.w, h = math.max(0, r.h - (y - r.y) - 28) }, items,
                          { hover = state.hoverRow, sel = self.sel, scroll = self.scroll })
  for _, row in ipairs(layout.rows) do
    self.hits[#self.hits + 1] = { rect = row.rect, kind = "entry", index = row.index }
  end

  -- 标签云：按出现次数排序，一行排下去
  local tx = r.x + m.viewPad
  local ty = r.y + r.h - m.rowH
  kit:text({ x = tx, y = ty }, "#", { tone = "faint" })
  tx = tx + 10
  local names = {}
  for t, n in pairs(tags) do names[#names + 1] = { t = t, n = n } end
  table.sort(names, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.t < b.t end)
  for i = 1, math.min(#names, 10) do
    local label = names[i].t
    local lw = kit:measure(label, {})
    if tx + lw > r.x + r.w - m.viewPad then break end
    kit:text({ x = tx, y = ty }, label, { tone = "dim" })
    tx = tx + lw + 8
  end
  return self
end

function View:setQuery(q) self.query = tostring(q or ""); return true end

-- 标题行右侧「检索」：把焦点交给 composer（检索真正的通路是对话 + 桥侧 memory 检索）
function View:action(id, state)
  if id ~= "search" then return false end
  local wb = self.ctx and self.ctx.workbench
  if not wb then return false end
  wb:openInput()
  wb:log("在下面输入关键词检索记忆（例如「shell 蓝」）", "info")
  return true
end

-- 点检索框 = 想搜：把焦点交给 composer（与标题行「检索」同一个动作）
function View:click(hit)
  if hit and hit.kind == "search" then
    return self:action("search")
  end
  if hit and hit.kind == "entry" and hit.index then
    self.sel = hit.index
    return true
  end
  return false
end

function View:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then return h end
  end
  return nil
end

function View:nav(delta)
  local n = #self:entries()
  if n == 0 then return false end
  self.sel = math.max(1, math.min((self.sel or 1) + delta, n))
  return true
end

function View:wheel(dy) self.scroll = math.max(0, self.scroll + (dy > 0 and 1 or -1)); return true end

return memory
