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

local agent = { docName = function() return "001.ase" end, connects = 0 }
function agent:connect(quiet) self.connects = self.connects + 1; return true end
function agent:sendChat(text) self.lastChat = text; return true end
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
  -- 重试必须真的重连：connect 被调用一次，状态等真实回调
  eq(wb.state.busy, true, "点重试后进入「正在重连」的 busy 态")
  eq((agent.connects or 0), 1, "调用了 agent:connect 一次")
  wb:setStatus("connected", "ok")
  wb:setBusy(false)
  eq(wb.state.connected, true, "真实回调把状态改回已连接")
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

print("== 10. 原生输入行常驻（用户要求：输入框固定保留）==")
do
  -- 假 Dialog：记 visible/focus/modify，并模拟 modify 触发的重排
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
      if opts.visible ~= nil then
        self.layoutChanges = self.layoutChanges + 1
        self._bounds = { x = self._bounds.x, y = self._bounds.y, w = 912, h = 700 }
      end
    end
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
    local a = { sent = {}, chats = {}, frames = {}, docName = function() return "001.ase" end }
    -- 关键：聊天必须走 sendChat（send 是协议帧，语义完全不同）
    function a:send(tbl)
      local t2 = type(tbl) == "table" and (tostring(tbl.type) .. "") or "SCALAR"
      self.frames[#self.frames + 1] = t2
      if t2 == "SCALAR" then self.sent[#self.sent + 1] = tostring(tbl) end
      return true
    end
    function a:sendChat(text) self.chats[#self.chats + 1] = tostring(text); return true end
    function a:sendChatNow(text) self.chats[#self.chats + 1] = tostring(text); return true end
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
  eq(d.widgets.input.visible, true, "初始：entry 常驻可见")
  eq(d.widgets.send.visible, true, "初始：磁吸按钮常驻可见（否则 ENTER 提交不了）")
  eq(w.inputOpen, true, "初始 inputOpen=true")

  -- 常驻后不该再有人能把它收起来
  w:closeInput()
  eq(w.inputOpen, true, "closeInput() 被拒绝：输入行常驻，关掉就没地方打字了")
  eq(d.widgets.input.visible, true, "拒绝隐藏后 entry 仍可见")
  ok((w.inputHideRefused or 0) >= 1, "记下了被拒绝的隐藏请求", w.inputHideRefused)

  -- 点 composer → 只给焦点，不改变可见性
  local L = w:layout()
  local hh = w:handlers()
  hh.onmousedown({ x = math.floor(L.composer.w / 2), y = L.composer.y + 5, button = LEFT })
  hh.onmouseup({ x = math.floor(L.composer.w / 2), y = L.composer.y + 5, button = LEFT })
  eq(d.widgets.input.visible, true, "点 composer 后 entry 仍可见（本来就常驻）")
  eq(d.widgets.input.focus, true, "点 composer 把焦点给了 entry")
  ok(w.lastInputError == nil, "点 composer 不抛错", w.lastInputError)

  -- 提交 → 输入行不收起；聊天走 sendChat；并且自己回显用户那行
  local cv = w.views.console
  local before = cv:count()
  w:setInput("hello agent")
  w:submit()
  eq(w.inputOpen, true, "提交后输入行**不**收起（常驻）")
  eq(d.widgets.input.visible, true, "提交后 entry 仍可见")
  eq(d.widgets.send.visible, true, "提交后按钮仍可见")
  eq(w:getInput(), "", "提交后输入内容清空")
  eq(a.chats[1], "hello agent", "聊天走 sendChat（不是把输入当协议帧发出去）")
  eq(#a.chats, 1, "只发一次聊天")
  local sentAsFrame = false
  for _, f in ipairs(a.frames) do if f == "SCALAR" then sentAsFrame = true end end
  ok(not sentAsFrame, "没有把用户输入当裸帧发出去（旧 bug：send(text) 桥不认识 → 静默丢弃）", table.concat(a.frames, ","))
  eq(cv:count(), before + 1, "自己回显了用户那行（sendChat 明确不负责回显）")

  -- Esc：不再收起输入行；不清草稿
  w:setInput("draft text")
  local lvl = w:escape()
  ok(lvl ~= "input", "Esc 不再处理输入行（常驻，没有可收起的）", tostring(lvl))
  eq(w.inputOpen, true, "Esc 后输入行仍在")
  eq(w:getInput(), "draft text", "Esc 不丢草稿")

  -- 编辑态下回车只提交字段，不发聊天
  local settingsAgent = a
  settingsAgent.config = { model = "gpt-4o" }
  w:setView("settings")
  w:invalidate(); w:paint(fakeGC(900, 620))
  local modelHit = nil
  for _, hit in ipairs(w.view.hits or {}) do if hit.id == "model" then modelHit = hit end end
  ok(modelHit ~= nil, "设置页有模型行")
  if modelHit then
    hh.onmousedown({ x = modelHit.rect.x + 5, y = modelHit.rect.y + 5, button = LEFT })
    hh.onmouseup({ x = modelHit.rect.x + 5, y = modelHit.rect.y + 5, button = LEFT })
    ok(w.fieldEdit ~= nil, "点行进编辑态")
    local chatsBefore = #a.chats
    w:setInput("gpt-4.1")
    w:submit()
    eq(#a.chats, chatsBefore, "**编辑态回车不发聊天**（只提交字段）")
    eq(w.fieldEdit, nil, "提交字段后退出编辑态")
  end
end

print("== 11. 逃生口：命令面板里有一条「使用旧面板」 ==")
do
  local oldPanel = { log = function() end, show = function() end }
  local openCalls = 0
  local agentStub = { panel = oldPanel, docName = function() return "001.ase" end }
  function agentStub:open() openCalls = openCalls + 1; self.panel:show() end
  function agentStub:send() return true end

  local w = workbench.new({ width = 900, height = 620 })
  w:mount(nil, agentStub)
  w:setSize(900, 620)
  -- 模拟 main.lua 的 swapAgentPanel：agent.panel 变成适配器，适配器记着自己包的是谁
  local ad = { wb = w, fallback = oldPanel, log = function() end }
  agentStub.panel = ad
  -- 极简假 Dialog（第 10 节那个 fakeDialog 是块内 local，这里够用就行）
  local dlg = { data = {}, widgets = {} }
  function dlg:canvas(s) self.widgets.screen = s end
  function dlg:entry(s) self.widgets.input = s end
  function dlg:button(s) self.widgets[s.id] = s end
  function dlg:newrow() end
  function dlg:samerow() end
  function dlg:show() end
  function dlg:close() end
  function dlg:repaint() end
  function dlg:modify() end
  w:build(dlg)
  w.shown = true

  local found = nil
  for _, c in ipairs(w:commands()) do if c.id == "ui.legacy_panel" then found = c end end
  ok(found ~= nil, "命令列表内置了 ui.legacy_panel（不依赖任何能力包）")
  ok(found ~= nil and tostring(found.title):find("legacy", 1, true) ~= nil, "标题里带 legacy，Ctrl+K 搜得到")

  local okRun = w:runCommand(found, "")
  ok(okRun, "命令执行成功")
  eq(openCalls, 1, "agent:open() 被调用了一次（旧面板被打开）")
  ok(agentStub.panel == oldPanel, "agent.panel 已换回旧面板（否则 open 又会把工作台显示回来）")
  eq(w.shown, false, "工作台已隐藏")
  eq(w.legacyMode, true, "记下了 legacyMode")
end

print("== 12. 设置页：点任意一项 → 进入画布内编辑态（不再弹旧原生窗）==")
do
  local actions = {}
  local a = { docName = function() return "001.ase" end,
              config = { model = "gpt-4o", baseUrl = "https://x/v1", temperature = 0.2 },
              send = function() return true end,
              action = function(self, name) actions[#actions + 1] = name; return true end }
  local w = workbench.new({ width = 900, height = 620, viewId = "settings" })
  w:mount(nil, a)
  w:setSize(900, 620)
  w:paint(fakeGC(900, 620))

  local v = w:currentView()
  local fieldHit = nil
  for _, hit in ipairs(v.hits or {}) do if hit.kind == "field" then fieldHit = hit end end
  ok(fieldHit ~= nil, "设置页登记了行命中区")

  if fieldHit then
    local hh = w:handlers()
    local x = fieldHit.rect.x + 20
    local y = fieldHit.rect.y + 5

    -- 悬浮要有反馈（不然用户以为点不了）
    local gcHover = fakeGC(900, 620)
    w:invalidate()
    hh.onmousemove({ x = x, y = y })
    w:paint(gcHover)
    local hovered = false
    for _, c in ipairs(w.kit.calls) do
      if c.region == "main" and c.op == "fill" and c.tone == "surface2"
         and c.x == fieldHit.rect.x and c.y == fieldHit.rect.y then hovered = true end
    end
    ok(hovered, "悬浮到设置行时有高亮反馈")

    hh.onmousedown({ x = x, y = y, button = LEFT })
    hh.onmouseup({ x = x, y = y, button = LEFT })
    ok(w.fieldEdit ~= nil, "点行进入了字段编辑态（composer 变编辑器）")
    eq(#actions, 0, "**没有**再调 agent:action('settings')（不弹旧原生窗）", table.concat(actions, ","))
    ok(w.inputOpen, "编辑态把原生输入行浮出来了（中文输入要靠它）")
    ok(w.lastInputError == nil, "设置页点击不抛错", w.lastInputError)
  end
end

print("")
print(string.format("%d passed, %d failed", pass, fail))