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

-- 假的 GraphicsContext：_paint 只用到 measureText / fillRect / fillText / drawImage / width / height
-- rects 收集被填充的矩形（栏内控件的格子数靠它数）
local function fakeGC(w, h)
  local g = { width = w, height = h, color = nil, rects = {}, images = {}, texts = {} }
  g.measureText = function(_, s) return { width = #tostring(s) * 6, height = 12 } end
  g.fillRect = function(_, rc) g.rects[#g.rects + 1] = rc end
  g.fillText = function(_, s, x, y) g.texts[#g.texts + 1] = { text = tostring(s), x = x, y = y } end
  g.drawImage = function(_, img, x, y) g.images[#g.images + 1] = { img = img, x = x, y = y } end
  return g
end

-- 画布上有没有出现过这段文字（只看文本，不看位置）
local function drewText(gc, s)
  for _, t in ipairs(gc.texts or {}) do if t.text == s then return true end end
  return false
end

-- 造一张假"合成图"：给面板当工作图片缩略图的来源（32x32，右下角一个红点）
local function fakeFrameImage()
  local img = Image(32, 32, ColorMode.RGB)
  local rows = {}
  for y = 0, 31 do
    local row = {}
    for x = 0, 31 do
      if x >= 30 and y >= 30 then row[#row + 1] = string.char(0, 0, 255, 255)
      else row[#row + 1] = string.char(40, 40, 40, 255) end
    end
    rows[#rows + 1] = table.concat(row)
  end
  img.bytes = table.concat(rows)
  return img
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
  ok(p:cycleMode() == "small", "bar_side -> small（v0.5.5 起多了小窗形态）")
  ok(p:cycleMode() == "panel", "small -> panel")

  ok(i18n.builtinAction("栏") == "bar", "「栏」-> bar")
  ok(i18n.builtinAction("bar") == "bar", "bar -> bar")

  -- 贴位算式（纯函数，不用真窗口）：主窗口 960x564，窗口 372x79
  local W, H, bw, bh = 960, 564, 372, 79
  local x, y = panel.anchorFor("bar_bottom", W, H, bw, bh)
  ok(x == math.floor((W - bw) / 2) and y == H - bh, "底边栏：水平居中贴底", x .. "," .. y)
  x, y = panel.anchorFor("bar_side", W, H, 332, 467)
  ok(x == W - 332 and y == math.floor((H - 467) / 2), "侧边栏：贴右垂直居中", x .. "," .. y)
  x, y = panel.anchorFor("small", W, H, bw, bh)
  ok(x == W - bw and y == H - bh, "小窗：贴右下角（v0.5.9 起，以前是右侧居中）", x .. "," .. y)
  ok(panel.anchorFor("small", 0, 0, bw, bh) == nil, "拿不到主窗口尺寸 -> nil（调用方沿用原位置）")
  -- 主窗口比窗口还小：不能算出负数坐标（窗口会跑到屏幕外）
  x, y = panel.anchorFor("small", 100, 50, bw, bh)
  ok(x == 0 and y == 0, "主窗口比小窗还小 -> 夹到 0", x .. "," .. y)
  local rows = i18n.menuCommands()
  local found = nil
  for _, r in ipairs(rows) do if r.id == "bar" then found = r end end
  ok(found ~= nil, "菜单里有切换形态这一行")

  -- G4：面板里的「打开文件…」入口
  ok(i18n.builtinAction("打开文件") == "open_file", "「打开文件」-> open_file")
  ok(i18n.builtinAction("openfile") == "open_file", "openfile -> open_file")
  ok(i18n.builtinAction("打开") == "upload", "「打开」仍是选图进矫正队列（没被改坏）")

  -- 清空对话上下文（v0.5.2）：中英都能敲，而且不能撞上"清屏"
  ok(i18n.builtinAction("forget") == "reset_history", "forget -> reset_history")
  ok(i18n.builtinAction("reset") == "reset_history", "reset -> reset_history")
  ok(i18n.builtinAction("context") == "reset_history", "context -> reset_history")
  ok(i18n.builtinAction("清空上下文") == "reset_history", "「清空上下文」-> reset_history")
  ok(i18n.builtinAction("忘记") == "reset_history", "「忘记」-> reset_history")
  ok(i18n.builtinAction("清空") == "clear", "「清空」还是清屏（没被抢走）")
  ok(i18n.builtinAction("cls") == "clear", "cls 还是清屏")
  ok(i18n.miniLabel("reset_history") ~= "" and i18n.miniLabel("reset_history") ~= "reset_history",
    "小面板标签有本地化文案")

  -- 做不到清单（v0.5.6）：中英都能敲，命令表里有位置
  ok(i18n.builtinAction("gaps") == "gaps", "gaps -> gaps")
  ok(i18n.builtinAction("backlog") == "gaps", "backlog -> gaps")
  ok(i18n.builtinAction("做不到") == "gaps", "「做不到」-> gaps")
  ok(i18n.miniLabel("gaps") ~= "gaps", "做不到清单有本地化标签，实际 " .. tostring(i18n.miniLabel("gaps")))
  local rows = i18n.menuCommands()
  local found = false
  for _, row in ipairs(rows) do if row.id == "gaps" then found = true end end
  ok(found, "命令表里有「我做不到的事」这一行")
  ok(i18n.t("gapsNone") ~= nil and i18n.t("gapsReport") ~= nil and i18n.t("gapsWhere") ~= nil,
    "做不到清单的文案键都在")
  local of = nil
  for _, r in ipairs(rows) do if r.id == "open_file" then of = r end end
  ok(of ~= nil, "菜单里有「打开文件…」这一行")
  local od = nil
  for _, r in ipairs(rows) do if r.id == "open_doc" then od = r end end
  ok(od ~= nil and of.keys ~= od.keys, "两条打开的键位不冲突（O vs P）")
end

print("== P4 续：modify 之后窗口尺寸要放回去（输入不再撑大窗口）==")
do
  -- 假的 dlg：modify 会模拟 Aseprite 的行为 —— 把窗口撑回"内容自然尺寸"
  local function fakeDlg(naturalW, naturalH, startW, startH)
    local d = { bounds = Rectangle(10, 20, startW, startH), modifies = 0 }
    d.modify = function(_, _)
      d.modifies = d.modifies + 1
      d.bounds = Rectangle(d.bounds.x, d.bounds.y, naturalW, naturalH)   -- 这就是那个"撑回去"
    end
    return d
  end

  local p = panel.new{}
  p.shown = true
  p.dlg = fakeDlg(672, 467, 320, 220)          -- 用户把窗口缩成了 320x220

  -- 模拟"敲一个字"：Entry 变化 -> 重置哨兵 -> modify
  p.entrySyncing = false
  p:_resetEntry(false)
  ok(p.dlg.modifies > 0, "确实发生了一次 modify")
  ok(p.dlg.bounds.width == 320 and p.dlg.bounds.height == 220,
    string.format("窗口尺寸被放回去了，实际 %dx%d", p.dlg.bounds.width, p.dlg.bounds.height))
  ok(p.dlg.bounds.x == 10 and p.dlg.bounds.y == 20, "位置也没被挪动")

  -- 点画布：同样不能跳
  p.inputFocused = false
  p:_onCanvasMouseDown({ button = MouseButton.LEFT, x = 5, y = 5 })
  ok(p.dlg.bounds.width == 320, "点画布后还是 320")
  ok(p.inputFocused == true, "但焦点确实被设回了输入框（手感没牺牲）")

  -- 没缩过的窗口：不该被改（放回去的值 == 原值）
  local q = panel.new{}
  q.shown = true
  q.dlg = fakeDlg(672, 467, 672, 467)
  q:_resetEntry(false)
  ok(q.dlg.bounds.width == 672 and q.dlg.bounds.height == 467, "本来就是自然尺寸 -> 不动")
end

print("== G2 底边栏要放得下 3 行（状态 + 最后一行输出 + 输入）==")
do
  -- 行高约 18：高度必须 >= 3*行高，否则"正在执行的指令"那行画不出来
  local p = panel.new{}
  p:setMode("bar_bottom", true)
  p:setStatus("running draw_art...", "tool", "hero.ase")
  p:log("已画 128 像素（16x16），图层 主体", "tool")
  p:_paint(fakeGC(1000, 60))
  local rows = tonumber(tostring(p.dbg):match("rows=(%d+)"))
  ok(rows and rows >= 3, "画布能放 3 行以上，实际 rows=" .. tostring(rows))
  p:_paint(fakeGC(1000, 44))       -- 老高度：只够两行
  local rows2 = tonumber(tostring(p.dbg):match("rows=(%d+)"))
  ok(rows2 == 2, "高度 44 时确实只有 2 行（所以必须加高），实际 " .. tostring(rows2))
end

print("== G5 栏底色：可配置，认不出来的回落默认 ==")
do
  local p = panel.new{}
  ok(p:setBarColor("#2B2B2B") == true, "#RRGGBB 认得")
  ok(p.barBg ~= nil and p.barBg.red == 0x2B, "解析出 R=0x2B，实际 " .. tostring(p.barBg and p.barBg.red))
  ok(p:setBarColor("#abc") == true and p.barBg.red == 0xAA, "#RGB 简写也认（补成 AABBCC）")
  ok(p:setBarColor("") == false and p.barBg == nil, "空串 = 恢复默认")
  ok(p:setBarColor("not a colour") == false and p.barBg == nil, "乱填的回落默认")
  ok(p:setBarColor("#12345") == false, "位数不对也回落")
  -- 栏模式绘制用得上（不炸即可，颜色在 GUI 里目检）
  p:setBarColor("#101010")
  p:setMode("bar_bottom", true)
  p:_paint(fakeGC(1000, 60))
  ok(p.dbg ~= nil, "带自定义底色也能画")
end

print("== G3 形态变更会回调（持久化用）==")
do
  local got = {}
  local p = panel.new{ onModeChange = function(m) got[#got + 1] = m end }
  p:setMode("bar_side")
  ok(#got == 1 and got[1] == "bar_side", "形态变了就回调，实际 " .. tostring(got[1]))
  p:setMode("bar_side")                 -- 没变也要回调（调用方自己去重）
  ok(#got == 2, "重复设置也回调，让调用方决定要不要写盘")
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

----------------------------------------------------------------------
print("== 栏内控件：上下文电量条（20 格）==")
do
  local p = panel.new{}
  p:setMode("bar_bottom", true)

  p:setContext(0, 16000)
  ok(p:ctxFilled() == 0, "没用上下文 = 0 格，实际 " .. p:ctxFilled())
  p:setContext(8000, 16000)
  ok(p:ctxFilled() == 10, "用了一半 = 10 格，实际 " .. p:ctxFilled())
  p:setContext(16000, 16000)
  ok(p:ctxFilled() == 20, "用满 = 20 格，实际 " .. p:ctxFilled())
  p:setContext(99999, 16000)
  ok(p:ctxFilled() == 20, "超预算也不超过 20 格，实际 " .. p:ctxFilled())
  p:setContext(100, 0)
  ok(p:ctxFilled() == 0, "预算未知时不乱显示，实际 " .. p:ctxFilled())
  ok(p:ctxLabel() == "-", "预算未知时标签是 -，实际 " .. p:ctxLabel())

  p:setContext(8200, 16000)
  ok(p:ctxLabel() == "8.2k/16k", "标签是 8.2k/16k，实际 " .. p:ctxLabel())
  p:setContext(7000, 8000)
  ok(p:ctxLabel() == "7k/8k", "整千写 7k/8k 不写 7.0k/8.0k，实际 " .. p:ctxLabel())
  p:setContext(8200, 16000)
  p:setContext(900, 16000)
  ok(p:ctxLabel() == "900/16k", "不到 1k 直接显示数字，实际 " .. p:ctxLabel())

  -- 颜色分级：绿 -> 琥珀 -> 红
  local okColor, warnColor, errColor = false, false, false
  p:setContext(1000, 16000); okColor = p:ctxColor() ~= nil
  p:setContext(11000, 16000); warnColor = (p:ctxColor() ~= nil)
  p:setContext(15000, 16000); errColor = (p:ctxColor() ~= nil)
  ok(okColor and warnColor and errColor, "三档颜色都能取到")
  local a = p:ctxColor()           -- 15000/16000 = 94% -> 红
  p:setContext(1000, 16000)
  local b = p:ctxColor()
  ok(a ~= b, "快满了和刚开始的颜色不同（一眼能看出来）")

  -- 画出来：应该有 20 个格子
  p:setContext(8000, 16000)
  local gc = fakeGC(1000, 60)
  p:_paint(gc)
  ok(p.dbg:find("ctx=8000/16000") ~= nil, "调试串里带用量：" .. p.dbg)
  local anyHit = #p.barHit > 0
  local b0 = p.barHit[1]
  ok(anyHit and p:_barHitAt(b0.x + 2, b0.y + 2) ~= nil, "控件区能命中（鼠标点得到）")
  ok(p:_barHitAt(2, 2) == nil, "控件区之外不会误命中")
end

print("== 栏内控件：思考强度滑杆（4 档，可点可拖）==")
do
  local got = {}
  local p = panel.new{ onThinkingChange = function(v) got[#got + 1] = v end }
  p:setMode("bar_bottom", true)
  p:setThinking("auto")
  ok(p:thinkIndex() == 1, "auto = 第 1 档，实际 " .. p:thinkIndex())

  local gc = fakeGC(1000, 60)
  p:_paint(gc)
  ok(p.thinkTrack ~= nil, "绘制后记下了滑杆轨道（否则点不着）")

  local t = p.thinkTrack
  -- 点最右边 = 最高档
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = t.x + t.w - 1, y = t.y + 4 }
  ok(p.thinking == "high", "点最右 -> high，实际 " .. p.thinking)
  ok(#got == 1 and got[1] == "high", "单击就提交了一次，实际 " .. #got)

  -- 拖：中间两下不提交，松手才提交一次
  p.thinkDrag = true
  got = {}
  p:_onCanvasMouseMove{ x = t.x, y = t.y + 4 }              -- 最左 = auto
  p:_onCanvasMouseMove{ x = t.x + math.floor(t.w / 3), y = t.y + 4 }
  ok(#got == 0, "拖动过程中不提交（免得写 4 次配置），实际 " .. #got)
  ok(p.thinking ~= "high", "拖动过程中视觉已经跟着变，实际 " .. p.thinking)
  p:_onCanvasMouseUp{ button = MouseButton.LEFT }        -- 真事件一定带 button
  ok(#got == 1, "松手提交一次，实际 " .. #got)
  ok(p.thinkDrag == false, "松手后不再拖")

  -- 点"最左"回到 auto
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = t.x, y = t.y + 4 }
  ok(p.thinking == "auto", "点最左 -> auto，实际 " .. p.thinking)

  -- 非法值退回 auto
  p:setThinking("ultra")
  ok(p.thinking == "auto", "非法档位退回 auto，实际 " .. p.thinking)

  -- 档位映射：4 等分
  p.thinkTrack = { x = 0, y = 0, w = 96, h = 16 }
  ok(p:_thinkIndexAt(-50) == 1, "越界左侧 = 第 1 档")
  ok(p:_thinkIndexAt(0) == 1, "x=0 = 第 1 档")
  ok(p:_thinkIndexAt(32) == 2, "x=32 = 第 2 档，实际 " .. p:_thinkIndexAt(32))
  ok(p:_thinkIndexAt(64) == 3, "x=64 = 第 3 档，实际 " .. p:_thinkIndexAt(64))
  ok(p:_thinkIndexAt(95) == 4, "x=95 = 第 4 档，实际 " .. p:_thinkIndexAt(95))
  ok(p:_thinkIndexAt(9999) == 4, "越界右侧 = 第 4 档")

  -- 面板模式下【也】要画控件（v0.5.4 修的 bug：以前切回面板就全没了）
  local q = panel.new{}
  q:setMode("panel", true)
  local g2 = fakeGC(660, 420)
  q:_paint(g2)
  ok(q.thinkTrack ~= nil, "面板模式也有滑杆（切形态不少东西）")
  ok(#(q.barHit or {}) > 0, "面板模式也有控件命中区")
end

print("== 栏内控件：工作图片缩略图 + 打开新图 ==")
do
  local actions = {}
  local p = panel.new{
    frameImage = function() return fakeFrameImage() end,
    onAction = function(id) actions[#actions + 1] = id end,
  }
  p:setMode("bar_bottom", true)

  -- 缩略图：保持长宽比、缩到外框内、像素真的是从原图采的
  local thumb = p:thumbImage(40, 40)
  ok(thumb ~= nil, "拿到了缩略图")
  ok(thumb and thumb.width <= 40 and thumb.height <= 40, "不超过外框")
  ok(thumb and thumb.width == 40 and thumb.height == 40,
    "32x32 小图放大填满外框（看得清），实际 " ..
    (thumb and thumb.width .. "x" .. thumb.height or "nil"))
  -- 右下角那个红点应该在缩略图右下角（BGGRR：红 = 低字节 FF）
  local px = thumb and thumb:getPixel(31, 31) or 0
  ok(px ~= 0, "角落采样到了像素")

  -- 非正方形：保持长宽比（长边贴住外框）
  local wide = panel.new{ frameImage = function()
    local img = Image(64, 16, ColorMode.RGB)
    local rows = {}
    for y = 0, 15 do
      local row = {}
      for x = 0, 63 do row[#row + 1] = string.char(9, 9, 9, 255) end
      rows[#rows + 1] = table.concat(row)
    end
    img.bytes = table.concat(rows)
    return img
  end }
  local w2 = wide:thumbImage(40, 40)
  ok(w2 and w2.width == 40 and w2.height == 10, "64x16 -> 40x10（长宽比没被压扁），实际 " ..
    (w2 and w2.width .. "x" .. w2.height or "nil"))

  -- 没有文档（frameImage 返回 nil）也不能炸
  local nodoc = panel.new{ frameImage = function() return nil end }
  ok(nodoc:thumbImage(40, 40) == nil, "没有文档时返回 nil 而不是报错")

  -- 画出来：有缩略图 + "＋" 两个命中区
  local gc = fakeGC(1000, 60)
  p:_paint(gc)
  ok(#gc.images == 1, "画了一次缩略图，实际 " .. #gc.images)
  local kinds = {}
  for _, b in ipairs(p.barHit) do kinds[b.kind] = true end
  ok(kinds.work and kinds.open and kinds.ctx and kinds.think,
    "四个命中区都在（图 / ＋ / 电量条 / 滑杆）")

  -- 点缩略图 = 打开一张新图；点"＋"也是
  local thumbHit, openHit
  for _, b in ipairs(p.barHit) do
    if b.kind == "work" then thumbHit = b end
    if b.kind == "open" then openHit = b end
  end
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = thumbHit.x + 2, y = thumbHit.y + 2 }
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = openHit.x + 2, y = openHit.y + 2 }
  ok(#actions == 2 and actions[1] == "open_file" and actions[2] == "open_file",
    "两次都触发了 open_file，实际 " .. table.concat(actions, ","))

  -- 点电量条 = 问一句"现在用了多少"
  actions = {}
  local ctxHit
  for _, b in ipairs(p.barHit) do if b.kind == "ctx" then ctxHit = b end end
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = ctxHit.x + 2, y = ctxHit.y + 2 }
  ok(#actions == 1 and actions[1] == "ctx_info", "点电量条 -> ctx_info，实际 " ..
    table.concat(actions, ","))

  -- 命中的点击不能把焦点抢给输入框（否则拖滑杆会打断输入）
  local p2 = panel.new{ frameImage = function() return nil end }
  p2:setMode("bar_bottom", true)
  p2.inputFocused = false
  local dlgCalls = 0
  p2.dlg = { modify = function() dlgCalls = dlgCalls + 1 end }
  p2.shown = true
  p2:_paint(fakeGC(1000, 60))
  local th
  for _, b in ipairs(p2.barHit) do if b.kind == "think" then th = b end end
  p2:_onCanvasMouseDown{ button = MouseButton.LEFT, x = th.x + 4, y = th.y + 4 }
  ok(dlgCalls == 0, "点中控件时不碰输入框焦点，实际 modify 调用 " .. dlgCalls)
end

print("== 栏内控件：面板模式也要有（切形态不能少东西）==")
do
  local p = panel.new{ frameImage = function() return fakeFrameImage() end }
  p:setMode("panel", true)
  p:setContext(4000, 16000)
  p:setThinking("low")
  p.input = "把背景改成蓝色"
  local gc = fakeGC(660, 420)
  p:_paint(gc)
  local kinds = {}
  for _, b in ipairs(p.barHit) do kinds[b.kind] = true end
  ok(kinds.work and kinds.open and kinds.ctx and kinds.think and kinds.dock,
    "面板模式里五个控件都在（图/＋/电量条/滑杆/贴边），实际 " ..
    table.concat((function() local t = {} for k in pairs(kinds) do t[#t + 1] = k end table.sort(t) return t end)(), ","))
  ok(p.thinkTrack ~= nil, "面板模式里滑杆也能点（thinkTrack 记下了）")
  -- 控件在输入行那一行（不是别的地方）
  local caretY = tonumber(tostring(p.dbg):match("caret=%(%d+,(%d+)%)")) or 0
  local off = {}
  for _, b in ipairs(p.barHit) do
    if math.abs(b.y - caretY) > 12 then off[#off + 1] = b.kind end
  end
  ok(#off == 0, "控件都在输入行上（caretY=" .. caretY .. "），跑偏的：" .. table.concat(off, " "))
  ok(tostring(p.dbg):find("cls=0") == nil, "输入区为控件让了宽度：" .. tostring(p.dbg))

  -- 面板模式下点控件也要生效（以前只在栏模式命中）
  local actions = {}
  p.opts.onAction = function(id) actions[#actions + 1] = id end
  local openHit
  for _, b in ipairs(p.barHit) do if b.kind == "open" then openHit = b end end
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = openHit.x + 1, y = openHit.y + 1 }
  ok(#actions == 1 and actions[1] == "open_file", "面板模式点 ＋ 也能开图，实际 " ..
    table.concat(actions, ","))
end

print("== 贴边切换按钮：点一下在 贴底 / 贴侧边 之间切 ==")
do
  local p = panel.new{ frameImage = function() return nil end, onModeChange = function() end }
  p:setMode("panel", true)

  -- 面板模式点一下 -> 去贴底
  p:toggleDock()
  ok(p:layoutMode() == "bar_bottom", "面板 -> 贴底，实际 " .. p:layoutMode())
  -- 贴底再点 -> 贴侧边
  p:toggleDock()
  ok(p:layoutMode() == "bar_side", "贴底 -> 贴侧边，实际 " .. p:layoutMode())
  -- 贴侧边再点 -> 回贴底（两态切换，不会绕回面板）
  p:toggleDock()
  ok(p:layoutMode() == "bar_bottom", "贴侧边 -> 贴底，实际 " .. p:layoutMode())

  -- 真的点那个按钮（走鼠标路径）
  p:setMode("bar_bottom", true)
  local g = fakeGC(1000, 60)
  p:_paint(g)
  local dock
  for _, b in ipairs(p.barHit) do if b.kind == "dock" then dock = b end end
  ok(dock ~= nil, "贴边按钮画出来了")
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = dock.x + 2, y = dock.y + 2 }
  ok(p:layoutMode() == "bar_side", "点按钮 -> 贴侧边，实际 " .. p:layoutMode())

  -- 三种形态都要有这个按钮
  local all = true
  for _, m in ipairs({ "panel", "bar_bottom", "bar_side" }) do
    p:setMode(m, true)
    if m == "panel" then p:_paint(fakeGC(660, 420)) else
      p:_paint(fakeGC(m == "bar_bottom" and 1000 or 320, m == "bar_bottom" and 60 or 420))
    end
    local found = false
    for _, b in ipairs(p.barHit) do if b.kind == "dock" then found = true end end
    if not found then all = false end
  end
  ok(all, "面板 / 贴底 / 贴侧边 三种形态都有贴边按钮")
end

print("== 小窗口：控件不许被画到画布外 ==")
do
  -- 栏比需要的行数还矮（用户截图里那条黑条就很矮）
  for _, hh in ipairs({ 60, 40, 28, 20 }) do
    local p = panel.new{ frameImage = function() return nil end }
    p:setMode("bar_bottom", true)
    p:setContext(3000, 16000)
    local g = fakeGC(1000, hh)
    p:_paint(g)
    local bad, found = {}, 0
    for _, b in ipairs(p.barHit) do
      found = found + 1
      if b.y < 0 or b.y + b.h > hh then bad[#bad + 1] = b.kind .. "@y=" .. b.y end
    end
    ok(found > 0 and #bad == 0, "栏高 " .. hh .. " 时控件都在画布内（找到 " .. found ..
      " 个），越界的：" .. table.concat(bad, " "))
  end

  -- 面板被拖到很矮
  for _, hh in ipairs({ 420, 120, 60 }) do
    local p = panel.new{ frameImage = function() return nil end }
    p:setMode("panel", true)
    p:setContext(3000, 16000)
    local g = fakeGC(660, hh)
    p:_paint(g)
    local bad, found = {}, 0
    for _, b in ipairs(p.barHit) do
      found = found + 1
      if b.y < 0 or b.y + b.h > hh then bad[#bad + 1] = b.kind .. "@y=" .. b.y end
    end
    ok(#bad == 0, "面板高 " .. hh .. " 时控件都在画布内（找到 " .. found .. " 个），越界的：" ..
      table.concat(bad, " "))
  end
end

print("== 最小化：小窗形态 + 还原 ==")
do
  local p = panel.new{ frameImage = function() return fakeFrameImage() end }
  p:setMode("panel", true)
  p:setContext(5000, 16000)
  p:setThinking("medium")

  -- 最小化：记住来处
  p:toggleSmall()
  ok(p:layoutMode() == "small", "面板 -> 小窗，实际 " .. p:layoutMode())
  ok(p.lastMode == "panel", "记住了从面板来的，实际 " .. tostring(p.lastMode))

  -- 小窗里要画出控件 + 还原入口
  local gc = fakeGC(360, 56)
  p:_paint(gc)
  local kinds = {}
  for _, b in ipairs(p.barHit) do kinds[b.kind] = true end
  ok(kinds.small and kinds.work and kinds.ctx and kinds.think, "小窗里有控件和还原按钮，实际 " ..
    table.concat((function() local t = {} for k in pairs(kinds) do t[#t + 1] = k end table.sort(t) return t end)(), ","))
  ok(kinds.restore ~= nil, "点状态行也能还原（大目标）")
  local bad = {}
  for _, b in ipairs(p.barHit) do
    if b.x < 0 or b.y < 0 or b.x + b.w > 360 or b.y + b.h > 56 then bad[#bad + 1] = b.kind end
  end
  ok(#bad == 0, "小窗里控件都在画布内，越界的：" .. table.concat(bad, " "))

  -- 还原带不能盖住控件：_barHitAt 取第一个命中，盖住了就等于控件点不动
  local restoreBand, firstCell
  for _, b in ipairs(p.barHit) do
    if b.kind == "restore" then restoreBand = b end
    if b.kind == "work" then firstCell = b end
  end
  ok(restoreBand.x + restoreBand.w <= firstCell.x,
    string.format("还原带在控件左边，不重叠（带右端 %d，控件左端 %d）",
      restoreBand.x + restoreBand.w, firstCell.x))
  local hitWork = p:_barHitAt(firstCell.x + 2, firstCell.y + 2)
  ok(hitWork and hitWork.kind == "work", "点第一颗控件命中的是它自己，不是还原带")

  -- 输入行：小窗也要把正文画出来（原生 Entry 只当输入点，正文全靠画布）
  p.input = ""
  local gHint = fakeGC(360, 56)
  p:_paint(gHint)
  ok(drewText(gHint, i18n.t("smallHint")), "空输入时小窗画提示语：" .. tostring(i18n.t("smallHint")))

  p.input = "画个红苹果"
  local gType = fakeGC(360, 56)
  p:_paint(gType)
  ok(drewText(gType, "画个红苹果"), "最小化后打进去的字看得见（这是 gaps.md #2）")
  local caret = nil
  for _, rc in ipairs(gType.rects) do if rc.width == 5 then caret = rc end end
  ok(caret ~= nil, "小窗里有光标")
  if caret then
    local inputY = caret.y
    local statusY = 2
    ok(inputY > statusY, "光标在状态行下面（不在同一行）：" .. inputY)
    ok(inputY + caret.height <= 56, "光标没画到画布外")
  end

  -- 点输入行 = 把焦点给输入框（不是触发还原）
  local hitsBefore = #p.barHit
  p.dlg = { modify = function() end, repaint = function() end }
  p.shown = true
  p.inputFocused = false
  local focused = false
  p.dlg.modify = function(_, t) if t and t.focus then focused = true end end
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = 200, y = 50 }
  ok(focused, "点小窗的输入行 -> 焦点回到输入框（可以接着打字）")
  ok(p:layoutMode() == "small", "点输入行不会把窗口还原掉，实际 " .. p:layoutMode())
  ok(hitsBefore > 0, "（前置：上一帧确实登记过命中区）")

  -- 点还原按钮（控件行末尾那颗）-> 回到面板
  local smallHit
  for _, b in ipairs(p.barHit) do if b.kind == "small" then smallHit = b end end
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = smallHit.x + 2, y = smallHit.y + 2 }
  ok(p:layoutMode() == "panel", "小窗 -> 还原到面板，实际 " .. p:layoutMode())

  -- 从底边栏最小化，还原要回到底边栏（不是面板）
  p:setMode("bar_bottom", true)
  p:toggleSmall()
  ok(p:layoutMode() == "small" and p.lastMode == "bar_bottom", "从底边栏最小化并记住来处")
  p:toggleSmall()
  ok(p:layoutMode() == "bar_bottom", "还原回底边栏，实际 " .. p:layoutMode())

  -- 点状态行（上半部分）也能还原
  p:toggleSmall()
  p.dlg = { modify = function() end, repaint = function() end }
  p.shown = true
  local g2 = fakeGC(360, 56)
  p:_paint(g2)
  local restore
  for _, b in ipairs(p.barHit) do if b.kind == "restore" then restore = b end end
  p:_onCanvasMouseDown{ button = MouseButton.LEFT, x = restore.x + 10, y = restore.y + 3 }
  ok(p:layoutMode() == "bar_bottom", "点状态行还原到底边栏，实际 " .. p:layoutMode())

  -- 极小的小窗也不能变成死胡同：至少要能点回还原
  local q = panel.new{ frameImage = function() return nil end }
  q:setMode("small", true)
  local g3 = fakeGC(120, 30)
  q:_paint(g3)
  local hasRestore = false
  for _, b in ipairs(q.barHit) do
    if b.kind == "small" or b.kind == "restore" then hasRestore = true end
  end
  ok(hasRestore, "窗口窄到 120 也还能点回还原（不是死胡同）")
  -- 窄到没有控件位置时，输入行也还得画（否则最小化 = 打字看不见）
  q.input = "hi"
  local g4 = fakeGC(120, 30)
  q:_paint(g4)
  ok(drewText(g4, "hi"), "再窄的小窗也画出输入正文")
end

print("== 控件几何：方块等高、不超出自己的框和画布 ==")
do
  -- 所有方块同高（16），并且都在自己的 x..x+w 内
  local p = panel.new{ frameImage = function() return nil end }
  p:setMode("bar_bottom", true)
  p:setContext(8200, 16000)
  local gc = fakeGC(1000, 60)
  p:_paint(gc)
  local heights = {}
  for _, b in ipairs(p.barHit) do
    if b.kind ~= "restore" then heights[b.h] = true end
  end
  local n = 0
  for _ in pairs(heights) do n = n + 1 end
  ok(n == 1, "所有控件方块等高（16），实际出现 " .. n .. " 种高度")

  -- 相邻方块间距一致（对称感）+ 全部右对齐贴着 4px 边距
  local sorted = {}
  for _, b in ipairs(p.barHit) do sorted[#sorted + 1] = b end
  table.sort(sorted, function(a, b) return a.x < b.x end)
  local gaps = {}
  for i = 2, #sorted do gaps[#gaps + 1] = sorted[i].x - (sorted[i - 1].x + sorted[i - 1].w) end
  local uniform = true
  for _, g in ipairs(gaps) do if g ~= (gaps[1] or g) then uniform = false end end
  ok(uniform, "方块间距一致：" .. table.concat(gaps, ","))
  local right = sorted[#sorted].x + sorted[#sorted].w
  ok(right <= 1000 - 3, "最右边一个方块贴着右边距（右缘 = " .. right .. "，画布 1000）")

  -- 中文标签实测宽度要算进预算（以前按 48 硬编码，中文溢出 40px）
  local zh = panel.new{ frameImage = function() return nil end }
  i18n._resetLang()
  zh:setContext(8200, 16000)
  local gc2 = fakeGC(1000, 60)
  local planZh = zh:_clusterPlan(gc2, 1000, 130)
  local planNo = zh:_clusterPlan(gc2, 1000, 130)
  ok(planZh ~= nil and planZh.w > 0, "计划宽度算出来了：" .. (planZh and planZh.w or -1))
  -- 带标签的计划，其宽度必须 >= 实测标签宽 + 20 格宽度
  local cellsW = 20 * (3 + 1) - 1
  ok(planZh.w >= cellsW, "预算至少覆盖 20 格电池：" .. planZh.w .. " >= " .. cellsW)
end

print("== 栏内控件：侧边栏也要画（竖着摆）==")
do
  local p = panel.new{ frameImage = function() return fakeFrameImage() end }
  p:setMode("bar_side", true)
  p:setContext(4000, 16000)
  local gc = fakeGC(320, 420)
  p:_paint(gc)
  local kinds = {}
  for _, b in ipairs(p.barHit) do kinds[b.kind] = true end
  ok(kinds.work and kinds.open and kinds.ctx and kinds.think,
    "侧边栏里也有四个命中区")
  -- 每个控件都必须落在画布内，否则用户点不到
  local outside = {}
  for _, b in ipairs(p.barHit) do
    if b.x < 0 or b.y < 0 or b.x + b.w > 320 or b.y + b.h > 420 then
      outside[#outside + 1] = b.kind .. "(" .. b.x .. "," .. b.y .. ")"
    end
  end
  ok(#outside == 0, "侧边栏里控件都在画布内，越界的：" .. table.concat(outside, " "))
  -- 控件不能再占独立的一块地方：都在最后一行（输入行）里
  local rows = tonumber(tostring(p.dbg):match("rows=(%d+)")) or 0
  ok(rows >= 3, "侧边栏还有 3 行文本空间，实际 " .. rows)
  local bandTop = math.floor(420 - 18 * 1.5)
  local offRow = {}
  for _, b in ipairs(p.barHit) do
    if b.y < bandTop then offRow[#offRow + 1] = b.kind end
  end
  ok(#offRow == 0, "控件都在输入行里（没另占一块），跑到上面的：" .. table.concat(offRow, " "))

  local q = panel.new{ frameImage = function() return nil end }
  q:setMode("bar_bottom", true)
  local g3 = fakeGC(1000, 60)
  q:_paint(g3)
  local bad = {}
  for _, b in ipairs(q.barHit) do
    if b.x < 0 or b.y < 0 or b.x + b.w > 1000 or b.y + b.h > 60 then
      bad[#bad + 1] = b.kind
    end
  end
  ok(#bad == 0, "底边栏里控件都在画布内，越界的：" .. table.concat(bad, " "))
end

print("== 多对话（v0.5.8）：内建词 / 对话表 / 待输入参数 / 回放 ==")
do
  -- 中英都能敲，而且不能撞上别的命令
  ok(i18n.builtinAction("chats") == "conversations", "chats -> conversations")
  ok(i18n.builtinAction("conversations") == "conversations", "conversations -> conversations")
  ok(i18n.builtinAction("会话") == "conversations", "「会话」-> conversations")
  ok(i18n.builtinAction("对话表") == "conversations", "「对话表」-> conversations")
  ok(i18n.builtinAction("新对话") == "conversation_new", "「新对话」-> conversation_new")
  ok(i18n.builtinAction("newchat") == "conversation_new", "newchat -> conversation_new")
  ok(i18n.builtinAction("改名") == "conversation_rename", "「改名」-> conversation_rename")
  ok(i18n.builtinAction("删对话") == "conversation_delete", "「删对话」-> conversation_delete")
  ok(i18n.builtinAction("清空") == "clear", "「清空」还是清屏（没被抢走）")
  ok(i18n.builtinAction("清空上下文") == "reset_history", "「清空上下文」还是 reset_history")
  ok(i18n.builtinAction("history") == "versions", "history 还是版本栈（没被对话抢走）")

  -- 命令表里有对话这一行，键位不和别的撞
  local keys, ids = {}, {}
  for _, r in ipairs(i18n.menuCommands()) do
    keys[#keys + 1] = tostring(r.keys)
    ids[r.id] = true
  end
  ok(ids.conversations, "命令表里有 conversations 行")
  local seen, dup = {}, {}
  for _, k in ipairs(keys) do
    if seen[k] then dup[#dup + 1] = k end
    seen[k] = true
  end
  ok(#dup == 0, "键位没撞车，重复的：" .. table.concat(dup, ","))

  -- 对话表：走的是命令表那套交互（编号 / 点行 / 悬浮）
  local p = panel.new{ frameImage = function() return nil end }
  local picked = {}
  p.opts.onAction = function(id, arg) picked[#picked + 1] = { id = id, arg = arg } end
  local rows = {
    { id = "conv:1", keys = "", label = "外壳配色", note = "12 条 / 3.4k ← 当前" },
    { id = "conv:2", keys = "", label = "图标方案", note = "4 条 / 0.9k" },
    { id = "conversation_new", keys = "n", label = "新对话", note = "干净的一页" },
    { id = "conversation_rename", keys = "r", label = "改名当前对话", note = "下一行输入就是新名字" },
    { id = "conversation_delete", keys = "d", label = "删除当前对话", note = "移进回收站" },
  }
  p:openTable(rows, "对话表   --   敲编号切换", "conv")
  ok(p:menuIsOpen(), "打开对话表后进入可选状态")
  ok(#p.menuRows == 5, "五行都在，实际 " .. #p.menuRows)

  p:fillInput("2")
  p:_submit()
  ok(#picked == 1 and picked[1].id == "conv:2", "敲编号 2 -> conv:2，实际 " ..
    tostring(picked[1] and picked[1].id))

  p:fillInput("n")
  p:_submit()
  ok(picked[#picked].id == "conversation_new", "敲字母 n -> 新对话，实际 " .. tostring(picked[#picked].id))

  -- 重打的是对话表，不是命令表（以前写死重打命令表，这里会串）
  local sawConvTitle = false
  for _, l in ipairs(p.lines) do
    if tostring(l.text):find("对话表", 1, true) then sawConvTitle = true end
  end
  ok(sawConvTitle, "重打的还是对话表")
  local sawMenuTitle = false
  for _, l in ipairs(p.lines) do
    if tostring(l.text):find(i18n.t("menuTitle"), 1, true) then sawMenuTitle = true end
  end
  ok(not sawMenuTitle, "没有把命令表顶上来")

  -- 待输入参数：只吃下一行，不当命令也不当聊天
  local p2 = panel.new{ frameImage = function() return nil end }
  local got, chats = {}, {}
  p2.opts.onAction = function(id, arg) got[#got + 1] = { id = id, arg = arg } end
  p2.opts.onSend = function(text) chats[#chats + 1] = text end
  p2:setPendingInput("conversation_rename", i18n.t("convRenameAsk"), function(t) return t ~= "x" end)
  p2:fillInput("外壳配色")
  p2:_submit()
  ok(#got == 1 and got[1].id == "conversation_rename" and got[1].arg == "外壳配色",
    "下一行输入成了参数：" .. tostring(got[1] and got[1].arg))
  ok(#chats == 0, "没被当成聊天发出去")
  ok(p2.pendingInput == nil, "用完就清掉")
  p2:fillInput("普通一句话")
  p2:_submit()
  ok(#chats == 1 and #got == 1, "第二行恢复成正常聊天")

  -- 取消：accept 返回 false
  p2:setPendingInput("conversation_delete", i18n.t("convDeleteAsk"), function(t) return t == "确认" end)
  p2:fillInput("算了")
  p2:_submit()
  ok(#got == 1, "取消时不该发动作")
  local sawCancel = false
  for _, l in ipairs(p2.lines) do
    if l.text == i18n.t("convCancelled") then sawCancel = true end
  end
  ok(sawCancel, "取消要提示一句")
  p2:setPendingInput("conversation_delete", i18n.t("convDeleteAsk"), function(t) return t == "确认" end)
  p2:fillInput("确认")
  p2:_submit()
  ok(got[#got].id == "conversation_delete", "确认后才真的发删除")

  -- 回放：替换（不是追加），带 kind，带表头
  local p3 = panel.new{ frameImage = function() return nil end }
  p3:log("先有一行旧的", "info")
  p3:replayLines({
    { kind = "user", text = "画个苹果" },
    { kind = "tool", text = "已画 128 像素" },
    { kind = "ai", text = "画好了" },
    { kind = "info", text = "Bridge ready.", i18n = "ctxRestored" },
  }, 7)
  local stale = false
  local kinds = {}
  for _, l in ipairs(p3.lines) do
    if l.text == "先有一行旧的" then stale = true end
    kinds[l.kind] = (kinds[l.kind] or 0) + 1
  end
  ok(not stale, "回放是替换：旧行不在了")
  ok(#p3.lines == 5, "表头 + 四行 = 5 行，实际 " .. #p3.lines)
  ok(kinds.user == 1 and kinds.tool == 1 and kinds.ai == 1, "回放保留了 kind（颜色）")
  local head = tostring(p3.lines[1].text)
  ok(head:find("恢复", 1, true) ~= nil and head:find("7", 1, true) ~= nil, "表头写了行数和更早的条数：" .. head)
  local localized = false
  for _, l in ipairs(p3.lines) do
    if l.text == i18n.t("ctxRestored") then localized = true end
  end
  ok(localized, "带 i18n 键的行按本地化文案渲染")

  -- 带 %d 的文案（"超时 180 秒"）：回放时数字要填回去，不能留着 %d
  local p3b = panel.new{ frameImage = function() return nil end }
  p3b:replayLines({
    { kind = "warn", text = "raw", i18n = "llmTimeout", i18nArgs = { 180 } },
    { kind = "info", text = "raw2", i18n = "abortTimeout", i18nArgs = { 600 } },
  }, 0)
  local saw180, saw600, sawRaw = false, false, false
  for _, l in ipairs(p3b.lines) do
    local s = tostring(l.text)
    if s:find("180", 1, true) then saw180 = true end
    if s:find("600", 1, true) then saw600 = true end
    if s == "raw" or s == "raw2" then sawRaw = true end
  end
  ok(saw180 and saw600, "回放把 i18nArgs 填进了文案（180 / 600 秒）")
  ok(not sawRaw, "带 i18n 键时不用桥发来的英文原文")

  -- 参数缺失也不能把整行弄没（宁可少个数字，也不要留下 %d）
  local p3c = panel.new{ frameImage = function() return nil end }
  p3c:replayLines({ { kind = "info", text = "fallback", i18n = "llmTimeout" } }, 0)
  local noPlaceholder = true
  for _, l in ipairs(p3c.lines) do
    if tostring(l.text):find("%%d", 1, false) then noPlaceholder = false end
  end
  ok(#p3c.lines == 2 and noPlaceholder, "缺 i18nArgs 时不留 %d 占位符")

  -- i18n.render 的退化路径（面板和 agent 都靠它）
  ok(i18n.render("llmTimeout", { 30 }, "fb"):find("30", 1, true) ~= nil, "render 填参数")
  ok(i18n.render("no_such_key_xyz", { 1 }, "fb") == "fb", "render 认不出键 -> 退回 fallback")
  ok(i18n.render("aborted", nil, "fb") == i18n.t("aborted"), "render 没有参数（文案也没占位符）-> 直接用文案")
  ok(i18n.render("llmTimeout", nil, "fb") == "fb",
    "render 有占位符却没实参 -> 退回桥的原文，不留 %d")

  -- 空记录也要说一句，不能是一片空白
  local p4 = panel.new{ frameImage = function() return nil end }
  p4:replayLines({}, 0)
  ok(#p4.lines == 1 and p4.lines[1].text == i18n.t("replayNone"), "没有记录时提示一句")

  -- 面板本地产的行要告诉桥（记进回放），桥来的行不转发（否则记两遍）
  local p5 = panel.new{ frameImage = function() return nil end }
  local forwarded = {}
  p5.opts.onLog = function(kind, text) forwarded[#forwarded + 1] = { kind = kind, text = text } end
  p5:log("形态已切换到 底边栏", "info")
  ok(#forwarded == 1 and forwarded[1].text == "形态已切换到 底边栏", "本地产的行转给了桥")
  p5:log("桥发来的一行", "ai", { fromBridge = true })
  ok(#forwarded == 1, "桥来的行不转发")
  p5:echo("用户敲的")
  ok(#forwarded == 1, "回显（用户那行）不转发 —— 桥自己会记")

  -- token 短标签（对话表里用）
  ok(panel.shortTokens(3400) == "3.4k", "3400 -> 3.4k，实际 " .. panel.shortTokens(3400))
  ok(panel.shortTokens(2000) == "2k", "2000 -> 2k")
  ok(panel.shortTokens(950) == "950", "950 -> 950")
end

print(string.format("%d passed, %d failed", pass, fail))
