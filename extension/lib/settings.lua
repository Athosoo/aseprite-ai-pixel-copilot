-- lib/settings.lua -- 桥 / LLM 设置对话框（插件内改 API，不用手工编辑 config.json）
--
-- 安全约定：桥只把"是否已设置 + 掩码提示"发过来，绝不外传完整 key；
-- 输入框永远留空，留空 = 保持原值不变。
--
-- 布局：连接信息（Base URL / Model / API Key）+ 工作区 / 栏底色 + 高级（步数 / 上下文 / 温度 / 思考）。
-- 高级项故意放这儿而不是底边栏：底边栏只有 60px 高，输入区就占满了，塞不下输入框。

local i18n = require("lib.i18n")

local settings = {}

local Settings = {}
Settings.__index = Settings

function settings.new(opts)
  -- opts: { port, wsRoot, barBg, onSave(llm, wsRoot, barBg), onTest() }
  return setmetatable({ opts = opts or {}, dlg = nil, shown = false }, Settings)
end

function Settings:isShown()
  return self.shown
end

-- 打开 / 重开时把当前值填进输入框。current = 桥发来的 llm 配置。
function Settings:_fill(current, wsRoot, barBg)
  if not (self.dlg and self.shown) then return end
  current = current or {}
  if wsRoot ~= nil then self.opts.wsRoot = wsRoot end
  if barBg ~= nil then self.opts.barBg = barBg end

  local data = {
    baseUrl = current.baseUrl or "",
    model = current.model or "",
    maxSteps = tostring(current.maxSteps or 24),
    contextTokens = tostring(current.contextTokens or 16000),
    temperature = tostring(current.temperature or 0.2),
    thinking = current.thinking or "auto",
    -- 超时桥那边按毫秒存，界面上按秒填（用户想的是"多少秒"，不是"多少毫秒"）
    timeoutSec = tostring(math.floor((tonumber(current.timeoutMs) or 180000) / 1000)),
    maxTurnSec = tostring(math.floor((tonumber(current.maxTurnMs) or 600000) / 1000)),
  }
  pcall(function() self.dlg:modify{ id = "baseUrl", text = data.baseUrl } end)
  pcall(function() self.dlg:modify{ id = "model", text = data.model } end)
  pcall(function() self.dlg:modify{ id = "maxSteps", text = data.maxSteps } end)
  pcall(function() self.dlg:modify{ id = "contextTokens", text = data.contextTokens } end)
  pcall(function() self.dlg:modify{ id = "temperature", text = data.temperature } end)
  pcall(function() self.dlg:modify{ id = "timeoutSec", text = data.timeoutSec } end)
  pcall(function() self.dlg:modify{ id = "maxTurnSec", text = data.maxTurnSec } end)
  pcall(function() self.dlg:modify{ id = "thinking", option = data.thinking } end)
  pcall(function() self.dlg:modify{ id = "wsRoot", text = tostring(self.opts.wsRoot or "") } end)
  pcall(function() self.dlg:modify{ id = "barBg", text = tostring(self.opts.barBg or "") } end)
  pcall(function()
    self.dlg:modify{
      id = "apiKey",
      text = "",
      placeholder = current.apiKeySet
        and (i18n.t("keySetHint") .. " (" .. tostring(current.apiKeyHint or "****") .. ")")
        or i18n.t("keyNewHint"),
    }
  end)
end

function Settings:show(current, wsRoot, barBg)
  if self.shown and self.dlg then
    self:_fill(current, wsRoot, barBg)
    return
  end
  if wsRoot ~= nil then self.opts.wsRoot = wsRoot end
  if barBg ~= nil then self.opts.barBg = barBg end

  local dlg = Dialog{ title = i18n.t("settingsTitle"), onclose = function() self.shown = false end }

  dlg:label{ text = "Bridge: ws://127.0.0.1:" .. tostring(self.opts.port or 8777) }
  dlg:newrow()

  dlg:label{ text = "Base URL" }
  dlg:samerow()
  dlg:entry{ id = "baseUrl", text = (current and current.baseUrl) or "", width = 430 }
  dlg:newrow()

  dlg:label{ text = "Model" }
  dlg:samerow()
  dlg:entry{ id = "model", text = (current and current.model) or "", width = 430 }
  dlg:newrow()

  dlg:label{ text = "API Key" }
  dlg:samerow()
  dlg:entry{
    id = "apiKey",
    text = "",
    width = 430,
    placeholder = (current and current.apiKeySet)
      and (i18n.t("keySetHint") .. " (" .. tostring(current.apiKeyHint or "****") .. ")")
      or i18n.t("keyNewHint"),
  }
  dlg:newrow()

  dlg:separator{ text = i18n.t("wsTitle") }
  dlg:label{ text = "Workspace" }
  dlg:samerow()
  dlg:entry{
    id = "wsRoot",
    text = tostring(self.opts.wsRoot or ""),
    width = 430,
    placeholder = i18n.t("wsHint"),
  }
  dlg:newrow()

  dlg:label{ text = "Bar colour" }
  dlg:samerow()
  dlg:entry{
    id = "barBg",
    text = tostring(self.opts.barBg or ""),
    width = 430,
    placeholder = i18n.t("barBgHint"),
  }
  dlg:newrow()

  -- 高级项：这些值决定"一次能干多少活"
  dlg:separator{ text = i18n.t("advTitle") }
  dlg:label{ text = i18n.t("advSteps") }
  dlg:samerow()
  dlg:entry{ id = "maxSteps", text = "24", width = 70 }
  dlg:samerow()
  dlg:label{ text = i18n.t("advContext") }
  dlg:samerow()
  dlg:entry{ id = "contextTokens", text = "16000", width = 120 }
  dlg:newrow()

  dlg:label{ text = i18n.t("advTemp") }
  dlg:samerow()
  dlg:entry{ id = "temperature", text = "0.2", width = 70 }
  dlg:samerow()
  dlg:label{ text = i18n.t("advThinking") }
  dlg:samerow()
  dlg:combobox{ id = "thinking", option = "auto",
                options = { "auto", "low", "medium", "high" }, width = 120 }
  dlg:newrow()

  dlg:label{ text = i18n.t("advTimeout") }
  dlg:samerow()
  dlg:entry{ id = "timeoutSec", text = "180", width = 70 }
  dlg:samerow()
  dlg:label{ text = i18n.t("advTurn") }
  dlg:samerow()
  dlg:entry{ id = "maxTurnSec", text = "600", width = 70 }
  dlg:newrow()

  dlg:label{ text = i18n.t("advHint") }
  dlg:newrow()

  -- focus=true 让 Save 成为磁吸按钮：在输入框里按回车即保存
  dlg:button{ id = "save", text = i18n.t("btnSave"), focus = true, onclick = function() self:_save() end }
  dlg:button{ id = "test", text = i18n.t("btnTest"), onclick = function() self:_test() end }
  dlg:button{ id = "close", text = i18n.t("btnClose"), onclick = function() self:hide() end }

  self.dlg = dlg
  dlg:show{ wait = false }
  self.shown = true
  -- 输入框拿键盘焦点（Save 仍是磁吸按钮，回车照样能存）
  dlg:modify{ id = "baseUrl", focus = true }
end

function Settings:_values()
  local d = (self.dlg and self.dlg.data) or {}
  local function num(v)
    return tonumber(tostring(v or ""))
  end
  local out = {
    baseUrl = tostring(d.baseUrl or ""),
    model = tostring(d.model or ""),
    apiKey = tostring(d.apiKey or ""),
  }
  -- 数字项解析不出来就【不传】：桥保持原值，别把配置清成空
  local steps, ctx, temp = num(d.maxSteps), num(d.contextTokens), num(d.temperature)
  if steps then out.maxSteps = steps end
  if ctx then out.contextTokens = ctx end
  if temp then out.temperature = temp end
  -- 秒 -> 毫秒。桥那边还会再夹一次范围（10-1800s / 30-3600s），
  -- 这里不夹是故意的：手填了 0.5 也该让桥去决定怎么处理，而不是悄悄改成别的数。
  local tmo, tturn = num(d.timeoutSec), num(d.maxTurnSec)
  if tmo then out.timeoutMs = math.floor(tmo * 1000) end
  if tturn then out.maxTurnMs = math.floor(tturn * 1000) end
  local think = tostring(d.thinking or "")
  if think ~= "" then out.thinking = think end
  return out, tostring(d.wsRoot or ""), tostring(d.barBg or "")
end

function Settings:_save()
  local llm, wsRoot, barBg = self:_values()
  if self.dlg then pcall(function() self.dlg:modify{ id = "apiKey", text = "" } end) end
  -- 记住，下次重开对话框显示的是刚存的值
  self.opts.wsRoot = wsRoot
  self.opts.barBg = barBg
  if self.opts.onSave then self.opts.onSave(llm, wsRoot, barBg) end
end

function Settings:_test()
  -- 先把当前输入存下来，测试才会用新值
  self:_save()
  if self.opts.onTest then self.opts.onTest() end
end

function Settings:hide()
  if self.dlg then pcall(function() self.dlg:close() end) end
  self.shown = false
end

function Settings:destroy()
  self:hide()
  self.dlg = nil
end

return settings
