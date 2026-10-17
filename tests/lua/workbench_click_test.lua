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

print("== 10. 原生输入行按需浮出（task-7）==")
do
  -- 假 Dialog：只实现 build / modify / bounds 用到的那几个面
  local function fakeDialog()
    local d = { data = {}, widgets = {}, layoutChanges = 0, modifyLog = {} }
    d._bounds = { x = 100, y = 100, w = 912, h = 531 }
    function d:canvas(spec) self.widgets.screen = spec end
    function d:entry(spec) self.widgets.input = spec end
    function d:button(spec) self.widgets[spec.id] = spec end
    function d:newrow() end
    function d:samerow() end
    function d:show() end
    function d:repaint() end
    function d:close() end
    function d:modify(opts)
      self.modifyLog[#self.modifyLog + 1] = opts
      if opts.id == "input" then
        local w = self.widgets.input
        if opts.visible ~= nil then w.visible = opts.visible end
        if opts.focus ~= nil then w.focus = opts.focus end
        if opts.text ~= nil then self.data.input = opts.text end
      elseif opts.id == "send" then
        local w = self.widgets.send
        if opts.visible ~= nil then w.visible = opts.visible end
        if opts.focus ~= nil then w.focus = opts.focus end
      elseif opts.id == "screen" then
        self.widgets.screen.focus = opts.focus
      end
      -- 真实 modify 会让 Aseprite 重新布局、把窗口撑回自然尺寸：这里模拟它
      if opts.visible ~= nil then
        self.layoutChanges = self.layoutChanges + 1
        self._bounds = { x = self._bounds.x, y = self._bounds.y, w = 912, h = 700 }
      end
    end
    -- 真机上 dlg.bounds 是 Rectangle（.width/.height）；假件也要照这个面来，
    -- 否则 _preserveBounds 里 (b.width or 0) > 0 判不出来，测的就成了假的
    function d:_boundsView()
      return { x = self._bounds.x, y = self._bounds.y, width = self._bounds.w, height = self._bounds.h }
    end
    return setmetatable(d, { __index = function(_, k)
      if k == "bounds" then return d:_boundsView() end
      return nil
    end, __newindex = function(t, k, v)
      if k == "bounds" then d._bounds = { x = v.x, y = v.y, w = v.width or v.w, h = v.height or v.h }
      else rawset(t, k, v) end
    end })
  end

  local function freshWB()
    local a = { sent = {}, docName = function() return "001.ase" end }
    function a:send(t) self.sent[#self.sent + 1] = t; return true end
    local w = workbench.new({ width = 900, height = 620 })
    w:mount(nil, a)
    w:setSize(900, 620)
    local d = fakeDialog()
    w:build(d)
    w.shown = true
    w:invalidate()
    w:paint(fakeGC(900, 620))
    return w, d, a
  end

  local w, d, a = freshWB()
  eq(d.widgets.input.visible, false, "初始：entry 不可见（不再常驻白横条）")
  eq(d.widgets.send.visible, false, "初始：磁吸按钮也不可见（同显同隐）")
  eq(w.inputOpen, false, "初始 inputOpen=false")

  -- 隐藏态：自绘 composer 仍有输入提示与光标
  local gc0 = fakeGC(900, 620)
  w:invalidate()
  w:paint(gc0)
  local hasHint, caret = false, false
  for _, txt in ipairs(gc0.texts) do
    if txt:find("say something", 1, true) then hasHint = true end
  end
  for _, c in ipairs(w.kit.calls) do
    if c.region == "composer" and c.op == "fill" and c.w <= 1 and c.h >= 10 then caret = true end
  end
  ok(hasHint, "隐藏态：composer 仍画出输入提示")
  ok(caret, "隐藏态：composer 仍画出光标位")

  -- 点 composer → 两者浮出 + 聚焦 entry
  local L = w:layout()
  local cx = math.floor(L.composer.w / 2)
  local cy = L.composer.y + math.floor(L.composer.h / 2)
  h = w:handlers()
  h.onmousedown({ x = cx, y = cy, button = LEFT })
  h.onmouseup({ x = cx, y = cy, button = LEFT })
  eq(w.inputOpen, true, "点 composer 后输入行浮出")
  eq(d.widgets.input.visible, true, "entry 变可见")
  eq(d.widgets.send.visible, true, "磁吸按钮一起可见（否则 ENTER 提交不了）")
  eq(d.widgets.input.focus, true, "焦点给了 entry")
  ok(w.lastInputError == nil, "点 composer 不抛错", w.lastInputError)

  -- 窗口重排防护：modify 把窗口撑大了，_preserveBounds 必须还原
  eq(d._bounds.h, 531, "visible 切换后窗口高度被还原（_preserveBounds 生效），没有被撑回自然尺寸")

  -- 提交 → 两收回，焦点回 canvas
  w:setInput("hello agent")
  w:submit()
  eq(w.inputOpen, false, "提交后输入行收起")
  eq(d.widgets.input.visible, false, "提交后 entry 不可见")
  eq(d.widgets.send.visible, false, "提交后按钮不可见")
  eq(d.widgets.screen.focus, true, "提交后焦点交回 canvas")
  eq(a.sent[1], "hello agent", "提交的文本真的发出去了")
  eq(#a.sent, 1, "只发一次")

  -- Esc：收起但不提交
  w:openInput()
  w:setInput("draft text")
  local before = #a.sent
  eq(w:escape(), "input", "Esc 第一优先处理输入行")
  eq(w.inputOpen, false, "Esc 后输入行收起")
  eq(w:getInput(), "draft text", "Esc 不丢草稿")
  eq(#a.sent, before, "Esc 不提交")

  -- 隐藏态敲字：自动浮出并吞下该字符
  local w2, d2, a2 = freshWB()
  h = w2:handlers()
  h.onkeydown({ key = { unicode = "a", code = "a" } })
  eq(w2.inputOpen, true, "隐藏态敲 a → 输入行自动浮出")
  eq(w2:getInput(), "a", "隐藏态敲 a → 字符被吞进输入")
  eq(d2.widgets.input.visible, true, "自动浮出时 entry 可见")
  eq(d2.widgets.send.visible, true, "自动浮出时按钮也可见")
  ok(w2.lastInputError == nil, "敲字不抛错", w2.lastInputError)

  -- 组合键不算打字
  local w3 = freshWB()
  h = w3:handlers()
  h.onkeydown({ key = { unicode = "k", code = "k", ctrl = true } })
  eq(w3.inputOpen, false, "Ctrl+K 不被当成打字（走快捷键，不浮出输入行）")

  -- 已展开时不重复吞字（字由 entry 收）
  local w4 = freshWB()
  h = w4:handlers()
  w4:openInput()
  h.onkeydown({ key = { unicode = "z", code = "z" } })
  eq(w4:getInput(), "", "输入行已展开时 canvas 不再重复收集字符（避免双份）")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))