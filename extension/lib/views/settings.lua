-- lib/views/settings.lua -- 设置页：**画布内编辑**，不再打开旧面板的原生设置窗
--
-- 为什么改：之前点一行就调 agent:action("settings") 弹旧原生窗，用户一眼看出
-- "新 UI 里点一下掉回旧面板"。现在点行 → 进入字段编辑态（composer 变单行编辑器），
-- Enter 写回 bridge/config.json，Esc 取消。复用的是已验证的 entry 哨兵差分 + submit/Esc。

local i18n = require("lib.i18n")

local settings = {}
local View = {}
View.__index = View

local function zh() return i18n.isZh() end

function settings.mount(ctx) return setmetatable({ ctx = ctx, hits = {}, sel = 1, overlay = {} }, View) end
function View:title() return zh() and "设置" or "SETTINGS" end
-- 没有标题行动作了：保存由字段编辑的 Enter 承担（少一个"点了不知道干啥"的按钮）
function View:actions() return {} end

function View:agent() return self.ctx and self.ctx.agent or nil end

function View:config()
  local a = self:agent()
  local cfg = (a and a.config) or (self.ctx and self.ctx.config) or {}
  return cfg
end

local function maskOf(a)
  -- 只显示 hint，永远不回显真 key
  local hint = a and a.config and a.config.apiKeyHint or nil
  if type(hint) == "string" and hint ~= "" then return "***" .. hint end
  if a and a.config and a.config.apiKeySet then return "***" end
  return zh() and "未设置" or "not set"
end

-- 10 个字段一个不少。kind: text / number / enum / secret
function View:fields()
  local c = self:config()
  local a = self:agent()
  local o = self.overlay or {}
  local function pick(key, fallback)
    if o[key] ~= nil then return o[key] end
    local v = c[key]
    if v == nil then return fallback end
    return v
  end
  local function sec(ms)
    local n = tonumber(ms)
    if not n or n <= 0 then return ms end
    return tostring(math.floor(n / 1000))
  end
  local unset = zh() and "未设置" or "not set"
  local function textOf(key, fallback)
    local v = pick(key, nil)
    if v == nil or tostring(v) == "" then return unset, true end
    return tostring(v), false
  end
  local baseUrl, baseMissing = textOf("baseUrl")
  local model, modelMissing = textOf("model")
  return {
    { key = "baseUrl", label = zh() and "端点" or "Base URL", kind = "text", required = true,
      value = baseUrl, missing = baseMissing,
      hint = "Base URL（例如 https://api.openai.com/v1）—— 必填" },
    { key = "model", label = zh() and "模型" or "Model", kind = "text", required = true,
      value = model, missing = modelMissing, hint = "Model（例如 gpt-4o）—— 必填" },
    { key = "apiKey", label = zh() and "密钥" or "API Key", kind = "secret", required = true,
      value = maskOf(a), missing = not (a and a.config and a.config.apiKeySet),
      hint = zh() and "API Key（必填；留空 = 保持不变）" or "API Key (required; blank = keep current)" },
    { key = "language", label = zh() and "语言" or "Language", kind = "enum", enum = { "zh", "en" },
      value = zh() and "zh" or "en",
      hint = zh() and "语言 zh / en（重启 Aseprite 生效）" or "language zh / en (restart Aseprite)" },
    { key = "temperature", label = zh() and "温度" or "Temperature", kind = "number",
      value = tostring(pick("temperature", "0.2")), min = 0, max = 2, hint = "temperature 0 ~ 2" },
    { key = "maxSteps", label = zh() and "步数上限" or "Max steps", kind = "number",
      value = tostring(pick("maxSteps", "24")), min = 1, max = 200, hint = "maxSteps 1 ~ 200" },
    { key = "contextTokens", label = zh() and "上下文上限" or "Context tokens", kind = "number",
      value = tostring(pick("contextTokens", "16000")), min = 1000, max = 2000000,
      hint = "contextTokens（立即生效）" },
    { key = "thinking", label = zh() and "思考强度" or "Thinking", kind = "enum",
      enum = { "auto", "low", "medium", "high" },
      value = tostring(pick("thinking", "auto")), hint = "thinking auto / low / medium / high" },
    { key = "timeoutSec", label = zh() and "单次超时" or "Request timeout", kind = "number",
      value = sec(c.timeoutMs) or "180", min = 10, max = 1800,
      hint = zh() and "单次请求秒数 10 ~ 1800" or "request seconds 10 ~ 1800" },
    { key = "maxTurnSec", label = zh() and "整轮超时" or "Turn timeout", kind = "number",
      value = sec(c.maxTurnMs) or "600", min = 30, max = 3600,
      hint = zh() and "整轮秒数 30 ~ 3600" or "turn seconds 30 ~ 3600" },
  }
end

-- 校验 + 写回。返回 ok, err（err 原样打给用户）
function View:commitField(field, text)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local a = self:agent()
  local wb = self.ctx and self.ctx.workbench or nil

  if field.kind == "number" then
    local n = tonumber(text)
    if not n then return false, string.format(zh() and "%s 需要数字" or "%s needs a number", tostring(field.label)) end
    if field.min and n < field.min then return false, string.format("%s < %s", tostring(field.label), tostring(field.min)) end
    if field.max and n > field.max then return false, string.format("%s > %s", tostring(field.label), tostring(field.max)) end
  elseif field.kind == "enum" then
    local okEnum = false
    for _, v in ipairs(field.enum or {}) do if text == v then okEnum = true end end
    if not okEnum then
      return false, string.format(zh() and "%s 只能是 %s" or "%s must be one of %s",
        tostring(field.label), table.concat(field.enum or {}, " / "))
    end
  elseif field.kind == "text" then
    if text == "" then return false, string.format(zh() and "%s 不能为空" or "%s cannot be empty", tostring(field.label)) end
    if field.key == "baseUrl" and not text:match("^https?://") then
      return false, zh() and "端点要以 http:// 或 https:// 开头" or "endpoint must start with http(s)://"
    end
  elseif field.kind == "secret" then
    if text == "" then
      -- 留空 = 保持不变（不回显真 key，也就不允许"清空"这个副作用）
      if wb then wb:log(zh() and "密钥未改动（留空 = 保持不变）" or "API key unchanged", "info") end
      return true
    end
  end

  if field.key == "language" then
    local pref = (text == "zh") and "zh_hans" or "en"
    local okPref = pcall(function() app.preferences.general.language = pref end)
    if not okPref then return false, zh() and "写不了 Aseprite 首选项" or "cannot write Aseprite preferences" end
    self.overlay.language = text
    if wb then
      wb:log(string.format(zh() and "已保存 language=%s（重启 Aseprite 生效）"
        or "saved language=%s (restart to apply)", text), "tool")
    end
    return true
  end

  local llm = {}
  if field.key == "timeoutSec" then
    llm.timeoutMs = math.floor((tonumber(text) or 0) * 1000)
  elseif field.key == "maxTurnSec" then
    llm.maxTurnMs = math.floor((tonumber(text) or 0) * 1000)
  elseif field.kind == "number" then
    llm[field.key] = tonumber(text)
  else
    llm[field.key] = text
  end

  -- 未连接时**明说**，不要静默失败（用户反馈"密钥存不上"就卡在这里：set_config 发出去没人收）
  local connState = wb and wb.state and wb.state.connected
  local sinkOpen = nil
  if a and a.conn and type(a.conn.isOpen) == "function" then
    local okOpen, isOpen = pcall(a.conn.isOpen, a.conn)
    if okOpen then sinkOpen = isOpen and true or false end
  end
  if connState == false or sinkOpen == false then
    return false, zh() and "未连接桥，无法保存（请先在红条上点「重试」）"
                        or "bridge not connected; cannot save (hit Retry on the red bar first)"
  end
  if not (a and type(a.send) == "function") then
    return false, zh() and "桥没连上，改动无法写回" or "bridge not connected; cannot save"
  end
  local okSend, serr = pcall(a.send, a, { type = "set_config", llm = llm })
  if not okSend then return false, tostring(serr) end

  -- 本地立即反映（桥是唯一真相，但用户不该等到下一帧 status 才看到新值）
  if field.key ~= "apiKey" then self.overlay[field.key] = text end
  if wb then wb:log(string.format(zh() and "已保存 %s=%s" or "saved %s=%s", field.key, text), "tool") end
  return true
end

function View:render(kit, r, state)
  state = state or {}
  self.hits = {}
  local m = kit:theme().metrics
  kit:fill(r, "surface")
  local rows = self:fields()
  local x = r.x + m.viewPad
  local y = r.y + m.viewPad
  local innerW = r.w - m.viewPad * 2
  local editId = state.fieldEditId

  -- 首次配置引导：先告诉用户"连的是谁、缺哪三项就聊不了"
  local port = (self.ctx and self.ctx.kernel and self.ctx.kernel.ledger and nil) or 8777
  local a = self:agent()
  if a and a.cfg and tonumber(a.cfg.port) then port = tonumber(a.cfg.port) end
  local intro = zh()
    and string.format("本地桥 ws://127.0.0.1:%s · 端点 / 模型 / 密钥三项必填，缺一项就无法对话", tostring(port))
    or string.format("local bridge ws://127.0.0.1:%s · endpoint / model / API key are required; without them no chat", tostring(port))
  kit:text({ x = x, y = y }, intro, { tone = "faint" })
  y = y + m.lineH + m.gap

  local function section(title)
    kit:text({ x = x, y = y }, title, { bold = true, tone = "dim" })
    y = y + m.lineH + m.gap
  end
  local function fieldRow(field, index)
    local fr = { x = x, y = y, w = innerW, h = m.rowH }
    if state.hoverRow == index then kit:fill(fr, "surface2") end
    if editId == field.key then
      -- 正在编辑的那一行：左侧 2px accent 竖条（焦点可见性）
      kit:fill({ x = fr.x, y = fr.y, w = m.accentBar, h = fr.h }, "accent")
    end
    local label = tostring(field.label)
    if field.required then label = label .. " *" end
    kit:field(fr, label, tostring(field.value), { valueTone = field.missing and "err" or "text" })
    self.hits[#self.hits + 1] = { rect = fr, kind = "field", index = index, id = field.key }
    y = y + m.rowH
  end

  section(zh() and "连接" or "CONNECTION")
  for i = 1, 5 do fieldRow(rows[i], i) end
  y = y + m.gap
  kit:rule({ x = x, y = y, w = innerW, h = m.hair }, "line")
  y = y + m.gap + 4
  section(zh() and "高级" or "ADVANCED")
  for i = 6, #rows do fieldRow(rows[i], i) end

  y = y + m.gap
  kit:text({ x = x, y = y },
    zh() and "点一行即可在下方输入框里改：回车保存，Esc 取消（不弹原生窗口）"
         or "click a row to edit it in the composer: Enter saves, Esc cancels",
    { tone = "faint" })
  return self
end

function View:hitAt(x, y)
  for _, h in ipairs(self.hits) do
    if x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then return h end
  end
  return nil
end

-- 点一行 → 进入字段编辑态（composer 变单行编辑器）
function View:click(hit)
  if not hit or hit.kind ~= "field" then return false end
  local wb = self.ctx and self.ctx.workbench
  if not wb or type(wb.beginFieldEdit) ~= "function" then return false end
  local field = nil
  for _, f in ipairs(self:fields()) do if f.key == hit.id then field = f end end
  if not field then return false end

  -- 预填：secret 不预填（我们没有真 key，也不能造）；其它类型预填当前值
  local prefill = (field.kind == "secret") and "" or tostring(field.value or "")
  local view = self
  wb:beginFieldEdit({
    id = "settings." .. field.key,
    label = tostring(field.label),
    value = prefill,
    mask = (field.kind == "secret"),
    hint = field.hint,
    onCommit = function(text) return view:commitField(field, text) end,
  })
  return true
end

return settings
