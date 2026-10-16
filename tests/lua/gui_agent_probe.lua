-- tests/lua/gui_agent_probe.lua -- 整条加载链的 GUI 冒烟（v0.5.0）
--
-- 直接 require("lib.agent") 再 open()，跑的是 main.lua init 里同一串 require。
-- 目的：确认新增的 workspace.lua / 形态切换 / 状态转圈在**真 GUI** 下不会在加载
-- 或首帧绘制时炸掉（无头模式测不到 repaint / Timer / Dialog 那几条路径）。
-- 没有桥在跑也没关系：连不上只会留下一条"正在连接"的状态。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local OUT = os.getenv("ASE_PROBE_OUT")
if not OUT or OUT == "" then OUT = "gui_agent_probe.out" end

local writeErr = nil
local function say(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  line = "[agent-probe] " .. line
  pcall(print, line)
  local ok, err = pcall(function()
    local f, oerr = io.open(OUT, "a")
    if not f then error(tostring(oerr)) end
    f:write(line .. "\n")
    f:close()
  end)
  if not ok then writeErr = tostring(err) end
end

local function step(label, fn)
  local ok, err = pcall(fn)
  say("%-40s ok=%s%s", label, tostring(ok), ok and "" or ("  ERR: " .. tostring(err)))
  return ok
end

say("PROBE START")
local i18nMod = require("lib.i18n")
local function i18n_t(k) return i18nMod.t(k) end
local agent
step("require(lib.agent)", function()
  agent = require("lib.agent")
  assert(type(agent) == "table", "agent module")
end)
if not agent then say("PROBE EXIT") return end

local a
-- 注意：默认不连桥。connect() 会调 WebSocket{}，而 Aseprite 会为
-- **lib/ws.lua** 弹一个原生的 Security 模态框（"wants to open a WebSocket
-- connection to ..."），没人点它就卡住 —— 那是本体机制，探针绕不过去。
-- 所以这里手动走 open() 里除了 connect() 之外的部分（语言/提示/显示/首屏日志）。
step("agent.new + 面板初始化（不连桥）", function()
  a = agent.new{ port = 8799 }
  a:initLanguage()
  a.panel.opts.menuCommands = function() return a:menuCommands() end
  a.panel:setHint(i18n_t("hint"))
  a.panel:show()
  a.panel:log(i18n_t("ready"), "info")
  a.panel:log(i18n_t("tipMenu"), "info")
end)
if not a then say("PROBE EXIT") return end

step("面板真的建起来了", function()
  assert(a.panel, "panel")
  assert(a.panel.dlg, "dlg")
  assert(a.panel.shown, "shown")
end)
step("状态栏带上了文件名", function()
  assert(a.panel.docName ~= nil, "docName")
  say("    docName=%s status=%s", tostring(a.panel.docName), tostring(a.panel.status))
end)
step("设成忙 -> 转圈表在跑", function()
  a.panel:setStatus("thinking...", "busy", "probe.ase")
  assert(a.panel.spinTimer and a.panel.spinTimer.isRunning, "spinTimer running")
end)
step("G5 栏底色可配置", function()
  assert(a.panel:setBarColor("#2B2B2B"), "认得 #2B2B2B")
end)
step("切底边栏（真窗口改尺寸）", function()
  a.panel:setMode("bar_bottom")
  local b = a.panel.dlg.bounds
  say("    底边栏 bounds=%dx%d（G2 之后要够 3 行）", b.width, b.height)
  assert(b.width > 300 and b.height >= 3 * 18, "bar shape 至少 3 行高")
end)
step("底边栏真的画出了第 3 行（最后一条输出）", function()
  a.panel:log("已画 128 像素（16x16），图层 主体", "tool")
  local rows = tonumber(tostring(a.panel.dbg):match("rows=(%d+)"))
  say("    实际行数 = %s", tostring(rows))
  assert(rows == nil or rows >= 3, "3 行")
end)
step("切侧边栏", function()
  a.panel:setMode("bar_side")
  local b = a.panel.dlg.bounds
  say("    侧边栏 bounds=%dx%d", b.width, b.height)
  assert(b.width < 400 and b.height > 380, "side shape")
end)
step("切回面板", function()
  a.panel:setMode("panel")
  local b = a.panel.dlg.bounds
  say("    面板 bounds=%dx%d", b.width, b.height)
end)
step("选项窗（P7）弹出+关闭", function()
  a:askUser{ id = 1, question = "这是探针的选项窗：选哪个？", options = { "选项一", "选项二", "选项三" } }
  assert(a.panel:askDialogIsOpen(), "ask dialog open")
  a:answerAsk(2)
  assert(not a.panel:askDialogIsOpen(), "ask dialog closed")
end)
step("交付窗（P10）弹出+取消", function()
  a.workspace:setRoot("D:/tmp/probe-ws")
  a.workspace.managed = { original = "D:/a/o.ase", copy = "D:/a/c.ase", backup = "D:/b/x.ase" }
  a:deliver()
  assert(a.panel:askDialogIsOpen(), "deliver dialog open")
  a.panel:_closeAskDialog()
  a.workspace:clearManaged()
  a.workspace:setRoot("")
end)
step("停掉转圈 -> 就绪", function()
  a.panel:setStatus("ready", "ok", "probe.ase")
  assert(not a.panel.spinTimer.isRunning, "spin stopped")
end)
-- v0.5.3 栏内控件：真 GUI 里画一次（无头测试用的是假 GC，画不画得出来得在这儿证明）
step("栏内控件：上下文电量条 + 思考强度滑杆 + 工作图片", function()
  a.panel:setMode("bar_bottom")
  a.panel:setContext(6000, 16000)
  a.panel:setThinking("medium")
  a.panel.dlg:repaint()
  local kinds = {}
  for _, h in ipairs(a.panel.barHit or {}) do kinds[h.kind] = true end
  say("    命中区 = %s（已用 %s 格）",
    tostring(kinds.work) .. "/" .. tostring(kinds.open) .. "/" .. tostring(kinds.ctx) .. "/" .. tostring(kinds.think),
    tostring(a.panel:ctxFilled()))
  assert(kinds.work and kinds.open and kinds.ctx and kinds.think, "四个控件都画出来了")
  assert(a.panel:ctxFilled() == 8, "6000/16000 ≈ 8 格，实际 " .. a.panel:ctxFilled())
  assert(a.panel.thinkTrack ~= nil, "滑杆轨道记下来了")
end)
step("栏内控件：真缩略图（走真 sprite 合成 + 真 Canvas 绘制）", function()
  -- 探针里原来没有文档，先造一张（不然缩略图本来就该是空的）
  if not app.activeSprite then
    local spr = Sprite(16, 16, ColorMode.RGB)
    local cel = spr:newCel(spr.layers[1], 1, Image(16, 16, ColorMode.RGB), Point(0, 0))
    cel.image:clear(Rectangle(0, 0, 16, 16), Color(46, 134, 222))
    cel.image:clear(Rectangle(4, 4, 8, 8), Color(255, 224, 189))
    app.activeSprite = spr
  end
  local thumb = a.panel:thumbImage(40, 40)
  say("    缩略图 = %s", thumb and (thumb.width .. "x" .. thumb.height) or "nil")
  assert(thumb ~= nil, "缩略图不为空（frameImage 合成成功）")
  assert(thumb.width > 0 and thumb.height > 0, "尺寸合理")
  assert(thumb.bytesPerPixel == 4, "RGBA 4 字节")
  -- 采到的得是画布上真实的颜色：中心是奶油色 #FFE0BD，角落是蓝 #2E86DE
  -- getPixel 的打包是 0xAABBGGRR（蓝在低字节，别按 RGB 直觉写）
  local mid = thumb:getPixel(math.floor(thumb.width / 2), math.floor(thumb.height / 2))
  local corner = thumb:getPixel(1, 1)
  say("    中心 = 0x%08X 角落 = 0x%08X", mid, corner)
  assert(mid == 0xFFBDE0FF, "中心是奶油色（期望 0xFFBDE0FF），实际 " .. string.format("0x%08X", mid))
  assert(corner == 0xFFDE862E, "角落是蓝色（期望 0xFFDE862E），实际 " .. string.format("0x%08X", corner))
  -- 真的画一次：drawImage 打到真 Canvas 上不报错才算数
  a.panel.dlg:repaint()
end)
step("栏内控件：点滑杆真的改档（真鼠标事件路径）", function()
  local t = a.panel.thinkTrack
  a.panel:_onCanvasMouseDown{ button = MouseButton.LEFT, x = t.x + t.w - 1, y = t.y + 4 }
  say("    点最右后 thinking = %s", tostring(a.panel.thinking))
  assert(a.panel.thinking == "high", "点最右 = high，实际 " .. tostring(a.panel.thinking))
  a.panel:setThinking("auto")      -- 还原，别把探针状态留脏
end)

step("三种形态都要有控件（用户报的 bug：切形态就少东西）", function()
  local missing = {}
  for _, m in ipairs({ "panel", "bar_bottom", "bar_side", "small" }) do
    a.panel:setMode(m, true)
    if m == "panel" then
      a.panel:setContext(5000, 16000)
      a.panel:setThinking("medium")
    end
    a.panel.dlg:repaint()
    local kinds = {}
    for _, h in ipairs(a.panel.barHit or {}) do kinds[h.kind] = true end
    say("    %s -> %s", m, (kinds.work and "图" or "-") .. (kinds.open and "＋" or "-")
      .. (kinds.ctx and "电量" or "-") .. (kinds.think and "滑杆" or "-") .. (kinds.dock and "贴边" or "-"))
    if not (kinds.work and kinds.ctx and kinds.think and kinds.dock and kinds.small) then
      missing[#missing + 1] = m
    end
  end
  assert(#missing == 0, "这些形态缺控件：" .. table.concat(missing, ","))
end)
step("贴边按钮：点一下真的切形态", function()
  a.panel:setMode("bar_bottom", true)
  a.panel.dlg:repaint()
  local dock
  for _, h in ipairs(a.panel.barHit or {}) do if h.kind == "dock" then dock = h end end
  assert(dock, "找得到贴边按钮")
  a.panel:_onCanvasMouseDown{ button = MouseButton.LEFT, x = dock.x + 2, y = dock.y + 2 }
  local b = a.panel.dlg.bounds
  say("    点后形态 = %s bounds=%dx%d", a.panel:layoutMode(), b.width, b.height)
  assert(a.panel:layoutMode() == "bar_side", "贴底 -> 贴侧边，实际 " .. a.panel:layoutMode())
  a.panel.dlg:repaint()
  local dock2
  for _, h in ipairs(a.panel.barHit or {}) do if h.kind == "dock" then dock2 = h end end
  a.panel:_onCanvasMouseDown{ button = MouseButton.LEFT, x = dock2.x + 2, y = dock2.y + 2 }
  assert(a.panel:layoutMode() == "bar_bottom", "贴侧边 -> 贴底，实际 " .. a.panel:layoutMode())
end)

step("控件几何：真字体下也不越框（等高 / 等间距 / 不出画布）", function()
  for _, m in ipairs({ "bar_bottom", "bar_side", "small", "panel" }) do
    a.panel:setMode(m, true)
    a.panel:setContext(8200, 16000)
    a.panel:setThinking("high")
    a.panel.dlg:repaint()
    local cw = a.panel.canvasW or 0
    local ch = a.panel.canvasH or 0
    local hs, bad, sorted = {}, {}, {}
    for _, h in ipairs(a.panel.barHit or {}) do
      if h.x < 0 or h.y < 0 or h.x + h.w > cw or h.y + h.h > ch then
        bad[#bad + 1] = h.kind
      end
      if h.kind ~= "restore" then      -- 小窗里"点状态行还原"是整行命中带，不算方块
        hs[h.h] = (hs[h.h] or 0) + 1
        sorted[#sorted + 1] = h
      end
    end
    local nH = 0
    for _ in pairs(hs) do nH = nH + 1 end
    table.sort(sorted, function(x, y) return x.x < y.x end)
    local gaps, uniform = {}, true
    for i = 2, #sorted do
      gaps[#gaps + 1] = sorted[i].x - (sorted[i - 1].x + sorted[i - 1].w)
    end
    for _, g in ipairs(gaps) do if g ~= gaps[1] then uniform = false end end
    say("    %s: 画布=%dx%d 方块高度种类=%d 间距=%s 越框=%s", m, cw, ch, nH,
      table.concat(gaps, ","), (table.concat(bad, ",") ~= "" and table.concat(bad, ",") or "无"))
    assert(#bad == 0, m .. " 有控件越过画布：" .. table.concat(bad, ","))
    assert(nH <= 1, m .. " 方块高度不齐（" .. nH .. " 种）")
    assert(uniform, m .. " 方块间距不一致：" .. table.concat(gaps, ","))
  end
end)
step("回放：喂一条 replay，真面板真的把记录画出来", function()
  -- 关掉面板 / 重启 Aseprite 之后"它还记得"就靠这条：桥把记录推回来，面板重画。
  -- 这里喂一条合成的 replay，验证真 GUI 下渲染不炸、行数与颜色都对。
  local before = #a.panel.lines
  a:onMessage{ type = "replay", id = "c-probe", title = "探针对话", count = 1, more = 2,
    lines = {
      { kind = "user", text = "把外壳换成蓝色" },
      { kind = "tool", text = "已画 128 像素（16x16）" },
      { kind = "ai", text = "换好了。" },
    } }
  a.panel.dlg:repaint()
  local n = #a.panel.lines
  say("    回放前 %d 行 -> 回放后 %d 行", before, n)
  assert(n == 4, "表头 + 三行 = 4 行，实际 " .. n)
  assert(a.panel.lines[1].kind == "info" and a.panel.lines[2].kind == "user", "kind 传到了绘制层")
  assert(a.panel.lines[3].kind == "tool" and a.panel.lines[4].kind == "ai", "工具行和 AI 行都在")

  -- 对话表：真 GUI 下开一次，确认表格行渲染出来
  a:onMessage{ type = "conversations_result", id = 1, active = "c-1",
    items = {
      { id = "c-1", title = "探针对话", messages = 12, tokens = 3400, active = true },
      { id = "c-2", title = "另一个", messages = 4, tokens = 900, active = false },
    } }
  a.panel.dlg:repaint()
  assert(a.panel:menuIsOpen(), "对话表开着")
  assert(#a.panel.menuRows == 5, "两行对话 + 三行操作，实际 " .. #a.panel.menuRows)
  say("    对话表 %d 行，首行 id=%s", #a.panel.menuRows, tostring(a.panel.menuRows[1].id))
  -- 收尾：关掉表，别把状态留给后面的步骤
  a.panel.menuOpen = false
end)
step("最小化：真窗口真的变小，还原后回原形态", function()
  a.panel:setMode("bar_bottom", true)
  a.panel.dlg:repaint()
  local before = a.panel.dlg.bounds
  a.panel:toggleSmall()
  local sb = a.panel.dlg.bounds
  say("    小窗 bounds=%dx%d（底边栏是 %dx%d）", sb.width, sb.height, before.width, before.height)
  assert(sb.height < before.height, "小窗比底边栏矮")
  a.panel.dlg:repaint()
  local kinds = {}
  for _, h in ipairs(a.panel.barHit or {}) do kinds[h.kind] = true end
  say("    小窗里的控件：%s%s%s%s%s", kinds.work and "图" or "-", kinds.ctx and "电量" or "-",
    kinds.think and "滑杆" or "-", kinds.dock and "贴边" or "-", kinds.small and "还原" or "-")
  assert(kinds.work and kinds.ctx and kinds.think and kinds.small, "小窗里控件齐全")

  -- 小窗必须留出输入行（gaps.md #2）：原生 Entry 只当输入点，正文由画布画，
  -- 所以画布不留输入行 = 最小化后打字看不见。真字体下也要有地方放。
  local rowH = tonumber(tostring(a.panel.dbg):match("h=(%d+)")) or 0
  local lh = a.panel.lineH or 12
  say("    小窗画布 %dx%d lineH=%s", a.panel.canvasW or 0, rowH, tostring(lh))
  assert(rowH >= lh * 2 + 4, "小窗画布够高（状态行 + 输入行）：h=" .. rowH)

  -- 还原带不能压住控件：_barHitAt 取第一个命中，压住了控件就点不动
  local band, leftmost
  for _, h in ipairs(a.panel.barHit or {}) do
    if h.kind == "restore" then band = h
    elseif not leftmost or h.x < leftmost.x then leftmost = h end
  end
  assert(band and leftmost and band.x + band.w <= leftmost.x,
    "还原带在控件左边不重叠")

  -- 点还原按钮
  local s
  for _, h in ipairs(a.panel.barHit or {}) do if h.kind == "small" then s = h end end
  a.panel:_onCanvasMouseDown{ button = MouseButton.LEFT, x = s.x + 2, y = s.y + 2 }
  assert(a.panel:layoutMode() == "bar_bottom", "还原回底边栏，实际 " .. a.panel:layoutMode())
end)

-- 停在底边栏给外部截图（run_gui_agent.sh 在 ~4s 截），8 秒后自己关
step("停在底边栏等待截图", function()
  a.panel:setMode("bar_bottom")
  a.panel:setBarColor("#2B2B2B")
  a.panel:setStatus("running draw_art...", "tool", "hero.ase")
  a.panel:log("已画 128 像素（16x16），图层 主体", "tool")
  a.panel:log("现在这条栏上能看到状态 + 最后一行指令 + 输入行", "info")
end)
say("RESULT=DONE")
local t0
t0 = Timer{ interval = 8.0, ontick = function() t0:stop() end }
t0:start()
if writeErr then say("WRITE-ERR: %s", tostring(writeErr)) end

-- 留 6 秒给外部截图，然后退出
local t
t = Timer{ interval = 6.0, ontick = function() t:stop() end }
t:start()
say("PROBE EXIT")
