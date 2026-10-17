-- lib/views/packs.lua -- 扩展页：能力包管理（ui §5）
--
-- 数据全部来自 ledger（arch §3.6）：scan() 发现包、health() 给健康度、
-- enable/disable/rollback 是动作。视图自己**不碰文件系统**，只读 ledger 的结论。

local i18n = require("lib.i18n")

local packs = {}
local View = {}
View.__index = View

local TITLE = { zh = "扩展", en = "PACKS" }

local function zh() return i18n.isZh() end

function packs.mount(ctx)
  return setmetatable({ ctx = ctx, hits = {}, scroll = 0, sel = 1, hover = nil }, View)
end

function View:title() return zh() and TITLE.zh or TITLE.en end

function View:actions(state)
  -- 空状态正文里已经有一个「让它提议」大按钮，标题行再放一个是同义噪音
  if #self:scan() == 0 then
    return { { id = "rescan", label = zh() and "重扫" or "Rescan" } }
  end
  return {
    { id = "propose", label = zh() and "让它提议" or "Propose" },
    { id = "rescan", label = zh() and "重扫" or "Rescan" },
  }
end

function View:ledger()
  return self.ctx and self.ctx.ledger or nil
end

function View:scan()
  local l = self:ledger()
  if not l or not l.scan then return {} end
  local ok, list = pcall(l.scan, l)
  if not ok or type(list) ~= "table" then return {} end
  return list
end

function View:health()
  local l = self:ledger()
  if not l or not l.health then return {} end
  local ok, h = pcall(l.health, l)
  if not ok or type(h) ~= "table" then return {} end
  return h
end

-- 健康度压成一句人话：调用数 / 失败数 / 平均耗时 / 最后一次错误
local function healthLine(h)
  if not h then return zh() and "未运行" or "not run" end
  local bits = {}
  bits[#bits + 1] = string.format("%d %s", h.calls or 0, zh() and "次" or "calls")
  if (h.fails or 0) > 0 then bits[#bits + 1] = string.format("%d %s", h.fails, zh() and "失败" or "fails") end
  if h.msAvg then bits[#bits + 1] = string.format("%.1fms", h.msAvg) end
  return table.concat(bits, "  ")
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")
  local list = self:scan()

  if #list == 0 then
    local y = r.y + m.viewPad
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("还没有自建能力包。", "No custom capability packs yet."), { tone = "dim" })
    y = y + m.lineH + 8
    kit:text({ x = r.x + m.viewPad, y = y },
             kit:pick("让 AI 看看 gaps.md，它知道自己缺什么。", "Let the AI read gaps.md -- it knows what it is missing."),
             { tone = "faint" })
    y = y + m.lineH + 12
    local label = kit:pick("让它提议", "Propose")
    local br = { x = r.x + m.viewPad, y = y, w = kit:measure(label, {}) + 20, h = m.lineH + 8 }
    kit:button(br, label, { hover = state.hoverAction == "propose" })
    self.hits[#self.hits + 1] = { rect = br, kind = "action", id = "propose" }
    return self
  end

  local hh = self:health()
  local items = {}
  for i, pk in ipairs(list) do
    local id = tostring(pk.id or pk.name or ("pack" .. i))
    local h = hh[id]
    local failed = (h and (h.fails or 0) > 0) or pk.err ~= nil or pk.lastErr ~= nil
    local enabled = pk.enabled ~= false
    items[#items + 1] = {
      text = string.format("%s %s", enabled and "●" or "○", tostring(pk.name or id)),
      tone = failed and "err" or (enabled and "text" or "faint"),
      badge = enabled and (zh() and "启用" or "on") or (zh() and "停用" or "off"),
      badgeTone = failed and "err" or (enabled and "ok" or "dim"),
      id = id,
    }
    if failed and (h and h.lastErr or pk.err) then
      -- 失败原因单独一行：光一个红点不叫"失败原因"
      items[#items + 1] = {
        text = "  " .. tostring((h and h.lastErr) or pk.err),
        tone = "err",
        small = true,
        id = id,
      }
    end
  end

  local layout = kit:list({ x = r.x, y = r.y + 4, w = r.w - 96, h = r.h - 8 }, items,
                          { hover = self.hover, sel = self.sel, scroll = self.scroll })
  for _, row in ipairs(layout.rows) do
    self.hits[#self.hits + 1] = { rect = row.rect, kind = "pack", index = row.index, id = row.item.id }
  end

  -- 右侧动作列：启用/禁用、回滚、健康度（数值右对齐成列）
  local colX = r.x + r.w - 92
  local y = r.y + 4
  local cur = self:scan()[self.sel or 1]
  if cur then
    local id = tostring(cur.id or cur.name or ("pack" .. tostring(self.sel)))
    local toggle = (cur.enabled == false) and (zh() and "启用" or "Enable") or (zh() and "禁用" or "Disable")
    local br1 = { x = colX, y = y, w = 84, h = m.lineH + 8 }
    kit:button(br1, toggle, { hover = self.hover == "toggle" })
    self.hits[#self.hits + 1] = { rect = br1, kind = "toggle", id = id }
    local br2 = { x = colX, y = y + m.rowH + 4, w = 84, h = m.lineH + 8 }
    kit:button(br2, (zh() and "↺ 回滚" or "↺ Rollback"), { hover = self.hover == "rollback" })
    self.hits[#self.hits + 1] = { rect = br2, kind = "rollback", id = id }
    kit:text({ x = colX, y = br2.y + br2.h + 8 }, healthLine((self:health())[id]), { tone = "dim", mono = true })
  end
  return self
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
  self.scroll = math.max(0, self.scroll + (dy > 0 and 1 or -1))
  return true
end

function View:nav(delta)
  local n = #self:scan()
  if n == 0 then return false end
  self.sel = math.max(1, math.min((self.sel or 1) + delta, n))
  return true
end

return packs
