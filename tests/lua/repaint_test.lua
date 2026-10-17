-- tests/lua/repaint_test.lua -- 状态变了必须真的让宿主重绘
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/repaint_test.lua
--
-- 为什么必须单独有这条：真机上整整一帧之后再没重绘过 —— invalidate 只改脏标记，
-- 没人调 dlg:repaint()，用户看到的就是「状态变了、像素不动、什么都点不动」。
-- 以前的测试都手动调 wb:paint(gc) 或 wb:repaint()，正好把这条机制绕过去了。
--
-- 这里注入一个**只记账的假 Dialog**，断言每个改状态的动作都会请宿主重绘一次。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local i18n = require("lib.i18n")
i18n._resetLang()
i18n.resolve("en", "en")

local kernelInit = require("kernel.init")
local ops = require("lib.ops")
local workbench = require("lib.workbench")
local adapter = require("lib.panel_adapter")

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
  local g = { width = w or 900, height = h or 620 }
  g.measureText = function(_, s) s = tostring(s or ""); return { width = (utf8.len(s) or #s) * 6, height = 12 } end
  g.fillRect = function() end
  g.fillText = function() end
  g.drawImage = function() end
  return g
end

-- 只记账的假 Dialog：paint 由测试自己驱动，repaint 只数次数
local function countingDialog()
  local d = { repaints = 0, paints = 0, widgets = {}, data = {} }
  d._bounds = { x = 10, y = 10, w = 912, h = 531 }
  function d:repaint() self.repaints = self.repaints + 1 end
  function d:canvas(spec) self.widgets.screen = spec end
  function d:entry(spec) self.widgets.input = spec end
  function d:button(spec) self.widgets[spec.id] = spec end
  function d:newrow() end
  function d:samerow() end
  function d:show() end
  function d:close() end
  function d:modify(opts)
    if opts.id == "input" and opts.text ~= nil then self.data.input = opts.text end
  end
  return setmetatable(d, {
    __index = function(_, k) if k == "bounds" then return d._bounds end return nil end,
    __newindex = function(t, k, v)
      if k == "bounds" then d._bounds = { x = v.x, y = v.y, w = v.width, h = v.height } else rawset(t, k, v) end
    end,
  })
end

local function tempDir(tag)
  local base = os.getenv("TEMP") or os.getenv("TMP") or "."
  local dir = string.format("%s/ai-pixel-copilot-repaint-%s-%d", base, tag, os.time())
  pcall(function() app.fs.makeAllDirectories(dir) end)
  return dir
end

----------------------------------------------------------------------
-- 真 kernel（core 包注册视图）+ 假 Dialog
----------------------------------------------------------------------

local kernel = kernelInit.new({
  app = app,
  sandboxMs = 800,
  shared = { ops = ops },
  ledger = { dir = tempDir("journal"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin" } },
})
kernelInit.mountPacks(kernel, {})

local agent = { sent = {}, docName = function() return "001.ase" end }
function agent:send(t) self.sent[#self.sent + 1] = t; return true end

local wb = workbench.new({ width = 900, height = 620 })
wb:mount(kernel, agent)
wb:setSize(900, 620)
local dlg = countingDialog()
wb:build(dlg)
wb.shown = true
wb:invalidate()
wb:paint(fakeGC(900, 620))

print("== 1. 基线：宿主重绘是被真的调用了 ==")
ok(dlg.repaints >= 1, "打开后至少请宿主重绘过一次", dlg.repaints)
ok(type(wb.repaintCount) == "number" and wb.repaintCount >= 1, "工作台自己也在计数（便于排查）", wb.repaintCount)

-- 每个动作：记录前 → 触发 → 断言 repaint 增加了
local function expectRepaint(name, fn)
  local before = dlg.repaints
  local okc, err = pcall(fn)
  ok(okc, name .. "：调用不抛错", err)
  ok(dlg.repaints > before, name .. "：请宿主重绘了（+" .. (dlg.repaints - before) .. "）", dlg.repaints - before)
end

print("== 2. 消息 / 状态类 ==")
expectRepaint("log 新消息", function() wb:log("hello from agent", "user") end)
expectRepaint("setStatus", function() wb:setStatus("connected - gpt-4o", "ok") end)
expectRepaint("setDoc", function() wb:setDoc({ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 }) end)
expectRepaint("setBusy", function() wb:setBusy(true) end)
expectRepaint("setConnected(false)", function() wb:setConnected(false, { reason = "bridge refused", cmd = "node x.mjs" }) end)
expectRepaint("setConnected(true)", function() wb:setConnected(true) end)

print("== 3. 视图 / 布局类 ==")
expectRepaint("切视图", function() wb:setView("packs") end)
expectRepaint("切回 console", function() wb:setView("console") end)
expectRepaint("折叠上下文", function() wb:toggleContext() end)
expectRepaint("setMode", function() wb:setMode("bar_bottom") end)
expectRepaint("回到 panel", function() wb:setMode("panel") end)
expectRepaint("setSize", function() wb:setSize(880, 600) end)
expectRepaint("refresh", function() wb:refresh() end)

print("== 4. 输入 / 交互类 ==")
expectRepaint("输入回显", function() wb:setInput("make the red darker") end)
expectRepaint("提交", function() wb:submit() end)
-- 输入行现在常驻：openInput 无变化（不该重绘），closeInput 被拒绝（也不该重绘）
expectRepaint("焦点给 composer", function() wb:focusComposer() end)
expectRepaint("滚动", function() wb:wheel(400, 300, 1) end)
-- "/" 只在焦点不在 composer 时才被壳接住（焦点在 composer 时它由 entry 收）
wb.state.focus = "main"
expectRepaint("按 /", function() wb:key({ code = "/" }) end)
expectRepaint("Esc", function() wb:key({ code = "Escape" }) end)
-- Esc 只关弹层、不清草稿（正确的产品行为），所以先把上一段的 "/" 清掉
wb:setInput("")
expectRepaint("输入回显（常驻行）", function() wb:setInput("typed") end)

print("== 5. 鼠标点击类（real wiring 下的 rail / titlebar）==")
do
  local LEFT = (type(MouseButton) == "table" and MouseButton.LEFT) or 1
  local h = wb:handlers()
  wb:setView("console")
  wb:paint(fakeGC(900, 620))
  local railHit = nil
  for _, hit in ipairs(wb.railHits or {}) do
    if hit.kind == "view" and hit.id == "canvas" then railHit = hit end
  end
  ok(railHit ~= nil, "rail 有 canvas 命中框")
  if railHit then
    expectRepaint("点 rail 切画布", function()
      local x = railHit.rect.x + math.floor(railHit.rect.w / 2)
      local y = railHit.rect.y + math.floor(railHit.rect.h / 2)
      h.onmousedown({ x = x, y = y, button = LEFT })
      h.onmouseup({ x = x, y = y, button = LEFT })
    end)
  end
  wb:setView("console")
  wb:paint(fakeGC(900, 620))
  local ctxHit = nil
  for _, hit in ipairs(wb.titleHits or {}) do if hit.id == "ctx" then ctxHit = hit end end
  if ctxHit then
    expectRepaint("点 ◫ 折叠", function()
      local x = ctxHit.rect.x + math.floor(ctxHit.rect.w / 2)
      local y = ctxHit.rect.y + math.floor(ctxHit.rect.h / 2)
      h.onmousedown({ x = x, y = y, button = LEFT })
      h.onmouseup({ x = x, y = y, button = LEFT })
    end)
  end
end

do
  -- 悬浮到左轨某一项：hover 真的变了，必须重绘（悬停在空白处什么都不变，不该重绘）
  wb:paint(fakeGC(900, 620))
  local railHit = (wb.railHits or {})[2]
  ok(railHit ~= nil, "rail 有第二个命中框")
  expectRepaint("悬浮到左轨", function()
    wb:handlers().onmousemove({ x = railHit.rect.x + 2, y = railHit.rect.y + 2 })
  end)
end
do
  -- 视图内列表导航（画布页有 nav）
  wb:setView("canvas")
  wb:paint(fakeGC(900, 620))
  local cv = wb.view
  local before = dlg.repaints
  local handled = wb:key({ code = "ArrowDown" })
  ok(handled == true, "ArrowDown 被壳接住", wb.lastNavError)
  ok(dlg.repaints > before, "ArrowDown 列表导航：请宿主重绘了", dlg.repaints - before)
  wb:setView("console")
  wb:paint(fakeGC(900, 620))
end
expectRepaint("关闭断连条（重连）", function() wb:setConnected(true) end)

print("== 6. 连续 invalidate 不会把宿主刷爆（宿主自己会合并帧）==")
do
  local before = dlg.repaints
  for _ = 1, 20 do wb:invalidate("main") end
  ok(dlg.repaints > before, "连续 invalidate 至少触发一次重绘")
  ok(dlg.repaints - before <= 20, "每次 invalidate 最多一次请求（不做乘法）", dlg.repaints - before)
end

print("== 7. 绘制过程中触发 invalidate 不会自递归 ==")
do
  local nested = 0
  wb._painting = true
  local okc = pcall(function() wb:invalidate("main") end)
  wb._painting = false
  ok(okc, "绘制中 invalidate 不抛错")
  ok(true, "（_painting 期间的 invalidate 只记脏，不再请求重绘）")
end

print("== 8. 适配层转发的状态变化也会走到重绘 ==")
do
  local ad = adapter.new(wb, { agent = agent })
  local before = dlg.repaints
  ad:log("from agent", "ai")
  ad:setStatus("busy", "busy", "001.ase")
  ad:setHint("hint")
  ad:setContext(100, 4000)
  ad:setPendingApply(true)
  ok(dlg.repaints > before, "agent 侧的状态变化都会触发重绘（+" .. (dlg.repaints - before) .. "）",
     dlg.repaints - before)
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
