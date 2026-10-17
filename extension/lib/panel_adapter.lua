-- lib/panel_adapter.lua -- 把工作台伪装成 agent 认识的"面板"
--
-- 为什么需要它：agent.lua 里 self.panel 永远绑的是旧 lib.panel 实例（agent.lua:186），
-- 而工作台是另一个 new 出来的对象。于是真机上出现过这种事：新工作台窗口在那儿，
-- 但 log/状态/提问/命令表全写进一个不显示的旧面板 —— 看起来就是"面板点不动"。
-- 面板其实没死，是没人往里灌数据。
--
-- 这里做的是**适配器**，不是重写：agent 用到的每个方法都实现一遍，
-- 能映射到工作台能力的就映射，映射不了的退回旧面板（弹窗类），
-- 连旧面板都没有就安全 no-op 并记进 adapter.unsupported[]。
-- 铁律：**一个方法都不许抛错** —— agent 的调用点没有 pcall 兜着。

local adapter = {}
local Adapter = {}
Adapter.__index = Adapter

-- agent.lua 里 self.panel:X 的全部方法名（panel_contract_test 会静态核对这张表）
adapter.METHODS = {
  "log", "setStatus", "setHint", "setContext", "setThinking", "setBarColor",
  "setMode", "layoutMode", "cycleMode",
  "show", "isShown", "hide",
  "openMenu", "openTable", "replayLines", "clear",
  "setAsk", "setPendingInput", "setPendingApply",
  "showMini", "hideMini",
  "_showAskDialog", "_closeAskDialog", "_showFixDialog", "addFixFile", "fixQueueSize",
  "showDeliverDialog", "destroy",
}

-- 两种构造形状都认，因为调用方已经在树上了：
--   adapter.new(workbench, { fallback = 旧panel, agent = a })       -- 我的形状
--   adapter.new{ workbench = wb, panel = 旧panel, agent = a }       -- main.lua 的形状
-- 判据是"第一个参数里有 workbench/wb/panel 键"：Workbench 实例没有这些字段。
function adapter.new(wbOrOpts, opts)
  local o = opts or {}
  local wb = wbOrOpts
  if type(wbOrOpts) == "table" and (wbOrOpts.workbench ~= nil or wbOrOpts.wb ~= nil or wbOrOpts.panel ~= nil) then
    o = wbOrOpts
    wb = o.workbench or o.wb
  end
  local self = setmetatable({
    wb = wb,
    -- agent 会往面板上挂命令表数据源：self.panel.opts.menuCommands = function() ... end
    -- 所以这个字段必须存在且可写（agent.lua:532）。
    opts = {},
    fallback = o.fallback or o.panel or nil,
    agent = o.agent or nil,
    kernel = o.kernel or nil,
    unsupported = {},
    errors = {},
    calls = 0,
    _noopSet = {},
  }, Adapter)
  return self
end

-- 把 agent 的面板换成适配器（主入口，main.lua 一行就能用）
function adapter.attach(agent, wb)
  if not agent then return nil end
  local a = adapter.new(wb, { fallback = agent.panel, agent = agent })
  agent.panel = a
  return a
end

----------------------------------------------------------------------
-- 兜底管道
----------------------------------------------------------------------

function Adapter:_run(name, fn, ...)
  self.calls = self.calls + 1
  local ok, res = pcall(fn, ...)
  if not ok then
    self.errors[name] = tostring(res)
    return nil
  end
  return res
end

-- 两个后端都做不了：记一笔，绝不抛错
function Adapter:_noop(name)
  if not self._noopSet[name] then
    self._noopSet[name] = true
    self.unsupported[#self.unsupported + 1] = name
  end
  return nil
end

local unpackFn = table.unpack or unpack

-- 先工作台，再旧面板，都没有就 no-op。多余参数原样转给两边（弹窗类要带 ask/rows）。
function Adapter:_or(name, wbFn, ...)
  local args = { ... }
  if wbFn then
    local res = self:_run(name, wbFn, unpackFn(args))
    if res ~= nil then return res end
    -- 工作台这条路失败/没返回值：继续试旧面板，别把功能丢了
  end
  if self.fallback and type(self.fallback[name]) == "function" then
    local fb = self.fallback
    local res = self:_run(name, function() return fb[name](fb, unpackFn(args)) end)
    if res ~= nil then return res end
  end
  return self:_noop(name)
end

function Adapter:_consoleView()
  local wb = self.wb
  if not (wb and wb.views) then return nil end
  return wb.views.console
end

function Adapter:_invalidate(region)
  self:_run("invalidate", function()
    if self.wb then self.wb:invalidate(region) end
  end)
end

----------------------------------------------------------------------
-- 消息 / 状态
----------------------------------------------------------------------

function Adapter:log(text, kind, meta)
  return self:_run("log", function() return self.wb:log(text, kind, meta) end)
end

function Adapter:setStatus(text, kind, docName)
  return self:_run("setStatus", function()
    if docName ~= nil and docName ~= "" then
      self.wb:setDoc{ name = tostring(docName),
                      w = (self.wb.state.doc or {}).w or 0,
                      h = (self.wb.state.doc or {}).h or 0,
                      layers = (self.wb.state.doc or {}).layers or 0,
                      frame = (self.wb.state.doc or {}).frame or 0,
                      frames = (self.wb.state.doc or {}).frames or 0 }
    end
    return self.wb:setStatus(tostring(text or ""), kind)
  end)
end

function Adapter:setHint(text)
  return self:_run("setHint", function()
    self.wb.state.hint = tostring(text or "")
    local cv = self:_consoleView()
    if cv then cv.hint = self.wb.state.hint end
    self:_invalidate("composer")
    return true
  end)
end

function Adapter:setContext(used, budget)
  return self:_run("setContext", function()
    self.wb.state.context = { used = tonumber(used) or 0, budget = tonumber(budget) or 0 }
    self:_invalidate("context")
    return true
  end)
end

-- 思考强度是"档位"，不是"正在思考"：busy 由 turn.start/turn.end 驱动，
-- 所以这里只记档位供 titlebar/设置页显示，不去动 busy（否则转圈会跟真状态错位）。
function Adapter:setThinking(value)
  return self:_run("setThinking", function()
    self.wb.state.thinking = tostring(value or "")
    self:_invalidate("titlebar")
    return self.wb.state.thinking
  end)
end

function Adapter:setBarColor(text)
  return self:_run("setBarColor", function()
    self.wb.state.barColor = tostring(text or "")
    self:_invalidate("titlebar")
    return true
  end)
end

function Adapter:clear()
  return self:_run("clear", function()
    local cv = self:_consoleView()
    if cv and type(cv.clear) == "function" then cv:clear() end
    self:_invalidate("main")
    return true
  end)
end

----------------------------------------------------------------------
-- 形态
----------------------------------------------------------------------

function Adapter:setMode(mode, quiet)
  return self:_or("setMode", function() return self.wb:setMode(mode) end)
end

function Adapter:layoutMode()
  local mode = self:_run("layoutMode", function() return self.wb:layoutMode() end)
  if mode ~= nil then return mode end
  if self.fallback and type(self.fallback.layoutMode) == "function" then
    local fb = self:_run("layoutMode", function() return self.fallback:layoutMode() end)
    if fb ~= nil then return fb end
  end
  return "panel"
end

function Adapter:cycleMode()
  return self:_or("cycleMode", function() return self.wb:cycleMode() end)
end

function Adapter:show()
  return self:_or("show", function() return self.wb:show() end)
end

function Adapter:isShown()
  return self:_run("isShown", function() return self.wb:isShown() end) == true
end

function Adapter:hide()
  return self:_or("hide", function() return self.wb:hide() end)
end

----------------------------------------------------------------------
-- 命令表 / 会话表 / 回放
----------------------------------------------------------------------

-- 旧的"打印出来的命令表"升级成 Ctrl+K 的模糊面板
function Adapter:openMenu()
  return self:_or("openMenu", function() return self.wb:openPalette() end)
end

-- 会话表这类"可选的行表"仍按旧行为打印进滚回区：老用户的操作直觉没变
function Adapter:openTable(rows, title, kind)
  return self:_or("openTable", function()
    local cv = self:_consoleView()
    if not (cv and type(cv.printTable) == "function") then return nil end
    cv:printTable(rows or {}, title)
    self:_invalidate("main")
    return true
  end)
end

-- 回放是"替换"不是"追加"（README：桥是唯一真相来源）
function Adapter:replayLines(lines, more, title)
  return self:_or("replayLines", function()
    local cv = self:_consoleView()
    if not cv then return nil end
    if type(cv.clear) == "function" then cv:clear() end
    if title ~= nil and title ~= "" then cv:log(tostring(title), "info") end
    for _, line in ipairs(lines or {}) do
      if type(line) == "table" then
        cv:log(line.text or "", line.kind or "ai", line)
      else
        cv:log(tostring(line), "ai")
      end
    end
    if more ~= nil and tostring(more) ~= "" then
      cv:log(tostring(more), "info")
    end
    self:_invalidate("main")
    return true
  end)
end

----------------------------------------------------------------------
-- 提问 / 待确认 / 待应用（都先落到 state，由 console 视图渲染卡片）
----------------------------------------------------------------------

function Adapter:setAsk(ask, silent)
  return self:_run("setAsk", function()
    self.wb.state.ask = ask
    if ask and not silent then
      self.wb:log(tostring(ask.question or ""), "ai")
      local opts = ask.options or {}
      for i, opt in ipairs(opts) do
        self.wb:log(string.format("%d. %s", i, tostring(opt)), "menu")
      end
      self.wb:log(tostring(ask.hint or ""), "info")
    end
    self:_invalidate("main")
    return true
  end)
end

function Adapter:setPendingInput(action, hint, accept)
  return self:_run("setPendingInput", function()
    self.wb.state.pendingInput = { action = action, hint = hint, accept = accept }
    if hint ~= nil then self:setHint(hint) end
    self:_invalidate("composer")
    return true
  end)
end

function Adapter:setPendingApply(on)
  return self:_run("setPendingApply", function()
    self.wb.state.pendingApply = on and true or false
    self:_invalidate("main")
    return true
  end)
end

----------------------------------------------------------------------
-- 只能交给旧面板的（原生弹窗、小面板、矫正队列）
-- 工作台没有这些的原生控件；退回旧面板实现，行为一字不变。
----------------------------------------------------------------------

function Adapter:showMini()
  return self:_or("showMini", nil)
end

function Adapter:hideMini()
  return self:_or("hideMini", nil)
end

function Adapter:_showAskDialog(ask)
  return self:_or("_showAskDialog", nil, ask)
end

function Adapter:_closeAskDialog()
  return self:_or("_closeAskDialog", nil)
end

function Adapter:_showFixDialog()
  return self:_or("_showFixDialog", nil)
end

function Adapter:addFixFile(path)
  return self:_or("addFixFile", nil, path)
end

function Adapter:fixQueueSize()
  local n = self:_or("fixQueueSize", nil)
  return tonumber(n) or 0
end

function Adapter:showDeliverDialog(labels, onPick)
  return self:_or("showDeliverDialog", nil, labels, onPick)
end

----------------------------------------------------------------------

function Adapter:destroy()
  self:_run("destroy", function()
    if self.wb then self.wb:destroy() end
  end)
  if self.fallback and type(self.fallback.destroy) == "function" then
    self:_run("destroyFb", function() return self.fallback:destroy() end)
  end
  return true
end

-- 诊断用：哪些能力被降级成了 no-op
function Adapter:report()
  return { calls = self.calls, errors = self.errors, unsupported = self.unsupported }
end

return adapter
