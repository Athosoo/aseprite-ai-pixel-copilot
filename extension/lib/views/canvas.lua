-- lib/views/canvas.lua -- 画布页：算子台（ui §5）
--
-- 算子名单**只从 registry 来**（arch §3.2 的 op 规格），不硬编码 —— 硬编码正是
-- v0.5.x 的病根：加一个算子要改两处源码。
--
-- 参数表单也从 spec.params 生成，所以新算子装进来即有表单。

local i18n = require("lib.i18n")

local canvas = {}
local View = {}
View.__index = View

local TITLE = { zh = "画布", en = "CANVAS" }

local function zh() return i18n.isZh() end

function canvas.mount(ctx)
  return setmetatable({
    ctx = ctx,
    sel = 1,
    scroll = 0,
    hits = {},
    paramValues = {},   -- 不叫 params：会盖住同名的 View:params()
    flash = nil,
  }, View)
end

function View:title() return zh() and TITLE.zh or TITLE.en end

function View:actions(state)
  return {
    { id = "preview", label = zh() and "预览" or "Preview" },
    { id = "apply", label = zh() and "应用" or "Apply" },
  }
end

-- 算子表：registry 有 op 就全取（含包提供的），一个都没有时给空状态
function View:ops()
  local reg = self.ctx and self.ctx.registry
  if not reg or not reg.list then return {} end
  local ok, list = pcall(function() return reg:list("op") end)
  if not ok or type(list) ~= "table" then return {} end
  return list
end

function View:selected()
  local ops = self:ops()
  if #ops == 0 then return nil end
  local i = math.min(self.sel or 1, #ops)
  return ops[i], i
end

function View:params(spec)
  local out = {}
  for _, p in ipairs((spec and spec.params) or {}) do
    out[#out + 1] = {
      key = p.name or p.key,
      label = p.label or p.name or p.key,
      type = p.type or "string",
      value = self.paramValues[p.name or p.key] or p.default,
    }
  end
  return out
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")
  local ops = self:ops()

  if #ops == 0 then
    -- 空状态是设计的一部分（ui §5）
    local y = r.y + m.viewPad
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("还没有注册任何算子。", "No operators are registered."), { tone = "dim" })
    y = y + m.lineH + 8
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("算子由能力包提供 —— 去扩展页看看有没有装。", "Operators come from packs -- check the Extensions page."),
             { tone = "faint" })
    return self
  end

  local listW = math.min(180, math.floor(r.w * 0.38))
  local listR = { x = r.x, y = r.y, w = listW, h = r.h }
  local formR = { x = r.x + listW + 1, y = r.y, w = r.w - listW - 1, h = r.h }
  kit:fill(listR, "surface")
  kit:rule({ x = formR.x - 1, y = r.y, w = m.hair, h = r.h }, "line")
  kit:fill(formR, "surface")

  local items = {}
  for i, spec in ipairs(ops) do
    items[#items + 1] = {
      text = tostring(spec.label or spec.name or spec.id or "?"),
      tone = "text",
      badge = spec.name and tostring(spec.name) or nil,
      badgeTone = "dim",
    }
  end
  local layout = kit:list({ x = listR.x, y = listR.y + 4, w = listR.w, h = listR.h - 8 }, items,
                          { sel = self.sel, hover = state.hoverRow, scroll = self.scroll })
  for _, row in ipairs(layout.rows) do
    self.hits[#self.hits + 1] = { rect = row.rect, kind = "op", index = row.index }
  end

  local spec = self:selected()
  local y = formR.y + m.viewPad
  local x = formR.x + m.viewPad
  local innerW = formR.w - m.viewPad * 2
  kit:text({ x = x, y = y }, tostring(spec.label or spec.name or ""), { bold = true, tone = "text" })
  y = y + m.lineH + m.gap
  kit:text({ x = x, y = y }, string.format("%s  %s", tostring(spec.name or ""), zh() and "一步撤销" or "one undo step"),
           { tone = "dim", mono = true })
  y = y + m.lineH + m.gap
  kit:rule({ x = x, y = y, w = innerW, h = m.hair }, "line")
  y = y + m.gap + 4

  local ps = self:params(spec)
  if #ps == 0 then
    kit:text({ x = x, y = y }, kit:pick("这个算子没有参数。", "This operator takes no parameters."), { tone = "faint" })
  else
    for _, p in ipairs(ps) do
      local fr = { x = x, y = y, w = innerW, h = m.rowH }
      kit:field(fr, tostring(p.label), tostring(p.value == nil and "—" or p.value))
      self.hits[#self.hits + 1] = { rect = fr, kind = "param", key = p.key }
      y = y + m.rowH
    end
  end

  y = y + m.gap
  kit:rule({ x = x, y = y, w = innerW, h = m.hair }, "line")
  y = y + m.gap + 4
  kit:text({ x = x, y = y }, kit:pick("历史", "HISTORY"), { bold = true, tone = "dim" })
  y = y + m.lineH + m.gap
  local hist = self:history()
  if #hist == 0 then
    kit:text({ x = x, y = y }, kit:pick("还没有执行过。", "Nothing applied yet."), { tone = "faint" })
  else
    for i, h in ipairs(hist) do
      if i > 4 then break end
      kit:text({ x = x, y = y }, string.format("%s  %s", tostring(h.name or ""), tostring(h.detail or "")), { tone = "dim", mono = true })
      y = y + m.rowH
    end
  end
  return self
end

-- 历史来自 host:versions()（v0.5.x 的版本栈，接口不变）
function View:history()
  local host = self.ctx and self.ctx.host
  if not host or not host.versions then return {} end
  local ok, vs = pcall(host.versions, host)
  if not ok or not vs or type(vs.list) ~= "function" then return {} end
  local ok2, list = pcall(vs.list, vs)
  if not ok2 or type(list) ~= "table" then return {} end
  local out = {}
  for i = 1, math.min(#list, 4) do out[#out + 1] = list[i] end
  return out
end

function View:click(hit)
  if not hit then return false end
  if hit.kind == "op" and hit.index then
    self.sel = hit.index
    return true
  end
  return false
end

function View:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then
      return h
    end
  end
  return nil
end

function View:wheel(dy)
  local n = #self:ops()
  self.scroll = math.max(0, math.min(self.scroll + (dy > 0 and 1 or -1), math.max(0, n - 1)))
  return true
end

function View:nav(delta)
  local n = #self:ops()
  if n == 0 then return false end
  self.sel = math.max(1, math.min((self.sel or 1) + delta, n))
  return true
end

return canvas
