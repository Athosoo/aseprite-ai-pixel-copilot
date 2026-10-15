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
