-- lib/views/settings.lua -- 设置页（v1 骨架）
--
-- 端点/密钥/模型/温度/超时/语言/主题。密钥只显示尾部 —— 面板上永远不出现明文。
-- 真正的读写仍在 bridge/config.json（原地不动，D4）。

local i18n = require("lib.i18n")

local settings = {}
local View = {}
View.__index = View

local function zh() return i18n.isZh() end

function settings.mount(ctx) return setmetatable({ ctx = ctx, hits = {}, sel = 1 }, View) end
function View:title() return zh() and "设置" or "SETTINGS" end
function View:actions() return { { id = "save", label = zh() and "保存" or "Save" } } end

function View:config()
  return (self.ctx and self.ctx.config) or {}
end

local function mask(key)
  local s = tostring(key or "")
  if s == "" then return zh() and "未设置" or "not set" end
  if #s <= 6 then return "***" end
  return "***" .. kit.u8sub(s, -4)
end

function View:rows()
  local c = self:config()
  local llm = c.llm or {}
  local out = {
    { label = zh() and "端点" or "Endpoint", value = tostring(llm.baseUrl or c.baseUrl or "—") },
    { label = zh() and "密钥" or "API key", value = mask(llm.apiKey or c.apiKey) },
    { label = zh() and "模型" or "Model", value = tostring(llm.model or c.model or "—") },
    { label = zh() and "温度" or "Temperature", value = tostring(llm.temperature or "—") },
    { label = zh() and "单次超时" or "Request timeout", value = string.format("%ss", tostring(llm.timeoutMs and (llm.timeoutMs // 1000) or "—")) },
    { label = zh() and "整轮超时" or "Turn timeout", value = string.format("%ss", tostring(llm.maxTurnMs and (llm.maxTurnMs // 1000) or "—")) },
    { label = zh() and "语言" or "Language", value = zh() and "中文" or "English" },
    { label = zh() and "主题" or "Theme", value = self.ctx and self.ctx.theme and self.ctx.theme.name or "dark" },
  }
  return out
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")
  local rows = self:rows()
  local x = r.x + m.viewPad
  local y = r.y + m.viewPad
  local innerW = r.w - m.viewPad * 2
  kit:text({ x = x, y = y }, kit:pick("连接", "CONNECTION"), { bold = true, tone = "dim" })
  y = y + m.lineH + m.gap
  for i = 1, 6 do
    local row = rows[i]
    local fr = { x = x, y = y, w = innerW, h = m.rowH }
    kit:field(fr, row.label, row.value)
    self.hits[#self.hits + 1] = { rect = fr, kind = "field", index = i }
    y = y + m.rowH
  end
  y = y + m.gap
  kit:rule({ x = x, y = y, w = innerW, h = m.hair }, "line")
  y = y + m.gap + 4
  kit:text({ x = x, y = y }, kit:pick("界面", "INTERFACE"), { bold = true, tone = "dim" })
  y = y + m.lineH + m.gap
  for i = 7, #rows do
    local row = rows[i]
    local fr = { x = x, y = y, w = innerW, h = m.rowH }
    kit:field(fr, row.label, row.value)
    self.hits[#self.hits + 1] = { rect = fr, kind = "field", index = i }
    y = y + m.rowH
  end
  return self
end

function View:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then return h end
  end
  return nil
end

return settings
