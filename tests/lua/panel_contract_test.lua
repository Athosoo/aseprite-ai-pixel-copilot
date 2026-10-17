-- tests/lua/panel_contract_test.lua -- 适配层契约：agent 用到的每个 panel 方法都必须存在且可调
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/panel_contract_test.lua
--
-- 为什么要有它：真机上"面板点不动"过一次，根因是工作台从来没接上 agent ——
-- agent 的 25+ 个 self.panel:X 调用，工作台只实现了 6 个，直接换过去会一堆
-- attempt to call a nil value。所以这条测试**从 agent.lua 源码里静态提取**方法名，
-- 不靠人肉清单：以后 agent 多加一个 self.panel:foo，这里立刻变红。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local i18n = require("lib.i18n")
i18n._resetLang()
i18n.resolve("en", "en")

local adapter = require("lib.panel_adapter")
local workbench = require("lib.workbench")

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end
local function eq(a, b, name)
  ok(a == b, name, string.format("got %s want %s", tostring(a), tostring(b)))
end

----------------------------------------------------------------------
-- 1. 从 agent.lua 源码静态提取 self.panel:X / self.panel.X
----------------------------------------------------------------------

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local agentSrc = readFile(EXT .. "/lib/agent.lua")
ok(agentSrc ~= nil, "读到 agent.lua 源码")

local methods, fields = {}, {}
local order = {}
for name in (agentSrc or ""):gmatch("self%.panel:([A-Za-z_][A-Za-z0-9_]*)") do
  if not methods[name] then methods[name] = true; order[#order + 1] = name end
end
for name in (agentSrc or ""):gmatch("self%.panel%.([A-Za-z_][A-Za-z0-9_]*)") do
  if not fields[name] then fields[name] = true end
end

print("== 1. 静态提取 agent 对面板的依赖 ==")
ok(#order >= 20, "从 agent.lua 提取到足量方法调用", #order)
print("       提取到 " .. #order .. " 个方法：" .. table.concat(order, ", "))
local fieldNames = {}
for name in pairs(fields) do fieldNames[#fieldNames + 1] = name end
table.sort(fieldNames)
print("       提取到 " .. #fieldNames .. " 个字段：" .. table.concat(fieldNames, ", "))

----------------------------------------------------------------------
-- 2. 适配器必须实现全部方法（缺一个就红）
----------------------------------------------------------------------

local wb = workbench.new({ width = 900, height = 620 })
local a = adapter.new(wb, {})

print("== 2. 每个方法都存在且是函数 ==")
local missing = {}
for _, name in ipairs(order) do
  if type(a[name]) ~= "function" then missing[#missing + 1] = name end
end
ok(#missing == 0, "适配器实现了 agent 用到的全部方法（缺：" .. (#missing == 0 and "无" or table.concat(missing, ", ")) .. "）")
for _, name in ipairs(order) do
  eq(type(a[name]), "function", "有方法 " .. name)
end

print("== 3. 字段依赖也存在 ==")
for _, name in ipairs(fieldNames) do
  ok(a[name] ~= nil, "有字段 " .. name)
end
ok(type(a.opts) == "table", "opts 是可写表（agent 会往这里挂 menuCommands）")
a.opts.menuCommands = function() return {} end
ok(type(a.opts.menuCommands) == "function", "opts.menuCommands 能写进去")

----------------------------------------------------------------------
-- 3. 全部方法调一遍，一个都不许抛错
----------------------------------------------------------------------

print("== 4. 用假 agent 逐个调用（一个都不许抛错）==")
local args = {
  log = { "hello", "info", {} },
  setStatus = { "connected", "ok", "001.ase" },
  setHint = { "hint text" },
  setContext = { 1234, 8000 },
  setThinking = { "medium" },
  setBarColor = { "#2b2b2b" },
  setMode = { "bar_bottom", true },
  layoutMode = {},
  cycleMode = {},
  show = {},
  isShown = {},
  hide = {},
  openMenu = {},
  openTable = { { { id = "c1", keys = "1", label = "chat one" } }, "CONVERSATIONS", "conv" },
  replayLines = { { { text = "line a", kind = "ai" }, { text = "line b", kind = "user" } }, "more", "title" },
  clear = {},
  setAsk = { { question = "pick one", options = { "a", "b" }, hint = "h" }, true },
  setPendingInput = { "deliver", "type yes", function() end },
  setPendingApply = { true },
  showMini = {},
  hideMini = {},
  _showAskDialog = { { question = "q", options = { "x" } } },
  _closeAskDialog = {},
  _showFixDialog = {},
  addFixFile = { "/tmp/a.png" },
  fixQueueSize = {},
  showDeliverDialog = { { "overwrite", "keep" }, function() end },
  destroy = {},
}
local unpackFn = table.unpack or unpack
local threw = {}
for _, name in ipairs(order) do
  local okc, err = pcall(function() return a[name](a, unpackFn(args[name] or {})) end)
  if not okc then threw[#threw + 1] = name .. ": " .. tostring(err) end
end
ok(#threw == 0, "全部方法调用不抛错", threw[1])
local rep = a:report()
ok(next(rep.errors) == nil, "内部错误表为空（说明没有映射炸掉）", rep.errors and rep.errors.log)

print("== 5. 真工作台后端：消息真的落到工作台的会话视图里 ==")
do
  local wbv = workbench.new({ width = 900, height = 620 })
  wbv:mount(nil, { docName = function() return "001.ase" end })
  local av = adapter.new(wbv, {})
  av:log("hello from agent", "user")
  local cv = wbv.views and wbv.views.console
  ok(cv ~= nil, "工作台里有 console 视图实例")
  eq(cv and cv:count() or -1, 1, "agent 的 log 真的进了 console 视图（这就是「点不动」的根因接线）")
  av:setStatus("connected", "ok", "001.ase")
  eq(wbv.state.status, "connected", "setStatus 落到工作台 state")
  eq((wbv.state.doc or {}).name, "001.ase", "setStatus 的 docName 落到 state.doc")
  av:openTable({ { id = "c1", keys = "1", label = "one" } }, "CONV")
  ok(cv:count() > 1, "openTable 把表打进了会话视图")
  av:clear()
  eq(cv:count(), 0, "clear 清空会话视图")
  av:replayLines({ { text = "r1", kind = "ai" } }, nil, "REPLAY")
  ok(cv:count() >= 1, "replayLines 回放进会话视图")
  av:setAsk({ question = "A or B?", options = { "A", "B" } }, true)
  ok(wbv.state.ask ~= nil and wbv.state.ask.question == "A or B?", "提问落到 state.ask 供卡片渲染")
  av:setPendingApply(true)
  eq(wbv.state.pendingApply, true, "待应用标记落到 state")
  av:setContext(100, 4000)
  ok(wbv.state.context and wbv.state.context.used == 100, "上下文用量落到 state")
end

print("== 6. 没有工作台、没有旧面板时也只降级不抛错 ==")
do
  local bare = adapter.new(nil, {})
  local bad = {}
  for _, name in ipairs(order) do
    local okc, err = pcall(function() return bare[name](bare, unpackFn(args[name] or {})) end)
    if not okc then bad[#bad + 1] = name .. ": " .. tostring(err) end
  end
  ok(#bad == 0, "双后端都缺时仍然不抛错", bad[1])
  ok(#bare.unsupported > 0, "降级成 no-op 的能力被记进 unsupported[]", table.concat(bare.unsupported, ","))
  ok(not bare:isShown(), "isShown 安全返回 false")
  eq(bare:fixQueueSize(), 0, "fixQueueSize 安全返回 0")
  eq(bare:layoutMode(), "panel", "layoutMode 安全返回 panel")
end

print("== 7. 回落旧面板：弹窗类仍然交给旧实现 ==")
do
  local called = {}
  local fakePanel = {}
  -- 用适配器的完整方法表（不是 agent 的 25 个）：showMini 这类是 main.lua 在用的
  for _, name in ipairs(adapter.METHODS) do
    fakePanel[name] = function() called[name] = true; return true end
  end
  local fa = adapter.new(nil, { fallback = fakePanel })
  fa:_showAskDialog({ question = "q" })
  ok(called._showAskDialog == true, "没有工作台时 _showAskDialog 回落到旧面板")
  fa:showMini()
  ok(called.showMini == true, "showMini 回落到旧面板")
  eq(#fa.unsupported, 0, "回落成功时不记 unsupported")
end

print("== 8. main.lua 的构造形状也认（swapAgentPanel 传的是 opts 表）==")
do
  local oldPanel = { layoutMode = function() return "panel" end }
  local wb2 = workbench.new({ width = 900, height = 620 })
  local av = adapter.new{ workbench = wb2, panel = oldPanel, agent = { panel = oldPanel } }
  ok(av.wb == wb2, "opts.workbench 被认成了工作台")
  ok(av.fallback == oldPanel, "opts.panel 被认成了回落后端")
  ok(av:isShown() == false, "这种形状下方法也照常工作（isShown 安全）")
  local okc, err = pcall(function() av:log("x", "info") end)
  ok(okc and av:report().errors.log == nil, "这种形状下 log 不抛错", err)
end

print("== 9. attach 把 agent.panel 换掉（main.lua 那一行的等价物）==")
do
  local fakeAgent = { panel = { layoutMode = function() return "panel" end } }
  local old = fakeAgent.panel
  local av = adapter.attach(fakeAgent, wb)
  ok(av ~= nil, "attach 返回适配器")
  ok(fakeAgent.panel == av, "agent.panel 被换成适配器")
  ok(av.fallback == old, "旧面板留作回落后端")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
