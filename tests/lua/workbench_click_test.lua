-- tests/lua/workbench_click_test.lua -- 工作台交互链路（真 kernel + core 包视图 + 事件回调）
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/workbench_click_test.lua
--
-- 为什么要有这条用例：真机上"点不动"过一次。当时的测试只盖了 wb:mouse 的一个分支，
-- 而且从未用「真 kernel + core 包注册的视图 + workbench 的 _bounded 包装」这条链路跑过点击。
-- 所以这里刻意走**面板真正注册的那组回调**（workbench.handlers），而不是绕过它直接调内部函数。
--
-- 语义按旧面板踩出来的规矩（lib/panel.lua 的 _onCanvasMouseDown/_onCanvasMouseUp）：
--   mousedown = 只管焦点，不激活；**激活在 mouseup**；坐标/按钮字段缺了要当左键算。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local i18n = require("lib.i18n")
i18n._resetLang()
i18n.resolve("en", "en")

local ops = require("lib.ops")
local kernelInit = require("kernel.init")
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
-- stub GraphicsContext（与 kit_test 同一套）
----------------------------------------------------------------------

local function fakeGC(w, h)
  local g = { width = w or 900, height = h or 620, rects = {}, texts = {} }
  g.measureText = function(_, s)
    s = tostring(s or "")
    local n = utf8.len(s) or #s
    return { width = n * 6, height = 12 }
  end
  g.fillRect = function() end
  g.fillText = function(_, s) g.texts[#g.texts + 1] = tostring(s) end
  g.drawImage = function() end
  return g
end

local function tempDir(tag)
  local base = os.getenv("TEMP") or os.getenv("TMP") or "."
  local dir = string.format("%s/ai-pixel-copilot-click-%s-%d", base, tag, os.time())
  pcall(function() app.fs.makeAllDirectories(dir) end)
  return dir
end

----------------------------------------------------------------------
-- 真 kernel：core 包注册视图，ops 包注册算子
----------------------------------------------------------------------

local kernel = kernelInit.new({
  app = app,
  sandboxMs = 800,
  shared = { ops = ops },
  ledger = { dir = tempDir("journal"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin" } },
})
local packs, packErrors = kernelInit.mountPacks(kernel, {})

print("== 1. 真链路：core 包把视图注册进 registry ==")
eq(#packErrors, 0, "builtin 包全部装载成功", packErrors[1] and packErrors[1].err)
local viewSpecs = kernel.registry:list("view")
ok(#viewSpecs >= 7, "core 包注册了 7 个视图规格", #viewSpecs)
ok(kernel.registry:get("view", "packs") ~= nil, "registry 里有 packs 视图规格")
ok(kernel.registry:get("view", "console") ~= nil, "registry 里有 console 视图规格")

local agent = { docName = function() return "001.ase" end }
local wb = workbench.new({ width = 900, height = 620 })
wb:mount(kernel, agent)
wb:setSize(900, 620)
local gc = fakeGC(900, 620)
wb:paint(gc)

print("== 2. 视图来自 registry 的真身（不是 placeholder）==")
ok(wb.viewErrors == nil or wb.viewErrors.console == nil, "console 视图没有挂载错误", wb.viewErrors and wb.viewErrors.console)
ok(wb.view ~= nil and wb.view.placeholder ~= true, "挂的是真视图实例，不是 core 包的占位")
eq(wb.viewId, "console", "默认视图是 console")

print("== 3. 面板注册的回调齐了吗（这就是真机点击的入口）==")
local h = wb:handlers()
for _, name in ipairs({ "onmousedown", "onmouseup", "onmousemove", "onwheel", "onkeydown" }) do
  eq(type(h[name]), "function", "canvas 注册了 " .. name)
end

----------------------------------------------------------------------
-- 事件驱动的小工具：一律走 handlers，跟 Dialog 完全一样的路径
----------------------------------------------------------------------

local LEFT = (type(MouseButton) == "table" and MouseButton.LEFT) or 1
local RIGHT = (type(MouseButton) == "table" and MouseButton.RIGHT) or 2

local function clickAt(x, y, button)
  local ev = { x = x, y = y, button = button or LEFT }
  h.onmousedown(ev)
  h.onmouseup(ev)
end

local function rectCenter(target)
  local r = (target and target.rect) or target
  return r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
end

local function railHitOf(id)
  for _, hit in ipairs(wb.railHits or {}) do
    if hit.kind == "view" and hit.id == id then return hit end
  end
  return nil
end

local function tbHitOf(id)
  for _, hit in ipairs(wb.titleHits or {}) do
    if hit.id == id then return hit end
  end
  return nil
end

print("== 4. 左轨点击真的切视图（激活在 mouseup）==")
do
  local hit = railHitOf("packs")
  ok(hit ~= nil, "左轨有 packs 的命中框")
  local x, y = rectCenter(hit)

  -- 只有 mousedown：不许激活。这正是"激活写在 down 上"那个 bug 的判据。
  h.onmousedown({ x = x, y = y, button = LEFT })
  eq(wb.viewId, "console", "只有 mousedown 不切换视图（激活必须在 up 上）")

  -- 再补 mouseup：这一下才该切
  h.onmouseup({ x = x, y = y, button = LEFT })
  eq(wb.viewId, "packs", "mousedown+mouseup 之后切到 packs")

  wb:paint(fakeGC(900, 620))
  ok(wb.view ~= nil and wb.view.placeholder ~= true, "切过去的也是真视图", wb.view and wb.view.placeholder)

  -- 右键不该切
  wb:setView("console")
  h.onmousedown({ x = x, y = y, button = RIGHT })
  h.onmouseup({ x = x, y = y, button = RIGHT })
  eq(wb.viewId, "console", "右键点击不切换视图")
end

print("== 5. 事件字段缺失/异常时不许炸（真机上会穿进 C++）==")
do
  local before = wb.viewId
  h.onmousedown({})
  h.onmouseup({})
  h.onmousemove({})
  h.onwheel({})
  ok(wb.lastInputError == nil, "空事件（无 button/x/y）不抛错", wb.lastInputError)
  eq(wb.viewId, before, "空事件不改变当前视图")

  h.onmousedown({ x = nil, y = nil, button = LEFT })
  h.onmouseup({ x = nil, y = nil, button = LEFT })
  ok(wb.lastInputError == nil, "坐标为 nil 不抛错", wb.lastInputError)

  h.onmousedown({ x = "0", y = "0", button = LEFT })
  h.onmouseup({ x = "0", y = "0", button = LEFT })
  ok(wb.lastInputError == nil, "坐标是字符串也不抛错", wb.lastInputError)
end

print("== 6. titlebar 的 ◫ 真的折叠上下文 ==")
do
  local hit = tbHitOf("ctx")
  ok(hit ~= nil, "titlebar 有 ctx 命中框")
  local x, y = rectCenter(hit)
  eq(wb:layout().collapsed, false, "点之前上下文是展开的")
  clickAt(x, y)
  eq(wb:layout().collapsed, true, "点 ◫ 之后上下文折叠")
  clickAt(x, y)
  eq(wb:layout().collapsed, false, "再点一次展开")
end

print("== 7. 断连态的「重试」真的回连 ==")
do
  wb:setConnected(false, { reason = "bridge refused", cmd = "node x.mjs" })
  wb:paint(fakeGC(900, 620))
  ok(wb.retryHit ~= nil, "断连时画出了重试按钮")
  local x, y = rectCenter(wb.retryHit)
  clickAt(x, y)
  eq(wb.state.connected, true, "点重试回到已连接")
end

print("== 8. 视图内按钮点得动（扩展页的启用/停用）==")
do
  wb:setView("packs")
  wb:paint(fakeGC(900, 620))
  local toggleHit = nil
  for _, hit in ipairs(wb.view.hits or {}) do
    if hit.kind == "toggle" then toggleHit = hit end
  end
  ok(toggleHit ~= nil, "扩展页画出了启用/停用按钮", #(wb.view.hits or {}))
  if toggleHit then
    local id = toggleHit.id
    local wasEnabled = kernel.ledger:isEnabled(id)
    local x, y = rectCenter(toggleHit)
    clickAt(x, y)
    eq(kernel.ledger:isEnabled(id), not wasEnabled, "点一下真的改了包的启用状态")
    ok(wb.lastInputError == nil, "视图内点击不抛错", wb.lastInputError)
  end
end

print("== 9. 视图内点击分发到视图自己的 click() ==")
do
  local seen = nil
  wb.view = { id = "probe", title = function() return "probe" end,
             actions = function() return {} end,
             render = function() end,
             hitAt = function(self, x, y) return { rect = { x = 0, y = 0, w = 50, h = 50 }, kind = "probe", index = 7 } end,
             click = function(self, hit) seen = hit and hit.index end }
  wb:invalidate("main")
  wb:paint(fakeGC(900, 620))
  h.onmousedown({ x = 10, y = 10, button = LEFT })
  h.onmouseup({ x = 10, y = 10, button = LEFT })
  eq(seen, 7, "命中视图内的框后调用了 view:click(hit)")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
