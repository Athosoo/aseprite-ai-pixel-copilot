-- tests/lua/panel_test.lua -- 面板交互：滚轮方向 / 状态转圈 / Esc 中断
--
-- 跑法： 在仓库根执行
--   "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/panel_test.lua
--
-- 为什么能无头测：面板的处理器都抽成了方法（_onWheel / _onKeyDown / setStatus），
-- 不依赖 Dialog。`-b` 模式下 Dialog 构造返回 nil 是正常的，这里也不需要它。
--
-- 注意：无头模式下 Timer 的 ontick【不触发】（没有 UI 循环），所以这里断言的是
-- "表有没有被启动"（isRunning），不是动画本身 —— 动画要在 GUI 里目检。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local panel = require("lib.panel")
local i18n = require("lib.i18n")

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

-- 假的 GraphicsContext：_paint 只用到 measureText / fillRect / fillText / width / height
local function fakeGC(w, h)
  return {
    width = w, height = h, color = nil,
    measureText = function(_, s) return { width = #tostring(s) * 6, height = 12 } end,
    fillRect = function() end,
    fillText = function() end,
  }
end

----------------------------------------------------------------------
print("== P1 滚轮方向：上 = 翻历史，下 = 回最新 ==")
do
  local p = panel.new{}
  for i = 1, 40 do p:log("line " .. i) end

  p.scroll = 10
  p:_onWheel{ deltaY = 120 }          -- 滚轮向下
  ok(p.scroll == 7, "向下 = scroll 减 3（回最新），实际 " .. tostring(p.scroll))

  p.scroll = 10
  p:_onWheel{ deltaY = -120 }         -- 滚轮向上
  ok(p.scroll == 13, "向上 = scroll 加 3（翻历史），实际 " .. tostring(p.scroll))

  p.scroll = 1
  p:_onWheel{ deltaY = 120 }
  ok(p.scroll == 0, "回最新时钳在 0，不会变负，实际 " .. tostring(p.scroll))

  p.scroll = 0
  p:_onWheel{ deltaY = 0 }
  ok(p.scroll == 0, "deltaY = 0 不动")
end

print("== P1 scroll 上界：翻过顶就停住 ==")
do
  local p = panel.new{}
  for i = 1, 100 do p:log("line " .. i) end
  p.scroll = 99999
  p:_paint(fakeGC(660, 420))
  ok(p.scroll < 99999 and p.scroll > 0, "被钳到可视范围内，实际 " .. tostring(p.scroll))

  -- 行数刚好够一屏时，maxScroll 应该是 0（没有历史可翻）
  local q = panel.new{}
  q:log("only one line")
  q.scroll = 50
  q:_paint(fakeGC(660, 420))
  ok(q.scroll == 0, "内容不足一屏时 scroll 归 0，实际 " .. tostring(q.scroll))
end

----------------------------------------------------------------------
print("== P2 状态指示：忙才转圈 ==")
do
  local p = panel.new{}

  p:setStatus("thinking...")
  ok(p.busy == true, "thinking 算忙")
  ok(p.spinTimer ~= nil, "转圈表被建出来了（Timer 要被持有，否则被 GC）")
  ok(p.spinTimer and p.spinTimer.isRunning == true, "思考时转圈表在跑")

  p:setStatus("working (step 2)...")
  ok(p.busy == true and p.spinTimer.isRunning == true, "多步工作继续转")

  p:setStatus("running crop...", "tool")
  ok(p.statusKind == "tool", "执行算子 = tool 色（青），实际 " .. tostring(p.statusKind))
  ok(p.busy == true, "执行算子时还在转")

  p:setStatus("ready")
  ok(p.busy == false, "ready 算闲")
  ok(p.spinTimer.isRunning == false, "就绪后转圈表停了")
  ok(p.statusKind == "ok", "就绪 = 绿，实际 " .. tostring(p.statusKind))

  p:setStatus("connected")
  ok(p.busy == false, "connected 算闲")

  p:setStatus("connected, waiting for input")
  ok(p.busy == false, "connected, waiting for input 也算闲（前缀匹配）")

  p:setStatus("error")
  ok(p.busy == false and p.statusKind == "error", "error = 闲 + 红色")
end

print("== 桥发来的带变量状态也要本地化 ==")
do
  ok(i18n.statusText("thinking...") == "思考中…", "thinking... -> 思考中…，实际 " .. i18n.statusText("thinking..."))
  local w = i18n.statusText("working (step 3)...")
  ok(w:find("3", 1, true) ~= nil and w:find("working", 1, true) == nil,
    "working (step 3)... 带上步数并译成中文，实际 " .. w)
  local r = i18n.statusText("running crop...")
  ok(r:find("crop", 1, true) ~= nil and r:find("running", 1, true) == nil,
    "running crop... 保留算子名并译成中文，实际 " .. r)
  ok(i18n.statusText("something else") == "something else", "不认识的原样返回")

  -- 判忙闲用的是**原文**，所以翻译不影响逻辑
  local p = panel.new{}
  p:setStatus("working (step 3)...")
  ok(p.busy == true, "带步数的状态照样算忙")
end

print("== P2 断联醒目：红字 + 提示行 ==")
do
  local p = panel.new{}
  p:setStatus(i18n.t("disconnected"), "error")
  ok(p.statusKind == "error", "断开 = 红色")
  ok(p.alert ~= nil and p.alert ~= "", "状态栏下面多了一行提示")
  ok(p.alert == i18n.t("bridgeDown"), "提示文案走 i18n")

  p:setStatus("ready")
  ok(p.alert == "", "恢复后就绪时提示行消失")
end

print("== P2 本地化的中文状态也要能判忙闲 ==")
do
  local p = panel.new{}
  -- agent.lua 在连接期间传的是已经本地化过的文本（i18n.t("connecting") 的结果）
  p:setStatus(string.format(i18n.t("connecting"), "ws://127.0.0.1:1"))
  ok(p.busy == true, "「正在连接 …」算忙（要转圈）")
  p:setStatus(i18n.t("connected"))
  ok(p.busy == false, "「已连接」算闲")
  p:setStatus(i18n.t("disconnected"))
  ok(p.busy == false and p.statusKind == "error", "「已断开」= 闲 + 红")
end

----------------------------------------------------------------------
print("== P3 Esc：菜单开着先关菜单，忙时才是中断 ==")
do
  local acts = {}
  local p = panel.new{ onAction = function(id) acts[#acts + 1] = id end }

  p:setStatus("thinking...")
  p:_onKeyDown{ code = "Escape" }
  ok(#acts == 1 and acts[1] == "abort", "忙时 Esc -> abort，实际 " .. tostring(acts[1]))

  acts = {}
  p:setStatus("ready")
  p:_onKeyDown{ code = "Escape" }
  ok(#acts == 0, "闲时 Esc 不做事")

  acts = {}
  p:setStatus("thinking...")
  p.menuOpen = true
  p:_onKeyDown{ code = "Escape" }
  ok(#acts == 0, "菜单开着时 Esc 只关菜单，不中断")
  ok(p.menuOpen == false, "菜单真的关了")
end

print("== P3 内建命令 停止 / stop ==")
do
  ok(i18n.builtinAction("停止") == "abort", "「停止」-> abort")
  ok(i18n.builtinAction("中断") == "abort", "「中断」-> abort")
  ok(i18n.builtinAction("stop") == "abort", "stop -> abort")
  ok(i18n.builtinAction("abort") == "abort", "abort -> abort")
  ok(i18n.builtinAction("回滚") == "rollback", "没把别的命令带坏")
end

print("== 命令表里有「中断当前任务」这一行 ==")
do
  local rows = i18n.menuCommands()
  local found = nil
  for _, r in ipairs(rows) do
    if r.id == "abort" then found = r end
  end
  ok(found ~= nil, "菜单里有 abort 行")
  if found then
    ok(found.keys == "X", "键位是 X，实际 " .. tostring(found.keys))
    ok(type(found.label) == "string" and found.label ~= "", "有标题")
  end
end

print("== P5a 状态栏带当前文件名 ==")
do
  local p = panel.new{}
  p:setStatus("running crop...", "tool", "hero.ase")
  ok(p.docName == "hero.ase", "文件名存下来了，实际 " .. tostring(p.docName))
  -- docName 省略时保持不变（桥每次 status 都会带上，所以不会丢）
  p:setStatus("ready", "ok")
  ok(p.docName == "hero.ase", "不传时保留上一次的文件名")
end

print("== P7 提问期间：数字/字母优先当回答 ==")
do
  local answers = {}
  local p = panel.new{ onSend = function(t) answers.sent = t end,
                       onAskAnswer = function(i) answers[#answers + 1] = i end }

  -- 没有提问时，数字照常发给 AI
  p.input = "1"
  p:_submit()
  ok(answers.sent == "1", "没有提问时数字走聊天，实际 " .. tostring(answers.sent))

  -- 有提问时，数字/字母 = 回答
  answers = {}
  p:setAsk{ question = "要哪个？", options = { "覆盖", "保留", "丢弃" } }
  ok(p:askIsPending() == true, "进入待答状态")

  for _, pair in ipairs({ { "2", 2 }, { "3", 3 }, { "a", 1 }, { "C", 3 } }) do
    p.input = pair[1]
    p:_submit()
    ok(answers[#answers] == pair[2],
      string.format("输入 %q -> 第 %d 项，实际 %s", pair[1], pair[2], tostring(answers[#answers])))
  end

  ok(answers.sent == nil, "提问期间数字没有漏给 AI")

  -- 取消词
  p.input = "x"
  p:_submit()
  ok(answers[#answers] == "cancel", "x = 取消")
  p.input = "取消"
  p:_submit()
  ok(answers[#answers] == "cancel", "「取消」= 取消")

  -- 超出范围的数字 / 普通文字不是回答，照常发出去
  answers = {}
  p.input = "9"
  p:_submit()
  ok(answers[#answers] == nil and answers.sent == "9", "超范围的 9 走聊天")
  answers = {}
  p.input = "覆盖原图吧"
  p:_submit()
  ok(answers[#answers] == nil and answers.sent == "覆盖原图吧", "自由文本走聊天")

  -- 答完清状态
  p:setAsk(nil)
  ok(p:askIsPending() == false, "setAsk(nil) 清掉待答状态")
end

print("== P12 形态切换：面板 / 底边栏 / 侧边栏 ==")
do
  local p = panel.new{}
  ok(p:layoutMode() == "panel", "默认是面板")
  ok(p:isBar() == false, "面板不算栏")

  -- 无头下没有 dlg，setMode 只改状态（真正的窗口尺寸要在 GUI 里验）
  ok(p:setMode("bar_bottom") == "bar_bottom", "切到底边栏")
  ok(p:isBar() == true, "底边栏算栏")
  ok(p:setMode("bar_side") == "bar_side", "切到侧边栏")
  ok(p:setMode("nonsense") == "panel", "非法形态回落到面板")

  -- 循环切换
  p:setMode("panel", true)
  ok(p:cycleMode() == "bar_bottom", "panel -> bar_bottom")
  ok(p:cycleMode() == "bar_side", "bar_bottom -> bar_side")
  ok(p:cycleMode() == "panel", "bar_side -> panel")

  ok(i18n.builtinAction("栏") == "bar", "「栏」-> bar")
  ok(i18n.builtinAction("bar") == "bar", "bar -> bar")
  local rows = i18n.menuCommands()
  local found = nil
  for _, r in ipairs(rows) do if r.id == "bar" then found = r end end
  ok(found ~= nil, "菜单里有切换形态这一行")
end

print("== P12 栏形态的绘制：不炸 + 内容裁到宽度内 ==")
do
  local p = panel.new{}
  p:setMode("bar_bottom", true)
  p:setStatus("thinking...", "busy", "a-very-long-document-name-that-should-be-clipped.ase")
  p:log("这是一行很长的输出，长到必须被裁掉尾巴，否则会画到窗口外面去，看起来就崩了。", "ai")
  p.input = "输入的文本也应该只显示靠近光标的那一段，前面的裁掉"
  p:_paint(fakeGC(1000, 44))
  ok(p.dbg ~= nil and p.dbg:find("bar mode=bar_bottom") ~= nil, "画的是栏布局：" .. tostring(p.dbg))

  -- 侧边栏：窄窗口 + 正常布局
  p:setMode("bar_side", true)
  p:_paint(fakeGC(320, 420))
  ok(p.dbg ~= nil and p.dbg:find("w=320") ~= nil, "侧边栏能画出来：" .. tostring(p.dbg))

  -- 栏形态下不触发"窗口太小"（栏本来就矮）
  local q = panel.new{}
  q:setMode("bar_bottom", true)
  q:_paint(fakeGC(1000, 44))
  ok(q.dbg:find("too small") == nil, "栏形态不会被【窗口太小】拦掉")
end

print("== 生命周期：关窗停表，重开接着转 ==")
do
  local p = panel.new{}
  p:setStatus("thinking...")
  ok(p.spinTimer.isRunning == true, "开着")
  p:hide()
  ok(p.spinTimer.isRunning == false, "hide 后停表（窗口不在，别空转）")
  p.busy = true
  p.shown = true
  -- show() 在无头下没有 dlg，只会置 shown；直接验 _startSpin 的分支
  p:_startSpin()
  ok(p.spinTimer.isRunning == true, "重新显示后能接着转")
  p:destroy()
  ok(p.spinTimer == nil, "destroy 把表也丢了")
end

print(string.format("%d passed, %d failed", pass, fail))
