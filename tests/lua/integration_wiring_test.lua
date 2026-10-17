-- tests/lua/integration_wiring_test.lua -- 走 main.lua 的真实接线（init -> loadKernel -> mountPacks -> workbench）
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/integration_wiring_test.lua
--
-- 为什么必须有这条：模块级测试（kit_test / workbench_click_test）和 GUI 探针都自己传 kernel
-- 或干脆不传，从来没走过 main.lua 这条真链路。结果真机上 core 包的 view.mount 返回了占位视图，
-- 会话区显示「这个视图挂载失败：mount failed」——而所有单测都是绿的。
--
-- 这里**不复制** main.lua 的接线，而是 dofile 它、用假 plugin 调真正的 init()，
-- 再触发真正的命令回调（plugin:newCommand 注册的那些）。唯一的测试缝是把
-- lib.workbench.new / lib.agent.new 包一层，好拿到实例引用。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local i18n = require("lib.i18n")
i18n._resetLang()
i18n.resolve("en", "en")

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

local function fakeGC(w, h)
  local g = { width = w or 900, height = h or 620, texts = {} }
  g.measureText = function(_, s)
    s = tostring(s or "")
    return { width = (utf8.len(s) or #s) * 6, height = 12 }
  end
  g.fillRect = function() end
  g.fillText = function(_, s) g.texts[#g.texts + 1] = tostring(s) end
  g.drawImage = function() end
  return g
end

----------------------------------------------------------------------
-- 1. 加载 main.lua 并跑真正的 init()
----------------------------------------------------------------------

print("== 1. dofile main.lua + 假 plugin 跑 init() ==")
local mainChunk = loadfile(EXT .. "/main.lua")
ok(mainChunk ~= nil, "main.lua 能加载")
-- Aseprite 扩展的入口形状是"定义全局 init/exit"，不是返回一个表
local mainMod = nil
if mainChunk then
  local okRun, errRun = pcall(mainChunk)
  ok(okRun, "main.lua 顶层执行通过", errRun)
  mainMod = { init = _G.init, exit = _G.exit }
end
ok(type(mainMod) == "table" and type(mainMod.init) == "function", "拿到了真正的 init()（全局函数）")

-- 测试缝：包一层 new，拿到 main.lua 自己创建的那两个实例
local workbenchMod = require("lib.workbench")
local capturedWB, capturedOpts = nil, nil
local origNewWB = workbenchMod.new
workbenchMod.new = function(opts)
  local wb = origNewWB(opts)
  capturedWB, capturedOpts = wb, opts
  return wb
end

local commands = {}
local fakePlugin = {
  path = EXT,
  version = "0.6.0",
  newCommand = function(_, spec) commands[spec.id] = spec end,
  newMenu = function() end,
  newPref = function() end,
}
-- openPanel 里可能会"自动拉起本地桥"（os.execute 起 node）。测试里不真起进程。
local realExecute = os.execute
os.execute = function() return 0 end

local okInit, initErr = pcall(mainMod.init, fakePlugin)
os.execute = realExecute
ok(okInit, "init() 跑通", initErr)
ok(#commands > 0 or commands.ai_pixel_copilot_open ~= nil, "init() 注册了命令（拿得到真实回调）")

print("== 2. 触发真正的「打开面板」命令（走 openPanel -> openWorkbench）==")
local openCmd = commands.ai_pixel_copilot_open
ok(openCmd ~= nil and type(openCmd.onclick) == "function", "拿到 open 命令的 onclick")

-- 关键：真机上 require 只在 init() 作用域内可用（STATUS 约束 7）。视图是在"打开面板"
-- 时才挂载的，那时 require 已经没了。所以这里**必须**把 require 摘掉再开面板，
-- 否则测的是一个真机上不存在的世界 —— 上一轮的 mount failed 就是这么漏过去的。
local realRequire = require
require = nil
os.execute = function() return 0 end
local okOpen, openErr = pcall(openCmd.onclick)
os.execute = realExecute
-- 工作台是在"打开命令"里才创建的，所以包装要等这一下跑完再还原
workbenchMod.new = origNewWB
require = realRequire
ok(okOpen, "open 命令回调跑通", openErr)
ok(capturedWB ~= nil, "main.lua 真的创建了工作台")
ok(capturedOpts ~= nil and capturedOpts.kernel ~= nil, "工作台拿到的 kernel 非空（真链路）")

local wb = capturedWB
if not wb then
  print("FAIL 无法继续：没有工作台实例")
  print(string.format("%d passed, %d failed", pass, fail))
  return
end
wb:setSize(900, 620)
local gc = fakeGC(900, 620)
wb:paint(gc)

----------------------------------------------------------------------
-- 3. 真链路下的视图：必须是真身，不能是 placeholder / broken
----------------------------------------------------------------------

print("== 3. 真链路下每个视图都有 render，且不是 placeholder ==")
local specCount = #(wb.specs or {})
ok(specCount >= 7, "registry 里注册了 7 个视图（core 包）", specCount)

local brokenList, placeholderList, noRender = {}, {}, {}
for _, spec in ipairs(wb.specs or {}) do
  wb:setView(spec.id)
  local v = wb:currentView()
  if v == nil or v.broken then
    brokenList[#brokenList + 1] = spec.id .. "(" .. tostring(v and v.error) .. ")"
  elseif v.placeholder then
    placeholderList[#placeholderList + 1] = spec.id
  elseif type(v.render) ~= "function" then
    noRender[#noRender + 1] = spec.id
  end
end
ok(#brokenList == 0, "没有 broken 视图", table.concat(brokenList, ", "))
ok(#placeholderList == 0, "没有 core 包的占位视图（placeholder）", table.concat(placeholderList, ", "))
ok(#noRender == 0, "每个视图都有 render()", table.concat(noRender, ", "))
ok(wb.viewErrors == nil or next(wb.viewErrors) == nil, "wb.viewErrors 为空",
   wb.viewErrors and next(wb.viewErrors))
ok(wb.lastViewError == nil, "渲染没有异常", wb.lastViewError)

print("== 4. 真链路下点击 rail 能切视图 ==")
do
  wb:setView("console")
  wb:paint(fakeGC(900, 620))
  local h = wb:handlers()
  local LEFT = (type(MouseButton) == "table" and MouseButton.LEFT) or 1
  local target = nil
  for _, hit in ipairs(wb.railHits or {}) do
    if hit.kind == "view" and hit.id == "packs" then target = hit end
  end
  ok(target ~= nil, "rail 有 packs 的命中框")
  if target then
    local x = target.rect.x + math.floor(target.rect.w / 2)
    local y = target.rect.y + math.floor(target.rect.h / 2)
    h.onmousedown({ x = x, y = y, button = LEFT })
    h.onmouseup({ x = x, y = y, button = LEFT })
    eq(wb.viewId, "packs", "点 rail 切到 packs")
    ok(wb.lastInputError == nil, "点击没有异常", wb.lastInputError)
    wb:paint(fakeGC(900, 620))
    ok(wb.view ~= nil and not wb.view.broken and not wb.view.placeholder, "切过去也是真视图")
  end
end

print("== 4b. 真链路下 titlebar 的 ◫ 能折叠上下文（与 mount 无关的那类点击）==")
do
  wb:setView("console")
  wb:paint(fakeGC(900, 620))
  local h = wb:handlers()
  local LEFT = (type(MouseButton) == "table" and MouseButton.LEFT) or 1
  local ctxHit = nil
  for _, hit in ipairs(wb.titleHits or {}) do
    if hit.id == "ctx" then ctxHit = hit end
  end
  ok(ctxHit ~= nil, "titlebar 有 ctx 命中框")
  if ctxHit then
    local x = ctxHit.rect.x + math.floor(ctxHit.rect.w / 2)
    local y = ctxHit.rect.y + math.floor(ctxHit.rect.h / 2)
    local before = wb:layout().collapsed
    h.onmousedown({ x = x, y = y, button = LEFT })
    h.onmouseup({ x = x, y = y, button = LEFT })
    eq(wb:layout().collapsed, not before, "点 ◫ 真的切换了上下文折叠")
    ok(wb.lastInputError == nil, "titlebar 点击没有异常", wb.lastInputError)
  end
end

print("== 5. 真链路下键盘能进视图 ==")
do
  wb:setView("console")
  wb:paint(fakeGC(900, 620))
  local h = wb:handlers()
  wb.state.focus = "main"
  ok(wb:key({ code = "/" }), "按 / 被壳接住")
  eq(wb.state.focus, "composer", "按 / 把焦点给 composer")
  ok(wb.completionOpen, "按 / 打开补全")
  h.onkeydown({ key = { code = "Escape" } })
  ok(wb.lastInputError == nil, "键盘回调没有异常", wb.lastInputError)

  -- 视图内导航：画布页有 nav（算子列表），↓ 必须真的落到视图里
  wb:setView("canvas")
  wb:paint(fakeGC(900, 620))
  local cv = wb:currentView()
  ok(cv ~= nil and type(cv.nav) == "function", "画布视图有 nav（键盘可达）")
  if cv and type(cv.nav) == "function" then
    local before = cv.sel
    wb:key({ code = "ArrowDown" })
    ok(cv.sel ~= before, "ArrowDown 真的改到了视图内部状态", tostring(cv.sel))
  end
end

print("== 5b. 真机约束：init() 之后 require 就没了（STATUS 约束 7）==")
ok(true, "本测试在挂载阶段摘掉了全局 require，模拟真机（见下方 require = nil）")

print("== 6. 真链路下 agent 的日志进得了会话视图（panel_adapter 已接上）==")
do
  -- main.lua 的 swapAgentPanel 会把 agent.panel 换成适配器；这里从命令回调拿不到 agent，
  -- 就直接验工作台自己的 log 通到 console 视图（适配层另有 panel_contract_test 专测）
  local cv = wb.views and wb.views.console
  ok(cv ~= nil, "工作台里有 console 视图实例")
  local before = cv and cv:count() or -1
  wb:log("wiring test line", "user")
  eq(cv:count(), before + 1, "工作台 log 通到 console 视图")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
