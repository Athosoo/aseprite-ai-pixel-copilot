-- lib/settings.lua -- 桥 / LLM 设置对话框（插件内改 API，不用手工编辑 config.json）
--
-- 安全约定：桥只把"是否已设置 + 掩码提示"发过来，绝不外传完整 key；
-- 输入框永远留空，留空 = 保持原值不变。

local settings = {}

local Settings = {}
Settings.__index = Settings

function settings.new(opts)
  -- opts: { port, onSave(llmTable), onTest() }
  return setmetatable({ opts = opts or {}, dlg = nil, shown = false }, Settings)
end

function Settings:isShown()
  return self.shown
end

function Settings:_fill(current, wsRoot)
  if not (self.dlg and self.shown) then return end
  current = current or {}
  local data = {
    baseUrl = current.baseUrl or "",
    model = current.model or "",
  }
  pcall(function() self.dlg:modify{ id = "baseUrl", text = data.baseUrl } end)
  pcall(function() self.dlg:modify{ id = "model", text = data.model } end)
  if wsRoot ~= nil then
    pcall(function() self.dlg:modify{ id = "wsRoot", text = tostring(wsRoot) } end)
  end
  pcall(function()
    self.dlg:modify{
      id = "apiKey",
      text = "",
      placeholder = current.apiKeySet
        and ("already set (" .. tostring(current.apiKeyHint or "****") .. ") - leave empty to keep")
        or "paste your key here",
    }
  end)
end

function Settings:show(current)
  if self.shown and self.dlg then
    self:_fill(current)
    return
  end

  local dlg = Dialog{ title = "Bridge / LLM Settings", onclose = function() self.shown = false end }

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
      and ("already set (" .. tostring(current.apiKeyHint or "****") .. ") - leave empty to keep")
      or "paste your key here",
  }
  dlg:newrow()

  -- focus=true 让 Save 成为磁吸按钮：在输入框里按回车即保存
  dlg:button{ id = "save", text = "Save", focus = true, onclick = function() self:_save() end }
  dlg:button{ id = "test", text = "Test Connection", onclick = function() self:_test() end }
  dlg:button{ id = "close", text = "Close", onclick = function() self:hide() end }

  self.dlg = dlg
  dlg:show{ wait = false }
  self.shown = true
  -- 输入框拿键盘焦点（Save 仍是磁吸按钮，回车照样能存）
  dlg:modify{ id = "baseUrl", focus = true }
end

function Settings:_values()
  local d = (self.dlg and self.dlg.data) or {}
  return {
    baseUrl = tostring(d.baseUrl or ""),
    model = tostring(d.model or ""),
    apiKey = tostring(d.apiKey or ""),
    wsRoot = tostring(d.wsRoot or ""),
  }
end

function Settings:_save()
  local v = self:_values()
  if self.dlg then pcall(function() self.dlg:modify{ id = "apiKey", text = "" } end) end
  local llm = { baseUrl = v.baseUrl, model = v.model, apiKey = v.apiKey }
  if self.opts.onSave then self.opts.onSave(llm, v.wsRoot) end
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
